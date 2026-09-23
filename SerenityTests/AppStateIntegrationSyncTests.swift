import XCTest
@testable import SerenityMac

/// "Sync all" and the backend choice, driven through `AppState` with stubbed services.
@MainActor
final class AppStateIntegrationSyncTests: XCTestCase {
  private var cleanups: [() -> Void] = []

  override func tearDown() {
    cleanups.forEach { $0() }
    cleanups = []
    super.tearDown()
  }

  // MARK: - Sync all

  func testAFailingGoogleSyncDoesNotStopGitHub() async throws {
    let google = GoogleIntegrationService(
      secretStore: secretStore(),
      requestHandler: { _ in throw URLError(.notConnectedToInternet) }
    )
    _ = try await google.connectWithToken(accessToken: "g", refreshToken: nil, expiresAt: nil, userEmail: "me@example.com")
    let state = try makeState(google: google)
    await state.bootstrapLocalDatabase()
    state.googleIntegrationState.connected = true
    state.googleIntegrationState.syncEnabled = true
    state.githubIntegrationState.syncEnabled = true
    state.githubIntegrationState.tokens = [Self.tokenRecord]

    let outcomes = await state.syncIntegrationsNow()

    XCTAssertEqual(outcomes.map(\.provider), [.google, .github])
    XCTAssertEqual(outcomes.map(\.failed), [true, false])
    XCTAssertNotNil(state.googleIntegrationState.lastError)
    XCTAssertNotNil(state.githubIntegrationState.lastSyncAt)
    XCTAssertTrue(state.activeAlert?.message.contains("Google Calendar failed") ?? false)
  }

