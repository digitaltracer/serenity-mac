import CloudKit
import Foundation
import XCTest
@testable import SerenityMac

final class TodayBriefingTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func date(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute))!
  }

  private func task(_ id: String, due: Date?, tags: [String] = []) -> TaskEntity {
    TaskEntity(
      id: id, title: id, description: nil, completed: false, completedAt: nil, priority: .medium,
      dueDate: due, projectId: nil, tags: tags, createdAt: date(8), updatedAt: date(8),
      subtasks: [], recurring: nil, userId: nil
    )
  }

  private func block(_ id: String, from start: Date, minutes: Double, status: FocusBlockStatus = .planned) -> FocusBlockEntity {
    FocusBlockEntity(
      id: id, title: "Focus", start: start, end: start.addingTimeInterval(minutes * 60), goalId: nil, taskIds: [],
      status: status, startedAt: nil, finishedAt: nil, loggedMinutes: 0, createdAt: start, updatedAt: start
    )
  }

  func testPlanSplitsTimedFromUntimedAndMarksCalendarEvents() {
    let tasks = [
      task("standup", due: date(9, 30), tags: ["google-calendar"]),
      task("invoice", due: date(15)),
      task("dentist", due: date(0)),
      task("tomorrow", due: date(15).addingTimeInterval(86_400)),
    ]

    let plan = TodayBriefing.planItems(tasks: tasks, focusBlocks: [block("b", from: date(10), minutes: 120)], day: date(12), calendar: calendar)

    XCTAssertEqual(plan.timed.map(\.id), ["task-standup", "focus-b", "task-invoice"])
    XCTAssertEqual(plan.timed.first?.kind, .calendar)
    XCTAssertEqual(plan.untimed.map(\.id), ["dentist"])
  }

  func testOverlappingItemsShareTheLane() {
    let tasks = [task("a", due: date(10, 15)), task("b", due: date(13))]

    let plan = TodayBriefing.planItems(tasks: tasks, focusBlocks: [block("f", from: date(10), minutes: 60)], day: date(12), calendar: calendar)

    let byID = Dictionary(uniqueKeysWithValues: plan.timed.map { ($0.id, $0) })
    XCTAssertEqual(byID["focus-f"]?.columns, 2)
    XCTAssertEqual(byID["task-a"]?.column, 1)
    XCTAssertEqual(byID["task-b"]?.columns, 1)
  }

  func testSentenceDescribesTheDay() {
    XCTAssertEqual(
      TodayBriefing.sentence(meetings: 3, focusMinutes: 120, behindGoal: nil, inboxCount: 4),
      "3 meetings and 2 h of focus planned. 4 captures are waiting in the inbox."
    )
    XCTAssertEqual(TodayBriefing.sentence(meetings: 0, focusMinutes: 0, behindGoal: nil, inboxCount: 0), "A clear calendar.")
  }

  func testAttentionOrdersHousekeepingAroundWhatIsAtStake() {
    let items = TodayBriefing.attentionItems(
      inboxCount: 2,
      overdueCount: 1,
      goalReports: [],
      routineSummaries: [],
      pendingProposals: 0,
      standupPending: 3
    )

    XCTAssertEqual(items.map(\.id), ["inbox", "overdue", "standup"])
    XCTAssertEqual(items.first?.title, "2 captures to sort")
    XCTAssertFalse(items.contains(where: \.isUrgent))
  }

  func testRoutineSlipsAfterTwoMissesInThreeDays() {
    let routine = RoutineEntity(id: "r", title: "Walk", schedule: .daily, timeOfDay: .evening, archived: false, createdAt: date(8).addingTimeInterval(-30 * 86_400), updatedAt: date(8))
    let yesterday = RoutineDay.key(for: date(12).addingTimeInterval(-3 * 86_400), calendar: calendar)
    let summary = RoutineStreaks.summary(for: routine, checks: [yesterday: .done], now: date(12), calendar: calendar)

    XCTAssertTrue(TodayBriefing.isSlipping(summary))
  }

  func testFocusBlockRoundTripsThroughCloudKit() throws {
    var focus = block("sync", from: Date(timeIntervalSince1970: 1_800_000_000), minutes: 50, status: .done)
    focus.goalId = "goal-1"
    focus.taskIds = ["t1"]
    focus.loggedMinutes = 42
    focus.finishedAt = focus.end
    focus.pausedAt = focus.start.addingTimeInterval(600)
    focus.pausedSeconds = 120
    let record = CKRecord(recordType: SyncEntityType.focusBlock, recordID: CKRecord.ID(recordName: focus.id, zoneID: SerenityCloudKit.zoneID))

    try FocusBlockSyncRecordKind.encode(focus, into: record)

    XCTAssertEqual(try FocusBlockSyncRecordKind.decode(record), focus)
  }
}

