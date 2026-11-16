import Foundation

/// Everything one weekly review is computed from. Journal entries count only when `useJournal` is on.
struct WeeklyRecapInputs {
  var tasks: [TaskEntity] = []
  var projects: [ProjectEntity] = []
  var focusBlocks: [FocusBlockEntity] = []
  var routines: [RoutineEntity] = []
  var routineChecks: [RoutineCheckEntity] = []
  var goals: [GoalEntity] = []
  var journalEntries: [JournalEntryEntity] = []
  var useJournal = false
  /// "Not useful" answers from earlier reviews; they push the same kind of finding down.
  var feedback: [WeeklyFindingFeedback] = []
}

struct WeeklyFindingFeedback: Codable, Equatable {
  enum Reason: String, Codable, CaseIterable {
    case knewThis
    case numbersWrong
    case fineThisWeek

    var label: String {
      switch self {
      case .knewThis: return "I knew this"
      case .numbersWrong: return "The numbers are wrong"
      case .fineThisWeek: return "Fine this week"
      }
    }
  }

  var findingId: String
  var kind: WeeklyFinding.Kind
  var reason: Reason
  var weekStart: Date
}

/// One row behind a claim. `ref` is the id of the record it came from, so a model citing it can be checked.
struct WeeklyEvidence: Codable, Equatable {
  enum Source: String, Codable {
    case task
    case focus
    case journal
    case routine
    case calendar
    case goal
    case week
  }

  var source: Source
  var ref: String
  var date: Date?
  var when: String
  var what: String
  var meta: String
}

/// The one thing a finding offers to do. Each case is something Serenity can do and undo on its own.
enum WeeklyAction: Codable, Equatable {
  case bookFocus(title: String, goalId: String?, slots: [DateInterval])
  case firstOnToday(taskId: String)
  case lateEveningReminder(routineId: String, hour: Int, minute: Int)
  case scheduleTask(taskId: String, day: Date)
  case pauseGoal(goalId: String)
}

struct WeeklyFinding: Codable, Equatable, Identifiable {
  enum Kind: String, Codable, CaseIterable {
    case goalAtRisk
    case routineAfterLateEvening
    case stuckTask
    case deepWorkBelowBaseline
    case quietArea
    case moodAfterBusyDays

    var tag: String {
      switch self {
      case .goalAtRisk: return "Goal at risk"
      case .routineAfterLateEvening, .moodAfterBusyDays: return "Pattern"
      case .stuckTask: return "Stuck"
      case .deepWorkBelowBaseline: return "Below your usual"
      case .quietArea: return "Quiet"
      }
    }

    /// Needs the four weeks before to say anything honest.
    var needsHistory: Bool {
      switch self {
      case .routineAfterLateEvening, .deepWorkBelowBaseline, .moodAfterBusyDays: return true
      case .goalAtRisk, .stuckTask, .quietArea: return false
      }
    }
  }

  /// Kind plus subject, so the same finding about the same thing keeps its id from week to week.
  var id: String
  var kind: Kind
  var subjectId: String
  var linked: String
  var title: String
  var body: String
  var evidenceLabel: String
  var evidence: [WeeklyEvidence]
  var action: WeeklyAction?
  var actionTitle: String?
  var score: Double

  var tag: String { kind.tag }
}

struct WeeklyRecap: Equatable {
  struct ProjectCount: Equatable {
    let name: String
    let count: Int
  }

  struct TaskMetric: Equatable {
    let done: Int
    let baseline: Double?
    let byProject: [ProjectCount]
  }

  struct FocusMetric: Equatable {
    let hours: Double
    let baseline: Double?
    /// From a weekly focus-time goal, when there is one.
    let target: Double?
    let goalId: String?
    let emptyDays: [Date]
  }

  struct RoutineMetric: Equatable {
    let routineId: String
    let title: String
    let done: Int
    let expected: Int
    let missed: [Date]
    let baseline: Double?
  }

  struct Session: Equatable {
    let id: String
    let title: String
    let hours: Double
    let projectId: String?
    let projectName: String?
    let date: Date
  }

  struct ProjectHours: Equatable {
    let projectId: String?
    let name: String
    let hours: Double
  }

  struct Item: Equatable {
    let id: String
    let title: String
    let date: Date
  }

  struct JournalNote: Equatable {
    let id: String
    let title: String
    let excerpt: String
    let mood: Int?
    let date: Date
  }

  struct Day: Equatable {
    let date: Date
    let focus: [ProjectHours]
    let sessions: [Session]
    let done: [Item]
    let calendar: [Item]
    let journal: [JournalNote]
    /// Out of 5; nil without a mooded entry or with the journal switch off.
    let mood: Int?
    let routineMarks: [String: RoutineDayMark]
    /// An event at 19:00 or later.
    let lateEvent: Item?

    var focusHours: Double { focus.reduce(0) { $0 + $1.hours } }
  }

  struct CarryItem: Equatable {
    let taskId: String
    let title: String
    let projectName: String?
    let dueDate: Date?
    let moves: Int
    let focusHours: Double
    let createdAt: Date
  }

  struct GoalSnapshot: Equatable {
    let current: Double
    let target: Double
    let expected: Double?
    let pace: GoalPace
    let statusLabel: String
    let daysQuiet: Int?
  }

  struct GoalChange: Equatable {
    let goalId: String
    let title: String
    let kind: GoalKind
    let unit: String
    let before: GoalSnapshot
    let after: GoalSnapshot
    let dueDate: Date?
    let isPaused: Bool
    let needsSetup: Bool
    let lastActivity: Date?
  }

  struct Line: Equatable {
    let id: String
    let text: String
    let source: String
  }

  struct SourceCounts: Equatable {
    var tasks = 0
    var sessions = 0
    var journal = 0
    var routineChecks = 0
    var calendar = 0
  }

  let weekStart: Date
  let weekEnd: Date
  let weeksOfHistory: Int
  let tasks: TaskMetric
  let focus: FocusMetric
  let routines: [RoutineMetric]
  let days: [Day]
  let carryOver: [CarryItem]
  let goals: [GoalChange]
  let findings: [WeeklyFinding]
  let moved: [Line]
  let stalled: [Line]
  let sources: SourceCounts
  let usedJournal: Bool

  var hasPatterns: Bool { weeksOfHistory >= WeeklyRecap.historyWeeks }

  static let historyWeeks = 4
  static let maxFindings = 3
  static let lateEveningHour = 19
  static let focusSlotHour = 9
  static let focusSlotMinutes = 90
  static let calendarEventMinutes: Double = 60
  static let somedayTag = "someday"

