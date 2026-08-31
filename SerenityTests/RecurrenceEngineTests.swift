import XCTest
@testable import SerenityMac

final class RecurrenceEngineTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }()

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  private func pattern(_ type: RecurringType, every interval: Int = 1, until endDate: Date? = nil) -> TaskRecurringPattern {
    TaskRecurringPattern(type: type, interval: interval, endDate: endDate)
  }

  func testDailyAdvancesByInterval() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 8, 6), pattern: pattern(.daily), calendar: calendar),
      date(2026, 8, 7)
    )
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 8, 6), pattern: pattern(.daily, every: 3), calendar: calendar),
      date(2026, 8, 9)
    )
  }

  func testWeeklyAdvancesBySevenDays() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 8, 6), pattern: pattern(.weekly), calendar: calendar),
      date(2026, 8, 13)
    )
  }

  func testMonthlyClampsToTheEndOfAShorterMonth() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 1, 31), pattern: pattern(.monthly), calendar: calendar),
      date(2026, 2, 28),
      "Jan 31 + 1 month must not spill into March"
    )
  }

  func testCustomIntervalCountsDays() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 8, 6), pattern: pattern(.custom, every: 10), calendar: calendar),
      date(2026, 8, 16)
    )
  }

  func testZeroOrNegativeIntervalStillAdvances() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(after: date(2026, 8, 6), pattern: pattern(.daily, every: 0), calendar: calendar),
      date(2026, 8, 7),
      "a zero interval would otherwise loop forever on the same date"
    )
  }

  func testSeriesStopsAfterItsEndDate() {
    XCTAssertNil(
      RecurrenceEngine.nextOccurrence(
        after: date(2026, 8, 6),
        pattern: pattern(.daily, until: date(2026, 8, 6, hour: 23)),
        calendar: calendar
      )
    )
  }

  func testOccurrenceOnTheEndDateItselfIsAllowed() {
    XCTAssertEqual(
      RecurrenceEngine.nextOccurrence(
        after: date(2026, 8, 6),
        pattern: pattern(.daily, until: date(2026, 8, 7, hour: 12)),
        calendar: calendar
      ),
      date(2026, 8, 7)
    )
  }

  // MARK: Successor

  private func task(dueDate: Date?, recurring: TaskRecurringPattern?, subtasksDone: Bool = true) -> TaskEntity {
    TaskEntity(
      id: "original",
      title: "Water the plants",
      description: "desc",
      completed: true,
      completedAt: date(2026, 8, 6),
      priority: .high,
      dueDate: dueDate,
      projectId: "project",
      tags: ["home"],
      createdAt: date(2026, 8, 1),
      updatedAt: date(2026, 8, 6),
      subtasks: [TaskSubtask(id: "s1", title: "Fill can", completed: subtasksDone, order: 0)],
      recurring: recurring,
      userId: nil
    )
  }

  func testNonRecurringTaskHasNoSuccessor() {
    XCTAssertNil(RecurrenceEngine.successor(for: task(dueDate: date(2026, 8, 6), recurring: nil), calendar: calendar))
  }

  func testSuccessorIsAFreshOpenInstanceOnTheNextDate() throws {
    let successor = try XCTUnwrap(
      RecurrenceEngine.successor(
        for: task(dueDate: date(2026, 8, 6), recurring: pattern(.daily)),
        now: date(2026, 8, 6, hour: 20),
        calendar: calendar,
        makeID: { "next" }
      )
    )

    XCTAssertEqual(successor.id, "next")
    XCTAssertNotEqual(successor.id, "original")
    XCTAssertFalse(successor.completed)
    XCTAssertNil(successor.completedAt)
    XCTAssertEqual(successor.dueDate, date(2026, 8, 7))
  }

  func testSuccessorCarriesTheDefinitionForward() throws {
    let successor = try XCTUnwrap(
      RecurrenceEngine.successor(
        for: task(dueDate: date(2026, 8, 6), recurring: pattern(.weekly)),
        calendar: calendar,
        makeID: { "next" }
      )
    )

    XCTAssertEqual(successor.title, "Water the plants")
    XCTAssertEqual(successor.priority, .high)
    XCTAssertEqual(successor.projectId, "project")
    XCTAssertEqual(successor.tags, ["home"])
    XCTAssertEqual(successor.recurring?.type, .weekly, "the successor must keep recurring")
  }

  func testSuccessorResetsSubtasks() throws {
    let successor = try XCTUnwrap(
      RecurrenceEngine.successor(
        for: task(dueDate: date(2026, 8, 6), recurring: pattern(.daily), subtasksDone: true),
        calendar: calendar,
        makeID: { "next" }
      )
    )

    XCTAssertEqual(successor.subtasks.map(\.completed), [false], "a repeat starts with its checklist clear")
  }

  func testUndatedRecurringTaskAnchorsToCompletionTime() throws {
    let successor = try XCTUnwrap(
      RecurrenceEngine.successor(
        for: task(dueDate: nil, recurring: pattern(.daily)),
        now: date(2026, 8, 6, hour: 20),
        calendar: calendar,
        makeID: { "next" }
      )
    )

    XCTAssertEqual(successor.dueDate, date(2026, 8, 7, hour: 20))
  }

  func testFinishedSeriesProducesNoSuccessor() {
    XCTAssertNil(
      RecurrenceEngine.successor(
        for: task(dueDate: date(2026, 8, 6), recurring: pattern(.daily, until: date(2026, 8, 6, hour: 12))),
        calendar: calendar
      )
    )
  }

  /// Guards the property habits depend on: completing an instance must leave the
  /// finished one behind and add exactly one open successor.
  func testCompletingAnInstanceLeavesHistoryAndExactlyOneSuccessor() throws {
    let completed = task(dueDate: date(2026, 8, 6), recurring: pattern(.daily))
    let successor = try XCTUnwrap(
      RecurrenceEngine.successor(for: completed, calendar: calendar, makeID: { "next" })
    )

    let series = [completed, successor]
    XCTAssertEqual(series.filter(\.completed).count, 1, "the finished instance is the streak record")
    XCTAssertEqual(series.filter { !$0.completed }.count, 1, "exactly one open instance carries the series forward")
    XCTAssertEqual(Set(series.map(\.id)).count, 2, "the successor must not reuse the completed task's id")
  }
}
