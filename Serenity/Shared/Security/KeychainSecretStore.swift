import Foundation
import Security

enum KeychainSecretStoreError: Error, LocalizedError {
  case unexpectedStatus(OSStatus)
  case encodingFailure

  var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      return "Keychain operation failed with status \(status)."
    case .encodingFailure:
      return "Failed to encode secret value."
    }
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

  init(synchronizable: Bool = true) {
    self.synchronizable = synchronizable
  }

  func set(service: String, key: String, data: Data) throws {
    let lookup = baseQuery(service: service, key: key, includeSynchronizableAny: true)

    let status = SecItemCopyMatching(lookup as CFDictionary, nil)

    if status == errSecSuccess {
      // Updating sync attributes via SecItemUpdate isn't supported reliably,
      // so when migrating an existing local item to a synchronizable one we
      // delete and re-add. Same for any unrelated attribute drift.
      let deleteStatus = SecItemDelete(lookup as CFDictionary)
      guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
        throw KeychainSecretStoreError.unexpectedStatus(deleteStatus)
      }
    } else if status != errSecItemNotFound {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }

    var addQuery = baseQuery(service: service, key: key, includeSynchronizableAny: false)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    if synchronizable {
      addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
    }

    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainSecretStoreError.unexpectedStatus(addStatus)
    }
  }

  func get(service: String, key: String) throws -> Data? {
    var query = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

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
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  func contains(service: String, key: String) throws -> Bool {
    var query = baseQuery(service: service, key: key, includeSynchronizableAny: true)
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      return false
    }
    throw KeychainSecretStoreError.unexpectedStatus(status)
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
