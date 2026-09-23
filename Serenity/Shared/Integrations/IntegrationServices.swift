import Foundation
import GoogleSignIn
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum IntegrationServiceError: Error, LocalizedError {
  case missingGoogleConfiguration
  case missingGoogleSession
  case missingGooglePresenter
  case invalidResponse
  case unsupportedResponseStatus(Int, String)
  case missingGitHubToken
  case missingSlackConfiguration
  case missingSlackSession
  case missingSlackPresenter
  case slackAuthorizationCancelled
  case slackAPIError(String)

  var errorDescription: String? {
    switch self {
    case .missingGoogleConfiguration:
      return "Google Sign-In is not configured. Add GOOGLE_CLIENT_ID, GOOGLE_REVERSED_CLIENT_ID, and the matching URL scheme to the app configuration."
    case .missingGoogleSession:
      return "Google session is missing. Connect Google first."
    case .missingGooglePresenter:
      return "Serenity could not find a window or view controller to present Google Sign-In."
    case .invalidResponse:
      return "Integration service returned an invalid response."
    case .unsupportedResponseStatus(let status, let body):
      return "Integration request failed (\(status)): \(body)"
    case .missingGitHubToken:
      return "GitHub token is missing."
    case .missingSlackConfiguration:
      return "Slack is not configured. Add SLACK_CLIENT_ID to the app configuration."
    case .missingSlackSession:
      return "Slack session is missing. Connect Slack first."
    case .missingSlackPresenter:
      return "Serenity could not find a window to present Slack sign-in."
    case .slackAuthorizationCancelled:
      return "Slack sign-in was cancelled."
    case .slackAPIError(let code):
      return "Slack API returned an error: \(code)"
    }
  }
}

typealias IntegrationRequestHandler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

enum URLSessionIntegrationClient {
  static let shared: IntegrationRequestHandler = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw IntegrationServiceError.invalidResponse
    }
    return (data, httpResponse)
  }
}

