import Foundation

/// Everything a goal can draw progress from. Passed in whole so reports stay a pure function.
struct GoalProgressInputs {
  var tasks: [TaskEntity] = []
  var routineChecks: [RoutineCheckEntity] = []
  var journalEntries: [JournalEntryEntity] = []
  /// Logged focus time as (when it ended, hours, the goal it was booked to if any).
  var focusHours: [(date: Date, hours: Double, goalId: String?)] = []
}

enum GoalPace: Equatable {
  case done
  case ahead(Double)
  case onPace
  case behind(Double)
  /// No deadline or period to measure against.
  case untimed
}

struct GoalReport: Identifiable {
  struct Point: Equatable {
    let date: Date
    let value: Double
  }

  let goal: GoalEntity
  let kind: GoalKind
  let source: GoalSource
  let current: Double
  let target: Double
  let unit: String
  let windowStart: Date?
  let windowEnd: Date?
  /// Where the goal should be by now if progress were even across the window.
  let expected: Double?
  let pace: GoalPace
  /// Where the current rate lands by the end of the window.
  let projected: Double?
  /// Running total over the window, for the pace chart.
  let series: [Point]
  let lastActivity: Date?
  let daysQuiet: Int?
  let quietThreshold: Int
  /// The goal was paused for the current week, so falling behind doesn't count.
  var isPaused = false
  /// Things that touched an area per day, oldest first, ending today.
  var activityDays: [Int] = []

  var id: String { goal.id }

  /// A hand-logged goal with no unit and nothing logged measures nothing yet, like the old "0 / 10".
  var needsSetup: Bool {
    kind != .area && source == .manual && unit.isEmpty
      && (goal.config.checkIns ?? []).isEmpty && goal.progress.current == 0
  }

  var isManual: Bool {
    kind != .area && source == .manual
  }

  var lastCheckIn: GoalCheckIn? {
    (goal.config.checkIns ?? []).max { $0.date < $1.date }
  }

  /// One-tap amounts for logging: the ones used most recently, or a spread scaled to the target.
  var logPresets: [Double] {
    let recent = (goal.config.checkIns ?? []).sorted { $0.date > $1.date }.map(\.amount).filter { $0 > 0 }
    var presets: [Double] = []
    for amount in recent where !presets.contains(amount) {
      presets.append(amount)
      if presets.count == 3 { break }
    }
    if presets.count >= 2 { return presets.sorted() }
    if target <= 10 { return [1] }
    let step = GoalReport.niceStep(target / 12)
    return [step, step * 2, step * 4]
  }

  /// Logging by one: a small count like books or sessions needs no amount picker.
  var logsByOne: Bool {
    isManual && target <= 10
  }

  static func singular(_ unit: String) -> String {
    unit.hasSuffix("s") && unit.count > 1 ? String(unit.dropLast()) : unit
  }

  static func niceStep(_ value: Double) -> Double {
    guard value > 1 else { return 1 }
    let magnitude = pow(10, floor(log10(value)))
    let leading = value / magnitude
    let nice: Double = leading < 1.5 ? 1 : (leading < 3.5 ? 2 : (leading < 7.5 ? 5 : 10))
    return nice * magnitude
  }

