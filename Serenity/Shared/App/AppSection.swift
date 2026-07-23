import Foundation

public enum AppSection: String, CaseIterable, Identifiable {
  case today
  case tasks
  case projects
  case journal
  case goals
  case insights
  case settings

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .today:
      return "Today"
    case .tasks:
      return "Tasks"
    case .projects:
      return "Projects"
    case .journal:
      return "Journal"
    case .goals:
      return "Goals"
    case .insights:
      return "Insights"
    case .settings:
      return "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .today:
      return "calendar"
    case .tasks:
      return "checkmark.circle"
    case .projects:
      return "folder"
    case .journal:
      return "book.closed"
    case .goals:
      return "target"
    case .insights:
      return "sparkles"
    case .settings:
      return "gearshape"
    }
  }
}

public enum SettingsTab: String, CaseIterable, Identifiable, Equatable {
  case general
  case ai
  case syncBackend
  case advanced

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .general:
      return "General"
    case .ai:
      return "AI"
    case .syncBackend:
      return "Sync & Backend"
    case .advanced:
      return "Advanced"
    }
  }

  var systemImage: String {
    switch self {
    case .general:
      return "gearshape"
    case .ai:
      return "sparkles"
    case .syncBackend:
      return "arrow.triangle.2.circlepath"
    case .advanced:
      return "wrench.and.screwdriver"
    }
  }
}