  /// Journal mood on a five-point scale, low to high.
  static func moodScore(_ mood: JournalMood) -> Int {
    switch mood {
    case .sad: return 1
    case .stressed: return 2
    case .neutral: return 3
    case .happy: return 4
    case .excited: return 5
    }
  }

  static func isCalendarEvent(_ task: TaskEntity) -> Bool {
    task.tags.contains(TodayBriefing.calendarTag)
  }

  static let stopwords: Set<String> = ["about", "after", "again", "before", "check", "email", "follow", "maybe", "should", "their", "there", "these", "thing", "things", "today", "tomorrow", "update", "write", "which", "would"]

  /// The longest word worth matching in a journal entry, or nil when a title has none.
  static func keyword(in title: String) -> String? {
    title.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count >= 5 && !stopwords.contains($0) }
      .max { $0.count < $1.count }
  }

  /// Due-date changes in the task's history; the log only records changes, never the first date.
  static func dueMoves(_ task: TaskEntity) -> [Date] {
    task.activity
      .filter { $0.kind == .event && ($0.text.hasPrefix("Due date set to") || $0.text == "Due date cleared") }
      .map(\.createdAt)
      .sorted()
  }
}

// MARK: - Building

extension WeeklyRecap {
  static func build(
    inputs: WeeklyRecapInputs,
    weekStart: Date,
    now: Date,
    calendar: Calendar = WeeklyReview.calendar,
    goalCalendar: Calendar = .current,
    locale: Locale = .current
  ) -> WeeklyRecap {
    Builder(inputs: inputs, weekStart: weekStart, now: now, calendar: calendar, goalCalendar: goalCalendar, locale: locale).build()
  }
}

private struct Builder {
  let inputs: WeeklyRecapInputs
  let weekStart: Date
  let weekEnd: Date
  let now: Date
  let calendar: Calendar
  let format: RecapFormat
  let projectNames: [String: String]
  let tasksByID: [String: TaskEntity]
  let journal: [JournalEntryEntity]
  let goalCalendar: Calendar
  let doneSessions: [WeeklyRecap.Session]
  let calendarEvents: [TaskEntity]
  let checkIndex: [String: RoutineCheckStatus]