  /// "4 km", "1 book", "3": the unit agrees with the amount and drops away when there is none.
  func amountPhrase(_ amount: Double) -> String {
    [GoalReport.format(amount), unitWord(for: amount)].filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// The pace in words, so nobody has to decode the tick: where you are, where an even pace puts you,
  /// and, when behind on a deadline, where the current rate lands.
  func paceLine(now: Date = Date(), calendar: Calendar = .current) -> String {
    if kind == .area {
      let quiet = "flags after \(quietThreshold) quiet days"
      guard let daysQuiet else { return "Nothing yet · \(quiet)" }
      switch daysQuiet {
      case 0: return "Touched today · \(quiet)"
      case 1: return "Last touched yesterday · \(quiet)"
      default: return "Last touched \(daysQuiet) days ago · \(quiet)"
      }
    }
    if isPaused {
      return "Paused until \(pausedUntilLabel(calendar: calendar)). Missed days won't count as behind."
    }
    var parts = ["\(GoalReport.format(current)) of \(amountPhrase(target))" + periodSuffix]
    if case .done = pace {
      parts.append("done")
    } else if let expected {
      let shown = target >= 10 ? expected.rounded() : (expected * 10).rounded() / 10
      parts.append("should be at \(GoalReport.format(shown)) today")
      if case .behind = pace, kind == .outcome, let projected, projected < target, let due = windowEnd {
        parts.append("at this rate ~\(GoalReport.format(projected.rounded())) by \(due.formatted(.dateTime.day().month(.abbreviated)))")
      }
    }
    return parts.joined(separator: " · ")
  }

  private var periodSuffix: String {
    guard kind == .target else { return "" }
    switch goal.config.timeframe {
    case .monthly: return " this month"
    case .daily: return " today"
    default: return " this week"
    }
  }

  private func pausedUntilLabel(calendar: Calendar) -> String {
    guard let until = goal.config.pausedUntil else { return "next week" }
    return until.formatted(.dateTime.weekday(.wide))
  }

  /// What feeds the goal, so it's clear whether to log anything. Names come from the caller.
  func sourceLine(projectName: String?, routineName: String?) -> String {
    if kind == .area {
      var watched: [String] = []
      if let tag = goal.config.areaTag { watched.append("#\(tag)") }
      if let projectName { watched.append(projectName) }
      let what = watched.isEmpty ? "anything you log here" : "tasks and entries in \(watched.joined(separator: " or ")), and anything you log here"
      return "Counts \(what)"
    }
    switch source {
    case .manual:
      guard !unit.isEmpty else { return "Not counting anything yet" }
      return "You log it · \(unit)"
    case .projectTasks:
      return "Automatic · counts finished tasks in \(projectName ?? "its project")"
    case .completedTasks:
      return "Automatic · counts every task you finish"
    case .routine:
      return "Automatic · counts days you tick \(routineName ?? "its routine")"
    case .journalEntries:
      return "Automatic · counts journal entries"
    case .focusTime:
      return "Automatic · counts finished focus sessions"
    }
  }

  var fraction: Double {
    guard target > 0 else { return 0 }
    return min(max(current / target, 0), 1)
  }

  var expectedFraction: Double? {
    guard let expected, target > 0 else { return nil }
    return min(max(expected / target, 0), 1)
  }

  var isQuiet: Bool {
    guard kind == .area, let daysQuiet else { return false }
    return daysQuiet >= quietThreshold
  }

  var needsAttention: Bool {
    guard goal.status == .active, !isPaused, !needsSetup else { return false }
    if kind == .area { return isQuiet }
    if case .behind = pace { return true }
    return false
  }

  var statusLabel: String {
    if kind == .area {
      guard let daysQuiet else { return "No activity yet" }
      if isQuiet { return "Quiet \(daysQuiet) days" }
      switch daysQuiet {
      case 0:
        return "Touched today"
      case 1:
        return "Touched yesterday"
      default:
        return "Touched \(daysQuiet) days ago"
      }
    }
    if needsSetup { return "Needs setup" }
    if isPaused { return "Paused this week" }
    switch pace {
    case .done:
      return "Done"
    case .ahead(let amount):
      return [GoalReport.format(amount), unitWord(for: amount), "ahead"].filter { !$0.isEmpty }.joined(separator: " ")
    case .onPace:
      return "On pace"
    case .behind(let amount):
      return [GoalReport.format(amount), unitWord(for: amount), "behind"].filter { !$0.isEmpty }.joined(separator: " ")
    case .untimed:
      return "\(GoalReport.format(current)) of \(GoalReport.format(target))"
    }
  }

  var progressLabel: String {
    let label = "\(GoalReport.format(current)) / \(GoalReport.format(target))"
    return unit.isEmpty ? label : "\(label) \(unit)"
  }

  private func unitWord(for amount: Double) -> String {
    // "2 tasks behind" reads naturally; "2 km behind" too. Bare numbers drop the unit.
    if unit.isEmpty { return "" }
    if amount == 1, unit.hasSuffix("s") { return String(unit.dropLast()) }
    return unit
  }

  static func format(_ value: Double) -> String {
    if value.rounded() == value { return String(Int(value)) }
    return String(format: "%.1f", value)
  }
}

enum GoalReports {
  static let defaultQuietDays = 7

