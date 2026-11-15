import Foundation
import XCTest
@testable import SerenityMac

final class GoalReportTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func goal(_ config: GoalConfig, created: Date? = nil, progress: Double = 0, target: Double = 1) -> GoalEntity {
    let created = created ?? date(11, 1)
    return GoalEntity(
      id: "g1",
      title: "Goal",
      description: nil,
      type: .weeklyTasks,
      config: config,
      progress: GoalProgress(current: progress, target: target, percentage: 0, isCompleted: false, periodStart: created, periodEnd: created),
      status: .active,
      priority: .medium,
      reminders: [],
      createdAt: created,
      updatedAt: created,
      userId: nil
    )
  }

  private func config(_ kind: GoalKind, _ source: GoalSource, target: Double? = nil) -> GoalConfig {
    GoalConfig(targetCount: target, projectId: nil, priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: kind, source: source)
  }

  private func task(_ id: String, project: String?, completedOn completed: Date?, tags: [String] = []) -> TaskEntity {
    TaskEntity(
      id: id,
      title: id,
      description: nil,
      completed: completed != nil,
      completedAt: completed,
      priority: .medium,
      dueDate: nil,
      projectId: project,
      tags: tags,
      createdAt: date(10, 1),
      updatedAt: completed ?? date(10, 1),
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }

  func testOutcomeBehindPaceAndProjection() {
    var outcome = config(.outcome, .manual, target: 20)
    outcome.startDate = date(11, 1)
    outcome.dueDate = date(11, 21)
    outcome.checkIns = [GoalCheckIn(date: date(11, 3), amount: 4, note: nil), GoalCheckIn(date: date(11, 6), amount: 1, note: nil)]

    let report = GoalReports.report(for: goal(outcome), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)

    XCTAssertEqual(report.current, 5)
    XCTAssertEqual(report.expected ?? 0, 10, accuracy: 0.01)
    XCTAssertEqual(report.pace, .behind(5))
    XCTAssertEqual(report.statusLabel, "5 behind")
    XCTAssertEqual(report.projected ?? 0, 10, accuracy: 0.01)
    XCTAssertTrue(report.needsAttention)
  }

  func testProjectOutcomeTargetsEveryTaskInTheProjectByDefault() {
    var outcome = config(.outcome, .projectTasks)
    outcome.projectId = "p1"
    outcome.dueDate = date(12, 15)
    let tasks = [
      task("a", project: "p1", completedOn: date(10, 20)),
      task("b", project: "p1", completedOn: date(11, 5)),
      task("c", project: "p1", completedOn: nil),
      task("d", project: "p2", completedOn: date(11, 5)),
    ]

    let report = GoalReports.report(for: goal(outcome), inputs: GoalProgressInputs(tasks: tasks), now: date(11, 11), calendar: calendar)

    XCTAssertEqual(report.target, 3)
    XCTAssertEqual(report.current, 2)
    XCTAssertEqual(report.unit, "tasks")
    XCTAssertEqual(report.series.first?.value, 1, "work done before the goal started lifts the line's start")
  }

  func testTargetCountsOnlyTheCurrentPeriod() {
    var weekly = config(.target, .routine, target: 5)
    weekly.routineId = "r1"
    let checks = ["2026-11-06", "2026-11-09", "2026-11-10", "2026-11-11"].map {
      RoutineCheckEntity(routineId: "r1", day: $0, status: .done, createdAt: date(11, 1), updatedAt: date(11, 1))
    }

    let report = GoalReports.report(for: goal(weekly), inputs: GoalProgressInputs(routineChecks: checks), now: date(11, 11), calendar: calendar)

    XCTAssertEqual(report.current, 3, "Friday the 6th belongs to last week")
    XCTAssertEqual(report.windowStart, calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    XCTAssertEqual(report.pace, .ahead(1))
  }

  func testAreaGoesQuietAfterItsThreshold() {
    var area = config(.area, .manual)
    area.areaTag = "Health"
    area.quietDays = 7
    let tasks = [task("gym", project: nil, completedOn: date(11, 2), tags: ["health"])]

    let quiet = GoalReports.report(for: goal(area), inputs: GoalProgressInputs(tasks: tasks), now: date(11, 11), calendar: calendar)
    XCTAssertEqual(quiet.daysQuiet, 9)
    XCTAssertTrue(quiet.needsAttention)
    XCTAssertEqual(quiet.statusLabel, "Quiet 9 days")

    area.checkIns = [GoalCheckIn(date: date(11, 10), amount: 1, note: "Booked a physio")]
    let touched = GoalReports.report(for: goal(area), inputs: GoalProgressInputs(tasks: tasks), now: date(11, 11), calendar: calendar)
    XCTAssertEqual(touched.statusLabel, "Touched yesterday")
    XCTAssertFalse(touched.needsAttention)
  }

  func testGoalsFromBeforeKindsKeepTheirCount() {
    let legacy = goal(
      GoalConfig(targetCount: 5, projectId: nil, priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly),
      progress: 3,
      target: 5
    )

    let report = GoalReports.report(for: legacy, inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)

    XCTAssertEqual(report.current, 3)
    XCTAssertEqual(report.target, 5)
    XCTAssertEqual(report.pace, .untimed)
    XCTAssertEqual(report.statusLabel, "3 of 5")
  }

  func testDraftRoundTripsThroughConfig() {
    var draft = GoalDraft()
    draft.title = "Run"
    draft.kind = .target
    draft.source = .manual
    draft.target = 60
    draft.unit = "km"
    draft.timeframe = .monthly

    let config = draft.apply(
      to: GoalConfig(targetCount: nil, projectId: nil, priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly),
      now: date(11, 1)
    )
    let restored = GoalDraft(goal: goal(config))

    XCTAssertEqual(restored.kind, .target)
    XCTAssertEqual(restored.target, 60)
    XCTAssertEqual(restored.unit, "km")
    XCTAssertEqual(restored.timeframe, .monthly)
    XCTAssertNil(config.dueDate)
  }

  func testAHandLoggedGoalWithoutAUnitNeedsSetup() {
    var bare = config(.target, .manual, target: 10)
    let report = GoalReports.report(for: goal(bare), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)
    XCTAssertTrue(report.needsSetup)
    XCTAssertEqual(report.statusLabel, "Needs setup")
    XCTAssertFalse(report.needsAttention, "an unset goal isn't behind, it's unset")

    bare.unit = "km"
    XCTAssertFalse(GoalReports.report(for: goal(bare), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar).needsSetup)

    var routine = config(.target, .routine, target: 5)
    routine.routineId = "r1"
    XCTAssertFalse(GoalReports.report(for: goal(routine), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar).needsSetup)
  }

  func testAPausedWeekIsNotBehind() {
    var weekly = config(.target, .manual, target: 10)
    weekly.unit = "km"
    weekly.pausedUntil = date(11, 16, hour: 0)

    let paused = GoalReports.report(for: goal(weekly), inputs: GoalProgressInputs(), now: date(11, 13), calendar: calendar)
    XCTAssertTrue(paused.isPaused)
    XCTAssertEqual(paused.statusLabel, "Paused this week")
    XCTAssertFalse(paused.needsAttention)
    XCTAssertTrue(paused.paceLine(now: date(11, 13), calendar: calendar).hasPrefix("Paused until"))

    let after = GoalReports.report(for: goal(weekly), inputs: GoalProgressInputs(), now: date(11, 17), calendar: calendar)
    XCTAssertFalse(after.isPaused, "the pause ends on its own when the week does")
  }

  func testThePaceLineSaysWhereYouShouldBe() {
    var outcome = config(.outcome, .manual, target: 20)
    outcome.unit = "km"
    outcome.startDate = date(11, 1)
    outcome.dueDate = date(11, 21)
    outcome.checkIns = [GoalCheckIn(date: date(11, 3), amount: 5, note: nil)]
    let behind = GoalReports.report(for: goal(outcome), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)
    let line = behind.paceLine(now: date(11, 11), calendar: calendar)
    XCTAssertTrue(line.hasPrefix("5 of 20 km · should be at 10 today · at this rate ~10 by "), line)

    var monthly = config(.target, .manual, target: 2)
    monthly.timeframe = .monthly
    monthly.unit = "books"
    monthly.checkIns = [GoalCheckIn(date: date(11, 3), amount: 1, note: nil)]
    let books = GoalReports.report(for: goal(monthly), inputs: GoalProgressInputs(), now: date(11, 16), calendar: calendar)
    XCTAssertEqual(books.paceLine(now: date(11, 16), calendar: calendar), "1 of 2 books this month · should be at 1 today")
    XCTAssertEqual(books.amountPhrase(1), "1 book")
  }

  func testAnAreaKeepsFourWeeksOfActivity() {
    var area = config(.area, .manual)
    area.areaTag = "health"
    area.checkIns = [GoalCheckIn(date: date(11, 11), amount: 1, note: "Walk"), GoalCheckIn(date: date(11, 9), amount: 1, note: "Gym")]
    let tasks = [task("gym", project: nil, completedOn: date(11, 9), tags: ["Health"]), task("old", project: nil, completedOn: date(9, 1), tags: ["health"])]

    let report = GoalReports.report(for: goal(area), inputs: GoalProgressInputs(tasks: tasks), now: date(11, 11), calendar: calendar)

    XCTAssertEqual(report.activityDays.count, 28)
    XCTAssertEqual(report.activityDays.last, 1, "today")
    XCTAssertEqual(report.activityDays[25], 2, "two days ago had two things")
    XCTAssertEqual(report.activityDays.reduce(0, +), 3, "September is outside the four weeks")
  }

  func testLogPresetsFollowRecentAmountsOrTheTarget() {
    var monthly = config(.target, .manual, target: 60)
    monthly.unit = "km"
    let fresh = GoalReports.report(for: goal(monthly), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)
    XCTAssertEqual(fresh.logPresets, [5, 10, 20])
    XCTAssertFalse(fresh.logsByOne)

    monthly.checkIns = [3, 8, 3, 12].enumerated().map { GoalCheckIn(date: date(11, 2 + $0.offset), amount: Double($0.element), note: nil) }
    let used = GoalReports.report(for: goal(monthly), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar)
    XCTAssertEqual(used.logPresets, [3, 8, 12])

    var books = config(.target, .manual, target: 2)
    books.unit = "books"
    XCTAssertTrue(GoalReports.report(for: goal(books), inputs: GoalProgressInputs(), now: date(11, 11), calendar: calendar).logsByOne)
  }

  func testTheEditorSuggestsWhatCountsFromTheName() {
    let pages = RoutineEntity(id: "r1", title: "Morning pages", schedule: .daily, timeOfDay: .morning, archived: false, createdAt: date(11, 1), updatedAt: date(11, 1))
    var draft = GoalDraft()
    draft.kind = .target

    draft.title = "Morning pages 5 days a week"
    XCTAssertEqual(draft.suggestedSource(routines: [pages], projects: []), .routine)
    XCTAssertEqual(draft.matchingRoutine(in: [pages])?.id, "r1")

    draft.title = "15 h of deep work a week"
    XCTAssertEqual(draft.suggestedSource(routines: [pages], projects: []), .focusTime)

    draft.title = "Run 60 km a month"
    XCTAssertEqual(draft.suggestedSource(routines: [pages], projects: []), .manual)
    draft.source = .manual
    XCTAssertTrue(draft.needsUnit)
    XCTAssertTrue(draft.previewSentence(projectName: nil, routineName: nil, targetText: "60").contains("needs a unit"))
    draft.unit = "km"
    draft.timeframe = .monthly
    XCTAssertEqual(draft.previewSentence(projectName: nil, routineName: nil, targetText: "60"), "60 km every month. You log it yourself from the goal or the Today card.")
  }

}

@MainActor
final class GoalPauseAppStateTests: XCTestCase {
  func testPausingLastsUntilTheWeekEndsAndResumeClearsIt() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-goal-pause-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.goal-pause.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "goal-pause.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )
    var draft = GoalDraft()
    draft.title = "Run 20 km a week"
    draft.kind = .target
    draft.source = .manual
    draft.unit = "km"
    draft.target = 20
    await state.createGoal(draft)
    let id = try XCTUnwrap(state.goals.first?.id)

    let now = Date()
    await state.pauseGoalForWeek(id: id, now: now)
    let until = try XCTUnwrap(state.goals.first?.config.pausedUntil)
    XCTAssertEqual(until, Calendar.current.dateInterval(of: .weekOfYear, for: now)?.end)
    XCTAssertEqual(state.goalReports(now: now).first?.statusLabel, "Paused this week")

    await state.resumeGoal(id: id)
    XCTAssertNil(state.goals.first?.config.pausedUntil)
  }
}

