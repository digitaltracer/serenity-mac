import Foundation
import XCTest
@testable import SerenityMac

final class AuthSessionManagerTests: XCTestCase {
  func testOAuthConfigurationPersistsAndClearsStoredValues() {
    let suiteName = "serenity.macos.oauth-config.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let configuration = OAuthEnvironmentConfiguration(
      baseURL: URL(string: "https://auth.serenity.test")!,
      clientID: "desktop-client",
      redirectURI: "serenity://oauth/callback"
    )
    configuration.persist(defaults)

    XCTAssertEqual(OAuthEnvironmentConfiguration.fromStored(defaults), configuration)

    let resolved = OAuthEnvironmentConfiguration.fromStoredOrEnvironment(
      defaults: defaults,
      environment: [
        "SERENITY_OAUTH_BASE_URL": "https://env.serenity.test",
        "SERENITY_OAUTH_CLIENT_ID": "env-client",
        "SERENITY_OAUTH_REDIRECT_URI": "serenity://env/callback",
      ]
    )
    XCTAssertEqual(resolved, configuration)

    OAuthEnvironmentConfiguration.clearStored(defaults)
    XCTAssertNil(OAuthEnvironmentConfiguration.fromStored(defaults))

    let fallback = OAuthEnvironmentConfiguration.fromStoredOrEnvironment(
      defaults: defaults,
      environment: [
        "SERENITY_OAUTH_BASE_URL": "https://env.serenity.test",
        "SERENITY_OAUTH_CLIENT_ID": "env-client",
        "SERENITY_OAUTH_REDIRECT_URI": "serenity://env/callback",
      ]
    )
    XCTAssertEqual(fallback?.clientID, "env-client")
  }

  func testLoginPersistsSessionAndAuthenticates() async {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: memorySecretStore())
    let client = MockOAuthClient(
      exchangeResponse: OAuthTokenPayload(
        accessToken: "access-1",
        refreshToken: "refresh-1",
        tokenType: "Bearer",
        expiresIn: 3_600,
        userID: "user-1",
        userEmail: "user@serenity.test"
      ),
      refreshResponse: nil
    )

    let manager = AuthSessionManager(oauthClient: client, store: store)
    let state = await manager.login(withAuthorizationCode: "auth-code")

    guard case .authenticated(let session) = state else {
      return XCTFail("Expected authenticated state")
    }

    XCTAssertEqual(session.accessToken, "access-1")
    XCTAssertEqual(session.userID, "user-1")

    let persisted = await store.load()
    XCTAssertEqual(persisted?.accessToken, "access-1")
  }

  func testBootstrapRestoresPersistedSession() async {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: memorySecretStore())
    await store.save(
      OAuthSession(
        accessToken: "access-existing",
        refreshToken: "refresh-existing",
        tokenType: "Bearer",
        expiresAt: Date().addingTimeInterval(3_600),
        userID: "user-existing",
        userEmail: "existing@serenity.test"
      )
    )

    let manager = AuthSessionManager(
      oauthClient: MockOAuthClient(exchangeResponse: nil, refreshResponse: nil),
      store: store
    )

    let state = await manager.bootstrap()

    guard case .authenticated(let session) = state else {
      return XCTFail("Expected restored session")
    }

    XCTAssertEqual(session.userID, "user-existing")
  }

  func testRefreshSessionIfNeededUsesRefreshToken() async {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: memorySecretStore())
    let nearlyExpired = OAuthSession(
      accessToken: "access-old",
      refreshToken: "refresh-old",
      tokenType: "Bearer",
      expiresAt: Date().addingTimeInterval(5),
      userID: "user-old",
      userEmail: "old@serenity.test"
    )
    await store.save(nearlyExpired)

    let client = MockOAuthClient(
      exchangeResponse: nil,
      refreshResponse: OAuthTokenPayload(
        accessToken: "access-new",
        refreshToken: "refresh-new",
        tokenType: "Bearer",
        expiresIn: 3_600,
        userID: "user-old",
        userEmail: "old@serenity.test"
      )
    )

    let manager = AuthSessionManager(oauthClient: client, store: store)
    _ = await manager.bootstrap()

    let refreshedState = await manager.refreshSessionIfNeeded()
    guard case .authenticated(let refreshedSession) = refreshedState else {
      return XCTFail("Expected refreshed authenticated state")
    }

    XCTAssertEqual(refreshedSession.accessToken, "access-new")
    let refreshCalls = await client.refreshCalls
    XCTAssertEqual(refreshCalls, 1)
  }

  func testLogoutClearsPersistedSession() async {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: memorySecretStore())
    await store.save(
      OAuthSession(
        accessToken: "access-existing",
        refreshToken: "refresh-existing",
        tokenType: "Bearer",
        expiresAt: Date().addingTimeInterval(3_600),
        userID: "user-existing",
        userEmail: "existing@serenity.test"
      )
    )

    let manager = AuthSessionManager(
      oauthClient: MockOAuthClient(exchangeResponse: nil, refreshResponse: nil),
      store: store
    )

    let state = await manager.logout()
    XCTAssertEqual(state, .unauthenticated)
    let persisted = await store.load()
    XCTAssertNil(persisted)
  }
}