  static func report(
    for goal: GoalEntity,
    inputs: GoalProgressInputs,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> GoalReport {
    let config = goal.config
    let kind = config.kind ?? .outcome
    let source = config.source ?? .manual
    let events = events(for: goal, source: source, inputs: inputs, calendar: calendar)
    let quietThreshold = config.quietDays ?? defaultQuietDays
    var report = rawReport(goal: goal, kind: kind, source: source, events: events, inputs: inputs, quietThreshold: quietThreshold, now: now, calendar: calendar)
    report.isPaused = config.pausedUntil.map { $0 > now } ?? false
    if kind == .area {
      report.activityDays = activityDays(events: events, days: 28, now: now, calendar: calendar)
    }
    return report
  }

  /// Counts per day for the last `days` days, oldest first, ending today.
  static func activityDays(events: [(date: Date, amount: Double)], days: Int, now: Date, calendar: Calendar) -> [Int] {
    let today = calendar.startOfDay(for: now)
    var counts = Array(repeating: 0, count: days)
    for event in events {
      let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.date), to: today).day ?? -1
      if offset >= 0, offset < days { counts[days - 1 - offset] += 1 }
    }
    return counts
  }

  private static func rawReport(
    goal: GoalEntity,
    kind: GoalKind,
    source: GoalSource,
    events: [(date: Date, amount: Double)],
    inputs: GoalProgressInputs,
    quietThreshold: Int,
    now: Date,
    calendar: Calendar
  ) -> GoalReport {
    let config = goal.config
    switch kind {
    case .area:
      let lastActivity = events.map(\.date).filter { $0 <= now }.max()
      let daysQuiet = lastActivity.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: now)).day ?? 0 }
      return GoalReport(
        goal: goal,
        kind: kind,
        source: source,
        current: 0,
        target: 0,
        unit: unit(for: goal, source: source),
        windowStart: nil,
        windowEnd: nil,
        expected: nil,
        pace: .untimed,
        projected: nil,
        series: [],
        lastActivity: lastActivity,
        daysQuiet: daysQuiet,
        quietThreshold: quietThreshold
      )

    case .target:
      let component: Calendar.Component = config.timeframe == .monthly ? .month : (config.timeframe == .daily ? .day : .weekOfYear)
      let period = calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
      return timedReport(
        goal: goal,
        kind: kind,
        source: source,
        events: events.filter { period.contains($0.date) },
        target: max(config.targetCount ?? goal.progress.target, 1),
        windowStart: period.start,
        windowEnd: period.end,
        now: now,
        quietThreshold: quietThreshold
      )

    case .outcome:
      let start = config.startDate ?? goal.createdAt
      // Project tasks count whenever they were finished: the project's history is the goal's.
      let counted = source == .projectTasks ? events : events.filter { $0.date >= start }
      return timedReport(
        goal: goal,
        kind: kind,
        source: source,
        events: counted,
        target: max(outcomeTarget(for: goal, source: source, inputs: inputs), 1),
        windowStart: start,
        windowEnd: config.dueDate,
        now: now,
        quietThreshold: quietThreshold
      )
    }
  }

  /// A project goal with no explicit target finishes when the project's tasks are all done.
  private static func outcomeTarget(for goal: GoalEntity, source: GoalSource, inputs: GoalProgressInputs) -> Double {
    if let explicit = goal.config.targetCount, explicit > 0 { return explicit }
    if source == .projectTasks, let projectId = goal.config.projectId {
      return Double(inputs.tasks.filter { $0.projectId == projectId }.count)
    }
    return goal.progress.target
  }

  private static func timedReport(
    goal: GoalEntity,
    kind: GoalKind,
    source: GoalSource,
    events: [(date: Date, amount: Double)],
    target: Double,
    windowStart: Date,
    windowEnd: Date?,
    now: Date,
    quietThreshold: Int
  ) -> GoalReport {
    let sorted = events.sorted { $0.date < $1.date }
    let current = sorted.reduce(0) { $0 + $1.amount }

    // Project history from before the window starts the line at its real height.
    var running = sorted.filter { $0.date < windowStart }.reduce(0) { $0 + $1.amount }
    var series = [GoalReport.Point(date: windowStart, value: running)]
    for event in sorted where event.date >= windowStart {
      running += event.amount
      series.append(GoalReport.Point(date: event.date, value: running))
    }
    if now > windowStart {
      series.append(GoalReport.Point(date: min(now, windowEnd ?? now), value: current))
    }

    var expected: Double?
    var projected: Double?
    let pace: GoalPace

    if current >= target {
      pace = .done
    } else if let windowEnd, windowEnd > windowStart {
      let total = windowEnd.timeIntervalSince(windowStart)
      let elapsed = min(max(now.timeIntervalSince(windowStart), 0), total)
      let expectedValue = target * elapsed / total
      expected = expectedValue
      if elapsed >= 86_400 {
        projected = current / elapsed * total
      }
      let delta = current - expectedValue
      let tolerance = max(0.5, target * 0.03)
      if abs(delta) < tolerance {
        pace = .onPace
      } else if delta > 0 {
        pace = .ahead(delta.rounded())
      } else {
        pace = .behind((-delta).rounded(.up))
      }
    } else {
      pace = .untimed
    }

    return GoalReport(
      goal: goal,
      kind: kind,
      source: source,
      current: current,
      target: target,
      unit: unit(for: goal, source: source),
      windowStart: windowStart,
      windowEnd: windowEnd,
      expected: expected,
      pace: pace,
      projected: projected,
      series: series,
      lastActivity: sorted.last?.date,
      daysQuiet: nil,
      quietThreshold: quietThreshold
    )
  }

  private static func unit(for goal: GoalEntity, source: GoalSource) -> String {
    if let unit = goal.config.unit?.trimmingCharacters(in: .whitespaces), !unit.isEmpty { return unit }
    switch source {
    case .manual:
      return ""
    case .projectTasks, .completedTasks:
      return "tasks"
    case .routine:
      return "days"
    case .journalEntries:
      return "entries"
    case .focusTime:
      return "h"
    }
  }

  private static func events(
    for goal: GoalEntity,
    source: GoalSource,
    inputs: GoalProgressInputs,
    calendar: Calendar
  ) -> [(date: Date, amount: Double)] {
    let config = goal.config
    var events: [(date: Date, amount: Double)] = (config.checkIns ?? []).map { ($0.date, $0.amount) }

    // Goals from before kinds existed kept their count in `progress.current`.
    if config.kind == nil, goal.progress.current > 0 {
      events.append((goal.createdAt, goal.progress.current))
    }

    if config.kind == .area {
      let tag = config.areaTag?.lowercased()
      for task in inputs.tasks where task.completed {
        let matches = (config.projectId != nil && task.projectId == config.projectId)
          || (tag.map { tag in task.tags.contains { $0.lowercased() == tag } } ?? false)
        if matches { events.append((task.completedAt ?? task.updatedAt, 1)) }
      }
      if let tag {
        for entry in inputs.journalEntries where entry.tags.contains(where: { $0.lowercased() == tag }) {
          events.append((entry.date, 1))
        }
      }
      return events
    }

    switch source {
    case .manual:
      break
    case .projectTasks:
      for task in inputs.tasks where task.completed && task.projectId == config.projectId && config.projectId != nil {
        events.append((task.completedAt ?? task.updatedAt, 1))
      }
    case .completedTasks:
      for task in inputs.tasks where task.completed {
        events.append((task.completedAt ?? task.updatedAt, 1))
      }
    case .routine:
      for check in inputs.routineChecks where check.routineId == config.routineId && check.status == .done {
        if let day = date(fromDayKey: check.day, calendar: calendar) {
          events.append((day, 1))
        }
      }
    case .journalEntries:
      for entry in inputs.journalEntries {
        events.append((entry.date, 1))
      }
    case .focusTime:
      // A block booked to another goal is that goal's; unbooked blocks count for every focus goal.
      for entry in inputs.focusHours where entry.goalId == nil || entry.goalId == goal.id {
        events.append((entry.date, entry.hours))
      }
    }
    return events
  }

  /// Noon on the day, so a period boundary at midnight never drops it.
  static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }
}

