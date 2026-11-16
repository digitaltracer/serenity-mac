import Foundation

/// Answers bridge requests by calling AppState, so every change Claude makes takes the app's own
/// path: it syncs to iCloud, shows on screen and can be undone like one made by hand.
@MainActor
final class ClaudeBridgeRouter {
  nonisolated static let methods = [
    "status", "today", "review.week",
    "tasks.list", "tasks.add", "tasks.setDone", "tasks.reschedule",
    "focus.status", "focus.start", "focus.pause", "focus.resume", "focus.finish", "focus.extend", "focus.link",
    "routines.list", "routines.setDone",
    "goals.list", "goals.checkIn",
    "journal.search", "journal.add",
  ]

  nonisolated static let taskScopes = ["today", "overdue", "upcoming", "inbox", "open", "completed"]
  static let journalExcerptLimit = 4000

  private let appState: AppState
  private let settings: ClaudeBridgeSettings
  private let now: () -> Date

  init(appState: AppState, settings: ClaudeBridgeSettings, now: @escaping () -> Date = Date.init) {
    self.appState = appState
    self.settings = settings
    self.now = now
  }

  func handle(_ line: Data) async -> Data {
    guard let request = try? JSONDecoder().decode(ClaudeBridgeRequest.self, from: line) else {
      return Self.reply(id: nil, failure: ClaudeBridgeFailure(
        code: .invalidRequest,
        message: "Send one JSON object per line with a numeric id and a method."
      ))
    }
    do {
      let result = try await dispatch(request.method, line: line)
      return Self.reply(id: request.id, result: result)
    } catch let failure as ClaudeBridgeFailure {
      return Self.reply(id: request.id, failure: failure)
    } catch {
      return Self.reply(id: request.id, failure: .invalidParams(Self.describe(error)))
    }
  }

  private func dispatch(_ method: String, line: Data) async throws -> any Encodable {
    if method != "status", case .locked = appState.localLockStatus {
      throw ClaudeBridgeFailure(code: .locked, message: "Serenity is locked. Unlock it on this Mac first.")
    }
    if method != "status", case .lockedOut = appState.localLockStatus {
      throw ClaudeBridgeFailure(code: .locked, message: "Serenity is locked. Unlock it on this Mac first.")
    }

    switch method {
    case "status":
      return status()
    case "today":
      return today()
    case "review.week":
      return week()
    case "tasks.list":
      return try listTasks(Self.optionalParams(TaskListParams.self, from: line) ?? TaskListParams())
    case "tasks.add":
      return try await addTask(Self.requiredParams(TaskAddParams.self, from: line))
    case "tasks.setDone":
      return try await setTaskDone(Self.requiredParams(TaskDoneParams.self, from: line))
    case "tasks.reschedule":
      return try await rescheduleTask(Self.requiredParams(TaskRescheduleParams.self, from: line))
    case "focus.status":
      return ClaudeFocusResult(focus: appState.activeFocusBlock.map(focusSnapshot))
    case "focus.start":
      return try await startFocus(Self.optionalParams(FocusStartParams.self, from: line) ?? FocusStartParams())
    case "focus.pause":
      return try await pauseFocus()
    case "focus.resume":
      return try await resumeFocus()
    case "focus.finish":
      return try await finishFocus()
    case "focus.extend":
      return try await extendFocus(Self.requiredParams(FocusExtendParams.self, from: line))
    case "focus.link":
      return try await linkFocus(Self.requiredParams(FocusLinkParams.self, from: line))
    case "routines.list":
      return ClaudeListResult(items: appState.routineSummaries(now: now()).map(routineSnapshot))
    case "routines.setDone":
      return try await setRoutineDone(Self.requiredParams(RoutineDoneParams.self, from: line))
    case "goals.list":
      return ClaudeListResult(items: appState.goalReports(now: now()).map(goalSnapshot))
    case "goals.checkIn":
      return try await checkInGoal(Self.requiredParams(GoalCheckInParams.self, from: line))
    case "journal.search":
      try requireJournalAccess()
      return try searchJournal(Self.optionalParams(JournalSearchParams.self, from: line) ?? JournalSearchParams())
    case "journal.add":
      try requireJournalAccess()
      return try await addJournalEntry(Self.requiredParams(JournalAddParams.self, from: line))
    default:
      throw ClaudeBridgeFailure(
        code: .unknownMethod,
        message: "Unknown method \(method). Known: \(Self.methods.joined(separator: ", "))."
      )
    }
  }

  // MARK: - Reads