private actor MockOAuthClient: OAuthClient {
  let exchangeResponse: OAuthTokenPayload?
  let refreshResponse: OAuthTokenPayload?
  private(set) var refreshCalls: Int = 0

  init(exchangeResponse: OAuthTokenPayload?, refreshResponse: OAuthTokenPayload?) {
    self.exchangeResponse = exchangeResponse
    self.refreshResponse = refreshResponse
  }

  func exchangeAuthorizationCode(_ code: String) async throws -> OAuthTokenPayload {
    try await Task.sleep(for: .milliseconds(10))
    if let exchangeResponse {
      return exchangeResponse
    }
    throw OAuthClientError.notConfigured
  }

  func refreshToken(_ refreshToken: String) async throws -> OAuthTokenPayload {
    refreshCalls += 1
    if let refreshResponse {
      return refreshResponse
    }
    throw OAuthClientError.notConfigured
  }
}

extension AuthSessionManagerTests {
  /// An offline launch says nothing about the refresh token, so signing the user out would be wrong.
  func testANetworkFailureDuringRefreshKeepsTheSession() async {
    let (store, cleanup) = await storeWithExpiredSession()
    defer { cleanup() }
    let manager = AuthSessionManager(oauthClient: FailingOAuthClient(error: URLError(.notConnectedToInternet)), store: store)

    let state = await manager.bootstrap()

    guard case .authenticated(let session) = state else {
      return XCTFail("Expected the stored session to survive, got \(state)")
    }
    XCTAssertEqual(session.refreshToken, "refresh-old")
    let persisted = await store.load()
    XCTAssertNotNil(persisted)
  }

  func testAServerErrorDuringRefreshKeepsTheSession() async {
    let (store, cleanup) = await storeWithExpiredSession()
    defer { cleanup() }
    let error = OAuthClientError.requestFailed(status: 503, message: "maintenance")
    let manager = AuthSessionManager(oauthClient: FailingOAuthClient(error: error), store: store)

    _ = await manager.refreshSession(force: true)

    let persisted = await store.load()
    XCTAssertNotNil(persisted)
  }

  func testARejectedRefreshTokenClearsTheSession() async {
    let (store, cleanup) = await storeWithExpiredSession()
    defer { cleanup() }
    let error = OAuthClientError.requestFailed(status: 400, message: #"{"error":"invalid_grant"}"#)
    let manager = AuthSessionManager(oauthClient: FailingOAuthClient(error: error), store: store)

    let state = await manager.refreshSession(force: true)

    guard case .failed = state else {
      return XCTFail("Expected a failed state, got \(state)")
    }
    let persisted = await store.load()
    XCTAssertNil(persisted)
  }

  private func storeWithExpiredSession() async -> (OAuthSessionStore, () -> Void) {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: memorySecretStore())
    await store.save(
      OAuthSession(
        accessToken: "access-old",
        refreshToken: "refresh-old",
        tokenType: "Bearer",
        expiresAt: Date().addingTimeInterval(-60),
        userID: "user-old",
        userEmail: "old@serenity.test"
      )
    )
    return (store, { defaults.removePersistentDomain(forName: suiteName) })
  }
}

private struct FailingOAuthClient: OAuthClient {
  let error: Error

  func exchangeAuthorizationCode(_ code: String) async throws -> OAuthTokenPayload {
    throw error
  }

  func refreshToken(_ refreshToken: String) async throws -> OAuthTokenPayload {
    throw error
  }
}

extension AuthSessionManagerTests {
  /// A build before this one kept the session in UserDefaults. It moves to the Keychain on first
  /// read, and the UserDefaults copy goes only once the Keychain copy reads back.
  func testASessionLeftInUserDefaultsMovesToTheKeychain() async throws {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let legacy = OAuthSession(
      accessToken: "access-legacy",
      refreshToken: "refresh-legacy",
      tokenType: "Bearer",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      userID: "u",
      userEmail: "u@serenity.test"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    defaults.set(try encoder.encode(legacy), forKey: "oauth_session_test")
    let secrets = memorySecretStore()
    let store = OAuthSessionStore(defaults: defaults, key: "oauth_session_test", secretStore: secrets)

    let loaded = await store.load()

    XCTAssertEqual(loaded, legacy)
    XCTAssertNil(defaults.data(forKey: "oauth_session_test"))
    XCTAssertNotNil(try secrets.secret(for: "oauth_session_test"))
  }

  func testAKeychainThatRefusesTheCopyLeavesUserDefaultsInPlace() async throws {
    let suiteName = "serenity.macos.auth.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let legacy = OAuthSession(
      accessToken: "access-legacy",
      refreshToken: "refresh-legacy",
      tokenType: "Bearer",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      userID: "u",
      userEmail: "u@serenity.test"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    defaults.set(try encoder.encode(legacy), forKey: "oauth_session_test")
    let store = OAuthSessionStore(
      defaults: defaults,
      key: "oauth_session_test",
      secretStore: KeychainSecretStore(service: "test", backend: RefusingSecretBackend())
    )

    let loaded = await store.load()

    XCTAssertEqual(loaded, legacy)
    XCTAssertNotNil(defaults.data(forKey: "oauth_session_test"))
  }

  func memorySecretStore() -> KeychainSecretStore {
    KeychainSecretStore(service: "test.auth.\(UUID().uuidString)", backend: MemorySecretBackend())
  }
}

private final class MemorySecretBackend: SecretStorageBackend {
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

private struct RefusingSecretBackend: SecretStorageBackend {
  func set(service: String, key: String, data: Data) throws {
    throw KeychainSecretStoreError.unexpectedStatus(errSecInteractionNotAllowed)
  }

  func get(service: String, key: String) throws -> Data? {
    nil
  }

  func delete(service: String, key: String) throws {}

  func contains(service: String, key: String) throws -> Bool {
    false
  }
}
