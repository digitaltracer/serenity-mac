import Foundation

enum TaskCompletionFilter: String, CaseIterable, Identifiable {
  case all
  case open
  case completed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      return "All"
    case .open:
      return "Open"
    case .completed:
      return "Completed"
    }
  }
}

enum TaskPriorityFilter: String, CaseIterable, Identifiable {
  case any
  case low
  case medium
  case high

  var id: String { rawValue }

  var title: String {
    switch self {
    case .any:
      return "Any Priority"
    case .low:
      return "Low"
    case .medium:
      return "Medium"
    case .high:
      return "High"
    }
  }

  var matches: TaskPriority? {
    switch self {
    case .any:
      return nil
    case .low:
      return .low
    case .medium:
      return .medium
    case .high:
      return .high
    }
  }
}

struct TaskWorkflowFilter: Equatable {
  var query = ""
  var completion: TaskCompletionFilter = .open
  var priority: TaskPriorityFilter = .any
}

enum GlobalSearchResultType: String, CaseIterable, Identifiable, Codable {
  case task
  case project
  case journal
  case goal

  var id: String { rawValue }

  var title: String {
    switch self {
    case .task:
      return "Task"
    case .project:
      return "Project"
    case .journal:
      return "Journal"
    case .goal:
      return "Goal"
    }
  }
}

struct GlobalSearchResult: Identifiable, Equatable, Codable {
  let type: GlobalSearchResultType
  let entityID: String
  let title: String
  let subtitle: String
  let updatedAt: Date

  var id: String { "\(type.rawValue):\(entityID)" }
}

struct GlobalSearchDocument {
  let type: GlobalSearchResultType
  let entityID: String
  let title: String
  let body: String
  let updatedAt: Date
}

extension GlobalSearchResultType {
  var targetSection: AppSection {
    switch self {
    case .task:
      return .actionHub
    case .project:
      return .projects
    case .journal:
      return .journal
    case .goal:
      return .goals
    }
  }

  var systemImage: String {
    switch self {
    case .task:
      return "checklist"
    case .project:
      return "folder"
    case .journal:
      return "book.closed"
    case .goal:
      return "target"
    }
  }
}

struct TaskExportSubtask: Encodable {
  let id: String
  let title: String
  let completed: Bool
  let order: Int
}

struct TaskExportItem: Encodable {
  let id: String
  let title: String
  let description: String?
  let completed: Bool
  let completedAt: Date?
  let priority: String
  let dueDate: Date?
  let projectId: String?
  let tags: [String]
  let subtasks: [TaskExportSubtask]
  let createdAt: Date
  let updatedAt: Date
}

struct ProjectExportItem: Encodable {
  let id: String
  let name: String
  let description: String?
  let color: String
  let icon: String?
  let archived: Bool
  let createdAt: Date
  let updatedAt: Date
}

struct JournalExportItem: Encodable {
  let id: String
  let title: String?
  let content: String
  let date: Date
  let tags: [String]
  let pinned: Bool
  let mood: String?
  let createdAt: Date
  let updatedAt: Date
}

struct GoalExportItem: Encodable {
  let id: String
  let title: String
  let description: String?
  let type: String
  let status: String
  let priority: String
  let progressCurrent: Double
  let progressTarget: Double
  let progressPercentage: Double
  let progressCompleted: Bool
  let createdAt: Date
  let updatedAt: Date
}

struct CoreDataExportSnapshot: Encodable {
  let exportedAt: Date
  let backend: String
  let tasks: [TaskExportItem]
  let projects: [ProjectExportItem]
  let journalEntries: [JournalExportItem]
  let goals: [GoalExportItem]
}

/// Turns a task save into the lines its activity log should carry. Events are
/// rendered once, here, and stored as text — an entry written today has to
/// still read correctly a month from now, so nothing relative goes in.
enum TaskActivityRecorder {
  static func events(
    from old: TaskEntity,
    to new: TaskEntity,
    projectNames: [String: String] = [:],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [TaskActivityEntry] {
    var lines: [String] = []

    if old.title != new.title {
      lines.append("Renamed from \"\(old.title)\"")
    }

    if old.completed != new.completed {
      lines.append(new.completed ? "Marked complete" : "Reopened")
    }

    if old.priority != new.priority {
      lines.append("Priority set to \(new.priority.rawValue.capitalized)")
    }

    if old.dueDate != new.dueDate {
      if let dueDate = new.dueDate {
        lines.append("Due date set to \(stamp(dueDate, calendar: calendar))")
      } else {
        lines.append("Due date cleared")
      }
    }

    if old.projectId != new.projectId {
      if let projectId = new.projectId {
        lines.append("Moved to \(projectNames[projectId] ?? "another project")")
      } else {
        lines.append("Removed from its project")
      }
    }

    lines.append(contentsOf: subtaskLines(from: old, to: new))
    lines.append(contentsOf: tagLines(from: old, to: new))

    return lines.map {
      TaskActivityEntry(id: UUID().uuidString, kind: .event, text: $0, createdAt: now)
    }
  }

  private static func subtaskLines(from old: TaskEntity, to new: TaskEntity) -> [String] {
    var lines: [String] = []
    let before = Dictionary(old.subtasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    for subtask in new.subtasks {
      guard let previous = before[subtask.id] else {
        lines.append("Subtask added · \(subtask.title)")
        continue
      }
      if previous.completed != subtask.completed {
        lines.append("\(subtask.completed ? "Subtask done" : "Subtask reopened") · \(subtask.title)")
      }
    }

    let surviving = Set(new.subtasks.map(\.id))
    for subtask in old.subtasks where !surviving.contains(subtask.id) {
      lines.append("Subtask removed · \(subtask.title)")
    }

    return lines
  }

  private static func tagLines(from old: TaskEntity, to new: TaskEntity) -> [String] {
    guard old.tags != new.tags else { return [] }

    var lines: [String] = []
    let added = new.tags.filter { !old.tags.contains($0) }
    let removed = old.tags.filter { !new.tags.contains($0) }

    if !added.isEmpty {
      lines.append("Tagged \(added.joined(separator: ", "))")
    }
    if !removed.isEmpty {
      lines.append("Untagged \(removed.joined(separator: ", "))")
    }

    return lines
  }

  private static func stamp(_ date: Date, calendar: Calendar) -> String {
    let day = date.formatted(.dateTime.day().month(.abbreviated).year())
    let time = calendar.dateComponents([.hour, .minute], from: date)
    guard (time.hour ?? 0) != 0 || (time.minute ?? 0) != 0 else { return day }
    return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
  }
}