  private func status() -> ClaudeStatusResult {
    ClaudeStatusResult(
      app: "Serenity",
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
      today: ClaudeBridgeDates.day(now()),
      timeZone: TimeZone.current.identifier,
      journalAccess: settings.journalAccess
    )
  }

  private func today() -> ClaudeTodayResult {
    let now = now()
    let topThree = appState.topThreeTasks(on: now)
    let topIDs = Set(topThree.map(\.id))
    let plan = TodayBriefing.planItems(
      tasks: appState.tasks,
      focusBlocks: appState.focusBlocks(on: now),
      day: now,
      now: now
    )
    return ClaudeTodayResult(
      date: ClaudeBridgeDates.day(now),
      focus: appState.activeFocusBlock.map(focusSnapshot),
      topThree: topThree.map { taskSnapshot($0, topIDs: topIDs) },
      dueToday: appState.todayTasks.filter { !topIDs.contains($0.id) }.prefix(30).map { taskSnapshot($0, topIDs: topIDs) },
      overdue: appState.overdueTasks.prefix(30).map { taskSnapshot($0, topIDs: topIDs) },
      plan: plan.timed.map(planSnapshot),
      routines: appState.routineSummaries(now: now).map(routineSnapshot),
      goals: appState.goalReports(now: now).map(goalSnapshot),
      inboxCount: appState.inboxTasks.count
    )
  }

  /// This week so far; on a Monday, the week just finished.
  private func week() -> ClaudeWeekResult {
    let now = now()
    let calendar = WeeklyReview.calendar
    let start = calendar.component(.weekday, from: now) == 2
      ? WeeklyReview.reviewedWeekStart(for: now, calendar: calendar)
      : calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    let recap = appState.weeklyRecap(weekStart: start, now: now)
    return ClaudeWeekResult(
      weekStart: ClaudeBridgeDates.day(recap.weekStart),
      weekEnd: ClaudeBridgeDates.day(recap.weekEnd),
      completedTasks: recap.days.flatMap(\.done).reversed().map(\.title),
      focusHours: (recap.focus.hours * 10).rounded() / 10,
      routines: recap.routines.map { .init(title: $0.title, done: $0.done) },
      goals: appState.goalReports(now: now).filter { $0.goal.status == .active && $0.kind != .area }.map(goalSnapshot)
    )
  }

  private func listTasks(_ params: TaskListParams) throws -> ClaudeListResult<ClaudeTaskSnapshot> {
    let scope = params.scope ?? "today"
    let candidates: [TaskEntity]
    switch scope {
    case "today":
      candidates = appState.todayTasks
    case "overdue":
      candidates = appState.overdueTasks
    case "upcoming":
      candidates = appState.upcomingTasks
    case "inbox":
      candidates = appState.inboxTasks
    case "open":
      candidates = appState.tasks.filter { !$0.completed }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    case "completed":
      candidates = appState.tasks.filter(\.completed).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    default:
      throw ClaudeBridgeFailure.invalidParams("Unknown scope \(scope). Use one of: \(Self.taskScopes.joined(separator: ", ")).")
    }
    let query = params.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let limit = min(max(params.limit ?? 50, 1), 200)
    let topIDs = Set(appState.topThreeTasks(on: now()).map(\.id))
    let matching = query.isEmpty ? candidates : candidates.filter {
      $0.title.lowercased().contains(query) || ($0.description?.lowercased().contains(query) ?? false)
    }
    return ClaudeListResult(items: matching.prefix(limit).map { taskSnapshot($0, topIDs: topIDs) })
  }

  private func searchJournal(_ params: JournalSearchParams) -> ClaudeListResult<ClaudeJournalSnapshot> {
    let query = params.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let limit = min(max(params.limit ?? 10, 1), 50)
    let entries = appState.journalEntries
      .filter { entry in
        query.isEmpty
          || entry.content.lowercased().contains(query)
          || (entry.title?.lowercased().contains(query) ?? false)
      }
      .sorted { $0.date > $1.date }
    return ClaudeListResult(items: entries.prefix(limit).map(journalSnapshot))
  }

  // MARK: - Tasks

  private func addTask(_ params: TaskAddParams) async throws -> ClaudeTaskSnapshot {
    let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ClaudeBridgeFailure.invalidParams("title can't be empty.") }
    let due = try params.due.map(Self.date)
    let priority = try params.priority.map { raw in
      guard let priority = TaskPriority(rawValue: raw) else {
        throw ClaudeBridgeFailure.invalidParams("priority must be low, medium or high.")
      }
      return priority
    } ?? .medium
    if let projectId = params.projectId, !appState.projects.contains(where: { $0.id == projectId }) {
      throw ClaudeBridgeFailure.notFound("No project with id \(projectId).")
    }