  init(inputs: WeeklyRecapInputs, weekStart: Date, now: Date, calendar: Calendar, goalCalendar: Calendar, locale: Locale) {
    self.inputs = inputs
    self.weekStart = calendar.startOfDay(for: weekStart)
    self.weekEnd = calendar.date(byAdding: .day, value: 7, to: self.weekStart) ?? weekStart
    self.now = now
    self.calendar = calendar
    self.format = RecapFormat(calendar: calendar, locale: locale)
    self.projectNames = Dictionary(inputs.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    self.tasksByID = Dictionary(inputs.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.journal = inputs.useJournal ? inputs.journalEntries : []
    self.goalCalendar = goalCalendar
    let projects = projectNames
    let tasks = tasksByID
    let goalProjects = Dictionary(inputs.goals.map { ($0.id, $0.config.projectId) }, uniquingKeysWith: { first, _ in first })
    self.doneSessions = inputs.focusBlocks
      .filter { $0.status == .done && $0.loggedMinutes > 0 }
      .map { block in
        let projectId = block.taskId.flatMap { tasks[$0]?.projectId } ?? block.goalId.flatMap { goalProjects[$0] ?? nil }
        return WeeklyRecap.Session(
          id: block.id,
          title: block.title,
          hours: block.loggedMinutes / 60,
          projectId: projectId,
          projectName: projectId.flatMap { projects[$0] },
          date: block.startedAt ?? block.start
        )
      }
    self.calendarEvents = inputs.tasks.filter { WeeklyRecap.isCalendarEvent($0) && !$0.completed && $0.dueDate != nil }
    self.checkIndex = Dictionary(inputs.routineChecks.map { ("\($0.routineId)|\($0.day)", $0.status) }, uniquingKeysWith: { first, _ in first })
  }

  func build() -> WeeklyRecap {
    let history = weeksOfHistory()
    let hasHistory = history >= WeeklyRecap.historyWeeks
    let days = (0..<7).map { day(at: $0) }
    let focusMetric = focusMetric(days: days, hasHistory: hasHistory)
    let goals = goalChanges()
    let routines = routineMetrics(hasHistory: hasHistory)
    let carry = carryOver()

    var candidates: [WeeklyFinding] = []
    candidates += goalAtRiskFindings(goals: goals)
    candidates += lateEveningFindings()
    candidates += stuckTaskFindings()
    candidates += deepWorkFindings(focus: focusMetric, days: days)
    candidates += quietAreaFindings(goals: goals)
    candidates += moodFindings()
    let findings = WeeklyRecap.rank(candidates, feedback: inputs.feedback, hasHistory: hasHistory, weekStart: weekStart, calendar: calendar)

    return WeeklyRecap(
      weekStart: weekStart,
      weekEnd: weekEnd,
      weeksOfHistory: history,
      tasks: taskMetric(hasHistory: hasHistory),
      focus: focusMetric,
      routines: routines,
      days: days,
      carryOver: carry,
      goals: goals,
      findings: findings,
      moved: movedLines(goals: goals, routines: routines),
      stalled: stalledLines(findings: findings, goals: goals, routines: routines),
      sources: sourceCounts(),
      usedJournal: inputs.useJournal
    )
  }

  // MARK: Windows

  func weekStart(offset weeks: Int) -> Date {
    calendar.date(byAdding: .day, value: 7 * weeks, to: weekStart) ?? weekStart
  }

  func inWeek(_ date: Date, offset weeks: Int = 0) -> Bool {
    let start = weekStart(offset: weeks)
    let end = weekStart(offset: weeks + 1)
    return date >= start && date < end
  }

  /// Whole weeks of any recorded activity before the reviewed week.
  func weeksOfHistory() -> Int {
    var dates: [Date] = inputs.tasks.filter { !WeeklyRecap.isCalendarEvent($0) }.map(\.createdAt)
    dates += inputs.focusBlocks.map(\.start)
    dates += inputs.routineChecks.compactMap { GoalReports.date(fromDayKey: $0.day, calendar: calendar) }
    dates += inputs.journalEntries.map(\.date)
    guard let earliest = dates.min(), earliest < weekStart else { return 0 }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: weekStart).day ?? 0
    return days / 7
  }

  // MARK: Sessions and days

  func focusHours(offset weeks: Int, projectId: String? = nil, anyProject: Bool = true) -> Double {
    doneSessions
      .filter { inWeek($0.date, offset: weeks) && (anyProject || $0.projectId == projectId) }
      .reduce(0) { $0 + $1.hours }
  }

  func lateEvent(on day: Date) -> TaskEntity? {
    calendarEvents
      .filter { calendar.isDate($0.dueDate!, inSameDayAs: day) && calendar.component(.hour, from: $0.dueDate!) >= WeeklyRecap.lateEveningHour }
      .max { $0.dueDate! < $1.dueDate! }
  }

  func mood(on day: Date) -> Int? {
    let scores = journal.filter { calendar.isDate($0.date, inSameDayAs: day) }.compactMap(\.mood).map(WeeklyRecap.moodScore)
    guard !scores.isEmpty else { return nil }
    return Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
  }

  func day(at index: Int) -> WeeklyRecap.Day {
    let date = calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
    let sessions = doneSessions.filter { calendar.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date }
    var byProject: [String: WeeklyRecap.ProjectHours] = [:]
    for session in sessions {
      let key = session.projectId ?? ""
      let previous = byProject[key]?.hours ?? 0
      byProject[key] = WeeklyRecap.ProjectHours(projectId: session.projectId, name: session.projectName ?? "Other", hours: previous + session.hours)
    }
    let focus = byProject.values.sorted(by: Self.moreHours)
    let done: [WeeklyRecap.Item] = inputs.tasks
      .filter { isDone($0, on: date) }
      .map { WeeklyRecap.Item(id: $0.id, title: $0.title, date: $0.completedAt ?? date) }
      .sorted { $0.date < $1.date }
    let events = calendarEvents
      .filter { calendar.isDate($0.dueDate!, inSameDayAs: date) }
      .sorted { $0.dueDate! < $1.dueDate! }
      .map { WeeklyRecap.Item(id: $0.id, title: $0.title, date: $0.dueDate!) }
    let notes = journal
      .filter { calendar.isDate($0.date, inSameDayAs: date) }
      .sorted { $0.date < $1.date }
      .map { note(for: $0) }
    var marks: [String: RoutineDayMark] = [:]
    for routine in activeRoutines {
      marks[routine.id] = mark(routine, on: date)
    }
    let late = lateEvent(on: date).map { WeeklyRecap.Item(id: $0.id, title: $0.title, date: $0.dueDate!) }
    return WeeklyRecap.Day(
      date: date,
      focus: focus,
      sessions: sessions,
      done: done,
      calendar: events,
      journal: notes,
      mood: mood(on: date),
      routineMarks: marks,
      lateEvent: late
    )
  }

  static func moreHours(_ lhs: WeeklyRecap.ProjectHours, _ rhs: WeeklyRecap.ProjectHours) -> Bool {
    lhs.hours == rhs.hours ? lhs.name < rhs.name : lhs.hours > rhs.hours
  }

  func isDone(_ task: TaskEntity, on day: Date) -> Bool {
    guard task.completed, !WeeklyRecap.isCalendarEvent(task), let completedAt = task.completedAt else { return false }
    return calendar.isDate(completedAt, inSameDayAs: day)
  }

  func note(for entry: JournalEntryEntity) -> WeeklyRecap.JournalNote {
    let excerpt = entry.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return WeeklyRecap.JournalNote(
      id: entry.id,
      title: entry.title ?? "",
      excerpt: String(excerpt.prefix(120)),
      mood: entry.mood.map(WeeklyRecap.moodScore),
      date: entry.date
    )
  }

  // MARK: Routines

  var activeRoutines: [RoutineEntity] {
    inputs.routines.filter { !$0.archived }
  }

  func status(_ routine: RoutineEntity, on day: Date) -> RoutineCheckStatus? {
    checkIndex["\(routine.id)|\(RoutineDay.key(for: day, calendar: calendar))"]
  }

  /// Done, skipped or missed on a scheduled day; off before the routine existed or on free days.
  func mark(_ routine: RoutineEntity, on day: Date) -> RoutineDayMark {
    let start = calendar.startOfDay(for: day)
    guard start >= calendar.startOfDay(for: routine.createdAt) else { return .off }
    switch status(routine, on: start) {
    case .done: return .done
    case .skipped: return .skipped
    case nil: break
    }
    if case .timesPerWeek = routine.schedule { return .off }
    guard RoutineStreaks.isScheduled(routine.schedule, on: start, calendar: calendar) else { return .off }
    return start < calendar.startOfDay(for: now) ? .missed : .open
  }

  func routineDone(_ routine: RoutineEntity, offset weeks: Int) -> (done: Int, expected: Int, missed: [Date]) {
    var done = 0
    var expected = 0
    var missed: [Date] = []
    for index in 0..<7 {
      let day = calendar.date(byAdding: .day, value: index + 7 * weeks, to: weekStart) ?? weekStart
      switch mark(routine, on: day) {
      case .done:
        done += 1
        expected += 1
      case .missed:
        expected += 1
        missed.append(day)
      case .open:
        expected += 1
      case .skipped, .off:
        break
      }
    }
    if case .timesPerWeek(let target) = routine.schedule {
      expected = max(target, 1)
    }
    return (done, expected, missed)
  }

  func routineMetrics(hasHistory: Bool) -> [WeeklyRecap.RoutineMetric] {
    activeRoutines.compactMap { routine in
      let week = routineDone(routine, offset: 0)
      guard week.expected > 0 || week.done > 0 else { return nil }
      let baseline: Double? = hasHistory
        ? Double((1...WeeklyRecap.historyWeeks).map { routineDone(routine, offset: -$0).done }.reduce(0, +)) / Double(WeeklyRecap.historyWeeks)
        : nil
      return WeeklyRecap.RoutineMetric(
        routineId: routine.id,
        title: routine.title,
        done: week.done,
        expected: week.expected,
        missed: week.missed,
        baseline: baseline
      )
    }
  }

  // MARK: Metrics

  func tasksDone(offset weeks: Int) -> [TaskEntity] {
    inputs.tasks.filter { task in
      guard task.completed, !WeeklyRecap.isCalendarEvent(task), let completedAt = task.completedAt else { return false }
      return inWeek(completedAt, offset: weeks)
    }
  }

  static func moreTasks(_ lhs: WeeklyRecap.ProjectCount, _ rhs: WeeklyRecap.ProjectCount) -> Bool {
    lhs.count == rhs.count ? lhs.name < rhs.name : lhs.count > rhs.count
  }

  func taskMetric(hasHistory: Bool) -> WeeklyRecap.TaskMetric {
    let done = tasksDone(offset: 0)
    var counts: [String: Int] = [:]
    for task in done {
      counts[task.projectId.flatMap { projectNames[$0] } ?? "No project", default: 0] += 1
    }
    let byProject: [WeeklyRecap.ProjectCount] = counts
      .map { WeeklyRecap.ProjectCount(name: $0.key, count: $0.value) }
      .sorted(by: Self.moreTasks)
    let usual: Double? = hasHistory ? baseline { Double(tasksDone(offset: $0).count) } : nil
    return WeeklyRecap.TaskMetric(done: done.count, baseline: usual, byProject: byProject)
  }

  func baseline(_ value: (Int) -> Double) -> Double {
    (1...WeeklyRecap.historyWeeks).map { value(-$0) }.reduce(0, +) / Double(WeeklyRecap.historyWeeks)
  }

  var focusGoal: GoalEntity? {
    inputs.goals.first { $0.status == .active && $0.config.source == .focusTime && $0.config.kind == .target && $0.config.timeframe == .weekly }
  }

  func focusMetric(days: [WeeklyRecap.Day], hasHistory: Bool) -> WeeklyRecap.FocusMetric {
    let goal = focusGoal
    return WeeklyRecap.FocusMetric(
      hours: days.reduce(0) { $0 + $1.focusHours },
      baseline: hasHistory ? baseline { focusHours(offset: $0) } : nil,
      target: goal.map { max($0.config.targetCount ?? $0.progress.target, 1) },
      goalId: goal?.id,
      emptyDays: days.filter { $0.focusHours == 0 && $0.date < now }.map(\.date)
    )
  }

  func sourceCounts() -> WeeklyRecap.SourceCounts {
    var counts = WeeklyRecap.SourceCounts()
    counts.tasks = tasksDone(offset: 0).count
    counts.sessions = doneSessions.filter { inWeek($0.date) }.count
    counts.journal = journal.filter { inWeek($0.date) }.count
    counts.routineChecks = inputs.routineChecks.filter { check in
      GoalReports.date(fromDayKey: check.day, calendar: calendar).map { inWeek($0) } ?? false
    }.count
    counts.calendar = calendarEvents.filter { inWeek($0.dueDate!) }.count
    return counts
  }

  // MARK: Carry-over

  func carryOver() -> [WeeklyRecap.CarryItem] {
    inputs.tasks
      .filter { task in
        guard !task.completed, !WeeklyRecap.isCalendarEvent(task), !task.tags.contains(WeeklyRecap.somedayTag) else { return false }
        let dueByWeekEnd = task.dueDate.map { $0 < weekEnd } ?? false
        let touched = task.activity.contains { inWeek($0.createdAt) }
        return dueByWeekEnd || touched
      }
      .map { task in
        WeeklyRecap.CarryItem(
          taskId: task.id,
          title: task.title,
          projectName: task.projectId.flatMap { projectNames[$0] },
          dueDate: task.dueDate,
          moves: WeeklyRecap.dueMoves(task).count,
          focusHours: doneSessions.filter { session in
            inputs.focusBlocks.first { $0.id == session.id }?.taskId == task.id
          }.reduce(0) { $0 + $1.hours },
          createdAt: task.createdAt
        )
      }
      .sorted { lhs, rhs in
        if lhs.moves != rhs.moves { return lhs.moves > rhs.moves }
        return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
      }
      .prefix(8)
      .map { $0 }
  }

  // MARK: Goals

  /// What the goals looked like at `date`: nothing logged later counts.
  func goalInputs(at date: Date) -> GoalProgressInputs {
    GoalProgressInputs(
      tasks: inputs.tasks.map { task in
        guard task.completed, (task.completedAt ?? task.updatedAt) > date else { return task }
        var open = task
        open.completed = false
        open.completedAt = nil
        return open
      },
      routineChecks: inputs.routineChecks.filter { check in
        (GoalReports.date(fromDayKey: check.day, calendar: calendar) ?? .distantFuture) <= date
      },
      journalEntries: inputs.journalEntries.filter { $0.date <= date },
      focusHours: inputs.focusBlocks
        .filter { $0.status == .done && $0.loggedMinutes > 0 && ($0.finishedAt ?? $0.end) <= date }
        .map { (date: $0.finishedAt ?? $0.end, hours: $0.loggedMinutes / 60, goalId: $0.goalId) }
    )
  }

  func goalAsOf(_ goal: GoalEntity, _ date: Date) -> GoalEntity {
    var goal = goal
    goal.config.checkIns = goal.config.checkIns?.filter { $0.date <= date }
    return goal
  }

  func snapshot(_ report: GoalReport) -> WeeklyRecap.GoalSnapshot {
    WeeklyRecap.GoalSnapshot(
      current: report.current,
      target: report.target,
      expected: report.expected,
      pace: report.pace,
      statusLabel: report.statusLabel,
      daysQuiet: report.daysQuiet
    )
  }

  func goalChanges() -> [WeeklyRecap.GoalChange] {
    let beforeInputs = goalInputs(at: weekStart)
    let afterInputs = goalInputs(at: weekEnd)
    return inputs.goals
      .filter { $0.status == .active && $0.createdAt < weekEnd }
      .map { goal in
        let before = GoalReports.report(for: goalAsOf(goal, weekStart), inputs: beforeInputs, now: weekStart, calendar: goalCalendar)
        let after = GoalReports.report(for: goalAsOf(goal, weekEnd), inputs: afterInputs, now: weekEnd, calendar: goalCalendar)
        return WeeklyRecap.GoalChange(
          goalId: goal.id,
          title: goal.title,
          kind: after.kind,
          unit: after.unit,
          before: snapshot(before),
          after: snapshot(after),
          dueDate: goal.config.dueDate,
          isPaused: goal.config.pausedUntil.map { $0 > now } ?? false,
          needsSetup: after.needsSetup,
          lastActivity: after.lastActivity
        )
      }
  }

  // MARK: Detectors

  func behindAmount(_ pace: GoalPace) -> Double? {
    if case .behind(let amount) = pace { return amount }
    return nil
  }

  func goalAtRiskFindings(goals: [WeeklyRecap.GoalChange]) -> [WeeklyFinding] {
    goals.compactMap { change in
      guard !change.isPaused, !change.needsSetup,
            let goal = inputs.goals.first(where: { $0.id == change.goalId }),
            goal.config.source == .projectTasks, let projectId = goal.config.projectId,
            let after = behindAmount(change.after.pace)
      else { return nil }
      let before = behindAmount(change.before.pace)
      guard before.map({ after > $0 }) ?? true else { return nil }

      let projectName = projectNames[projectId] ?? goal.title
      let weekSessions = doneSessions.filter { inWeek($0.date) }.sorted { $0.date < $1.date }
      let total = weekSessions.reduce(0) { $0 + $1.hours }
      let onGoal = weekSessions.filter { $0.projectId == projectId }.reduce(0) { $0 + $1.hours }
      let previous = focusHours(offset: -1, projectId: projectId, anyProject: false)

      var sentences: [String] = []
      var others: [String: Double] = [:]
      for session in weekSessions where session.projectId != projectId {
        others[session.projectName ?? "other work", default: 0] += session.hours
      }
      if let top = others.max(by: { $0.value < $1.value }), total > 0, top.value > onGoal {
        sentences.append("\(format.hours(top.value)) of your \(format.hours(total)) focus went to \(top.key).")
      }
      var focusLine = "\(projectName) got \(format.hours(onGoal))"
      if previous > 0 { focusLine += ", down from \(format.hours(previous)) the week before," }
      let unit = change.unit.isEmpty ? "" : " \(change.unit)"
      if let before {
        sentences.append("\(focusLine) and slipped from \(GoalReport.format(before)) to \(GoalReport.format(after))\(unit) behind.")
      } else {
        sentences.append("\(focusLine) and fell \(GoalReport.format(after))\(unit) behind.")
      }

      let slots = freeSlots(count: 2)
      if !slots.isEmpty {
        sentences.append("\(format.slotDays(slots)) \(slots.count == 1 ? "is" : "are") free this week.")
      }

      var evidence = weekSessions.map { session in
        WeeklyEvidence(
          source: .focus,
          ref: session.id,
          date: session.date,
          when: format.dayLabel(session.date),
          what: session.title,
          meta: "\(format.hoursOneDecimal(session.hours)) · \(session.projectName ?? "No project")"
        )
      }
      evidence.append(WeeklyEvidence(
        source: .week,
        ref: weekKey(offset: -1),
        date: weekStart(offset: -1),
        when: format.range(weekStart(offset: -1), weekStart),
        what: "\(projectName) the week before",
        meta: format.hoursOneDecimal(previous)
      ))
      var goalLine = "\(goal.title): \(GoalReport.format(change.before.current)) → \(GoalReport.format(change.after.current)) of \(GoalReport.format(change.after.target))"
      if let expected = change.after.expected {
        goalLine += "; even pace needs \(GoalReport.format(expected.rounded()))"
      }
      evidence.append(WeeklyEvidence(
        source: .goal,
        ref: goal.id,
        date: weekEnd,
        when: "Goal",
        what: goalLine,
        meta: change.dueDate.map { "due \(format.date($0))" } ?? ""
      ))

      return WeeklyFinding(
        id: "\(WeeklyFinding.Kind.goalAtRisk.rawValue):\(goal.id)",
        kind: .goalAtRisk,
        subjectId: goal.id,
        linked: goal.title,
        title: others.isEmpty ? "\(goal.title) is slipping" : "Other work took the focus \(goal.title) needed",
        body: sentences.joined(separator: " "),
        evidenceLabel: "Evidence: \(format.count(weekSessions.count, "focus session")), 2 goal snapshots",
        evidence: evidence,
        action: slots.isEmpty ? nil : .bookFocus(title: "\(projectName) focus", goalId: goal.id, slots: slots),
        actionTitle: slots.isEmpty ? nil : "Book \(format.slotList(slots))",
        score: 3 + min(after, 5) * 0.2
      )
    }
  }

  func weekKey(offset weeks: Int) -> String {
    let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart(offset: weeks))
    return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
  }

