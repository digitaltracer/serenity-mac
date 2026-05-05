import Foundation
import GoogleSignIn

enum IntegrationProvider: String, CaseIterable, Identifiable, Sendable {
  case google
  case github

  var id: String { rawValue }

  var title: String {
    switch self {
    case .google:
      return "Google Calendar"
    case .github:
      return "GitHub"
    }
  }
}

enum GoogleCalendarConfiguration {
  static let clientIDInfoKey = "GOOGLE_CLIENT_ID"
  static let reversedClientIDInfoKey = "GOOGLE_REVERSED_CLIENT_ID"
  static let bundleURLTypesInfoKey = "CFBundleURLTypes"
  static let bundleURLSchemesInfoKey = "CFBundleURLSchemes"
  static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
  static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
  static let calendarEventsURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

  static var requiredScopes: [String] {
    [calendarReadonlyScope]
  }

  static var isConfigured: Bool {
    guard clientID != nil, let reversedClientID else {
      return false
    }

    let urlTypes = Bundle.main.object(forInfoDictionaryKey: bundleURLTypesInfoKey) as? [[String: Any]] ?? []
    return urlTypes.contains { type in
      let schemes = type[bundleURLSchemesInfoKey] as? [String] ?? []
      return schemes.contains(reversedClientID)
    }
  }

  static var clientID: String? {
    infoString(for: clientIDInfoKey)
  }

  static var reversedClientID: String? {
    infoString(for: reversedClientIDInfoKey)
  }

  @discardableResult
  static func handleSignInURL(_ url: URL) -> Bool {
    GIDSignIn.sharedInstance.handle(url)
  }

  private static func infoString(for key: String) -> String? {
    let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else { return nil }
    guard !trimmed.hasPrefix("$(") || !trimmed.hasSuffix(")") else { return nil }
    return trimmed
  }
}

struct GoogleIntegrationSession: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date?
  var userEmail: String?
  var connectedAt: Date
}

struct GoogleIntegrationState: Equatable, Sendable {
  var connected: Bool
  var userEmail: String?
  var expiresAt: Date?
  var syncEnabled: Bool
  var lastSyncAt: Date?
  var lastError: String?

  static let disconnected = GoogleIntegrationState(
    connected: false,
    userEmail: nil,
    expiresAt: nil,
    syncEnabled: false,
    lastSyncAt: nil,
    lastError: nil
  )
}

struct GitHubTokenRecord: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var token: String
  var displayName: String
  var username: String
  var isActive: Bool
  var createdAt: Date
  var updatedAt: Date
  var lastValidatedAt: Date?
  var lastSyncAt: Date?

  var maskedToken: String {
    let suffix = token.suffix(4)
    return "••••\(suffix)"
  }
}

struct GitHubIntegrationState: Equatable, Sendable {
  var tokens: [GitHubTokenRecord]
  var syncEnabled: Bool
  var lastSyncAt: Date?
  var lastError: String?

  static let empty = GitHubIntegrationState(
    tokens: [],
    syncEnabled: false,
    lastSyncAt: nil,
    lastError: nil
  )
}

struct IntegrationSyncOutcome: Equatable, Sendable {
  var provider: IntegrationProvider
  var importedTasks: Int
  var detail: String
}

struct IntegrationDiagnosticsSnapshot: Equatable, Sendable {
  var lines: [String]
}

struct GoogleCalendarSyncPayload: Sendable {
  var tasks: [TaskEntity]
  var project: ProjectEntity?
  var importedCount: Int
}

struct GitHubSyncPayload: Sendable {
  var tasks: [TaskEntity]
  var project: ProjectEntity?
  var importedCount: Int
}
