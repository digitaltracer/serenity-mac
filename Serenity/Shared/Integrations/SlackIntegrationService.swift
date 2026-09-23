import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Hands the user to Slack's consent page and returns the callback URL it
/// redirects to. Split behind a protocol so the OAuth exchange can be tested
/// without a browser.
@MainActor
protocol SlackWebAuthorizing: AnyObject {
  func authorize(url: URL, callbackScheme: String) async throws -> URL
}

@MainActor
final class WebAuthenticationSlackAuthorizer: NSObject, SlackWebAuthorizing {
  // ASWebAuthenticationSession does not retain itself while presenting.
  private var session: ASWebAuthenticationSession?

  func authorize(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
        if let error {
          let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
          continuation.resume(throwing: cancelled ? IntegrationServiceError.slackAuthorizationCancelled : error)
          return
        }

        guard let callbackURL else {
          continuation.resume(throwing: IntegrationServiceError.invalidResponse)
          return
        }

        continuation.resume(returning: callbackURL)
      }

      session.presentationContextProvider = self
      self.session = session

      guard session.start() else {
        continuation.resume(throwing: IntegrationServiceError.missingSlackPresenter)
        return
      }
    }
  }
}

extension WebAuthenticationSlackAuthorizer: ASWebAuthenticationPresentationContextProviding {
  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      #if os(macOS)
      NSApplication.shared.keyWindow
        ?? NSApplication.shared.windows.first(where: \.isVisible)
        ?? ASPresentationAnchor()
      #elseif os(iOS)
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      return scene?.windows.first(where: \.isKeyWindow)
        ?? scene?.windows.first
        ?? ASPresentationAnchor()
      #else
      ASPresentationAnchor()
      #endif
    }
  }
}

/// Every Slack Web API call goes through here. Slack answers `200 OK` with
/// `{"ok": false, "error": "..."}` for most failures, so a status check alone
/// would let errors through as empty results.
struct SlackAPIClient: Sendable {
  private let requestHandler: IntegrationRequestHandler
  private let decoder: JSONDecoder