  func lateEveningFindings() -> [WeeklyFinding] {
    let windowStart = weekStart(offset: -WeeklyRecap.historyWeeks)
    return activeRoutines.compactMap { routine in
      guard routine.timeOfDay == .morning else { return nil }
      if case .timesPerWeek = routine.schedule { return nil }

      var lateTotal = 0
      var lateMissed: [(evening: TaskEntity, morning: Date, missed: Bool)] = []
      var otherTotal = 0
      var otherMissed = 0
      var day = windowStart
      while day < weekEnd {
        let mark = mark(routine, on: day)
        if mark == .done || mark == .missed {
          let previous = calendar.date(byAdding: .day, value: -1, to: day) ?? day
          if let evening = lateEvent(on: previous) {
            lateTotal += 1
            lateMissed.append((evening, day, mark == .missed))
          } else {
            otherTotal += 1
            if mark == .missed { otherMissed += 1 }
          }
        }
        day = calendar.date(byAdding: .day, value: 1, to: day) ?? weekEnd
      }

      let missedAfterLate = lateMissed.filter(\.missed).count
      guard lateTotal > 0, missedAfterLate >= 3 else { return nil }
      let lateRate = Double(missedAfterLate) / Double(lateTotal)
      let otherRate = otherTotal == 0 ? 0 : Double(otherMissed) / Double(otherTotal)
      guard lateRate >= 0.6, otherRate <= lateRate / 2 else { return nil }
      let thisWeek = lateMissed.filter { $0.missed && inWeek($0.morning) }
      guard !thisWeek.isEmpty else { return nil }

      let missedDays = format.dayList(thisWeek.map(\.morning))
      let lead = thisWeek.count == 1
        ? "You missed \(missedDays), after an evening event."
        : "You missed \(missedDays), and \(thisWeek.count == 2 ? "both" : "all") came after evening events."
      let since = lateMissed.first.map { format.date($0.evening.dueDate!) } ?? format.date(windowStart)
      let body = "\(lead) Since \(since) that has happened \(missedAfterLate) of the \(lateTotal) times you had something on at 19:00 or later, against \(format.count(otherMissed, "miss", plural: "misses")) in \(otherTotal) other mornings."

      let evidence = lateMissed.reversed().map { item in
        WeeklyEvidence(
          source: .calendar,
          ref: item.evening.id,
          date: item.evening.dueDate,
          when: format.dayLabel(item.evening.dueDate!),
          what: "\(item.evening.title) at \(format.time(item.evening.dueDate!)) → \(format.dayLabel(item.morning)) \(item.missed ? "missed" : "done")",
          meta: "calendar"
        )
      }

      return WeeklyFinding(
        id: "\(WeeklyFinding.Kind.routineAfterLateEvening.rawValue):\(routine.id)",
        kind: .routineAfterLateEvening,
        subjectId: routine.id,
        linked: "\(routine.title) routine",
        title: "\(routine.title) goes undone after late evenings",
        body: body,
        evidenceLabel: "Evidence: \(format.count(lateTotal, "late evening")), \(lateTotal + otherTotal) mornings",
        evidence: evidence,
        action: .lateEveningReminder(routineId: routine.id, hour: 8, minute: 30),
        actionTitle: "After late evenings, remind me at 8:30",
        score: 2 + Double(missedAfterLate) * 0.1
      )
    }
  }

