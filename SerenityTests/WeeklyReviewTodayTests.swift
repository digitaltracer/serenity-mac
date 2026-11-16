import Foundation
import XCTest
@testable import SerenityMac

final class WeeklyReviewTodayTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// 2026-11-16 is a Monday; the review on it covers 9–15 November.
  private func date(_ day: Int, _ hour: Int = 12, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  private var format: RecapFormat { RecapFormat(calendar: calendar, locale: Locale(identifier: "en_GB")) }

  private func task(_ id: String, done: Date? = nil, due: Date? = nil, calendarEvent: Bool = false) -> TaskEntity {
    TaskEntity(id: id, title: id, description: nil, completed: done != nil, completedAt: done, priority: .medium, dueDate: due, projectId: nil,
               tags: calendarEvent ? [TodayBriefing.calendarTag] : [], createdAt: date(1), updatedAt: date(1), subtasks: [], recurring: nil, userId: nil)
  }

  private func block(_ id: String, start: Date, done: Bool) -> FocusBlockEntity {
    FocusBlockEntity(id: id, title: "Ship focus", start: start, end: start.addingTimeInterval(5_400), goalId: "ship", taskIds: [], status: done ? .done : .planned,
                     startedAt: done ? start : nil, finishedAt: done ? start.addingTimeInterval(5_400) : nil, loggedMinutes: done ? 90 : 0, createdAt: date(16), updatedAt: date(16))
  }

  private func accepted(_ id: String, _ action: WeeklyAction, at: Date? = nil, blocks: [String] = [], findingId: String? = nil) -> WeeklyAcceptedAction {
    WeeklyAcceptedAction(id: id, findingId: findingId, kind: nil, action: action, title: "Title \(id)", acceptedAt: at ?? date(16, 8), focusBlockIds: blocks)
  }

  private var routine: RoutineEntity {
    RoutineEntity(id: "pages", title: "Morning pages", schedule: .daily, timeOfDay: .morning, archived: false, createdAt: date(1), updatedAt: date(1))
  }

  private func outcome(_ action: WeeklyAcceptedAction, tasks: [TaskEntity] = [], blocks: [FocusBlockEntity] = [], checks: [RoutineCheckEntity] = [], now: Date) -> (WeeklyAcceptedAction.Outcome?, String) {
    let result = WeeklyReview.outcome(of: action, tasks: tasks, focusBlocks: blocks, routines: [routine], routineChecks: checks, now: now, format: format)
    return (result.status, result.text)
  }

  func testBookedBlocksCountWhatHeldAndSayWhatsNext() {
    let action = accepted("a", .bookFocus(title: "x", goalId: "ship", slots: []), blocks: ["tue", "thu"])
    let blocks = [block("tue", start: date(17, 9), done: true), block("thu", start: date(19, 9), done: false)]

    let wednesday = outcome(action, blocks: blocks, now: date(18, 8))
    XCTAssertEqual(wednesday.0, .held)
    XCTAssertEqual(wednesday.1, "1 of 1 booked block held, 1.5 h of focus · next Thu 19 9:00")

    let friday = outcome(action, blocks: blocks, now: date(20, 8))
    XCTAssertEqual(friday.0, .partly)
    XCTAssertEqual(friday.1, "1 of 2 booked blocks held, 1.5 h of focus")

    XCTAssertEqual(outcome(action, blocks: [], now: date(20, 8)).0, .missed, "deleted blocks did not hold")
    let upcoming = [block("tue", start: date(17, 9), done: false), block("thu", start: date(19, 9), done: false)]
    XCTAssertNil(outcome(action, blocks: upcoming, now: date(16, 10)).0)
    XCTAssertEqual(outcome(action, blocks: upcoming, now: date(16, 10)).1, "Nothing due yet · next Tue 17 9:00")
  }

  func testFirstOnTodayHeldWhenDoneAndMissedOnceTheDayPasses() {
    let action = accepted("a", .firstOnToday(taskId: "inv"))
    XCTAssertEqual(outcome(action, tasks: [task("inv", done: date(16, 9, minute: 12))], now: date(18)).1, "Done Mon 9:12")
    XCTAssertNil(outcome(action, tasks: [task("inv")], now: date(16, 15)).0)
    XCTAssertEqual(outcome(action, tasks: [task("inv")], now: date(17, 9)).0, .missed)
    XCTAssertEqual(outcome(action, tasks: [], now: date(17, 9)).1, "The task was deleted")
  }

  func testLateEveningRuleIsJudgedOnTheMorningsAfter() {
    let action = accepted("a", .lateEveningReminder(routineId: "pages", hour: 8, minute: 30))
    let tasks = [task("retro", due: date(16, 19, minute: 30), calendarEvent: true)]
    let check = RoutineCheckEntity(routineId: "pages", day: "2026-11-17", status: .done, createdAt: date(17), updatedAt: date(17))

    XCTAssertNil(outcome(action, tasks: tasks, now: date(17, 8)).0, "Tuesday isn't over")
    let wednesday = outcome(action, tasks: tasks, checks: [check], now: date(18, 8))
    XCTAssertEqual(wednesday.0, .held)
    XCTAssertEqual(wednesday.1, "Morning pages done 1 of 1 morning after a late evening")
  }

  private func review(actions: [WeeklyAcceptedAction], findings: [WeeklyFinding] = [], seen: Date? = nil) -> WeeklyReviewEntity {
    var payload = WeeklyReviewPayload()
    payload.actions = actions
    payload.findings = findings
    payload.checkInSeenAt = seen
    return WeeklyReviewEntity(weekKey: "2026-W46", weekStart: date(9, 0), completedAt: date(16, 9), payload: payload, createdAt: date(16), updatedAt: date(16))
  }

  private func insight(_ reviews: [WeeklyReviewEntity], tasks: [TaskEntity] = [], blocks: [FocusBlockEntity] = [], now: Date) -> WeeklyReview.TodayInsight {
    WeeklyReview.todayInsight(reviews: reviews, tasks: tasks, focusBlocks: blocks, routines: [routine], routineChecks: [], now: now, format: format)
  }

  private var stuck: WeeklyFinding {
    WeeklyFinding(id: "stuckTask:inv", kind: .stuckTask, subjectId: "inv", linked: "", title: "Stuck", body: "Moved 3 times.", evidenceLabel: "", evidence: [WeeklyEvidence(source: .task, ref: "inv", date: nil, when: "4 Nov", what: "Created", meta: "")], action: .firstOnToday(taskId: "inv"), actionTitle: "Make it first", score: 2)
  }

  func testThePickedChangeShowsOnTheDayItWasPickedUntilDone() {
    let reviews = [review(actions: [accepted("stuckTask:inv", .firstOnToday(taskId: "inv"), findingId: "stuckTask:inv")], findings: [stuck])]

    let monday = insight(reviews, tasks: [task("inv")], now: date(16, 10))
    XCTAssertEqual(monday.highlight?.title, "Do “inv” first")
    XCTAssertEqual(monday.highlight?.body, "Moved 3 times.")
    XCTAssertEqual(monday.highlight?.evidence.count, 1)

    XCTAssertNil(insight(reviews, tasks: [task("inv", done: date(16, 11))], now: date(16, 12)).highlight)
    XCTAssertNil(insight(reviews, tasks: [task("inv")], now: date(17, 10)).highlight)
  }

  func testTheCheckInStartsWednesdayAndGoesAwayWhenDismissed() {
    let actions = [accepted("a", .bookFocus(title: "x", goalId: "ship", slots: []), blocks: ["tue"])]
    let blocks = [block("tue", start: date(17, 9), done: true)]

    XCTAssertTrue(insight([review(actions: actions)], blocks: blocks, now: date(17, 12)).checkIn.isEmpty, "Tuesday")
    let wednesday = insight([review(actions: actions)], blocks: blocks, now: date(18, 9))
    XCTAssertEqual(wednesday.checkIn.map(\.status), [.held])
    XCTAssertTrue(insight([review(actions: actions)], blocks: blocks, now: date(22, 9)).checkIn.count == 1, "Sunday still shows it")
    XCTAssertTrue(insight([review(actions: actions, seen: date(18, 10))], blocks: blocks, now: date(19, 9)).checkIn.isEmpty)
  }

  func testRoutineAndGoalRowsGetANoteFromTheReview() {
    let rule = accepted("r", .lateEveningReminder(routineId: "pages", hour: 8, minute: 30))
    let booking = accepted("b", .bookFocus(title: "x", goalId: "ship", slots: []), blocks: ["thu"])
    let tasks = [task("Agency retro", due: date(16, 19), calendarEvent: true)]

    let result = insight([review(actions: [rule, booking])], tasks: tasks, blocks: [block("thu", start: date(19, 9), done: false)], now: date(16, 10))

    XCTAssertEqual(result.routineHints["pages"]?.text, "Agency retro starts at 19:00 tonight, so tomorrow's reminder comes at 8:30.")
    XCTAssertNil(result.routineHints["pages"]?.offerFindingId)
    XCTAssertEqual(result.goalHints["ship"], "Next block Thu 19 9:00, booked in review")
  }

  func testAnUnacceptedPatternIsOfferedOnTheRoutineRowOnALateNight() {
    let pattern = WeeklyFinding(id: "routineAfterLateEvening:pages", kind: .routineAfterLateEvening, subjectId: "pages", linked: "", title: "Morning pages goes undone after late evenings", body: "", evidenceLabel: "", evidence: [], action: .lateEveningReminder(routineId: "pages", hour: 8, minute: 30), actionTitle: "", score: 2)
    let tasks = [task("Agency retro", due: date(16, 19, minute: 30), calendarEvent: true)]

    let result = insight([review(actions: [], findings: [pattern])], tasks: tasks, now: date(16, 10))

    XCTAssertEqual(result.routineHints["pages"]?.offerFindingId, "routineAfterLateEvening:pages")
    XCTAssertEqual(result.routineHints["pages"]?.text, "Agency retro starts at 19:30 tonight. Morning pages goes undone after late evenings.")
    XCTAssertTrue(insight([review(actions: [], findings: [pattern])], now: date(16, 10)).routineHints.isEmpty, "no late event tonight")
  }

  func testNextWeeksReviewSaysHowTheChangesWent() {
    var action = accepted("a", .firstOnToday(taskId: "inv"))
    action.outcomeText = "Done Mon 9:12"
    var undone = accepted("b", .pauseGoal(goalId: "g"))
    undone.undoneAt = date(16, 9)

    XCTAssertEqual(WeeklyReview.loopLine(for: review(actions: [action, undone])), "Last week's changes. Title a: done Mon 9:12.")
    XCTAssertNil(WeeklyReview.loopLine(for: review(actions: [undone])))
  }
}

