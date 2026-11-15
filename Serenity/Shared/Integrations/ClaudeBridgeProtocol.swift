import Foundation

/// The line protocol between Serenity and its Claude connector: one JSON object per line each way.
/// A request is `{"id": 1, "method": "tasks.add", "params": {...}}`; the reply carries the same id
/// and either `result` or `error`.
enum ClaudeBridgeWire {
  static let socketFileName = "claude-bridge.sock"
  /// Longer lines are refused, so a stuck client can't grow the buffer without end.
  static let maximumLineBytes = 1_048_576

  static func socketURL(fileManager: FileManager = .default) -> URL? {
    guard let support = try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ) else { return nil }
    return support
      .appendingPathComponent("Serenity", isDirectory: true)
      .appendingPathComponent(socketFileName)
  }
}

struct ClaudeBridgeRequest: Decodable {
  let id: Int
  let method: String
}

struct ClaudeBridgeFailure: Codable, Error, Equatable {
  enum Code: String, Codable {
    case invalidRequest = "invalid_request"
    case unknownMethod = "unknown_method"
    case invalidParams = "invalid_params"
    case notFound = "not_found"
    case journalOff = "journal_off"
    case locked
    case failed
  }

  let code: Code
  let message: String

  static func invalidParams(_ message: String) -> Self { .init(code: .invalidParams, message: message) }
  static func notFound(_ message: String) -> Self { .init(code: .notFound, message: message) }
  static func failed(_ message: String) -> Self { .init(code: .failed, message: message) }
}

/// Dates cross the bridge as local calendar days (`2026-11-15`) or moments with an offset
/// (`2026-11-15T14:30:00+05:30`). Tasks with no time are stored at midnight, so midnight reads as a day.
enum ClaudeBridgeDates {
  static func day(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func moment(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  static func due(_ date: Date, calendar: Calendar = .current) -> String {
    hasTime(date, calendar: calendar) ? moment(date, timeZone: calendar.timeZone) : day(date, calendar: calendar)
  }

  static func hasTime(_ date: Date, calendar: Calendar = .current) -> Bool {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return parts.hour != 0 || parts.minute != 0
  }

  /// Reads a day, a moment with an offset, or a local moment without one (`2026-11-15T14:30`).
  static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let dayParts = trimmed.split(separator: "-").compactMap { Int($0) }
    if trimmed.count == 10, dayParts.count == 3 {
      let components = DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2])
      guard let date = calendar.date(from: components),
            calendar.component(.day, from: date) == dayParts[2] else { return nil }
      return calendar.startOfDay(for: date)
    }
    let withOffset = ISO8601DateFormatter()
    withOffset.formatOptions = [.withInternetDateTime]
    if let date = withOffset.date(from: trimmed) { return date }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.calendar = calendar
    local.timeZone = calendar.timeZone
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
      local.dateFormat = format
      if let date = local.date(from: trimmed) { return date }
    }
    return nil
  }
}

// MARK: - Results

struct ClaudeStatusResult: Codable, Equatable {
  let app: String
  let version: String
  let today: String
  let timeZone: String
  let journalAccess: Bool
}

struct ClaudeTaskSnapshot: Codable, Equatable {
  let id: String
  let title: String
  let notes: String?
  let done: Bool
  let due: String?
  let priority: String
  let project: String?
  let topThree: Bool
}

struct ClaudeFocusSnapshot: Codable, Equatable {
  let id: String
  let title: String
  /// running, paused, planned or done.
  let status: String
  let startedAt: String?
  /// Focused time so far, leaving out pauses.
  let focusedMinutes: Int
  /// Nil for a session with no set length.
  let lengthMinutes: Int?
  let remainingMinutes: Int?
  /// Second-level counts, so a card can run its own clock between refreshes.
  let focusedSeconds: Int
  let remainingSeconds: Int?
  let taskId: String?
  let taskTitle: String?
  let journalEntryId: String?
}