/// The editable shape of a goal, shared by the new-goal and edit sheets.
struct GoalDraft: Equatable {
  var title = ""
  var why = ""
  var kind: GoalKind = .outcome
  var source: GoalSource = .manual
  var target: Double = 10
  var unit = ""
  var timeframe: GoalTimeframe = .weekly
  var dueDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
  var projectId: String?
  var routineId: String?
  var areaTag = ""
  var quietDays = GoalReports.defaultQuietDays

  init() {}

  init(goal: GoalEntity) {
    let config = goal.config
    title = goal.title
    why = goal.description ?? ""
    kind = config.kind ?? .outcome
    source = config.source ?? .manual
    target = config.targetCount ?? goal.progress.target
    unit = config.unit ?? ""
    timeframe = config.timeframe
    dueDate = config.dueDate ?? dueDate
    projectId = config.projectId
    routineId = config.routineId
    areaTag = config.areaTag ?? ""
    quietDays = config.quietDays ?? GoalReports.defaultQuietDays
  }

  /// Applies the draft over `config`, keeping check-ins and anything the draft does not edit.
  func apply(to config: GoalConfig, now: Date) -> GoalConfig {
    var config = config
    config.kind = kind
    config.source = kind == .area ? .manual : source
    config.targetCount = kind == .area ? nil : target
    config.unit = unit.trimmingCharacters(in: .whitespaces).isEmpty ? nil : unit.trimmingCharacters(in: .whitespaces)
    config.timeframe = kind == .target ? timeframe : .weekly
    config.dueDate = kind == .outcome ? dueDate : nil
    config.startDate = config.startDate ?? now
    config.projectId = projectId
    config.routineId = source == .routine ? routineId : nil
    config.areaTag = areaTag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : areaTag.trimmingCharacters(in: .whitespaces)
    config.quietDays = kind == .area ? quietDays : nil
    return config
  }
}