  func stuckTaskFindings() -> [WeeklyFinding] {
    let candidates = inputs.tasks.compactMap { task -> (task: TaskEntity, moves: [Date])? in
      guard !task.completed, !WeeklyRecap.isCalendarEvent(task) else { return nil }
      let moves = WeeklyRecap.dueMoves(task)
      guard moves.count >= 3, moves.contains(where: { inWeek($0) }) else { return nil }
      return (task, moves)
    }
    guard let stuck = candidates.max(by: { $0.moves.count < $1.moves.count }) else { return [] }
    let task = stuck.task

    let mentions = journalMentions(of: task)
    var body = "“\(task.title)” has been moved \(stuck.moves.count) times since \(format.date(task.createdAt))."
    let lowMood = mentions.filter { ($0.mood.map(WeeklyRecap.moodScore) ?? 3) <= 2 }
    if lowMood.count >= 2 {
      body += " Your \(lowMood.count) lowest-mood entries this week mention it."
    } else if !mentions.isEmpty {
      body += " It came up in \(format.count(mentions.count, "journal entry", plural: "journal entries")) this week."
    }

    var evidence = [WeeklyEvidence(
      source: .task,
      ref: task.id,
      date: task.createdAt,
      when: format.date(task.createdAt),
      what: "Task created: “\(task.title)”",
      meta: task.projectId.flatMap { projectNames[$0] } ?? "task"
    )]
    evidence.append(WeeklyEvidence(
      source: .task,
      ref: task.id,
      date: stuck.moves.last,
      when: format.dayNumberList(stuck.moves),
      what: "Due date changed",
      meta: "task history"
    ))
    for entry in mentions {
      let mood = entry.mood.map { ", mood \(WeeklyRecap.moodScore($0))" } ?? ""
      evidence.append(WeeklyEvidence(
        source: .journal,
        ref: entry.id,
        date: entry.date,
        when: format.dayLabel(entry.date),
        what: "Journal\(mood): “\(quote(entry))”",
        meta: "journal"
      ))
    }

    return [WeeklyFinding(
      id: "\(WeeklyFinding.Kind.stuckTask.rawValue):\(task.id)",
      kind: .stuckTask,
      subjectId: task.id,
      linked: [task.projectId.flatMap { projectNames[$0] }, mentions.isEmpty ? nil : "Journal"].compactMap { $0 }.joined(separator: " · "),
      title: mentions.isEmpty ? "“\(task.title)” keeps getting moved" : "“\(task.title)” is weighing on you",
      body: body,
      evidenceLabel: "Evidence: 1 task history" + (mentions.isEmpty ? "" : ", \(format.count(mentions.count, "journal entry", plural: "journal entries"))"),
      evidence: evidence,
      action: .firstOnToday(taskId: task.id),
      actionTitle: "Make it first on Today",
      score: 2 + Double(stuck.moves.count - 3) * 0.3 + (mentions.isEmpty ? 0 : 0.5)
    )]
  }

