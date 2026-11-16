import Foundation

public enum AppSection: String, CaseIterable, Identifiable {
  case home
  case actionHub
  case standup
  case journal
  case goals
  case routines
  case review
  case projects
  case integrations
  case settings

  public var id: String { rawValue }

  /// Sidebar order. The first nine take ⌘1–⌘9; Settings, last, takes ⌘, instead. `allCases` is
  /// the declaration order and is not guaranteed to match what the user sees.
  static let navigationOrder: [AppSection] = [
    .home, .actionHub, .standup, .journal, .goals, .routines, .review, .integrations, .settings,
  ]

  var title: String {
    switch self {
    case .home:
      return "Today"
    case .actionHub:
      return "ActionHub"
    case .standup:
      return "Stand-up"
    case .journal:
      return "Journal"
    case .goals:
      return "Goals"
    case .routines:
      return "Routines"
    case .review:
      return "Weekly review"
    case .projects:
      return "Projects"
    case .integrations:
      return "Integrations"
    case .settings:
      return "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .home:
      return "sun.max"
    case .actionHub:
      return "checklist"
    case .standup:
      return "mic"
    case .journal:
      return "book"
    case .goals:
      return "target"
    case .routines:
      return "repeat"
    case .review:
      return "calendar.badge.checkmark"
    case .projects:
      return "folder"
    case .integrations:
      return "globe"
    case .settings:
      return "gearshape"
    }
  }
}

public enum SettingsTab: String, CaseIterable, Identifiable, Equatable {
  case appearance
  case aiProvider
  case costCenter
  case backend
  case auth
  case appLock
  case database
  case diagnostics
  case claude

  public static var allCases: [SettingsTab] {
    #if os(macOS)
    [.appearance, .aiProvider, .claude, .costCenter, .appLock, .database]
    #else
    [.appearance, .aiProvider, .costCenter, .appLock, .database]
    #endif
  }

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .appearance:
      return "Appearance"
    case .aiProvider:
      return "AI Provider"
    case .costCenter:
      return "Cost Center"
    case .backend:
      return "Backend"
    case .auth:
      return "Auth"
    case .appLock:
      return "App Lock"
    case .database:
      return "Database"
    case .diagnostics:
      return "Diagnostics"
    case .claude:
      return "Claude"
    }
  }

  var systemImage: String {
    switch self {
    case .appearance:
      return "paintpalette"
    case .aiProvider:
      return "key.horizontal.fill"
    case .costCenter:
      return "dollarsign.circle"
    case .backend:
      return "server.rack"
    case .auth:
      return "person.crop.circle.badge.checkmark"
    case .appLock:
      return "lock.shield"
    case .database:
      return "internaldrive"
    case .diagnostics:
      return "stethoscope"
    case .claude:
      return "sparkles"
    }
  }
}
