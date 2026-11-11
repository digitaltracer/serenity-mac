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
}