  /// This week's entries naming the task's most distinctive word.
  func journalMentions(of task: TaskEntity) -> [JournalEntryEntity] {
    guard let keyword = WeeklyRecap.keyword(in: task.title) else { return [] }
    return journal
      .filter { inWeek($0.date) && "\($0.title ?? "") \($0.content)".lowercased().contains(keyword) }
      .sorted { $0.date < $1.date }
  }

  func quote(_ entry: JournalEntryEntity) -> String {
    let text = (entry.title?.isEmpty == false ? entry.title! : entry.content)
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }

  func deepWorkFindings(focus: WeeklyRecap.FocusMetric, days: [WeeklyRecap.Day]) -> [WeeklyFinding] {
    guard let usual = focus.baseline, usual >= 3, focus.hours < usual * 0.75 else { return [] }
    var body = "\(format.hours(focus.hours)) of focus against your usual \(format.hours(usual))."
    if let target = focus.target, focus.hours < target {
      body += " That's \(format.hours(target - focus.hours)) short of your \(format.hours(target)) goal."
    }
    if !focus.emptyDays.isEmpty {
      body += " \(format.dayList(focus.emptyDays)) had none."
    }
    let slots = freeSlots(count: 2)
    var evidence = (1...WeeklyRecap.historyWeeks).reversed().map { back in
      WeeklyEvidence(
        source: .week,
        ref: weekKey(offset: -back),
        date: weekStart(offset: -back),
        when: format.range(weekStart(offset: -back), weekStart(offset: -back + 1)),
        what: "Focus that week",
        meta: format.hoursOneDecimal(focusHours(offset: -back))
      )
    }
    evidence += days.filter { $0.date < now }.map { day in
      WeeklyEvidence(
        source: .week,
        ref: RoutineDay.key(for: day.date, calendar: calendar),
        date: day.date,
        when: format.dayLabel(day.date),
        what: day.sessions.isEmpty ? "No focus sessions" : format.count(day.sessions.count, "focus session"),
        meta: format.hoursOneDecimal(day.focusHours)
      )
    }
    return [WeeklyFinding(
      id: "\(WeeklyFinding.Kind.deepWorkBelowBaseline.rawValue):focus",
      kind: .deepWorkBelowBaseline,
      subjectId: focus.goalId ?? "focus",
      linked: focusGoal?.title ?? "Focus",
      title: "Deep work fell below your usual week",
      body: body,
      evidenceLabel: "Evidence: \(WeeklyRecap.historyWeeks) earlier weeks, 7 days",
      evidence: evidence,
      action: slots.isEmpty ? nil : .bookFocus(title: "Focus", goalId: focus.goalId, slots: slots),
      actionTitle: slots.isEmpty ? nil : "Book \(format.slotList(slots))",
      score: 2 + (1 - focus.hours / usual)
    )]
  }

  func quietAreaFindings(goals: [WeeklyRecap.GoalChange]) -> [WeeklyFinding] {
    goals.compactMap { change in
      guard change.kind == .area, !change.isPaused,
            let goal = inputs.goals.first(where: { $0.id == change.goalId }),
            let quiet = change.after.daysQuiet, quiet >= (goal.config.quietDays ?? GoalReports.defaultQuietDays)
      else { return nil }
      let tag = goal.config.areaTag?.lowercased()
      let open = inputs.tasks.filter { task in
        !task.completed && !WeeklyRecap.isCalendarEvent(task)
          && ((goal.config.projectId != nil && task.projectId == goal.config.projectId)
            || (tag.map { tag in task.tags.contains { $0.lowercased() == tag } } ?? false))
      }.sorted { $0.createdAt < $1.createdAt }

      var body = "Nothing has touched \(goal.title)"
      body += change.lastActivity.map { " since \(format.date($0))." } ?? " yet."
      if open.count == 1 {
        body += " “\(open[0].title)” is the only open item."
      } else if open.count > 1 {
        body += " \(open.count) items are open, oldest “\(open[0].title)”."
      }
      var evidence: [WeeklyEvidence] = [WeeklyEvidence(
        source: .goal,
        ref: goal.id,
        date: change.lastActivity,
        when: change.lastActivity.map(format.date) ?? "Never",
        what: "Last activity in \(goal.title)",
        meta: "\(quiet) days quiet"
      )]
      evidence += open.prefix(3).map { task in
        WeeklyEvidence(source: .task, ref: task.id, date: task.createdAt, when: format.date(task.createdAt), what: task.title, meta: "open")
      }
      let day = nextWeekday(after: now)
      return WeeklyFinding(
        id: "\(WeeklyFinding.Kind.quietArea.rawValue):\(goal.id)",
        kind: .quietArea,
        subjectId: goal.id,
        linked: goal.title,
        title: "\(goal.title) has been quiet for \(quiet) days",
        body: body,
        evidenceLabel: "Evidence: goal activity" + (open.isEmpty ? "" : ", \(format.count(min(open.count, 3), "open task"))"),
        evidence: evidence,
        action: open.first.map { .scheduleTask(taskId: $0.id, day: day) },
        actionTitle: open.first.map { "Plan “\($0.title)” for \(format.weekday(day))" },
        score: 1.5 + min(Double(quiet) / 30, 0.5)
      )
    }
  }