@MainActor
final class WeeklyReviewOutcomeStateTests: XCTestCase {
  func testPreparingANewReviewWritesDownHowTheLastOnesChangesWent() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("serenity-review-outcome-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.review.outcome.\(UUID().uuidString)"
    defer {
      UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: UserDefaults(suiteName: suiteName)!,
        defaultsKey: "review.outcome.backend",
        registry: BackendProfileRegistry(descriptors: BackendProfileRegistry.live.descriptors, validators: [.sqliteLocal: { .available(message: "ok") }])
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )
    await state.bootstrapLocalDatabase()
    await state.refreshCoreWorkflowData()

    let reviewed = WeeklyReview.reviewedWeekStart(for: Date())
    let previousStart = WeeklyReview.calendar.date(byAdding: .day, value: -7, to: reviewed)!
    _ = await state.createTask(title: "Invoice", priority: .medium, dueDate: nil, tags: [], subtaskTitles: [], id: "inv")
    await state.toggleTaskCompletion(id: "inv")
    var payload = WeeklyReviewPayload()
    payload.actions = [WeeklyAcceptedAction(id: "a", findingId: nil, kind: nil, action: .firstOnToday(taskId: "inv"), title: "Invoice first", acceptedAt: reviewed)]
    let previousKey = WeeklyReview.weekKey(forWeekStart: previousStart)
    await state.saveWeeklyReview(WeeklyReviewEntity(weekKey: previousKey, weekStart: previousStart, completedAt: reviewed, payload: payload, createdAt: reviewed, updatedAt: reviewed))

    await state.prepareWeeklyReview()

    let settled = try XCTUnwrap(state.weeklyReview(forWeek: previousKey)?.payload.actions.first)
    XCTAssertEqual(settled.outcome, .held)
    XCTAssertTrue(settled.outcomeText?.hasPrefix("Done") ?? false)
  }
}