@MainActor
final class FocusBlockAppStateTests: XCTestCase {
  private var cleanups: [() -> Void] = []

  override func tearDown() {
    cleanups.forEach { $0() }
    cleanups = []
    super.tearDown()
  }

  private func makeState() throws -> AppState {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-focus-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.focus.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    return AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "focus.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

  }

  func testPausedTimeIsLeftOutOfTheLog() async throws {
    let state = try makeState()

    var draft = GoalDraft()
    draft.title = "Deep work"
    draft.kind = .target
    draft.source = .focusTime
    draft.target = 15
    await state.createGoal(draft)

    let start = Date()
    await state.startFocus(title: "  Sync fixes ", minutes: 50, goalId: nil, now: start)
    let running = try XCTUnwrap(state.activeFocusBlock)
    XCTAssertEqual(running.title, "Sync fixes")
    XCTAssertEqual(running.plannedMinutes, 50, accuracy: 0.01)

    await state.pauseFocusBlock(id: running.id, now: start.addingTimeInterval(20 * 60))
    XCTAssertEqual(state.activeFocusBlock?.status, .paused)
    let paused = try XCTUnwrap(state.activeFocusBlock)
    XCTAssertEqual(FocusBlockTiming.clockText(for: paused, now: start.addingTimeInterval(30 * 60)), "30:00", "the clock stops while paused")

    await state.resumeFocusBlock(id: running.id, now: start.addingTimeInterval(30 * 60))
    let resumed = try XCTUnwrap(state.activeFocusBlock)
    XCTAssertEqual(resumed.pausedSeconds, 600, accuracy: 0.01)
    XCTAssertEqual(resumed.end.timeIntervalSince(start), 60 * 60, accuracy: 0.01, "the end moves back by the pause")

    await state.finishFocusBlock(id: running.id, now: start.addingTimeInterval(55 * 60))
    XCTAssertNil(state.activeFocusBlock)
    XCTAssertEqual(state.focusBlocks.first?.loggedMinutes ?? 0, 45, accuracy: 0.01)

    let report = try XCTUnwrap(state.goalReports().first { $0.goal.title == "Deep work" })
    XCTAssertEqual(report.current, 0.75, accuracy: 0.01)
  }

  func testStartingPicksUpTheBlockPlannedForNow() async throws {
    let state = try makeState()
    let now = Date()
    await state.planFocusBlock(title: "Draft", start: now.addingTimeInterval(10 * 60), minutes: 90, goalId: nil)
    let planned = try XCTUnwrap(state.focusBlocks.first)

    await state.startFocus(title: "Write the spec", minutes: 25, goalId: nil, now: now)

    XCTAssertEqual(state.focusBlocks.count, 1, "no second block beside the planned one")
    XCTAssertEqual(state.activeFocusBlock?.id, planned.id)
    XCTAssertEqual(state.activeFocusBlock?.title, "Write the spec")
    XCTAssertEqual(state.activeFocusBlock?.plannedMinutes ?? 0, 25, accuracy: 0.01)
  }
}