@MainActor
final class GoogleIntegrationService {
  private let secretStore: KeychainSecretStore
  private let requestHandler: IntegrationRequestHandler
  private let sessionKey = "integrations.google.session"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    secretStore: KeychainSecretStore = KeychainSecretStore(service: "com.digitaltracer.serenity.integrations"),
    requestHandler: @escaping IntegrationRequestHandler = URLSessionIntegrationClient.shared
  ) {
    self.secretStore = secretStore
    self.requestHandler = requestHandler
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  var isConfigured: Bool {
    GoogleCalendarConfiguration.isConfigured
  }

  func connectWithToken(
    accessToken: String,
    refreshToken: String?,
    expiresAt: Date?,
    userEmail: String?
  ) async throws -> GoogleIntegrationSession {
    let session = GoogleIntegrationSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      userEmail: userEmail,
      connectedAt: Date()
    )
    try saveSession(session)
    return session
  }

  func restorePreviousSession() async -> GoogleIntegrationSession? {
    guard isConfigured else {
      return try? await currentSession()
    }

    configureGoogleSignInIfPossible()

    do {
      let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
      let session = try makeSession(from: user, preservingRefreshToken: try await currentSession()?.refreshToken)
      try saveSession(session)
      return session
    } catch {
      try? await disconnect()
      return nil
    }
  }

  func signIn() async throws -> GoogleIntegrationSession {
    AppLogger.info("GoogleSignIn.signIn invoked")
    AppLogger.info("GoogleSignIn.isConfigured=\(isConfigured) clientID=\(GoogleCalendarConfiguration.clientID ?? "nil") reversedClientID=\(GoogleCalendarConfiguration.reversedClientID ?? "nil")")

    guard isConfigured else {
      AppLogger.error("GoogleSignIn aborting: missingGoogleConfiguration")
      throw IntegrationServiceError.missingGoogleConfiguration
    }

    configureGoogleSignInIfPossible()

    #if os(macOS)
    let allWindows = NSApplication.shared.windows
    AppLogger.info("GoogleSignIn windows count=\(allWindows.count) keyWindow=\(NSApplication.shared.keyWindow?.title ?? "nil")")
    for (idx, win) in allWindows.enumerated() {
      AppLogger.info("GoogleSignIn window[\(idx)] title=\(win.title) isVisible=\(win.isVisible) isKey=\(win.isKeyWindow)")
    }

    guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else {
      AppLogger.error("GoogleSignIn aborting: missingGooglePresenter (no visible window)")
      throw IntegrationServiceError.missingGooglePresenter
    }

    AppLogger.info("GoogleSignIn presenting on window=\(window.title) — calling GIDSignIn.signIn(withPresenting:)")
    do {
      let result = try await GIDSignIn.sharedInstance.signIn(
        withPresenting: window,
        hint: nil,
        additionalScopes: GoogleCalendarConfiguration.requiredScopes
      )
      AppLogger.info("GoogleSignIn returned user=\(result.user.profile?.email ?? "unknown")")
      let session = try makeSession(from: result.user, preservingRefreshToken: try await currentSession()?.refreshToken)
      try saveSession(session)
      AppLogger.info("GoogleSignIn session saved")
      return session
    } catch {
      AppLogger.error("GoogleSignIn threw: \(error) — \(error.localizedDescription)")
      throw error
    }
    #elseif os(iOS)
    guard let presenter = Self.activePresentingViewController() else {
      throw IntegrationServiceError.missingGooglePresenter
    }

    let result = try await GIDSignIn.sharedInstance.signIn(
      withPresenting: presenter,
      hint: nil,
      additionalScopes: GoogleCalendarConfiguration.requiredScopes
    )
    let session = try makeSession(from: result.user, preservingRefreshToken: try await currentSession()?.refreshToken)
    try saveSession(session)
    return session
    #else
    throw IntegrationServiceError.missingGooglePresenter
    #endif
  }

  func currentSession() async throws -> GoogleIntegrationSession? {
    guard let raw = try secretStore.secret(for: sessionKey),
          let data = raw.data(using: .utf8)
    else {
      return nil
    }

    return try decoder.decode(GoogleIntegrationSession.self, from: data)
  }

  func disconnect() async throws {
    if GIDSignIn.sharedInstance.currentUser != nil {
      do {
        try await GIDSignIn.sharedInstance.disconnect()
      } catch {
        GIDSignIn.sharedInstance.signOut()
      }
    } else {
      GIDSignIn.sharedInstance.signOut()
    }

    try secretStore.deleteSecret(for: sessionKey)
  }

  func syncCalendarTasks(
    existingTasks: [TaskEntity],
    existingProjects: [ProjectEntity],
    rangeDays: Int = 7
  ) async throws -> GoogleCalendarSyncPayload {
    let session = try await activeSession()

    let now = Date()
    let endDate = Calendar.current.date(byAdding: .day, value: max(1, rangeDays), to: now) ?? now
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    var components = URLComponents(url: GoogleCalendarConfiguration.calendarEventsURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "singleEvents", value: "true"),
      URLQueryItem(name: "orderBy", value: "startTime"),
      URLQueryItem(name: "timeMin", value: formatter.string(from: now)),
      URLQueryItem(name: "timeMax", value: formatter.string(from: endDate)),
      URLQueryItem(name: "maxResults", value: "50"),
    ]

    guard let url = components?.url else {
      throw IntegrationServiceError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await requestHandler(request)
    guard 200..<300 ~= response.statusCode else {
      throw IntegrationServiceError.unsupportedResponseStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    let payload = try decoder.decode(GoogleCalendarEventsResponse.self, from: data)
    let project = existingProjects.first(where: { $0.name.lowercased() == "google calendar" && !$0.archived })
      ?? ProjectEntity(
        id: "google-calendar-project",
        name: "Google Calendar",
        description: "Synced calendar events",
        color: "#4285F4",
        icon: "calendar",
        createdAt: now,
        updatedAt: now,
        archived: false,
        userId: nil
      )

    let existingEventIDs = Set(
      existingTasks
        .flatMap(\.tags)
        .filter { $0.hasPrefix("google-event-") }
    )

    let importedTasks = payload.items.compactMap { event -> TaskEntity? in
      guard let eventID = event.id,
            let title = event.summary,
            !title.isEmpty
      else {
        return nil
      }

      let eventTag = "google-event-\(eventID)"
      if existingEventIDs.contains(eventTag) {
        return nil
      }

      let dueDate = event.start.parsedDate
      return TaskEntity(
        id: "google-event-\(eventID)",
        title: title,
        description: event.description,
        completed: event.status == "cancelled",
        completedAt: event.status == "cancelled" ? now : nil,
        priority: .medium,
        dueDate: dueDate,
        projectId: project.id,
        tags: ["google-calendar", eventTag],
        createdAt: now,
        updatedAt: now,
        subtasks: [],
        recurring: nil,
        userId: nil
      )
    }

    return GoogleCalendarSyncPayload(
      tasks: importedTasks,
      project: existingProjects.contains(where: { $0.id == project.id }) ? nil : project,
      importedCount: importedTasks.count
    )
  }

  private func fetchGoogleUserEmail(accessToken: String) async throws -> String? {
    var request = URLRequest(url: GoogleCalendarConfiguration.userInfoURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await requestHandler(request)
    guard 200..<300 ~= response.statusCode else {
      return nil
    }

    let profile = try decoder.decode(GoogleUserInfoResponse.self, from: data)
    return profile.email
  }

  private func activeSession() async throws -> GoogleIntegrationSession {
    if let currentUser = GIDSignIn.sharedInstance.currentUser {
      let refreshedUser = try await currentUser.refreshTokensIfNeeded()
      let session = try makeSession(from: refreshedUser, preservingRefreshToken: try await currentSession()?.refreshToken)
      try saveSession(session)
      return session
    }

    if let restored = await restorePreviousSession() {
      return restored
    }

    guard let session = try await currentSession() else {
      throw IntegrationServiceError.missingGoogleSession
    }
    return session
  }

  private func configureGoogleSignInIfPossible() {
    guard let clientID = GoogleCalendarConfiguration.clientID else {
      AppLogger.error("configureGoogleSignInIfPossible: clientID is nil — skipping")
      return
    }
    AppLogger.info("configureGoogleSignInIfPossible: setting clientID=\(clientID)")
    GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
  }

  private func makeSession(
    from user: GIDGoogleUser,
    preservingRefreshToken preservedRefreshToken: String?
  ) throws -> GoogleIntegrationSession {
    let accessToken = user.accessToken.tokenString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accessToken.isEmpty else {
      throw IntegrationServiceError.invalidResponse
    }

    return GoogleIntegrationSession(
      accessToken: accessToken,
      refreshToken: user.refreshToken.tokenString.nilIfBlank ?? preservedRefreshToken,
      expiresAt: user.accessToken.expirationDate,
      userEmail: user.profile?.email,
      connectedAt: Date()
    )
  }

  #if os(iOS)
  private static func activePresentingViewController() -> UIViewController? {
    let foregroundScene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    let root = foregroundScene?.windows.first { $0.isKeyWindow }?.rootViewController
      ?? foregroundScene?.windows.first?.rootViewController
    return topViewController(from: root)
  }

  private static func topViewController(from root: UIViewController?) -> UIViewController? {
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }
  #endif

  private func saveSession(_ session: GoogleIntegrationSession) throws {
    let data = try encoder.encode(session)
    guard let raw = String(data: data, encoding: .utf8) else {
      throw IntegrationServiceError.invalidResponse
    }

    try secretStore.setSecret(raw, for: sessionKey)
  }
}

/// One reviewer's standing verdict on a pull request. This is where "requested
/// changes" lives, which is most of the reason a pull request becomes a task.
struct GitHubReviewSummary: Equatable, Sendable {
  var reviewer: String
  var state: String
  var body: String?
  var submittedAt: Date?
  var isBot: Bool = false

  var requestsChanges: Bool { state.uppercased() == "CHANGES_REQUESTED" }
  var approves: Bool { state.uppercased() == "APPROVED" }
}

struct GitHubCommentSummary: Equatable, Sendable {
  var author: String
  var body: String
  var createdAt: Date?
  var isBot: Bool = false
}

/// A review bot posts a walkthrough on every pull request. Left indistinguishable
/// from a person, it crowds a human's one-line ask out of the prompt purely by
/// being longer — the same reason the Slack filter drops bot messages by default.
enum GitHubAuthor {
  static func isBot(login: String?, type: String?) -> Bool {
    guard let login else { return type?.caseInsensitiveCompare("Bot") == .orderedSame }
    return login.hasSuffix("[bot]") || type?.caseInsensitiveCompare("Bot") == .orderedSame
  }
}

/// Everything read from a pull request link, in the shape a draft needs. The
/// diff is deliberately absent: it is the most expensive thing to read and the
/// least useful for deciding what the work is.
struct GitHubPullSnapshot: Equatable, Sendable {
  /// The **issue** id, not the pull id. `syncGitHubPullRequests` tags with the
  /// search API's id, which is an issue id, so anything else would fail to
  /// collide with a task the sync already created — and silently duplicate it.
  var issueID: Int64
  var owner: String
  var repo: String
  var number: Int
  var title: String
  var body: String?
  var state: String
  var isPullRequest: Bool
  var isDraft: Bool
  var isMerged: Bool
  var labels: [String]
  var assignees: [String]
  var requestedReviewers: [String]
  var milestoneTitle: String?
  var milestoneDueOn: Date?
  var changedFileNames: [String]
  var changedFileCount: Int
  var reviews: [GitHubReviewSummary]
  var comments: [GitHubCommentSummary]
  var htmlURL: String
  var createdAt: Date?
  var updatedAt: Date?

  var slug: String { "\(owner)/\(repo)#\(number)" }

  /// The tag that links a task back to this pull request, matching the one the
  /// background sync writes.
  var originTag: String { "github-pr-\(issueID)" }
}

enum GitHubFetchError: Error, Equatable, LocalizedError {
  case noActiveToken
  case noAccess(String)
  case rateLimited

  var errorDescription: String? {
    switch self {
    case .noActiveToken:
      return "Add a GitHub token in Integrations first."
    case .noAccess(let slug):
      // GitHub answers 404 for a repository a token cannot see, exactly as it
      // does for one that is not there, so the message has to allow for both.
      return "No access to \(slug) — either it does not exist, or none of your GitHub tokens can reach it."
    case .rateLimited:
      return "GitHub's rate limit is spent. Try again in a few minutes."
    }
  }
}

actor GitHubIntegrationService {
  private let secretStore: KeychainSecretStore
  private let requestHandler: IntegrationRequestHandler
  private let tokensKey = "integrations.github.tokens"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    secretStore: KeychainSecretStore = KeychainSecretStore(service: "com.digitaltracer.serenity.integrations"),
    requestHandler: @escaping IntegrationRequestHandler = URLSessionIntegrationClient.shared
  ) {
    self.secretStore = secretStore
    self.requestHandler = requestHandler
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  func listTokens() throws -> [GitHubTokenRecord] {
    try loadTokens()
  }

  func addToken(_ token: String, displayName: String?) async throws -> [GitHubTokenRecord] {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw IntegrationServiceError.missingGitHubToken
    }

    let username = try await validateTokenAndFetchUsername(trimmed)
    var tokens = try loadTokens()

    let now = Date()
    let record = GitHubTokenRecord(
      id: UUID().uuidString,
      token: trimmed,
      displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? displayName! : "\(username) Token",
      username: username,
      isActive: true,
      createdAt: now,
      updatedAt: now,
      lastValidatedAt: now,
      lastSyncAt: nil
    )
    tokens.append(record)
    try saveTokens(tokens)
    return tokens
  }

  func removeToken(id: String) throws -> [GitHubTokenRecord] {
    var tokens = try loadTokens()
    tokens.removeAll { $0.id == id }
    try saveTokens(tokens)
    return tokens
  }

  func toggleTokenActive(id: String) throws -> [GitHubTokenRecord] {
    var tokens = try loadTokens()
    guard let index = tokens.firstIndex(where: { $0.id == id }) else {
      return tokens
    }

    tokens[index].isActive.toggle()
    tokens[index].updatedAt = Date()
    try saveTokens(tokens)
    return tokens
  }

  /// `alreadyImported` holds every pull request imported before, so one whose task was deleted
  /// stays deleted. A tracked pull request refreshes its task: the title follows it, and the task
  /// completes once the pull request is merged or closed.
  func syncGitHubPullRequests(
    existingTasks: [TaskEntity],
    existingProjects: [ProjectEntity],
    alreadyImported: Set<Int64> = [],
    lookbackDays: Int = 14
  ) async throws -> GitHubSyncPayload {
    var tokens = try loadTokens().filter(\.isActive)
    guard !tokens.isEmpty else {
      return GitHubSyncPayload(tasks: [], project: nil, importedCount: 0)
    }

    let now = Date()
    let lookbackDate = Calendar.current.date(byAdding: .day, value: -max(1, lookbackDays), to: now) ?? now
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let dateString = formatter.string(from: lookbackDate)

    let project = existingProjects.first(where: { $0.name.lowercased() == "github" && !$0.archived })
      ?? ProjectEntity(
        id: "github-project",
        name: "GitHub",
        description: "Synced pull requests and issues",
        color: "#333333",
        icon: "chevron.left.forwardslash.chevron.right",
        createdAt: now,
        updatedAt: now,
        archived: false,
        userId: nil
      )

    var trackedByTag: [String: TaskEntity] = [:]
    for task in existingTasks {
      for tag in task.tags where tag.hasPrefix("github-pr-") {
        trackedByTag[tag] = task
      }
    }

    var importedTasks: [TaskEntity] = []
    var refreshedTasks: [TaskEntity] = []
    var newlyImported: [Int64] = []
    var seenPRIDs: Set<Int64> = []

    for tokenIndex in tokens.indices {
      let tokenRecord = tokens[tokenIndex]
      let query = "is:pr author:\(tokenRecord.username) updated:>=\(dateString)"

      var components = URLComponents(string: "https://api.github.com/search/issues")
      components?.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "per_page", value: "50"),
        URLQueryItem(name: "sort", value: "updated"),
        URLQueryItem(name: "order", value: "desc"),
      ]

      guard let url = components?.url else {
        continue
      }

      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("Bearer \(tokenRecord.token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

      let (data, response) = try await requestHandler(request)
      guard 200..<300 ~= response.statusCode else {
        throw IntegrationServiceError.unsupportedResponseStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
      }

      let payload = try decoder.decode(GitHubIssueSearchResponse.self, from: data)
      for item in payload.items {
        if seenPRIDs.contains(item.id) {
          continue
        }
        seenPRIDs.insert(item.id)

        let tag = "github-pr-\(item.id)"
        let isOpen = item.state.lowercased() == "open"

        if var tracked = trackedByTag[tag] {
          var changed = false
          if tracked.title != item.title {
            tracked.title = item.title
            changed = true
          }
          if !isOpen, !tracked.completed {
            tracked.completed = true
            tracked.completedAt = now
            changed = true
          }
          if changed {
            tracked.updatedAt = now
            refreshedTasks.append(tracked)
          }
          continue
        }
        guard !alreadyImported.contains(item.id) else { continue }

        // No due date: a pull request has no deadline of its own, and "due now" made every one overdue.
        let task = TaskEntity(
          id: "github-pr-\(item.id)",
          title: item.title,
          description: [item.body ?? "", item.htmlURL].joined(separator: "\n\n"),
          completed: !isOpen,
          completedAt: isOpen ? nil : now,
          priority: .medium,
          dueDate: nil,
          projectId: project.id,
          tags: ["github", "pull-request", tag],
          createdAt: item.createdAt,
          updatedAt: now,
          subtasks: [],
          recurring: nil,
          userId: nil
        )
        importedTasks.append(task)
        newlyImported.append(item.id)
      }

      tokens[tokenIndex].lastSyncAt = now
      tokens[tokenIndex].updatedAt = now
    }

    try saveTokens(tokens)
    return GitHubSyncPayload(
      tasks: importedTasks + refreshedTasks,
      project: existingProjects.contains(where: { $0.id == project.id }) ? nil : project,
      importedCount: importedTasks.count,
      newlyImportedIDs: newlyImported
    )
  }


  /// A PR with eighty comments is mostly "LGTM" and resolved chatter; the
  /// prompt budget is better spent on the body and the review verdicts.
  static let commentLimit = 30
  static let fileNameLimit = 30

  /// Reads one pull request or issue named by a link. Four calls, all cheap
  /// against the 5000/hour authenticated budget, and none of them the diff.
  func fetchPullRequest(
    _ reference: GitHubPullReference,
    includeFiles: Bool = true
  ) async throws -> GitHubPullSnapshot {
    let tokens = try loadTokens().filter(\.isActive)
    guard !tokens.isEmpty else { throw GitHubFetchError.noActiveToken }

    // A repository a token cannot see answers 404, identically to one that does
    // not exist, so the only way to tell them apart is to try every token.
    var sawRateLimit = false

    for record in tokens {
      let issue: GitHubIssueDetail?
      do {
        issue = try await fetch(
          GitHubIssueDetail.self,
          path: "/repos/\(reference.owner)/\(reference.repo)/issues/\(reference.number)",
          token: record.token
        )
      } catch GitHubFetchError.rateLimited {
        sawRateLimit = true
        continue
      }

      guard let issue else { continue }
      return try await snapshot(for: reference, issue: issue, token: record.token, includeFiles: includeFiles)
    }

    throw sawRateLimit ? GitHubFetchError.rateLimited : GitHubFetchError.noAccess(reference.slug)
  }

  private func snapshot(
    for reference: GitHubPullReference,
    issue: GitHubIssueDetail,
    token: String,
    includeFiles: Bool
  ) async throws -> GitHubPullSnapshot {
    let base = "/repos/\(reference.owner)/\(reference.repo)"
    var pull: GitHubPullDetail?
    var reviews: [GitHubReviewSummary] = []
    var fileNames: [String] = []

    // An issue link has no pulls endpoint, and a pull request whose reviews are
    // unreadable is still worth drafting from.
    if reference.isPullRequest {
      pull = try await fetch(GitHubPullDetail.self, path: "\(base)/pulls/\(reference.number)", token: token)
      let raw = try await fetch(
        [GitHubReviewDetail].self,
        path: "\(base)/pulls/\(reference.number)/reviews",
        token: token,
        query: [URLQueryItem(name: "per_page", value: "100")]
      )
      reviews = Self.standingVerdicts(from: raw ?? [])

      if includeFiles {
        let files = try await fetch(
          [GitHubFileDetail].self,
          path: "\(base)/pulls/\(reference.number)/files",
          token: token,
          query: [URLQueryItem(name: "per_page", value: String(Self.fileNameLimit))]
        )
        fileNames = (files ?? []).map(\.filename)
      }
    }

    let comments = try await fetch(
      [GitHubCommentDetail].self,
      path: "\(base)/issues/\(reference.number)/comments",
      token: token,
      query: [URLQueryItem(name: "per_page", value: "100")]
    )

    return GitHubPullSnapshot(
      issueID: issue.id,
      owner: reference.owner,
      repo: reference.repo,
      number: reference.number,
      title: issue.title,
      body: issue.body?.nilIfBlank,
      state: issue.state,
      isPullRequest: reference.isPullRequest,
      isDraft: pull?.draft ?? false,
      isMerged: pull?.merged ?? false,
      labels: (issue.labels ?? []).map(\.name),
      assignees: (issue.assignees ?? []).map(\.login),
      requestedReviewers: (pull?.requestedReviewers ?? []).map(\.login),
      milestoneTitle: issue.milestone?.title,
      // The only real deadline a pull request has. Without it a drafted due date
      // would be a guess, and a guessed deadline is one the user learns to
      // delete.
      milestoneDueOn: issue.milestone?.dueOn,
      changedFileNames: fileNames,
      changedFileCount: pull?.changedFiles ?? fileNames.count,
      reviews: reviews,
      comments: Self.trailing(of: comments ?? [], limit: Self.commentLimit),
      htmlURL: issue.htmlURL,
      createdAt: issue.createdAt,
      updatedAt: issue.updatedAt
    )
  }

  /// GitHub's own review decision counts the latest *verdict* per reviewer, not
  /// the latest review: a reviewer who requested changes and then left a plain
  /// comment is still blocking.
  private static func standingVerdicts(from reviews: [GitHubReviewDetail]) -> [GitHubReviewSummary] {
    var byReviewer: [String: GitHubReviewSummary] = [:]

    for review in reviews {
      guard let reviewer = review.user?.login else { continue }
      let summary = GitHubReviewSummary(
        reviewer: reviewer,
        state: review.state,
        body: review.body?.nilIfBlank,
        submittedAt: review.submittedAt,
        isBot: GitHubAuthor.isBot(login: reviewer, type: review.user?.type)
      )

      guard let held = byReviewer[reviewer] else {
        byReviewer[reviewer] = summary
        continue
      }
      let heldIsVerdict = held.state.uppercased() != "COMMENTED"
      let newIsVerdict = summary.state.uppercased() != "COMMENTED"
      if newIsVerdict || !heldIsVerdict {
        byReviewer[reviewer] = summary
      }
    }

    return byReviewer.values.sorted { lhs, rhs in
      (lhs.submittedAt ?? .distantPast) < (rhs.submittedAt ?? .distantPast)
    }
  }

  private static func trailing(of comments: [GitHubCommentDetail], limit: Int) -> [GitHubCommentSummary] {
    comments
      .suffix(limit)
      .compactMap { comment in
        guard let body = comment.body?.nilIfBlank else { return nil }
        return GitHubCommentSummary(
          author: comment.user?.login ?? "someone",
          body: body,
          createdAt: comment.createdAt,
          isBot: GitHubAuthor.isBot(login: comment.user?.login, type: comment.user?.type)
        )
      }
  }

  /// Returns `nil` for anything the token cannot see, so the caller can move on
  /// to the next token or carry on without an optional part of the picture.
  private func fetch<T: Decodable>(
    _ type: T.Type,
    path: String,
    token: String,
    query: [URLQueryItem] = []
  ) async throws -> T? {
    var components = URLComponents(string: "https://api.github.com\(path)")
    if !query.isEmpty {
      components?.queryItems = query
    }
    guard let url = components?.url else {
      throw IntegrationServiceError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let (data, response) = try await requestHandler(request)

    // A spent rate limit and a permission problem share a status code; the
    // remaining-count header is the only thing that separates them.
    if response.statusCode == 403 || response.statusCode == 429 {
      guard response.value(forHTTPHeaderField: "x-ratelimit-remaining") != "0" else {
        throw GitHubFetchError.rateLimited
      }
      return nil
    }
    if response.statusCode == 401 || response.statusCode == 404 {
      return nil
    }
    guard 200..<300 ~= response.statusCode else {
      throw IntegrationServiceError.unsupportedResponseStatus(
        response.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    return try decoder.decode(T.self, from: data)
  }

  private func validateTokenAndFetchUsername(_ token: String) async throws -> String {
    var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let (data, response) = try await requestHandler(request)
    guard 200..<300 ~= response.statusCode else {
      throw IntegrationServiceError.unsupportedResponseStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    let payload = try decoder.decode(GitHubUserResponse.self, from: data)
    return payload.login
  }

  private func loadTokens() throws -> [GitHubTokenRecord] {
    guard let raw = try secretStore.secret(for: tokensKey),
          let data = raw.data(using: .utf8)
    else {
      return []
    }

    return try decoder.decode([GitHubTokenRecord].self, from: data)
  }

  private func saveTokens(_ tokens: [GitHubTokenRecord]) throws {
    let data = try encoder.encode(tokens)
    guard let raw = String(data: data, encoding: .utf8) else {
      throw IntegrationServiceError.invalidResponse
    }

    try secretStore.setSecret(raw, for: tokensKey)
  }
}

private struct GoogleUserInfoResponse: Codable {
  let email: String?
}

private struct GoogleCalendarEventsResponse: Codable {
  let items: [GoogleCalendarEvent]
}

private struct GoogleCalendarEvent: Codable {
  let id: String?
  let status: String
  let summary: String?
  let description: String?
  let start: GoogleCalendarEventDate
}

private struct GoogleCalendarEventDate: Codable {
  let dateTime: String?
  let date: String?

  var parsedDate: Date? {
    if let dateTime,
       let parsed = ISO8601DateFormatter().date(from: dateTime) {
      return parsed
    }

    if let date {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.date(from: date)
    }

    return nil
  }
}

private struct GitHubUserResponse: Codable {
  let login: String
}

private struct GitHubIssueSearchResponse: Codable {
  let items: [GitHubIssue]
}

private struct GitHubIssue: Codable {
  let id: Int64
  let title: String
  let body: String?
  let state: String
  let htmlURL: String
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case body
    case state
    case htmlURL = "html_url"
    case createdAt = "created_at"
  }
}

private struct GitHubUserRef: Codable {
  let login: String
  let type: String?
}

private struct GitHubLabelRef: Codable {
  let name: String
}

private struct GitHubMilestoneRef: Codable {
  let title: String
  let dueOn: Date?

  enum CodingKeys: String, CodingKey {
    case title
    case dueOn = "due_on"
  }
}

private struct GitHubIssueDetail: Codable {
  let id: Int64
  let title: String
  let body: String?
  let state: String
  let htmlURL: String
  let createdAt: Date?
  let updatedAt: Date?
  let labels: [GitHubLabelRef]?
  let assignees: [GitHubUserRef]?
  let milestone: GitHubMilestoneRef?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case body
    case state
    case htmlURL = "html_url"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case labels
    case assignees
    case milestone
  }
}

private struct GitHubPullDetail: Codable {
  let draft: Bool?
  let merged: Bool?
  let changedFiles: Int?
  let requestedReviewers: [GitHubUserRef]?

  enum CodingKeys: String, CodingKey {
    case draft
    case merged
    case changedFiles = "changed_files"
    case requestedReviewers = "requested_reviewers"
  }
}

private struct GitHubReviewDetail: Codable {
  let user: GitHubUserRef?
  let state: String
  let body: String?
  let submittedAt: Date?

  enum CodingKeys: String, CodingKey {
    case user
    case state
    case body
    case submittedAt = "submitted_at"
  }
}

private struct GitHubCommentDetail: Codable {
  let user: GitHubUserRef?
  let body: String?
  let createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case user
    case body
    case createdAt = "created_at"
  }
}

private struct GitHubFileDetail: Codable {
  let filename: String
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