struct ClaudePlanSnapshot: Codable, Equatable {
  let title: String
  /// calendar, task or focus.
  let kind: String
  let start: String
  let end: String
  let done: Bool
}

struct ClaudeRoutineSnapshot: Codable, Equatable {
  let id: String
  let title: String
  let scheduledToday: Bool
  /// done, skipped, or nil when today is still open.
  let today: String?
  let streak: String
  let thisWeek: String?
}

struct ClaudeGoalSnapshot: Codable, Equatable {
  let id: String
  let title: String
  let kind: String
  let progress: String
  let pace: String
  /// done, ahead, onPace, behind or untimed.
  let paceState: String
  let current: Double
  let target: Double
  /// Where the goal should be by now; nil without a deadline.
  let expected: Double?
  let unit: String
  let due: String?
}

struct ClaudeJournalSnapshot: Codable, Equatable {
  let id: String
  let title: String
  let date: String
  let content: String
  let truncated: Bool
  let tags: [String]
}

struct ClaudeTodayResult: Codable, Equatable {
  let date: String
  let focus: ClaudeFocusSnapshot?
  let topThree: [ClaudeTaskSnapshot]
  let dueToday: [ClaudeTaskSnapshot]
  let overdue: [ClaudeTaskSnapshot]
  let plan: [ClaudePlanSnapshot]
  let routines: [ClaudeRoutineSnapshot]
  let goals: [ClaudeGoalSnapshot]
  let inboxCount: Int
}

struct ClaudeWeekResult: Codable, Equatable {
  struct RoutineLine: Codable, Equatable {
    let title: String
    let done: Int
  }

  let weekStart: String
  let weekEnd: String
  let completedTasks: [String]
  let focusHours: Double
  let routines: [RoutineLine]
  let goals: [ClaudeGoalSnapshot]
}

/// The session under way, or an explicit null when there is none.
struct ClaudeFocusResult: Codable, Equatable {
  let focus: ClaudeFocusSnapshot?
  /// Set when starting a session finished one that was already running.
  var finishedPrevious: ClaudeFocusSnapshot?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(focus, forKey: .focus)
    try container.encodeIfPresent(finishedPrevious, forKey: .finishedPrevious)
  }
}

struct ClaudeListResult<Item: Codable & Equatable>: Codable, Equatable {
  let items: [Item]
}

// MARK: - Settings and activity

struct ClaudeBridgeActivity: Codable, Equatable, Identifiable {
  var id: Date { date }
  let date: Date
  let summary: String
}

/// Per-device: connecting this Mac to Claude says nothing about another device.
@MainActor
final class ClaudeBridgeSettings: ObservableObject {
  static let enabledKey = "serenity.claude.enabled"
  static let journalAccessKey = "serenity.claude.journalAccess"
  static let activityKey = "serenity.claude.activity"
  static let activityLimit = 50

  @Published var isEnabled: Bool {
    didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
  }

  @Published var journalAccess: Bool {
    didSet { defaults.set(journalAccess, forKey: Self.journalAccessKey) }
  }

  /// Newest first: every change Claude made, so nothing it does goes unseen.
  @Published private(set) var activity: [ClaudeBridgeActivity]

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    journalAccess = defaults.bool(forKey: Self.journalAccessKey)
    activity = defaults.data(forKey: Self.activityKey)
      .flatMap { try? JSONDecoder().decode([ClaudeBridgeActivity].self, from: $0) } ?? []
  }

  func record(_ summary: String, at date: Date = Date()) {
    activity = Array(([ClaudeBridgeActivity(date: date, summary: summary)] + activity).prefix(Self.activityLimit))
    defaults.set(try? JSONEncoder().encode(activity), forKey: Self.activityKey)
  }

  func clearActivity() {
    activity = []
    defaults.removeObject(forKey: Self.activityKey)
  }
}
