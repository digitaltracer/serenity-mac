import Foundation

enum BackendConfigurationStoreError: Error, LocalizedError {
  case invalidValue(String)

  var errorDescription: String? {
    switch self {
    case .invalidValue(let message):
      return message
    }
  }
}

final class BackendConfigurationStore {
  private enum DefaultsKey {
    static let serenityCloudBaseURL = "serenity.macos.backend.cloud.base_url"
    static let serenityCloudTimeout = "serenity.macos.backend.cloud.timeout"
    static let postgresHost = "serenity.macos.backend.postgres.host"
    static let postgresPort = "serenity.macos.backend.postgres.port"
    static let postgresDatabase = "serenity.macos.backend.postgres.database"
    static let postgresUsername = "serenity.macos.backend.postgres.username"
    static let postgresSSLMode = "serenity.macos.backend.postgres.ssl_mode"
    static let postgresTimeout = "serenity.macos.backend.postgres.timeout"
  }

  private enum SecretKey {
    static let serenityCloudAccessToken = "serenity.macos.backend.cloud.access_token"
    static let postgresPassword = "serenity.macos.backend.postgres.password"
  }

  private let defaults: UserDefaults
  private let secretStore: KeychainSecretStore

  init(defaults: UserDefaults = .standard, secretStore: KeychainSecretStore = KeychainSecretStore()) {
    self.defaults = defaults
    self.secretStore = secretStore
  }

  func loadSerenityCloudConfiguration() -> SerenityCloudConfiguration? {
    guard
      let baseURLString = defaults.string(forKey: DefaultsKey.serenityCloudBaseURL),
      let baseURL = URL(string: baseURLString),
      let token = (try? secretStore.secret(for: SecretKey.serenityCloudAccessToken)) ?? nil
    else {
      return nil
    }

    let accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !accessToken.isEmpty else {
      return nil
    }

    let timeout = defaults.double(forKey: DefaultsKey.serenityCloudTimeout)
    return SerenityCloudConfiguration(
      baseURL: baseURL,
      accessToken: accessToken,
      timeout: timeout > 0 ? timeout : 15
    )
  }

  @discardableResult
  func saveSerenityCloudConfiguration(
    baseURLString: String,
    accessToken: String,
    timeout: TimeInterval = 15
  ) throws -> SerenityCloudConfiguration {
    let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let baseURL = URL(string: trimmedURL),
      let scheme = baseURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      throw BackendConfigurationStoreError.invalidValue("Enter a valid cloud base URL (http:// or https://).")
    }

    let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      throw BackendConfigurationStoreError.invalidValue("Cloud access token is required.")
    }

    defaults.set(baseURL.absoluteString, forKey: DefaultsKey.serenityCloudBaseURL)
    defaults.set(timeout, forKey: DefaultsKey.serenityCloudTimeout)
    try secretStore.setSecret(trimmedToken, for: SecretKey.serenityCloudAccessToken)

    return SerenityCloudConfiguration(
      baseURL: baseURL,
      accessToken: trimmedToken,
      timeout: timeout
    )
  }

  func clearSerenityCloudConfiguration() {
    defaults.removeObject(forKey: DefaultsKey.serenityCloudBaseURL)
    defaults.removeObject(forKey: DefaultsKey.serenityCloudTimeout)
    try? secretStore.deleteSecret(for: SecretKey.serenityCloudAccessToken)
  }

  func loadExternalPostgresConfiguration() -> ExternalPostgresConfiguration? {
    guard
      let host = defaults.string(forKey: DefaultsKey.postgresHost),
      !host.isEmpty,
      let database = defaults.string(forKey: DefaultsKey.postgresDatabase),
      !database.isEmpty,
      let username = defaults.string(forKey: DefaultsKey.postgresUsername),
      !username.isEmpty,
      let password = (try? secretStore.secret(for: SecretKey.postgresPassword)) ?? nil
    else {
      return nil
    }

    let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPassword.isEmpty else {
      return nil
    }

    let configuredPort = defaults.integer(forKey: DefaultsKey.postgresPort)
    let port = UInt16(clamping: configuredPort == 0 ? 5432 : configuredPort)
    let sslMode = defaults.string(forKey: DefaultsKey.postgresSSLMode) ?? "require"
    let timeout = defaults.double(forKey: DefaultsKey.postgresTimeout)

    return ExternalPostgresConfiguration(
      host: host,
      port: port,
      database: database,
      username: username,
      password: trimmedPassword,
      sslMode: sslMode,
      timeout: timeout > 0 ? timeout : 10
    )
  }

  @discardableResult
  func saveExternalPostgresConfiguration(
    host: String,
    port: UInt16,
    database: String,
    username: String,
    password: String,
    sslMode: String,
    timeout: TimeInterval = 10
  ) throws -> ExternalPostgresConfiguration {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSSLMode = sslMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "require" : sslMode

    guard !trimmedHost.isEmpty else {
      throw BackendConfigurationStoreError.invalidValue("PostgreSQL host is required.")
    }
    guard !trimmedDatabase.isEmpty else {
      throw BackendConfigurationStoreError.invalidValue("PostgreSQL database name is required.")
    }
    guard !trimmedUsername.isEmpty else {
      throw BackendConfigurationStoreError.invalidValue("PostgreSQL username is required.")
    }
    guard !trimmedPassword.isEmpty else {
      throw BackendConfigurationStoreError.invalidValue("PostgreSQL password is required.")
    }

    defaults.set(trimmedHost, forKey: DefaultsKey.postgresHost)
    defaults.set(Int(port), forKey: DefaultsKey.postgresPort)
    defaults.set(trimmedDatabase, forKey: DefaultsKey.postgresDatabase)
    defaults.set(trimmedUsername, forKey: DefaultsKey.postgresUsername)
    defaults.set(normalizedSSLMode, forKey: DefaultsKey.postgresSSLMode)
    defaults.set(timeout, forKey: DefaultsKey.postgresTimeout)
    try secretStore.setSecret(trimmedPassword, for: SecretKey.postgresPassword)

    return ExternalPostgresConfiguration(
      host: trimmedHost,
      port: port,
      database: trimmedDatabase,
      username: trimmedUsername,
      password: trimmedPassword,
      sslMode: normalizedSSLMode,
      timeout: timeout
    )
  }

  func clearExternalPostgresConfiguration() {
    defaults.removeObject(forKey: DefaultsKey.postgresHost)
    defaults.removeObject(forKey: DefaultsKey.postgresPort)
    defaults.removeObject(forKey: DefaultsKey.postgresDatabase)
    defaults.removeObject(forKey: DefaultsKey.postgresUsername)
    defaults.removeObject(forKey: DefaultsKey.postgresSSLMode)
    defaults.removeObject(forKey: DefaultsKey.postgresTimeout)
    try? secretStore.deleteSecret(for: SecretKey.postgresPassword)
  }
}