    let id = UUID().uuidString
    await appState.createTask(
      title: title,
      priority: priority,
      dueDate: due,
      tags: [],
      subtaskTitles: [],
      description: params.notes ?? "",
      projectID: params.projectId,
      id: id
    )
    let created = try task(id, failure: "Serenity couldn't save the task. Check the app for details.")
    settings.record("Added task “\(created.title)”", at: now())
    return taskSnapshot(created)
  }

  private func setTaskDone(_ params: TaskDoneParams) async throws -> ClaudeTaskSnapshot {
    let existing = try task(params.id)
    if existing.completed != params.done {
      await appState.toggleTaskCompletion(id: params.id)
    }
    let updated = try task(params.id)
    guard updated.completed == params.done else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't update the task. Check the app for details.")
    }
    if existing.completed != params.done {
      settings.record("\(params.done ? "Completed" : "Reopened") “\(updated.title)”", at: now())
    }
    return taskSnapshot(updated)
  }

  private func rescheduleTask(_ params: TaskRescheduleParams) async throws -> ClaudeTaskSnapshot {
    let existing = try task(params.id)
    let due = try params.due.map(Self.date)
    if let due, ClaudeBridgeDates.hasTime(due) {
      await appState.adjustTask(id: params.id) { task in
        task.dueDate = due
        task.tags.removeAll { $0 == AppState.somedayTag }
      }
    } else {
      await appState.scheduleTask(id: params.id, on: due)
    }
    let updated = try task(params.id)
    guard updated.dueDate == due else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't move the task. Check the app for details.")
    }
    let when = due.map { "to \(ClaudeBridgeDates.due($0))" } ?? "back to the inbox"
    settings.record("Moved “\(existing.title)” \(when)", at: now())
    return taskSnapshot(updated)
  }

  // MARK: - Focus

  private func startFocus(_ params: FocusStartParams) async throws -> ClaudeFocusResult {
    let minutes: Int?
    if params.openEnded == true {
      minutes = nil
    } else if let requested = params.minutes {
      guard AppState.focusLengthRange.contains(requested) else {
        throw ClaudeBridgeFailure.invalidParams("minutes must be between \(AppState.focusLengthRange.lowerBound) and \(AppState.focusLengthRange.upperBound), or set openEnded.")
      }
      minutes = requested
    } else {
      minutes = AppState.lastFocusMinutes
    }
    let linkedTask = try params.taskId.map { try task($0) }
    if let entryId = params.journalEntryId {
      try requireJournalAccess()
      _ = try journalEntry(entryId)
    }

    let previous = appState.activeFocusBlock
    let title = params.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? linkedTask?.title ?? ""
    await appState.startFocus(
      title: title,
      minutes: minutes,
      goalId: nil,
      taskId: params.taskId,
      journalEntryId: params.journalEntryId,
      now: now()
    )
    guard let started = appState.activeFocusBlock, started.id != previous?.id else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't start the session. Check the app for details.")
    }
    var result = ClaudeFocusResult(focus: focusSnapshot(started))
    if let previous {
      result.finishedPrevious = appState.focusBlocks.first { $0.id == previous.id }.map(focusSnapshot)
    }
    settings.record("Started focus “\(started.title)”", at: now())
    return result
  }

  private func pauseFocus() async throws -> ClaudeFocusResult {
    let block = try activeBlock()
    if block.status == .running {
      await appState.pauseFocusBlock(id: block.id, now: now())
      settings.record("Paused focus “\(block.title)”", at: now())
    }
    return ClaudeFocusResult(focus: appState.activeFocusBlock.map(focusSnapshot))
  }

  private func resumeFocus() async throws -> ClaudeFocusResult {
    let block = try activeBlock()
    if block.status == .paused {
      await appState.resumeFocusBlock(id: block.id, now: now())
      settings.record("Resumed focus “\(block.title)”", at: now())
    }
    return ClaudeFocusResult(focus: appState.activeFocusBlock.map(focusSnapshot))
  }

  private func finishFocus() async throws -> ClaudeFocusResult {
    let block = try activeBlock()
    await appState.finishFocusBlock(id: block.id, now: now())
    guard let done = appState.focusBlocks.first(where: { $0.id == block.id }), done.status == .done else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't finish the session. Check the app for details.")
    }
    settings.record("Finished focus “\(done.title)” · \(Int(done.loggedMinutes.rounded())) min", at: now())
    return ClaudeFocusResult(focus: nil, finishedPrevious: focusSnapshot(done))
  }

  private func extendFocus(_ params: FocusExtendParams) async throws -> ClaudeFocusResult {
    let block = try activeBlock()
    guard !block.isOpenEnded else {
      throw ClaudeBridgeFailure.invalidParams("This session has no set length, so there is nothing to extend.")
    }
    guard params.minutes != 0 else { return ClaudeFocusResult(focus: focusSnapshot(block)) }
    await appState.extendFocusBlock(id: block.id, byMinutes: params.minutes)
    let sign = params.minutes > 0 ? "+" : "−"
    settings.record("\(sign)\(abs(params.minutes)) min on “\(block.title)”", at: now())
    return ClaudeFocusResult(focus: appState.activeFocusBlock.map(focusSnapshot))
  }

  private func linkFocus(_ params: FocusLinkParams) async throws -> ClaudeFocusResult {
    let block = try activeBlock()
    guard params.taskId != nil || params.journalEntryId != nil else {
      throw ClaudeBridgeFailure.invalidParams("Pass taskId or journalEntryId; null unlinks.")
    }
    if case let .some(taskId) = params.taskId {
      if let taskId { _ = try task(taskId) }
      await appState.linkFocusBlock(id: block.id, toTask: taskId)
    }
    if case let .some(entryId) = params.journalEntryId {
      try requireJournalAccess()
      if let entryId { _ = try journalEntry(entryId) }
      await appState.linkFocusBlock(id: block.id, toJournalEntry: entryId)
    }
    let updated = try activeBlock()
    let link = appState.focusLinkSummary(for: updated).map { "to \($0)" } ?? "from everything"
    settings.record("Linked “\(updated.title)” \(link)", at: now())
    return ClaudeFocusResult(focus: focusSnapshot(updated))
  }

  // MARK: - Routines and goals

  private func setRoutineDone(_ params: RoutineDoneParams) async throws -> ClaudeRoutineSnapshot {
    guard let summary = appState.routineSummaries(now: now()).first(where: { $0.id == params.id }) else {
      throw ClaudeBridgeFailure.notFound("No routine with id \(params.id).")
    }
    if (summary.today == .done) != params.done {
      await appState.toggleRoutineDone(id: params.id, now: now())
    }
    guard let updated = appState.routineSummaries(now: now()).first(where: { $0.id == params.id }),
          (updated.today == .done) == params.done else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't update the routine. Check the app for details.")
    }
    if (summary.today == .done) != params.done {
      settings.record("\(params.done ? "Ticked" : "Unticked") routine “\(updated.routine.title)”", at: now())
    }
    return routineSnapshot(updated)
  }

  private func checkInGoal(_ params: GoalCheckInParams) async throws -> ClaudeGoalSnapshot {
    guard let goal = appState.goals.first(where: { $0.id == params.id }) else {
      throw ClaudeBridgeFailure.notFound("No goal with id \(params.id).")
    }
    let note = params.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    guard params.amount != 0 || note != nil else {
      throw ClaudeBridgeFailure.invalidParams("Pass a non-zero amount, a note, or both.")
    }
    let before = goal.config.checkIns?.count ?? 0
    await appState.checkInGoal(id: params.id, amount: params.amount, note: note, date: now())
    guard (appState.goals.first(where: { $0.id == params.id })?.config.checkIns?.count ?? 0) > before,
          let report = appState.goalReports(now: now()).first(where: { $0.id == params.id }) else {
      throw ClaudeBridgeFailure.failed("Serenity couldn't save the check-in. Check the app for details.")
    }
    settings.record("Checked in on “\(goal.title)”: \(GoalReport.format(params.amount)) \(report.unit)".trimmingCharacters(in: .whitespaces), at: now())
    return goalSnapshot(report)
  }

  // MARK: - Journal

  private func addJournalEntry(_ params: JournalAddParams) async throws -> ClaudeJournalSnapshot {
    let content = params.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw ClaudeBridgeFailure.invalidParams("content can't be empty.") }
    let id = UUID().uuidString
    await appState.createJournalEntry(title: params.title ?? "", content: content, mood: nil, tags: [], id: id)
    let entry = try journalEntry(id, failure: "Serenity couldn't save the entry. Check the app for details.")
    settings.record("Wrote journal entry “\(entry.title ?? "Untitled")”", at: now())
    return journalSnapshot(entry)
  }

  private func requireJournalAccess() throws {
    guard settings.journalAccess else {
      throw ClaudeBridgeFailure(
        code: .journalOff,
        message: "Journal access is off. Turn it on in Serenity › Settings › Claude."
      )
    }
  }

  // MARK: - Lookups

  private func task(_ id: String, failure: String? = nil) throws -> TaskEntity {
    guard let task = appState.tasks.first(where: { $0.id == id }) else {
      throw failure.map(ClaudeBridgeFailure.failed) ?? .notFound("No task with id \(id).")
    }
    return task
  }

  private func journalEntry(_ id: String, failure: String? = nil) throws -> JournalEntryEntity {
    guard let entry = appState.journalEntries.first(where: { $0.id == id }) else {
      throw failure.map(ClaudeBridgeFailure.failed) ?? .notFound("No journal entry with id \(id).")
    }
    return entry
  }

  private func activeBlock() throws -> FocusBlockEntity {
    guard let block = appState.activeFocusBlock else {
      throw ClaudeBridgeFailure.notFound("No focus session is running.")
    }
    return block
  }

  // MARK: - Snapshots

  private func taskSnapshot(_ task: TaskEntity) -> ClaudeTaskSnapshot {
    taskSnapshot(task, topIDs: Set(appState.topThreeTasks(on: now()).map(\.id)))
  }

  private func taskSnapshot(_ task: TaskEntity, topIDs: Set<String>) -> ClaudeTaskSnapshot {
    ClaudeTaskSnapshot(
      id: task.id,
      title: task.title,
      notes: task.description,
      done: task.completed,
      due: task.dueDate.map { ClaudeBridgeDates.due($0) },
      priority: task.priority.rawValue,
      project: task.projectId.flatMap { id in appState.projects.first { $0.id == id }?.name },
      topThree: topIDs.contains(task.id)
    )
  }

  private func focusSnapshot(_ block: FocusBlockEntity) -> ClaudeFocusSnapshot {
    let focused = block.activeSeconds(at: now())
    let length = block.isOpenEnded ? nil : block.plannedMinutes - block.pausedSeconds / 60
    let focusedSeconds = block.status == .done ? block.loggedMinutes * 60 : focused
    return ClaudeFocusSnapshot(
      id: block.id,
      title: block.title,
      status: block.status.rawValue,
      startedAt: block.startedAt.map { ClaudeBridgeDates.moment($0) },
      focusedMinutes: Int(focusedSeconds / 60),
      lengthMinutes: length.map { Int($0.rounded()) },
      remainingMinutes: block.isActive ? length.map { max(Int((($0 * 60) - focused) / 60), 0) } : nil,
      focusedSeconds: Int(focusedSeconds),
      remainingSeconds: block.isActive ? length.map { max(Int(($0 * 60) - focused), 0) } : nil,
      taskId: block.taskId,
      taskTitle: block.taskId.flatMap { id in appState.tasks.first { $0.id == id }?.title },
      journalEntryId: settings.journalAccess ? block.journalEntryId : nil
    )
  }

  private func planSnapshot(_ item: PlanItem) -> ClaudePlanSnapshot {
    let kind: String
    switch item.kind {
    case .calendar: kind = "calendar"
    case .task: kind = "task"
    case .focus: kind = "focus"
    }
    return ClaudePlanSnapshot(
      title: item.title,
      kind: kind,
      start: ClaudeBridgeDates.moment(item.start),
      end: ClaudeBridgeDates.moment(item.end),
      done: item.isDone
    )
  }

  private func routineSnapshot(_ summary: RoutineSummary) -> ClaudeRoutineSnapshot {
    ClaudeRoutineSnapshot(
      id: summary.id,
      title: summary.routine.title,
      scheduledToday: summary.isScheduledToday,
      today: summary.today?.rawValue,
      streak: summary.streakLabel,
      thisWeek: summary.weekProgress.map { "\($0.done) of \($0.target)" }
    )
  }

  private func goalSnapshot(_ report: GoalReport) -> ClaudeGoalSnapshot {
    ClaudeGoalSnapshot(
      id: report.id,
      title: report.goal.title,
      kind: report.kind.rawValue,
      progress: report.progressLabel,
      pace: report.statusLabel,
      paceState: report.needsSetup ? "needsSetup" : (report.isPaused ? "paused" : Self.paceState(report.pace)),
      current: report.current,
      target: report.target,
      expected: report.expected,
      unit: report.unit,
      due: report.windowEnd.map { ClaudeBridgeDates.day($0) }
    )
  }

  private static func paceState(_ pace: GoalPace) -> String {
    switch pace {
    case .done: return "done"
    case .ahead: return "ahead"
    case .onPace: return "onPace"
    case .behind: return "behind"
    case .untimed: return "untimed"
    }
  }

  private func journalSnapshot(_ entry: JournalEntryEntity) -> ClaudeJournalSnapshot {
    let truncated = entry.content.count > Self.journalExcerptLimit
    return ClaudeJournalSnapshot(
      id: entry.id,
      title: entry.title ?? "Untitled",
      date: ClaudeBridgeDates.moment(entry.date),
      content: truncated ? String(entry.content.prefix(Self.journalExcerptLimit)) : entry.content,
      truncated: truncated,
      tags: entry.tags
    )
  }

  // MARK: - Wire

  private static func date(_ text: String) throws -> Date {
    guard let date = ClaudeBridgeDates.parse(text) else {
      throw ClaudeBridgeFailure.invalidParams("Couldn't read the date \(text). Use 2026-11-15 or 2026-11-15T14:30.")
    }
    return date
  }

  private struct Envelope<P: Decodable>: Decodable {
    let params: P?
  }

  private static func optionalParams<P: Decodable>(_ type: P.Type, from line: Data) throws -> P? {
    try JSONDecoder().decode(Envelope<P>.self, from: line).params
  }

  private static func requiredParams<P: Decodable>(_ type: P.Type, from line: Data) throws -> P {
    guard let params = try optionalParams(type, from: line) else {
      throw ClaudeBridgeFailure.invalidParams("This method needs params.")
    }
    return params
  }

  private static func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.keyNotFound(let key, _):
      return "Missing \(key.stringValue)."
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      let path = context.codingPath.map(\.stringValue).filter { $0 != "params" }.joined(separator: ".")
      return "Wrong type for \(path.isEmpty ? "params" : path)."
    case DecodingError.dataCorrupted:
      return "That isn't valid JSON."
    default:
      return error.localizedDescription
    }
  }

  private struct Reply: Encodable {
    let id: Int?
    let result: AnyEncodable?
    let error: ClaudeBridgeFailure?
  }

  private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
  }

  static func reply(id: Int?, result: any Encodable) -> Data {
    encode(Reply(id: id, result: AnyEncodable(value: result), error: nil))
  }

  static func reply(id: Int?, failure: ClaudeBridgeFailure) -> Data {
    encode(Reply(id: id, result: nil, error: failure))
  }

  private static func encode(_ reply: Reply) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(reply)) ?? Data(#"{"error":{"code":"failed","message":"Couldn't encode the reply."}}"#.utf8)
  }
}

