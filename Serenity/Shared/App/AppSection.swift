import Foundation

public enum AppSection: String, CaseIterable, Identifiable {
  case home
  case actionHub
  case journal
  case goals
  case projects
  case integrations
  case insights
  case aiSummaries
  case settings

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .home:
      return "Home"
    case .actionHub:
      return "ActionHub"
    case .journal:
      return "Journal"
    case .goals:
      return "Goals"
    case .projects:
      return "Projects"
    case .integrations:
      return "Integrations"
    case .insights:
      return "Insights"
    case .aiSummaries:
      return "AI Summaries"
    case .settings:
      return "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .home:
      return "house"
    case .actionHub:
      return "checklist"
    case .journal:
      return "book"
    case .goals:
      return "target"
    case .projects:
      return "folder"
    case .integrations:
      return "globe"
    case .insights:
      return "chart.bar.xaxis"
    case .aiSummaries:
      return "sparkles"
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

  public static var allCases: [SettingsTab] {
    [.appearance, .aiProvider, .costCenter, .appLock, .database]
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
    }
  }
}