  func moodFindings() -> [WeeklyFinding] {
    guard inputs.useJournal else { return [] }
    let windowStart = weekStart(offset: -WeeklyRecap.historyWeeks)
    var low: [(day: Date, meetings: Int)] = []
    var other: [(day: Date, meetings: Int)] = []
    var day = windowStart
    while day < weekEnd {
      if let mood = mood(on: day) {
        let meetings = calendarEvents.filter { calendar.isDate($0.dueDate!, inSameDayAs: day) }.count
        if mood <= 2 { low.append((day, meetings)) } else { other.append((day, meetings)) }
      }
      day = calendar.date(byAdding: .day, value: 1, to: day) ?? weekEnd
    }
    guard low.count >= 4, other.count >= 4, low.contains(where: { inWeek($0.day) }) else { return [] }
    let lowAvg = Double(low.map(\.meetings).reduce(0, +)) / Double(low.count)
    let otherAvg = Double(other.map(\.meetings).reduce(0, +)) / Double(other.count)
    guard lowAvg >= 2, lowAvg >= otherAvg * 1.5 else { return [] }

    let busiest = freeSlots(count: 1, preferBusiest: true)
    let body = "On your \(low.count) low-mood days since \(format.date(low[0].day)) you had \(format.decimal(lowAvg)) calendar events on average, against \(format.decimal(otherAvg)) on other days."
    let evidence = low.reversed().map { item in
      WeeklyEvidence(
        source: .journal,
        ref: journal.first { calendar.isDate($0.date, inSameDayAs: item.day) && $0.mood != nil }?.id ?? RoutineDay.key(for: item.day, calendar: calendar),
        date: item.day,
        when: format.dayLabel(item.day),
        what: "Mood \(mood(on: item.day) ?? 0), \(format.count(item.meetings, "event"))",
        meta: "journal + calendar"
      )
    }
    return [WeeklyFinding(
      id: "\(WeeklyFinding.Kind.moodAfterBusyDays.rawValue):mood",
      kind: .moodAfterBusyDays,
      subjectId: "mood",
      linked: "Journal · Calendar",
      title: "Low-mood days are your busiest ones",
      body: body,
      evidenceLabel: "Evidence: \(low.count + other.count) journal days",
      evidence: evidence,
      action: busiest.isEmpty ? nil : .bookFocus(title: "Protected focus", goalId: nil, slots: busiest),
      actionTitle: busiest.isEmpty ? nil : "Protect \(format.slotList(busiest)) for focus",
      score: 1.6 + min(lowAvg - otherAvg, 2) * 0.2
    )]
  }

  // MARK: Lines for the guided review

  func movedLines(goals: [WeeklyRecap.GoalChange], routines: [WeeklyRecap.RoutineMetric]) -> [WeeklyRecap.Line] {
    var lines: [WeeklyRecap.Line] = []
    let done = tasksDone(offset: 0)
    let grouped = Dictionary(grouping: done) { $0.projectId ?? "" }
    for (projectId, tasks) in grouped.sorted(by: { $0.value.count > $1.value.count }) where tasks.count >= 2 {
      let name = projectNames[projectId] ?? "No project"
      let titles = tasks.sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }.prefix(2).map(\.title)
      lines.append(WeeklyRecap.Line(id: "project:\(projectId)", text: "\(name): \(titles.joined(separator: "; "))\(tasks.count > 2 ? " and \(tasks.count - 2) more" : "")", source: format.count(tasks.count, "task")))
    }
    for change in goals where change.kind != .area && change.after.current > change.before.current {
      if case .behind = change.after.pace { continue }
      let unit = change.unit.isEmpty ? "" : " \(change.unit)"
      lines.append(WeeklyRecap.Line(id: "goal:\(change.goalId)", text: "\(change.title): \(GoalReport.format(change.before.current)) → \(GoalReport.format(change.after.current))\(unit), \(change.after.statusLabel.lowercased())", source: "goal"))
    }
    for routine in routines where routine.expected > 0 && routine.done >= routine.expected {
      lines.append(WeeklyRecap.Line(id: "routine:\(routine.routineId)", text: "\(routine.title) \(routine.done) of \(routine.expected) days", source: "routine"))
    }
    return lines
  }

  func stalledLines(findings: [WeeklyFinding], goals: [WeeklyRecap.GoalChange], routines: [WeeklyRecap.RoutineMetric]) -> [WeeklyRecap.Line] {
    var lines = findings.map { WeeklyRecap.Line(id: $0.id, text: $0.title, source: $0.tag.lowercased()) }
    let covered = Set(findings.map(\.subjectId))
    for change in goals where !covered.contains(change.goalId) && !change.isPaused {
      if change.kind == .area {
        if let quiet = change.after.daysQuiet, quiet >= GoalReports.defaultQuietDays {
          lines.append(WeeklyRecap.Line(id: "goal:\(change.goalId)", text: "Nothing in \(change.title) for \(quiet) days", source: "goal"))
        }
      } else if case .behind = change.after.pace {
        lines.append(WeeklyRecap.Line(id: "goal:\(change.goalId)", text: "\(change.title) is \(change.after.statusLabel)", source: "goal"))
      }
    }
    for routine in routines where !covered.contains(routine.routineId) && !routine.missed.isEmpty {
      lines.append(WeeklyRecap.Line(id: "routine:\(routine.routineId)", text: "\(routine.title) missed \(format.dayList(routine.missed))", source: "routine"))
    }
    return lines
  }

  // MARK: Free time

  /// Up to `count` free mornings this week at 9:00, spread out where possible.
  func freeSlots(count: Int, preferBusiest: Bool = false) -> [DateInterval] {
    let busy: [DateInterval] = inputs.tasks.compactMap { task in
      guard !task.completed, let due = task.dueDate else { return nil }
      let parts = calendar.dateComponents([.hour, .minute], from: due)
      guard parts.hour != 0 || parts.minute != 0 else { return nil }
      let minutes = WeeklyRecap.isCalendarEvent(task) ? WeeklyRecap.calendarEventMinutes : TodayBriefing.defaultTaskMinutes
      return DateInterval(start: due, duration: minutes * 60)
    } + inputs.focusBlocks.filter { $0.status != .done && $0.end > $0.start }.map { DateInterval(start: $0.start, end: $0.end) }

    let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86_400)
    var candidates: [DateInterval] = []
    var day = calendar.startOfDay(for: now)
    while day < thisWeek.end {
      let weekday = calendar.component(.weekday, from: day)
      if weekday != 1 && weekday != 7,
         let start = calendar.date(bySettingHour: WeeklyRecap.focusSlotHour, minute: 0, second: 0, of: day), start > now {
        let slot = DateInterval(start: start, duration: Double(WeeklyRecap.focusSlotMinutes) * 60)
        if !busy.contains(where: { $0.intersects(slot) && $0.end != slot.start && $0.start != slot.end }) {
          candidates.append(slot)
        }
      }
      day = calendar.date(byAdding: .day, value: 1, to: day) ?? thisWeek.end
    }

    if preferBusiest {
      let load: (DateInterval) -> Int = { slot in busy.filter { self.calendar.isDate($0.start, inSameDayAs: slot.start) }.count }
      return Array(candidates.sorted { load($0) > load($1) }.prefix(count))
    }
    var picked: [DateInterval] = []
    for slot in candidates where picked.count < count {
      if let last = picked.last, (calendar.dateComponents([.day], from: last.start, to: slot.start).day ?? 0) < 2 { continue }
      picked.append(slot)
    }
    for slot in candidates where picked.count < count && !picked.contains(slot) {
      picked.append(slot)
    }
    return picked.sorted { $0.start < $1.start }
  }

  func nextWeekday(after date: Date) -> Date {
    var day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: date) ?? date)
    while [1, 7].contains(calendar.component(.weekday, from: day)) {
      day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }
    return day
  }
}

