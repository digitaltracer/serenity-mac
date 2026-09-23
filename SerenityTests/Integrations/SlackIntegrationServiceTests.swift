import XCTest
@testable import SerenityMac

@MainActor
final class SlackIntegrationServiceTests: XCTestCase {
  func testPKCESignInStoresTheUserTokenAndWorkspaceIdentity() async throws {
    let recorder = RequestRecorder()
    let authorizer = StubAuthorizer()
    let service = makeService(authorizer: authorizer, recorder: recorder)

    let session = try await service.signIn()

    XCTAssertEqual(session.accessToken, "xoxp-user-token")
    XCTAssertEqual(session.refreshToken, "xoxe-refresh-token")
    XCTAssertEqual(session.teamID, "T123")
    XCTAssertEqual(session.teamName, "Acme")
    XCTAssertEqual(session.userID, "U_ME")
    XCTAssertEqual(session.userName, "adarsh")
    XCTAssertEqual(session.teamURL, "https://acme.slack.com/")

    let stored = try XCTUnwrap(try service.currentSession())
    XCTAssertEqual(stored.accessToken, "xoxp-user-token")
  }

  func testAuthorizeURLCarriesPKCEAndUserScopesOnly() async throws {
    let authorizer = StubAuthorizer()
    let service = makeService(authorizer: authorizer, recorder: RequestRecorder())

    _ = try await service.signIn()

    let query = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(authorizer.requestedURL), resolvingAgainstBaseURL: false)?.queryItems
    )
    let values = Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })

    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertNotNil(values["code_challenge"])
    XCTAssertEqual(values["redirect_uri"], "serenity://slack-oauth")
    XCTAssertNil(values["scope"], "Desktop redirects cannot request bot scopes")

    let scopes = try XCTUnwrap(values["user_scope"]).split(separator: ",").map(String.init)
    XCTAssertTrue(scopes.contains("channels:history"))
    XCTAssertTrue(scopes.contains("groups:history"))
    XCTAssertFalse(scopes.contains("im:history"), "DMs must be unreachable by construction")
    XCTAssertFalse(scopes.contains("mpim:history"))
  }

  func testTokenExchangeSendsTheVerifierAndNoClientSecret() async throws {
    let recorder = RequestRecorder()
    let service = makeService(authorizer: StubAuthorizer(), recorder: recorder)

    _ = try await service.signIn()

    let recorded = await recorder.body(forPath: "/api/oauth.v2.access")
    let body = try XCTUnwrap(recorded)
    XCTAssertTrue(body.contains("code_verifier="))
    XCTAssertTrue(body.contains("code=auth-code"))
    XCTAssertFalse(body.contains("client_secret"), "PKCE public clients must not send a secret")
  }

  func testAMismatchedStateIsRejected() async {
    let authorizer = StubAuthorizer()
    authorizer.stateOverride = "not-the-state-we-sent"
    let service = makeService(authorizer: authorizer, recorder: RequestRecorder())

    do {
      _ = try await service.signIn()
      XCTFail("Expected the state check to reject the callback")
    } catch let error as IntegrationServiceError {
      XCTAssertEqual(error.localizedDescription, "Slack API returned an error: state_mismatch")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testAnExpiringSessionIsRefreshedAndTheRotatedTokenIsKept() async throws {
    let recorder = RequestRecorder()
    let backend = InMemorySlackSecretBackend()
    let service = makeService(authorizer: StubAuthorizer(), recorder: recorder, backend: backend)

    _ = try await service.signIn()
    await recorder.setRefreshing(true)

    // Rotating tokens expire in hours, so the sync path refreshes rather than
    // waiting for a 401 to tell it.
    let refreshed = try await service.activeSession(now: Date().addingTimeInterval(12 * 3600))

    XCTAssertEqual(refreshed.accessToken, "xoxp-rotated-token")
    XCTAssertEqual(refreshed.refreshToken, "xoxe-rotated-refresh")
    XCTAssertEqual(refreshed.userID, "U_ME", "Identity survives a refresh response that omits it")

    let recorded = await recorder.body(forPath: "/api/oauth.v2.access", occurrence: 1)
    let body = try XCTUnwrap(recorded)
    XCTAssertTrue(body.contains("grant_type=refresh_token"))

    let stored = try XCTUnwrap(try service.currentSession())
    XCTAssertEqual(stored.refreshToken, "xoxe-rotated-refresh")
  }

  func testAFreshSessionIsNotRefreshed() async throws {
    let recorder = RequestRecorder()
    let service = makeService(authorizer: StubAuthorizer(), recorder: recorder)

    _ = try await service.signIn()
    let calls = await recorder.count(forPath: "/api/oauth.v2.access")

    _ = try await service.activeSession(now: Date())

    let after = await recorder.count(forPath: "/api/oauth.v2.access")
    XCTAssertEqual(calls, after)
  }

  /// Slack rotates the refresh token on use, so two overlapping refreshes would spend it twice.
  func testOverlappingCallersShareOneRefresh() async throws {
    let recorder = RequestRecorder()
    let service = makeService(authorizer: StubAuthorizer(), recorder: recorder)

    _ = try await service.signIn()
    await recorder.setRefreshing(true)
    let later = Date().addingTimeInterval(12 * 3600)

    async let first = service.activeSession(now: later)
    async let second = service.activeSession(now: later)
    let (a, b) = try await (first, second)

    XCTAssertEqual(a.accessToken, "xoxp-rotated-token")
    XCTAssertEqual(b.accessToken, "xoxp-rotated-token")
    let refreshes = await recorder.count(forPath: "/api/oauth.v2.access") - 1
    XCTAssertEqual(refreshes, 1)
  }

  private func makeService(
    authorizer: StubAuthorizer,
    recorder: RequestRecorder,
    backend: InMemorySlackSecretBackend = InMemorySlackSecretBackend()
  ) -> SlackIntegrationService {
    SlackIntegrationService(
      secretStore: KeychainSecretStore(service: "test.slack", backend: backend),
      requestHandler: { request in try await recorder.respond(to: request) },
      authorizer: authorizer,
      clientID: "1234.5678"
    )
  }
}

@MainActor
private final class StubAuthorizer: SlackWebAuthorizing {
  var requestedURL: URL?
  var stateOverride: String?

  func authorize(url: URL, callbackScheme: String) async throws -> URL {
    requestedURL = url
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let state = stateOverride ?? items.first { $0.name == "state" }?.value ?? ""
    return URL(string: "serenity://slack-oauth?code=auth-code&state=\(state)")!
  }
}

private actor RequestRecorder {
  private var requests: [(path: String, body: String?)] = []
  private var refreshing = false

  func setRefreshing(_ value: Bool) {
    refreshing = value
  }

  func count(forPath path: String) -> Int {
    requests.filter { $0.path == path }.count
  }

  func body(forPath path: String, occurrence: Int = 0) -> String? {
    let matches = requests.filter { $0.path == path }
    guard matches.indices.contains(occurrence) else { return nil }
    return matches[occurrence].body
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    requests.append((url.path, body))

    if url.path == "/api/oauth.v2.access", refreshing {
      // Slow enough that a second caller arrives while the first refresh is out.
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    let json: String
    switch url.path {
    case "/api/oauth.v2.access" where refreshing:
      json = """
      {"ok":true,"access_token":"xoxp-rotated-token","refresh_token":"xoxe-rotated-refresh","expires_in":43200}
      """
    case "/api/oauth.v2.access":
      json = """
      {"ok":true,"team":{"id":"T123","name":"Acme"},
       "authed_user":{"id":"U_ME","access_token":"xoxp-user-token","refresh_token":"xoxe-refresh-token","expires_in":43200}}
      """
    case "/api/auth.test":
      json = """
      {"ok":true,"user":"adarsh","user_id":"U_ME","team":"Acme","team_id":"T123","url":"https://acme.slack.com/"}
      """
    default:
      json = #"{"ok":true}"#
    }

    return (
      Data(json.utf8),
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

private final class InMemorySlackSecretBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  private func key(_ service: String, _ key: String) -> String { "\(service):\(key)" }

  func set(service: String, key: String, data: Data) throws {
    values[self.key(service, key)] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values[self.key(service, key)]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: self.key(service, key))
  }

  func contains(service: String, key: String) throws -> Bool {
    values[self.key(service, key)] != nil
  }
}