  func testAFailingGitHubSyncKeepsWhatGoogleImported() async throws {
    let google = GoogleIntegrationService(secretStore: secretStore(), requestHandler: { request in
      let payload = #"{"items":[{"id":"evt_1","status":"confirmed","summary":"Planning","start":{"date":"2026-02-16"}}]}"#
      return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    _ = try await google.connectWithToken(accessToken: "g", refreshToken: nil, expiresAt: nil, userEmail: "me@example.com")
    let github = GitHubIntegrationService(secretStore: secretStore(), requestHandler: { request in
      if request.url?.path == "/user" {
        return (Data(#"{"login":"octocat"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }
      return (Data("bad credentials".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    })
    let tokens = try await github.addToken("ghp_expired", displayName: "Work")
    let state = try makeState(google: google, github: github)
    await state.bootstrapLocalDatabase()
    state.googleIntegrationState.connected = true
    state.googleIntegrationState.syncEnabled = true
    state.githubIntegrationState.syncEnabled = true
    state.githubIntegrationState.tokens = tokens

    let outcomes = await state.syncIntegrationsNow()

    XCTAssertEqual(outcomes.first { $0.provider == .google }?.failed, false)
    XCTAssertEqual(outcomes.first { $0.provider == .github }?.failed, true)
    XCTAssertTrue(state.tasks.contains { $0.title == "Planning" })
    XCTAssertNotNil(state.githubIntegrationState.lastError)
  }

  // MARK: - Slack

  func testTwoSlackSyncsStartedTogetherRunOnePass() async throws {
    let slack = CountingSlack()
    let store = secretStore()
    let session = SlackIntegrationSession(
      accessToken: "xoxp",
      refreshToken: nil,
      expiresAt: nil,
      teamID: "T1",
      teamName: "Acme",
      teamURL: "https://acme.slack.com/",
      userID: "U_ME",
      userName: "me",
      connectedAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try store.setSecret(String(decoding: try encoder.encode(session), as: UTF8.self), for: "integrations.slack.session")
    let service = SlackIntegrationService(secretStore: store, requestHandler: { try await slack.respond(to: $0) }, clientID: "cid")
    let state = try makeState(slack: service)
    await state.bootstrapLocalDatabase()
    state.slackIntegrationState.connected = true
    state.slackIntegrationState.syncEnabled = true

    async let first = state.syncSlackNow()
    async let second = state.syncSlackNow()
    let (a, b) = await (first, second)

    XCTAssertNotNil(a)
    XCTAssertEqual(a, b)
    let passes = await slack.count(forPath: "/api/users.conversations")
    XCTAssertEqual(passes, 1)
  }

  // MARK: - Unreachable backend

  func testAnUnreachableRemoteBackendStaysSelectedAndWritesNothingLocally() async throws {
    let suiteName = "serenity.appstate.backend.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(BackendProfile.externalPostgres.rawValue, forKey: "appstate.backend")
    let (state, sqlite) = try makeBackendState(defaults: defaults, postgres: { .unavailable(reason: "connection refused") })

    await state.loadBackendSelectionState()

    XCTAssertEqual(defaults.string(forKey: "appstate.backend"), BackendProfile.externalPostgres.rawValue)
    XCTAssertEqual(state.backendSelectionState.activeProfile, .externalPostgres)
    XCTAssertTrue(state.backendSelectionState.activeProfileUnavailable)

    let saved = await state.createTask(title: "Typed while offline", priority: .medium, dueDate: nil, tags: [], subtaskTitles: [])

    XCTAssertFalse(saved)
    XCTAssertNotNil(state.activeAlert)
    _ = try await sqlite.bootstrap()
    let localTasks = try sqlite.makeCoreRepositories().tasks.fetchAll()
    XCTAssertTrue(localTasks.isEmpty)
  }

  func testSwitchToLocalIsThePathThatSavesTheChange() async throws {
    let suiteName = "serenity.appstate.backend.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(BackendProfile.externalPostgres.rawValue, forKey: "appstate.backend")
    let (state, _) = try makeBackendState(defaults: defaults, postgres: { .unavailable(reason: "connection refused") })
    await state.loadBackendSelectionState()

    await state.switchToLocalBackend()

    XCTAssertEqual(defaults.string(forKey: "appstate.backend"), BackendProfile.sqliteLocal.rawValue)
    XCTAssertFalse(state.backendSelectionState.activeProfileUnavailable)
  }

  /// An hour-old signed-in token is refreshed before the check, so expiry alone never reads as "unreachable".
  func testAnExpiredCloudTokenIsRefreshedBeforeTheBackendIsChecked() async throws {
    let suiteName = "serenity.appstate.backend.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(BackendProfile.serenityCloud.rawValue, forKey: "appstate.backend")
    let configStore = BackendConfigurationStore(defaults: defaults, secretStore: secretStore())
    _ = try configStore.saveSerenityCloudConfiguration(baseURLString: "https://cloud.example", accessToken: "expired-token")
    configStore.setSerenityCloudUsesSignedInSession(true)

    let sessionStore = OAuthSessionStore(defaults: defaults, key: "oauth", secretStore: secretStore())
    await sessionStore.save(
      OAuthSession(
        accessToken: "expired-token",
        refreshToken: "refresh",
        tokenType: "Bearer",
        expiresAt: Date().addingTimeInterval(-60),
        userID: "u",
        userEmail: "u@example.com"
      )
    )
    let auth = AuthSessionManager(oauthClient: RefreshingOAuthClient(), store: sessionStore)
    _ = await auth.bootstrap()

    let (state, _) = try makeBackendState(
      defaults: defaults,
      cloud: {
        configStore.loadSerenityCloudConfiguration()?.accessToken == "fresh-token"
          ? .available(message: "ok")
          : .unavailable(reason: "401")
      },
      configStore: configStore,
      auth: auth
    )

    await state.loadBackendSelectionState()

    XCTAssertFalse(state.backendSelectionState.activeProfileUnavailable)
    XCTAssertEqual(configStore.loadSerenityCloudConfiguration()?.accessToken, "fresh-token")
  }

  // MARK: - iCloud pull

  /// A pulled change reaches the screen, and an edit afterwards starts from it rather than from the
  /// copy that was on screen before — which would quietly revert the pulled fields.
  func testAPulledChangeShowsAndAnEditAfterwardsKeepsIt() async throws {
    let sqlite = try temporarySQLite()
    let suiteName = "serenity.appstate.pull.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
      backendProfileManager: BackendProfileManager(defaults: defaults, defaultsKey: "backend", registry: registry()),
      sqliteBackendAdapter: sqlite,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      aiWorkflowService: AIWorkflowService(sqliteBackendAdapter: sqlite, secretStore: secretStore())
    )
    await state.bootstrapLocalDatabase()
    let created = await state.createTask(title: "Plan", priority: .medium, dueDate: nil, tags: [], subtaskTitles: [])
    XCTAssertTrue(created)
    var pulled = try XCTUnwrap(state.tasks.first)

    pulled.subtasks = [TaskSubtask(id: "s1", title: "Added on the phone", completed: false, order: 0)]
    pulled.updatedAt = Date().addingTimeInterval(60)
    try sqlite.makeCoreRepositories().tasks.applyRemoteUpsert(pulled)
    await state.reloadAfterICloudPull(entityTypes: [SyncEntityType.task])

    XCTAssertEqual(state.tasks.first?.subtasks.map(\.title), ["Added on the phone"])

    let edited = await state.updateTask(
      id: pulled.id,
      title: "Plan the week",
      description: "",
      priority: .high,
      dueDate: nil,
      projectID: nil,
      tags: []
    )
    XCTAssertTrue(edited)
    let stored = try XCTUnwrap(try sqlite.makeCoreRepositories().tasks.fetchByID(pulled.id))
    XCTAssertEqual(stored.title, "Plan the week")
    XCTAssertEqual(stored.subtasks.map(\.title), ["Added on the phone"])
  }

  // MARK: - Helpers

  private static let tokenRecord = GitHubTokenRecord(
    id: "t1",
    token: "ghp",
    displayName: "Work",
    username: "octocat",
    isActive: true,
    createdAt: Date(),
    updatedAt: Date(),
    lastValidatedAt: nil,
    lastSyncAt: nil
  )

  private func secretStore() -> KeychainSecretStore {
    KeychainSecretStore(service: "test.appstate.sync.\(UUID().uuidString)", backend: MemoryBackend())
  }

  private func temporarySQLite() throws -> SQLiteBackendAdapter {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-appstate-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    cleanups.append { try? FileManager.default.removeItem(at: baseURL) }
    return SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite"))
  }

  private func makeState(
    google: GoogleIntegrationService? = nil,
    github: GitHubIntegrationService? = nil,
    slack: SlackIntegrationService? = nil
  ) throws -> AppState {
    let suiteName = "serenity.appstate.sync.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    let sqlite = try temporarySQLite()
    return AppState(
      backendProfileManager: BackendProfileManager(defaults: defaults, defaultsKey: "backend", registry: registry()),
      sqliteBackendAdapter: sqlite,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      googleIntegrationService: google ?? GoogleIntegrationService(secretStore: secretStore(), requestHandler: { _ in throw URLError(.badURL) }),
      githubIntegrationService: github ?? GitHubIntegrationService(secretStore: secretStore(), requestHandler: { _ in throw URLError(.badURL) }),
      slackIntegrationService: slack ?? SlackIntegrationService(secretStore: secretStore(), requestHandler: { _ in throw URLError(.badURL) }, clientID: "cid"),
      aiWorkflowService: AIWorkflowService(sqliteBackendAdapter: sqlite, secretStore: secretStore())
    )
  }

  private func makeBackendState(
    defaults: UserDefaults,
    cloud: @escaping @Sendable () async -> BackendProfileValidationState = { .unavailable(reason: "not configured") },
    postgres: @escaping @Sendable () async -> BackendProfileValidationState = { .unavailable(reason: "not configured") },
    configStore: BackendConfigurationStore? = nil,
    auth: AuthSessionManager? = nil
  ) throws -> (AppState, SQLiteBackendAdapter) {
    let sqlite = try temporarySQLite()
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "appstate.backend",
        registry: registry(cloud: cloud, postgres: postgres)
      ),
      sqliteBackendAdapter: sqlite,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      backendConfigurationStore: configStore ?? BackendConfigurationStore(defaults: defaults, secretStore: secretStore()),
      authSessionManager: auth ?? AuthSessionManager(oauthClient: RefreshingOAuthClient(), store: OAuthSessionStore(defaults: defaults, key: "oauth", secretStore: secretStore())),
      aiWorkflowService: AIWorkflowService(sqliteBackendAdapter: sqlite, secretStore: secretStore())
    )
    return (state, sqlite)
  }

  private func registry(
    cloud: @escaping @Sendable () async -> BackendProfileValidationState = { .unavailable(reason: "not configured") },
    postgres: @escaping @Sendable () async -> BackendProfileValidationState = { .unavailable(reason: "not configured") }
  ) -> BackendProfileRegistry {
    BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: cloud,
        .externalPostgres: postgres,
      ]
    )
  }
}

private struct RefreshingOAuthClient: OAuthClient {
  func exchangeAuthorizationCode(_ code: String) async throws -> OAuthTokenPayload {
    throw OAuthClientError.notConfigured
  }

  func refreshToken(_ refreshToken: String) async throws -> OAuthTokenPayload {
    OAuthTokenPayload(
      accessToken: "fresh-token",
      refreshToken: "refresh-2",
      tokenType: "Bearer",
      expiresIn: 3_600,
      userID: "u",
      userEmail: "u@example.com"
    )
  }
}

private actor CountingSlack {
  private var paths: [String] = []

  func count(forPath path: String) -> Int {
    paths.filter { $0 == path }.count
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    paths.append(url.path)
    let json: String
    switch url.path {
    case "/api/users.conversations":
      // Slow enough that the second caller arrives mid-pass.
      try await Task.sleep(nanoseconds: 50_000_000)
      json = #"{"ok":true,"channels":[{"id":"C1","name":"eng"}]}"#
    case "/api/users.list":
      json = #"{"ok":true,"members":[]}"#
    case "/api/usergroups.list":
      json = #"{"ok":true,"usergroups":[]}"#
    default:
      json = #"{"ok":true,"messages":[]}"#
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private final class MemoryBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  func set(service: String, key: String, data: Data) throws {
    values["\(service):\(key)"] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values["\(service):\(key)"]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: "\(service):\(key)")
  }

  func contains(service: String, key: String) throws -> Bool {
    values["\(service):\(key)"] != nil
  }
}
