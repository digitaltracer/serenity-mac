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
  case costCenter
  case database
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
    case .costCenter:
      return "Cost Center"
    case .database:
      return "Database"
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
    case .costCenter:
      return "dollarsign.circle"
    case .database:
      return "internaldrive"
    case .settings:
      return "gearshape"
    }
  }
}

public enum SettingsTab: String, CaseIterable, Identifiable, Equatable {
  case appearance
  case aiProvider
  case backend
  case auth
  case appLock
  case localDatabase
  case diagnostics

  public static var allCases: [SettingsTab] {
    [.appearance, .aiProvider, .appLock]
  }

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .appearance:
      return "Appearance"
    case .aiProvider:
      return "AI Provider"
    case .backend:
      return "Backend"
    case .auth:
      return "Auth"
    case .appLock:
      return "App Lock"
    case .localDatabase:
      return "Local Database"
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
    case .backend:
      return "server.rack"
    case .auth:
      return "person.crop.circle.badge.checkmark"
    case .appLock:
      return "lock.shield"
    case .localDatabase:
      return "cylinder.split.1x2"
    case .diagnostics:
      return "stethoscope"
    }
  }
}