  init(requestHandler: @escaping IntegrationRequestHandler) {
    self.requestHandler = requestHandler
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func get<T: Decodable & SlackAPIResponse>(
    _ method: String,
    token: String,
    query: [String: String] = [:]
  ) async throws -> T {
    var components = URLComponents(
      url: SlackConfiguration.apiBaseURL.appendingPathComponent(method),
      resolvingAgainstBaseURL: false
    )
    if !query.isEmpty {
      components?.queryItems = query
        .sorted { $0.key < $1.key }
        .map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    guard let url = components?.url else {
      throw IntegrationServiceError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    return try await send(request)
  }

  func postForm<T: Decodable & SlackAPIResponse>(
    _ url: URL,
    fields: [String: String],
    token: String? = nil
  ) async throws -> T {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = Self.formBody(fields)

    return try await send(request)
  }

  /// Slack reports throttling with `429` plus a `Retry-After` header in whole
  /// seconds. Waiting it out is the correct handling — a caller that treats it
  /// as failure ends up skipping messages.
  private func send<T: Decodable & SlackAPIResponse>(_ request: URLRequest, attempt: Int = 0) async throws -> T {
    let (data, response) = try await requestHandler(request)

    if response.statusCode == 429, attempt < 3 {
      let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
      try await Task.sleep(nanoseconds: UInt64(max(1, retryAfter) * 1_000_000_000))
      return try await send(request, attempt: attempt + 1)
    }

    guard 200..<300 ~= response.statusCode else {
      throw IntegrationServiceError.unsupportedResponseStatus(
        response.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    let payload = try decoder.decode(T.self, from: data)
    guard payload.ok else {
      throw IntegrationServiceError.slackAPIError(payload.error ?? "unknown_error")
    }

    return payload
  }

  /// `URLComponents` leaves `+` unescaped, where a form body reads it as a
  /// space. Slack tokens are alphanumeric today, but a silently corrupted
  /// refresh token is an ugly way to find out that changed.
  private static func formBody(_ fields: [String: String]) -> Data? {
    var components = URLComponents()
    components.queryItems = fields
      .sorted { $0.key < $1.key }
      .map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
      .data(using: .utf8)
  }
}

protocol SlackAPIResponse {
  var ok: Bool { get }
  var error: String? { get }
}

@MainActor
final class SlackIntegrationService {
  private let secretStore: KeychainSecretStore
  private let apiClient: SlackAPIClient
  private let authorizer: SlackWebAuthorizing
  private let configuredClientID: String?
  /// Slack rotates the refresh token on use, so a second concurrent refresh would spend a dead one.
  private var refreshInFlight: Task<SlackIntegrationSession, Error>?
  private let sessionKey = "integrations.slack.session"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    secretStore: KeychainSecretStore = KeychainSecretStore(service: "com.digitaltracer.serenity.integrations"),
    requestHandler: @escaping IntegrationRequestHandler = URLSessionIntegrationClient.shared,
    authorizer: SlackWebAuthorizing? = nil,
    clientID: String? = nil
  ) {
    self.secretStore = secretStore
    self.apiClient = SlackAPIClient(requestHandler: requestHandler)
    self.authorizer = authorizer ?? WebAuthenticationSlackAuthorizer()
    self.configuredClientID = clientID
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  var isConfigured: Bool {
    clientID != nil
  }

  private var clientID: String? {
    configuredClientID ?? SlackConfiguration.clientID
  }

  var client: SlackAPIClient {
    apiClient
  }

  func signIn() async throws -> SlackIntegrationSession {
    guard let clientID else {
      throw IntegrationServiceError.missingSlackConfiguration
    }

    let verifier = Self.randomURLSafeString()
    let expectedState = Self.randomURLSafeString()

    var components = URLComponents(url: SlackConfiguration.authorizeURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "user_scope", value: SlackConfiguration.userScopes.joined(separator: ",")),
      URLQueryItem(name: "redirect_uri", value: SlackConfiguration.redirectURI),
      URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: expectedState),
    ]

    guard let authorizeURL = components?.url else {
      throw IntegrationServiceError.invalidResponse
    }

    let callback = try await authorizer.authorize(
      url: authorizeURL,
      callbackScheme: SlackConfiguration.callbackScheme
    )

    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if let denial = items.first(where: { $0.name == "error" })?.value {
      throw IntegrationServiceError.slackAPIError(denial)
    }

    guard let code = items.first(where: { $0.name == "code" })?.value else {
      throw IntegrationServiceError.slackAuthorizationCancelled
    }
    guard items.first(where: { $0.name == "state" })?.value == expectedState else {
      throw IntegrationServiceError.slackAPIError("state_mismatch")
    }

    let response: SlackOAuthResponse = try await apiClient.postForm(
      SlackConfiguration.accessURL,
      fields: [
        "client_id": clientID,
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": SlackConfiguration.redirectURI,
      ]
    )

    var session = try Self.session(from: response, previous: nil)
    session = try await describing(session)
    try saveSession(session)
    return session
  }

  func currentSession() throws -> SlackIntegrationSession? {
    guard let raw = try secretStore.secret(for: sessionKey),
          let data = raw.data(using: .utf8)
    else {
      return nil
    }

    return try decoder.decode(SlackIntegrationSession.self, from: data)
  }

  /// Run at the top of every sync. PKCE forces rotating tokens, so an access
  /// token that was fine an hour ago usually is not.
  func activeSession(now: Date = Date()) async throws -> SlackIntegrationSession {
    guard let session = try currentSession() else {
      throw IntegrationServiceError.missingSlackSession
    }

    guard session.needsRefresh(now: now), let refreshToken = session.refreshToken else {
      return session
    }

    guard let clientID else {
      throw IntegrationServiceError.missingSlackConfiguration
    }

    if let running = refreshInFlight {
      return try await running.value
    }

    let refresh = Task { [apiClient] in
      let response: SlackOAuthResponse = try await apiClient.postForm(
        SlackConfiguration.accessURL,
        fields: [
          "client_id": clientID,
          "grant_type": "refresh_token",
          "refresh_token": refreshToken,
        ]
      )
      let refreshed = try Self.session(from: response, previous: session)
      try self.saveSession(refreshed)
      return refreshed
    }
    refreshInFlight = refresh
    defer { refreshInFlight = nil }
    return try await refresh.value
  }

  func disconnect() async throws {
    if let session = try? currentSession() {
      // Best effort: a revoke that fails must not strand the local session.
      let _: SlackAuthRevokeResponse? = try? await apiClient.postForm(
        SlackConfiguration.apiBaseURL.appendingPathComponent("auth.revoke"),
        fields: [:],
        token: session.accessToken
      )
    }

    try secretStore.deleteSecret(for: sessionKey)
  }

  /// `auth.test` both validates the freshly minted token and fills in the
  /// workspace and account names the Integrations row shows.
  private func describing(_ session: SlackIntegrationSession) async throws -> SlackIntegrationSession {
    let identity: SlackAuthTestResponse = try await apiClient.get("auth.test", token: session.accessToken)
    var described = session
    described.teamID = identity.teamID ?? session.teamID
    described.teamName = identity.team ?? session.teamName
    described.userID = identity.userID ?? session.userID
    described.userName = identity.user ?? session.userName
    described.teamURL = identity.url ?? session.teamURL
    return described
  }

  private func saveSession(_ session: SlackIntegrationSession) throws {
    let data = try encoder.encode(session)
    guard let raw = String(data: data, encoding: .utf8) else {
      throw IntegrationServiceError.invalidResponse
    }

    try secretStore.setSecret(raw, for: sessionKey)
  }

  /// The install response nests the user token under `authed_user`; a refresh
  /// response returns it at the top level. Both shapes land here.
  private static func session(
    from response: SlackOAuthResponse,
    previous: SlackIntegrationSession?,
    now: Date = Date()
  ) throws -> SlackIntegrationSession {
    guard let accessToken = response.authedUser?.accessToken ?? response.accessToken, !accessToken.isEmpty else {
      throw IntegrationServiceError.slackAPIError(response.error ?? "missing_access_token")
    }

    let expiresIn = response.authedUser?.expiresIn ?? response.expiresIn

    return SlackIntegrationSession(
      accessToken: accessToken,
      refreshToken: response.authedUser?.refreshToken ?? response.refreshToken ?? previous?.refreshToken,
      expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
      teamID: response.team?.id ?? previous?.teamID ?? "",
      teamName: response.team?.name ?? previous?.teamName,
      teamURL: previous?.teamURL,
      userID: response.authedUser?.id ?? previous?.userID ?? "",
      userName: previous?.userName,
      connectedAt: previous?.connectedAt ?? now
    )
  }

  private static func randomURLSafeString(byteCount: Int = 64) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
      bytes = (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
    }
    return Data(bytes).base64URLEncodedString()
  }

  private static func codeChallenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
  }
}

struct SlackOAuthResponse: Decodable, SlackAPIResponse {
  struct AuthedUser: Decodable {
    let id: String?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
      case id
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }

  struct Team: Decodable {
    let id: String?
    let name: String?
  }

  let ok: Bool
  let error: String?
  let authedUser: AuthedUser?
  let team: Team?
  let accessToken: String?
  let refreshToken: String?
  let expiresIn: Int?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case authedUser = "authed_user"
    case team
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}

struct SlackAuthTestResponse: Decodable, SlackAPIResponse {
  let ok: Bool
  let error: String?
  let user: String?
  let userID: String?
  let team: String?
  let teamID: String?
  let url: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case user
    case userID = "user_id"
    case team
    case teamID = "team_id"
    case url
  }
}

struct SlackAuthRevokeResponse: Decodable, SlackAPIResponse {
  let ok: Bool
  let error: String?
}

extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
