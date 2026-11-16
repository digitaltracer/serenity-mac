import Foundation
import XCTest
@testable import SerenityMac

final class WeeklyReviewFlowTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// 2026-11-16 is a Monday.
  private func date(_ day: Int, _ hour: Int = 12, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  private var format: RecapFormat { RecapFormat(calendar: calendar, locale: Locale(identifier: "en_GB")) }

  private func finding(_ id: String, action: WeeklyAction?, title: String = "Title") -> WeeklyFinding {
    WeeklyFinding(id: id, kind: .stuckTask, subjectId: id, linked: "Agency", title: title, body: "", evidenceLabel: "", evidence: [], action: action, actionTitle: action == nil ? nil : "Make it first on Today", score: 2)
  }

  func testOpenItemChoicesLandOnTodayOrFriday() {
    XCTAssertEqual(WeeklyReview.carryDueDate(.monday, now: date(16, 8), calendar: calendar), date(16, 0))
    XCTAssertEqual(WeeklyReview.carryDueDate(.thisWeek, now: date(16, 8), calendar: calendar), date(20, 0))
    XCTAssertEqual(WeeklyReview.carryDueDate(.thisWeek, now: date(21, 8), calendar: calendar), date(21, 0), "past Friday it means today")
    XCTAssertNil(WeeklyReview.carryDueDate(.someday, now: date(16), calendar: calendar))
    XCTAssertEqual(WeeklyReview.carryLabel(.monday, now: date(16), calendar: calendar), "Monday")
    XCTAssertEqual(WeeklyReview.carryLabel(.monday, now: date(17), calendar: calendar), "Today")
  }

  func testPicksComeFromFindingsWithActionsThenOpenItems() {
    let carry = [
      WeeklyRecap.CarryItem(taskId: "inv", title: "Invoice", projectName: "Agency", dueDate: nil, moves: 3, focusHours: 0, createdAt: date(4)),
      WeeklyRecap.CarryItem(taskId: "dent", title: "Book the dentist", projectName: nil, dueDate: nil, moves: 0, focusHours: 0, createdAt: date(7)),
    ]
    let picks = WeeklyReview.suggestedPicks(
      findings: [finding("stuckTask:inv", action: .firstOnToday(taskId: "inv")), finding("quietArea:x", action: nil)],
      carryOver: carry,
      format: format
    )

    XCTAssertEqual(picks.map(\.id), ["finding:stuckTask:inv", "task:dent"])
    XCTAssertEqual(picks[0].effect, "Puts it first on Today")
    XCTAssertEqual(picks[0].findingId, "stuckTask:inv")
    XCTAssertEqual(picks[1].taskId, "dent")
  }

  func testEffectsSayWhatActingDoes() {
    let slots = [DateInterval(start: date(17, 9), duration: 5_400), DateInterval(start: date(19, 9), duration: 5_400)]
    XCTAssertEqual(WeeklyReview.effect(of: .bookFocus(title: "x", goalId: nil, slots: slots), format: format), "Books Tue 17 and Thu 19, 9:00–10:30 in your plan")
    XCTAssertEqual(WeeklyReview.effect(of: .lateEveningReminder(routineId: "r", hour: 8, minute: 30), format: format), "After late evenings, reminds you at 8:30 instead")
  }

  func testJournalTextKeepsOnlyTickedLinesAndThePersonsWords() {
    let recap = WeeklyRecap.build(inputs: WeeklyRecapInputs(), weekStart: date(9, 0), now: date(16, 8), calendar: calendar, goalCalendar: calendar, locale: Locale(identifier: "en_GB"))
    var payload = WeeklyReviewPayload()
    payload.why = "Client work crowded it out"
    payload.picks = [WeeklyReviewPayload.Pick(id: "own:1", title: "Book the dentist", context: "", effect: "", findingId: nil, taskId: nil)]
    let accepted = WeeklyAcceptedAction(id: "a", findingId: nil, kind: nil, action: .firstOnToday(taskId: "t"), title: "Make it first on Today", acceptedAt: date(16))

    let text = WeeklyReview.journalText(recap: recap, payload: payload, accepted: [accepted])

    XCTAssertEqual(text, "## What stalled\n\nWhy: Client work crowded it out\n\n## This week\n- Book the dentist\n\n## Changes made\n- Make it first on Today")
    XCTAssertEqual(WeeklyReview.journalText(recap: recap, payload: WeeklyReviewPayload(), accepted: []), "Nothing to add this week.")
  }

  private func reviewWithRule(undone: Bool = false) -> WeeklyReviewEntity {
    var payload = WeeklyReviewPayload()
    payload.actions = [WeeklyAcceptedAction(
      id: "routineAfterLateEvening:pages", findingId: "routineAfterLateEvening:pages", kind: .routineAfterLateEvening,
      action: .lateEveningReminder(routineId: "pages", hour: 8, minute: 30), title: "After late evenings, remind me at 8:30",
      acceptedAt: date(16, 8), undoneAt: undone ? date(16, 9) : nil
    )]
    return WeeklyReviewEntity(weekKey: "2026-W46", weekStart: date(9, 0), payload: payload, createdAt: date(16), updatedAt: date(16))
  }

  private var routines: [RoutineEntity] {
    [RoutineEntity(id: "pages", title: "Morning pages", schedule: .weekdays([2, 3, 4, 5, 6]), timeOfDay: .morning, archived: false, createdAt: date(1), updatedAt: date(1))]
  }

  private func event(_ id: String, _ start: Date) -> TaskEntity {
    TaskEntity(id: id, title: "Agency retro", description: nil, completed: false, completedAt: nil, priority: .medium, dueDate: start, projectId: nil, tags: [TodayBriefing.calendarTag], createdAt: date(1), updatedAt: date(1), subtasks: [], recurring: nil, userId: nil)
  }

  func testAcceptedLateEveningRuleRemindsTheMorningAfterAnEveningEvent() {
    let tasks = [event("retro", date(16, 19, minute: 30)), event("lunch", date(17, 12)), event("friday", date(20, 20))]

    let occurrences = WeeklyReview.reminderOccurrences(reviews: [reviewWithRule()], routines: routines, tasks: tasks, now: date(16, 10), calendar: calendar)

    XCTAssertEqual(occurrences.map(\.id), ["review:pages:2026-11-17"], "Saturday is not a scheduled day")
    XCTAssertEqual(occurrences.first?.fireDate, date(17, 8, minute: 30))
    XCTAssertEqual(occurrences.first?.title, "Morning pages")
    XCTAssertEqual(occurrences.first?.body, "A later start after Agency retro.")
  }

  func testUndoingTheRuleStopsTheReminders() {
    let tasks = [event("retro", date(16, 19, minute: 30))]
    XCTAssertTrue(WeeklyReview.reminderOccurrences(reviews: [reviewWithRule(undone: true)], routines: routines, tasks: tasks, now: date(16, 10), calendar: calendar).isEmpty)
  }
}

