import XCTest
@testable import SerenityMac

final class KeychainSecretStoreTests: XCTestCase {
  func testSetGetAndDeleteSecret() throws {
    let backend = InMemorySecretStorageBackend()
    let store = KeychainSecretStore(service: "test.service", backend: backend)

    try store.setSecret("token-123", for: "oauth.access_token")
    XCTAssertTrue(try store.hasSecret(for: "oauth.access_token"))
    XCTAssertEqual(try store.secret(for: "oauth.access_token"), "token-123")

    try store.deleteSecret(for: "oauth.access_token")
    XCTAssertFalse(try store.hasSecret(for: "oauth.access_token"))
    XCTAssertNil(try store.secret(for: "oauth.access_token"))
  }
}

private final class InMemorySecretStorageBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  private func namespacedKey(service: String, key: String) -> String {
    "\(service):\(key)"
  }

  func set(service: String, key: String, data: Data) throws {
    values[namespacedKey(service: service, key: key)] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values[namespacedKey(service: service, key: key)]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: namespacedKey(service: service, key: key))
  }

  func contains(service: String, key: String) throws -> Bool {
    values[namespacedKey(service: service, key: key)] != nil
  }
}

extension KeychainSecretStoreTests {
  func testAnExistingItemIsUpdatedInPlace() throws {
    let keychain = FakeKeychain()
    keychain.items = [.init(service: "s", account: "k", synchronizable: true, data: Data("old".utf8))]
    let backend = KeychainBackend(synchronizable: true, api: keychain)

    try backend.set(service: "s", key: "k", data: Data("new".utf8))

    XCTAssertEqual(keychain.addCalls, 0)
    XCTAssertEqual(keychain.updateCalls, 1)
    XCTAssertEqual(try backend.get(service: "s", key: "k"), Data("new".utf8))
  }

  func testALocalItemMovesToTheSynchronizedKeychain() throws {
    let keychain = FakeKeychain()
    keychain.items = [.init(service: "s", account: "k", synchronizable: false, data: Data("old".utf8))]
    let backend = KeychainBackend(synchronizable: true, api: keychain)

    try backend.set(service: "s", key: "k", data: Data("new".utf8))

    XCTAssertEqual(keychain.items.count, 1)
    XCTAssertEqual(keychain.items.first?.synchronizable, true)
    XCTAssertEqual(keychain.items.first?.data, Data("new".utf8))
  }

  func testAFailedMoveRestoresTheOldValue() throws {
    let keychain = FakeKeychain()
    keychain.items = [.init(service: "s", account: "k", synchronizable: false, data: Data("old".utf8))]
    keychain.addFailures = [errSecIO]
    let backend = KeychainBackend(synchronizable: true, api: keychain)

    XCTAssertThrowsError(try backend.set(service: "s", key: "k", data: Data("new".utf8)))

    XCTAssertEqual(try backend.get(service: "s", key: "k"), Data("old".utf8))
    XCTAssertEqual(keychain.items.first?.synchronizable, false, "Restored exactly as it was")
  }

  func testAFailedRestoreHandsTheOldValueBack() {
    let keychain = FakeKeychain()
    keychain.items = [.init(service: "s", account: "k", synchronizable: false, data: Data("old".utf8))]
    keychain.addFailures = [errSecIO, errSecIO]
    let backend = KeychainBackend(synchronizable: true, api: keychain)

    XCTAssertThrowsError(try backend.set(service: "s", key: "k", data: Data("new".utf8))) { error in
      guard case KeychainSecretStoreError.restoreFailed(let previous, _, _) = error else {
        return XCTFail("Expected restoreFailed, got \(error)")
      }
      XCTAssertEqual(previous, Data("old".utf8))
    }
  }

  func testAFailedUpdateLeavesTheOldValue() throws {
    let keychain = FakeKeychain()
    keychain.items = [.init(service: "s", account: "k", synchronizable: true, data: Data("old".utf8))]
    keychain.updateStatus = errSecIO
    let backend = KeychainBackend(synchronizable: true, api: keychain)

    XCTAssertThrowsError(try backend.set(service: "s", key: "k", data: Data("new".utf8)))

    XCTAssertEqual(try backend.get(service: "s", key: "k"), Data("old".utf8))
  }

  /// The one test that touches the real Keychain. Synchronizable items need an entitlement the test
  /// runner lacks, so this uses a local item.
  func testRoundTripAgainstTheRealKeychain() throws {
    let backend = KeychainBackend(synchronizable: false)
    let service = "com.digitaltracer.serenity.tests.\(UUID().uuidString)"
    defer { try? backend.delete(service: service, key: "k") }

    do {
      try backend.set(service: service, key: "k", data: Data("first".utf8))
    } catch KeychainSecretStoreError.unexpectedStatus(let status)
      where status == errSecMissingEntitlement || status == errSecInteractionNotAllowed || status == errSecNotAvailable {
      throw XCTSkip("Keychain not reachable from this runner (status \(status))")
    }
    try backend.set(service: service, key: "k", data: Data("second".utf8))

    XCTAssertEqual(try backend.get(service: service, key: "k"), Data("second".utf8))
    try backend.delete(service: service, key: "k")
    XCTAssertNil(try backend.get(service: service, key: "k"))
  }
}

/// Keeps items the way the Keychain does: one per service, account and synchronizable flag.
private final class FakeKeychain: KeychainItemAPI {
  struct Item {
    var service: String
    var account: String
    var synchronizable: Bool
    var data: Data
  }

  var items: [Item] = []
  var addFailures: [OSStatus] = []
  var updateStatus: OSStatus = errSecSuccess
  var addCalls = 0
  var updateCalls = 0

  func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    guard let item = items.first(where: { matches($0, query) }) else {
      return (errSecItemNotFound, nil)
    }
    if query[kSecReturnAttributes as String] as? Bool == true {
      let attributes: [String: Any] = [
        kSecAttrSynchronizable as String: NSNumber(value: item.synchronizable),
        kSecValueData as String: item.data,
      ]
      return (errSecSuccess, attributes as NSDictionary)
    }
    if query[kSecReturnData as String] as? Bool == true {
      return (errSecSuccess, item.data as NSData)
    }
    return (errSecSuccess, nil)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    addCalls += 1
    if !addFailures.isEmpty {
      return addFailures.removeFirst()
    }
    let item = Item(
      service: attributes[kSecAttrService as String] as! String,
      account: attributes[kSecAttrAccount as String] as! String,
      synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool ?? false,
      data: attributes[kSecValueData as String] as! Data
    )
    if items.contains(where: { $0.service == item.service && $0.account == item.account && $0.synchronizable == item.synchronizable }) {
      return errSecDuplicateItem
    }
    items.append(item)
    return errSecSuccess
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    updateCalls += 1
    guard updateStatus == errSecSuccess else { return updateStatus }
    guard let index = items.firstIndex(where: { matches($0, query) }) else { return errSecItemNotFound }
    items[index].data = attributes[kSecValueData as String] as! Data
    return errSecSuccess
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    let before = items.count
    items.removeAll { matches($0, query) }
    return items.count < before ? errSecSuccess : errSecItemNotFound
  }

  private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
    guard item.service == query[kSecAttrService as String] as? String,
          item.account == query[kSecAttrAccount as String] as? String
    else {
      return false
    }
    switch query[kSecAttrSynchronizable as String] {
    case let any as String where any == (kSecAttrSynchronizableAny as String):
      return true
    case let flag as Bool:
      return item.synchronizable == flag
    default:
      return !item.synchronizable
    }
  }
}
