import Foundation
import Security

enum KeychainSecretStoreError: Error, LocalizedError {
  case unexpectedStatus(OSStatus)
  case encodingFailure
  /// The new value could not be written and the old one could not be put back. The old value
  /// travels with the error so the caller still has the secret.
  case restoreFailed(previousValue: Data, writeStatus: OSStatus, restoreStatus: OSStatus)

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      return "Keychain operation failed with status \(status)."
    case .encodingFailure:
      return "Failed to encode secret value."
    case .restoreFailed(_, let writeStatus, let restoreStatus):
      return "Keychain update failed with status \(writeStatus), and restoring the previous value failed with status \(restoreStatus)."
    }
  }
}

/// The `SecItem*` calls, so the failure paths can be driven without the real Keychain.
protocol KeychainItemAPI {
  func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainAPI: KeychainItemAPI {
  func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

protocol SecretStorageBackend {
  func set(service: String, key: String, data: Data) throws
  func get(service: String, key: String) throws -> Data?
  func delete(service: String, key: String) throws
  func contains(service: String, key: String) throws -> Bool
}

struct KeychainBackend: SecretStorageBackend {
  /// When true, items are written with `kSecAttrSynchronizable=true` so they
  /// ride iCloud Keychain to the user's other devices. Reads always include
  /// `kSecAttrSynchronizableAny` so legacy non-synced items remain visible.
  let synchronizable: Bool
  private let api: KeychainItemAPI

  init(synchronizable: Bool = true, api: KeychainItemAPI = SystemKeychainAPI()) {
    self.synchronizable = synchronizable
    self.api = api
  }

  /// Updates in place. Only an item whose synchronizable flag must change is deleted and re-added,
  /// because `SecItemUpdate` cannot move an item between the local and iCloud keychains — and then
  /// the old value is held until the new item reads back, so a failed write never loses the secret.
  func set(service: String, key: String, data: Data) throws {
    var lookup = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    lookup[kSecReturnAttributes as String] = true
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, result) = api.copyMatching(lookup)
    if status == errSecItemNotFound {
      try add(service: service, key: key, data: data, synchronizable: synchronizable)
      return
    }
    guard status == errSecSuccess, let existing = result as? [String: Any] else {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    let existingSynchronizable = (existing[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
    let exact = itemQuery(service: service, key: key, synchronizable: existingSynchronizable)

    if existingSynchronizable == synchronizable {
      let updateStatus = api.update(exact, attributes: [kSecValueData as String: data])
      guard updateStatus == errSecSuccess else {
        throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
      }
      return
    }

    guard let previousValue = existing[kSecValueData as String] as? Data else {
      throw KeychainSecretStoreError.unexpectedStatus(errSecDecode)
    }

    let deleteStatus = api.delete(exact)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      throw KeychainSecretStoreError.unexpectedStatus(deleteStatus)
    }

    let addStatus = addStatus(service: service, key: key, data: data, synchronizable: synchronizable)
    if addStatus == errSecSuccess, (try? get(service: service, key: key)) == data {
      return
    }

    // The new item is missing or wrong: put the old one back exactly as it was.
    _ = api.delete(itemQuery(service: service, key: key, synchronizable: synchronizable))
    let restoreStatus = self.addStatus(service: service, key: key, data: previousValue, synchronizable: existingSynchronizable)
    let writeStatus = addStatus == errSecSuccess ? errSecDataNotAvailable : addStatus
    guard restoreStatus == errSecSuccess else {
      throw KeychainSecretStoreError.restoreFailed(
        previousValue: previousValue,
        writeStatus: writeStatus,
        restoreStatus: restoreStatus
      )
    }
    throw KeychainSecretStoreError.unexpectedStatus(writeStatus)
  }

  func get(service: String, key: String) throws -> Data? {
    var query = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, result) = api.copyMatching(query)

    if status == errSecItemNotFound {
      return nil
    }

    guard status == errSecSuccess else {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    return result as? Data
  }

  func delete(service: String, key: String) throws {
    let query = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    let status = api.delete(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  func contains(service: String, key: String) throws -> Bool {
    var query = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, _) = api.copyMatching(query)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      return false
    }
    throw KeychainSecretStoreError.unexpectedStatus(status)
  }

  private func add(service: String, key: String, data: Data, synchronizable: Bool) throws {
    let status = addStatus(service: service, key: key, data: data, synchronizable: synchronizable)
    guard status == errSecSuccess else {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  private func addStatus(service: String, key: String, data: Data, synchronizable: Bool) -> OSStatus {
    var attributes = itemQuery(service: service, key: key, synchronizable: synchronizable)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return api.add(attributes)
  }

  private func itemQuery(service: String, key: String, synchronizable: Bool) -> [String: Any] {
    var query = baseQuery(service: service, key: key, includeSynchronizableAny: false)
    query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
    return query
  }

  private func baseQuery(
    service: String,
    key: String,
    includeSynchronizableAny: Bool
  ) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    if includeSynchronizableAny {
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    }
    return query
  }
}

final class KeychainSecretStore {
  private let service: String
  private let backend: SecretStorageBackend

  init(service: String = "com.digitaltracer.serenity", backend: SecretStorageBackend = KeychainBackend()) {
    self.service = service
    self.backend = backend
  }

  func setSecret(_ value: String, for key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainSecretStoreError.encodingFailure
    }

    try backend.set(service: service, key: key, data: data)
  }

  func secret(for key: String) throws -> String? {
    guard let data = try backend.get(service: service, key: key) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func deleteSecret(for key: String) throws {
    try backend.delete(service: service, key: key)
  }

  func hasSecret(for key: String) throws -> Bool {
    try backend.contains(service: service, key: key)
  }
}