// MARK: - Params

private struct TaskListParams: Decodable {
  var scope: String?
  var query: String?
  var limit: Int?
}

private struct TaskAddParams: Decodable {
  let title: String
  let due: String?
  let priority: String?
  let notes: String?
  let projectId: String?
}

private struct TaskDoneParams: Decodable {
  let id: String
  let done: Bool
}

/// `due` must be present: null sends the task back to the inbox, so leaving it out is a mistake.
private struct TaskRescheduleParams: Decodable {
  let id: String
  let due: String?

  enum CodingKeys: String, CodingKey { case id, due }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    due = try container.decode(String?.self, forKey: .due)
  }
}

private struct FocusStartParams: Decodable {
  var title: String?
  var minutes: Int?
  var openEnded: Bool?
  var taskId: String?
  var journalEntryId: String?
}

private struct FocusExtendParams: Decodable {
  let minutes: Int
}

/// A key left out is untouched; a null unlinks.
private struct FocusLinkParams: Decodable {
  let taskId: String??
  let journalEntryId: String??

  enum CodingKeys: String, CodingKey { case taskId, journalEntryId }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    taskId = container.contains(.taskId) ? .some(try container.decode(String?.self, forKey: .taskId)) : nil
    journalEntryId = container.contains(.journalEntryId)
      ? .some(try container.decode(String?.self, forKey: .journalEntryId))
      : nil
  }
}

private struct RoutineDoneParams: Decodable {
  let id: String
  let done: Bool
}

private struct GoalCheckInParams: Decodable {
  let id: String
  let amount: Double
  let note: String?
}

private struct JournalSearchParams: Decodable {
  var query: String?
  var limit: Int?
}

private struct JournalAddParams: Decodable {
  let content: String
  let title: String?
}