// MARK: - Ranking

extension WeeklyRecap {
  /// Drops what needs history it doesn't have, pushes down kinds marked "Not useful", keeps the top three.
  static func rank(
    _ findings: [WeeklyFinding],
    feedback: [WeeklyFindingFeedback],
    hasHistory: Bool,
    weekStart: Date,
    calendar: Calendar = WeeklyReview.calendar
  ) -> [WeeklyFinding] {
    let since = calendar.date(byAdding: .day, value: -56, to: weekStart) ?? weekStart
    let recent = feedback.filter { $0.weekStart >= since && $0.weekStart < weekStart }
    return findings
      .filter { hasHistory || !$0.kind.needsHistory }
      .map { finding in
        var ranked = finding
        ranked.score *= feedbackFactor(for: finding, feedback: recent)
        return ranked
      }
      .filter { $0.score >= 0.5 }
      .sorted(by: ranksAbove)
      .prefix(maxFindings)
      .map { $0 }
  }

  static func ranksAbove(_ lhs: WeeklyFinding, _ rhs: WeeklyFinding) -> Bool {
    lhs.score == rhs.score ? lhs.id < rhs.id : lhs.score > rhs.score
  }

  static func feedbackFactor(for finding: WeeklyFinding, feedback: [WeeklyFindingFeedback]) -> Double {
    feedback.filter { $0.kind == finding.kind }.reduce(1) { factor, item in
      let base: Double
      switch item.reason {
      case .knewThis: base = 0.6
      case .numbersWrong: base = 0.4
      case .fineThisWeek: base = 0.85
      }
      return factor * (item.findingId == finding.id ? base * base : base)
    }
  }
}

// MARK: - Formatting

/// Dates and hours as the recap writes them, in one locale and time zone so text and tests agree.
struct RecapFormat {
  let calendar: Calendar
  let locale: Locale

  private func string(_ date: Date, template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }

  /// "12 Oct" (or "Oct 12", by locale).
  func date(_ date: Date) -> String {
    string(date, template: "dMMM")
  }

  /// "Tue 10".
  func dayLabel(_ date: Date) -> String {
    "\(weekday(date)) \(calendar.component(.day, from: date))"
  }

  /// "Tue".
  func weekday(_ date: Date) -> String {
    string(date, template: "EEE")
  }

  func time(_ date: Date) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// "9–15 Nov" when both ends share a month; `end` is exclusive.
  func range(_ start: Date, _ end: Date) -> String {
    let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
    if calendar.component(.month, from: start) == calendar.component(.month, from: last) {
      let month = string(last, template: "MMM")
      return "\(calendar.component(.day, from: start))–\(calendar.component(.day, from: last)) \(month)"
    }
    return "\(date(start)) – \(date(last))"
  }

  /// "Wed and Fri", "Mon, Tue and Thu".
  func dayList(_ dates: [Date]) -> String {
    list(dates.sorted().map(weekday))
  }

  /// "6, 10, 13 Nov".
  func dayNumberList(_ dates: [Date]) -> String {
    let sorted = dates.sorted()
    guard let last = sorted.last else { return "" }
    let month = string(last, template: "MMM")
    let sameMonth = sorted.allSatisfy { calendar.component(.month, from: $0) == calendar.component(.month, from: last) }
    guard sameMonth else { return sorted.map(date).joined(separator: ", ") }
    var days: [String] = []
    for day in sorted.map({ String(calendar.component(.day, from: $0)) }) where days.last != day {
      days.append(day)
    }
    return "\(days.joined(separator: ", ")) \(month)"
  }

  /// "Tue and Thu".
  func slotDays(_ slots: [DateInterval]) -> String {
    list(slots.map { "\(weekday($0.start)) morning" })
  }

  /// "Tue 17 and Thu 19, 9:00–10:30".
  func slotList(_ slots: [DateInterval]) -> String {
    guard let first = slots.first else { return "" }
    return "\(list(slots.map { dayLabel($0.start) })), \(time(first.start))–\(time(first.end))"
  }

  func list(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
  }

  /// "11.5 h", "2 h".
  func hours(_ value: Double) -> String {
    "\(decimal(value)) h"
  }

  /// "2.0 h", for evidence columns that line up.
  func hoursOneDecimal(_ value: Double) -> String {
    String(format: "%.1f h", (value * 10).rounded() / 10)
  }

  func decimal(_ value: Double) -> String {
    GoalReport.format((value * 10).rounded() / 10)
  }

  func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
    "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
  }
}