@MainActor
final class WeeklyReviewStateTests: XCTestCase {
  private var baseURL: URL!
  private var suiteName = ""

  override func tearDown() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    if let baseURL { try? FileManager.default.removeItem(at: baseURL) }
    super.tearDown()
  }

  private func makeState() async throws -> AppState {
    baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-review-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    suiteName = "serenity.review.flow.\(UUID().uuidString)"
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: UserDefaults(suiteName: suiteName)!,
        defaultsKey: "review.flow.backend",
        registry: BackendProfileRegistry(descriptors: BackendProfileRegistry.live.descriptors, validators: [.sqliteLocal: { .available(message: "ok") }])
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )
    await state.bootstrapLocalDatabase()
    await state.refreshCoreWorkflowData()
    return state
  }

  private var weekKey: String { WeeklyReview.weekKey(for: Date()) }

  /// A prepared review whose only finding offers `action`.
  private func prepare(_ state: AppState, action: WeeklyAction) async {
    await state.prepareWeeklyReview()
    await state.updateWeeklyReview(weekKey: weekKey) { payload in
      payload.findings = [WeeklyFinding(id: "test:1", kind: .stuckTask, subjectId: "1", linked: "", title: "Stuck", body: "", evidenceLabel: "", evidence: [], action: action, actionTitle: "Do it", score: 2)]
    }
  }

  func testPreparingWorksOutFindingsOnceWithoutAKey() async throws {
    let state = try await makeState()

    let first = await state.prepareWeeklyReview()
    XCTAssertNotNil(first.payload.preparedAt)
    XCTAssertFalse(first.payload.writtenByModel)
    XCTAssertEqual(state.weeklyReviews.map(\.weekKey), [weekKey])

    let again = await state.prepareWeeklyReview()
    XCTAssertEqual(again.payload.preparedAt, first.payload.preparedAt)
    XCTAssertFalse(state.isWeeklyReviewDone)
  }

  func testFirstOnTodayIsDateOnlyAndUndoPutsTheTaskBack() async throws {
    let state = try await makeState()
    let laterDue = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date()))!
    _ = await state.createTask(title: "Invoice", priority: .medium, dueDate: laterDue, tags: ["someday"], subtaskTitles: [], id: "inv")
    await prepare(state, action: .firstOnToday(taskId: "inv"))

    await state.acceptFinding("test:1", weekKey: weekKey)

    let moved = try XCTUnwrap(state.tasks.first { $0.id == "inv" })
    XCTAssertEqual(moved.dueDate, Calendar.current.startOfDay(for: Date()))
    XCTAssertEqual(state.topThreeTasks().map(\.id), ["inv"])
    XCTAssertFalse(moved.tags.contains("someday"))
    XCTAssertEqual(state.weeklyReview(forWeek: weekKey)?.payload.liveActions.count, 1)

    let accepted = try XCTUnwrap(state.weeklyReview(forWeek: weekKey)?.payload.liveActions.first)
    await state.undoReviewAction(accepted.id, weekKey: weekKey)

    let restored = try XCTUnwrap(state.tasks.first { $0.id == "inv" })
    XCTAssertEqual(restored.dueDate, laterDue)
    XCTAssertTrue(restored.tags.contains("someday"))
    XCTAssertTrue(state.topThreeTasks().isEmpty)
    XCTAssertTrue(state.weeklyReview(forWeek: weekKey)?.payload.liveActions.isEmpty ?? false)
  }

  func testBookingCreatesFocusBlocksInSerenityAndUndoRemovesThem() async throws {
    let state = try await makeState()
    let start = Date().addingTimeInterval(86_400)
    await prepare(state, action: .bookFocus(title: "Ship focus", goalId: nil, slots: [DateInterval(start: start, duration: 5_400), DateInterval(start: start.addingTimeInterval(172_800), duration: 5_400)]))

    await state.acceptFinding("test:1", weekKey: weekKey)
    let accepted = try XCTUnwrap(state.weeklyReview(forWeek: weekKey)?.payload.liveActions.first)
    XCTAssertEqual(accepted.focusBlockIds.count, 2)
    XCTAssertEqual(state.focusBlocks.filter { accepted.focusBlockIds.contains($0.id) }.map(\.plannedMinutes), [90, 90])

    await state.acceptFinding("test:1", weekKey: weekKey)
    XCTAssertEqual(state.focusBlocks.count, 2, "accepting twice books once")

    await state.undoReviewAction(accepted.id, weekKey: weekKey)
    XCTAssertTrue(state.focusBlocks.isEmpty)
  }

  func testNotUsefulIsRecordedAndFeedsLaterWeeks() async throws {
    let state = try await makeState()
    await prepare(state, action: .firstOnToday(taskId: "none"))

    await state.markFindingNotUseful("test:1", reason: .knewThis, weekKey: weekKey)
    XCTAssertEqual(state.weeklyReview(forWeek: weekKey)?.payload.feedback.map(\.reason), [.knewThis])
    XCTAssertEqual(state.weeklyRecapInputs().feedback.map(\.findingId), ["test:1"])

    await state.undoNotUseful("test:1", weekKey: weekKey)
    XCTAssertTrue(state.weeklyRecapInputs().feedback.isEmpty)
  }

  func testSavingAppliesDecisionsPicksAndMarksTheWeekDone() async throws {
    let state = try await makeState()
    _ = await state.createTask(title: "Sync conflict", priority: .medium, dueDate: nil, tags: [], subtaskTitles: [], id: "sync")
    _ = await state.createTask(title: "Old idea", priority: .low, dueDate: nil, tags: [], subtaskTitles: [], id: "idea")
    _ = await state.createTask(title: "Renew domain", priority: .low, dueDate: nil, tags: [], subtaskTitles: [], id: "domain")
    await state.prepareWeeklyReview()
    await state.updateWeeklyReview(weekKey: weekKey) { payload in
      payload.carry = ["sync": .monday, "idea": .someday, "domain": .drop]
      payload.picks = [WeeklyReviewPayload.Pick(id: "own:1", title: "Book the dentist", context: "Your own", effect: "", findingId: nil, taskId: nil)]
      payload.why = "Busy"
    }

    await state.completeWeeklyReview(weekKey: weekKey)

    let today = Calendar.current.startOfDay(for: Date())
    XCTAssertEqual(state.tasks.first { $0.id == "sync" }?.dueDate, today)
    XCTAssertTrue(state.tasks.first { $0.id == "idea" }?.tags.contains("someday") ?? false)
    XCTAssertNil(state.tasks.first { $0.id == "domain" })
    let dentist = try XCTUnwrap(state.tasks.first { $0.title == "Book the dentist" })
    XCTAssertEqual(dentist.dueDate, today)
    XCTAssertTrue(dentist.tags.contains(WeeklyReview.tag))

    let saved = try XCTUnwrap(state.weeklyReview(forWeek: weekKey))
    XCTAssertNotNil(saved.completedAt)
    XCTAssertEqual(saved.payload.picks.first?.taskId, dentist.id)
    let entry = try XCTUnwrap(state.journalEntries.first { $0.id == saved.payload.journalEntryId })
    XCTAssertTrue(entry.tags.contains(WeeklyReview.tag))
    XCTAssertTrue(entry.content.contains("Why: Busy"))
    XCTAssertTrue(state.isWeeklyReviewDone)
    XCTAssertFalse(state.isWeeklyReviewDue)

    await state.completeWeeklyReview(weekKey: weekKey)
    XCTAssertEqual(state.journalEntries.filter { $0.tags.contains(WeeklyReview.tag) }.count, 1, "saving twice writes one entry")
  }

  func testPausingAGoalIsUndoneToItsEarlierState() async throws {
    let state = try await makeState()
    var draft = GoalDraft()
    draft.title = "Run 60 km"
    draft.kind = .target
    draft.source = .manual
    draft.target = 60
    await state.createGoal(draft)
    let goal = try XCTUnwrap(state.goals.first)
    await prepare(state, action: .pauseGoal(goalId: goal.id))

    await state.acceptFinding("test:1", weekKey: weekKey)
    XCTAssertNotNil(state.goals.first?.config.pausedUntil)

    let accepted = try XCTUnwrap(state.weeklyReview(forWeek: weekKey)?.payload.liveActions.first)
    await state.undoReviewAction(accepted.id, weekKey: weekKey)
    XCTAssertNil(state.goals.first?.config.pausedUntil)
  }
}