extension GoalDraft {
  /// What most likely counts toward a goal with this name: a routine it names, focus or journal
  /// words, or a project when finishing something. Anything else is logged by hand.
  func suggestedSource(routines: [RoutineEntity], projects: [ProjectEntity]) -> GoalSource {
    let name = title.lowercased()
    if kind == .outcome, !projects.isEmpty { return .projectTasks }
    if let routine = routines.first(where: { !$0.title.isEmpty && name.contains($0.title.lowercased()) }), !routine.archived {
      return .routine
    }
    if ["focus", "deep work", "hours of"].contains(where: name.contains) { return .focusTime }
    if ["journal", "write daily", "diary"].contains(where: name.contains) { return .journalEntries }
    return .manual
  }

  /// The routine a name points at, so choosing "Days you tick a routine" can preselect it.
  func matchingRoutine(in routines: [RoutineEntity]) -> RoutineEntity? {
    let name = title.lowercased()
    return routines.first { !$0.archived && !$0.title.isEmpty && name.contains($0.title.lowercased()) }
  }

  /// The unit a source implies; only hand-logged goals name their own.
  var effectiveUnit: String {
    switch source {
    case .manual: return unit.trimmingCharacters(in: .whitespaces)
    case .projectTasks, .completedTasks: return "tasks"
    case .routine: return "days"
    case .journalEntries: return "entries"
    case .focusTime: return "hours"
    }
  }

  var needsUnit: Bool {
    kind != .area && source == .manual && unit.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// The goal in one sentence, as it will behave once saved.
  func previewSentence(projectName: String?, routineName: String?, targetText: String) -> String {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "This goal" : title.trimmingCharacters(in: .whitespacesAndNewlines)
    if kind == .area {
      let watched = [areaTag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "#\(areaTag.trimmingCharacters(in: .whitespaces))", projectName]
        .compactMap { $0 }
      let what = watched.isEmpty ? "you log here" : "in \(watched.joined(separator: " or ")) is finished, written or logged"
      return "\(name) stays on your list with no number. If nothing \(what) for \(quietDays) days, Serenity flags it on Today."
    }
    if needsUnit { return "\(name) needs a unit before it can track anything, like km or pages." }
    let amount = targetText.trimmingCharacters(in: .whitespaces)
    let how: String
    switch source {
    case .manual: how = "You log it yourself from the goal or the Today card."
    case .projectTasks: how = "Finishing tasks in \(projectName ?? "the project") moves it."
    case .completedTasks: how = "Every task you finish counts."
    case .routine: how = "Ticking \(routineName ?? "the routine") counts. Nothing else to log."
    case .journalEntries: how = "Each journal entry counts."
    case .focusTime: how = "Finished focus sessions count."
    }
    if kind == .target {
      let period = timeframe == .monthly ? "month" : "week"
      return "\(amount.isEmpty ? "?" : amount) \(effectiveUnit) every \(period). \(how)"
    }
    let due = dueDate.formatted(.dateTime.day().month(.wide))
    if source == .projectTasks && amount.isEmpty {
      return "Finish by \(due), when every task in \(projectName ?? "the project") is done. \(how)"
    }
    return "Reach \(amount.isEmpty ? "?" : amount) \(effectiveUnit) by \(due). \(how)"
  }
}

