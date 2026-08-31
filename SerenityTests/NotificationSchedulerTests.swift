import XCTest
@testable import SerenityMac

private actor FakeNotificationCenter: NotificationCenterAdapter {
  private(set) var scheduled: [String: NotifiableOccurrence] = [:]
  private(set) var cancelledCalls: [[String]] = []

  init(preloaded: [NotifiableOccurrence] = []) {
    for occurrence in preloaded {
      scheduled[occurrence.id] = occurrence
    }
  }

  func pendingIdentifiers() async -> Set<String> {
    Set(scheduled.keys)
  }

  func schedule(_ occurrence: NotifiableOccurrence) async {
    scheduled[occurrence.id] = occurrence
  }

  func cancel(identifiers: [String]) async {
    cancelledCalls.append(identifiers.sorted())
    for identifier in identifiers {
      scheduled.removeValue(forKey: identifier)
    }
  }
}

final class NotificationSchedulerTests: XCTestCase {
  private func occurrence(_ id: String, inHours hours: Int = 5) -> NotifiableOccurrence {
    NotifiableOccurrence(
      id: id,
      fireDate: Calendar.current.date(byAdding: .hour, value: hours, to: Date()) ?? Date(),
      title: id,
      body: nil
    )
  }

  func testReconcileSchedulesNewOccurrences() async {
    let center = FakeNotificationCenter()
    let scheduler = NotificationScheduler(center: center)

    let result = await scheduler.reconcile([occurrence("task:a"), occurrence("task:b")])

    XCTAssertEqual(result.added, ["task:a", "task:b"])
    let pending = await center.pendingIdentifiers()
    XCTAssertEqual(pending, ["task:a", "task:b"])
  }

  func testReconcileCancelsWhatIsNoLongerDesired() async {
    let center = FakeNotificationCenter(preloaded: [occurrence("task:gone"), occurrence("task:stays")])
    let scheduler = NotificationScheduler(center: center)

    let result = await scheduler.reconcile([occurrence("task:stays")])

    XCTAssertEqual(result.cancelled, ["task:gone"])
    XCTAssertEqual(result.unchanged, ["task:stays"])
    let pending = await center.pendingIdentifiers()
    XCTAssertEqual(pending, ["task:stays"])
  }

  func testReconcileLeavesUnchangedOccurrencesAlone() async {
    let center = FakeNotificationCenter(preloaded: [occurrence("task:a")])
    let scheduler = NotificationScheduler(center: center)

    let result = await scheduler.reconcile([occurrence("task:a")])

    XCTAssertEqual(result.added, [])
    XCTAssertEqual(result.cancelled, [])
    XCTAssertEqual(result.unchanged, ["task:a"])
    let cancelled = await center.cancelledCalls
    XCTAssertTrue(cancelled.isEmpty, "an unchanged occurrence must not be torn down and rebuilt")
  }

  func testReconcileIsIdempotent() async {
    let center = FakeNotificationCenter()
    let scheduler = NotificationScheduler(center: center)
    let desired = [occurrence("task:a"), occurrence("task:b")]

    _ = await scheduler.reconcile(desired)
    let second = await scheduler.reconcile(desired)

    XCTAssertEqual(second.added, [])
    XCTAssertEqual(second.cancelled, [])
    XCTAssertEqual(second.unchanged, ["task:a", "task:b"])
  }

  func testPastOccurrencesAreNeverScheduled() async {
    let center = FakeNotificationCenter()
    let scheduler = NotificationScheduler(center: center)

    let result = await scheduler.reconcile([occurrence("task:late", inHours: -3)])

    XCTAssertEqual(result.added, [])
    let pending = await center.pendingIdentifiers()
    XCTAssertTrue(pending.isEmpty)
  }
}

final class TaskNotificationPlanTests: XCTestCase {
  private let calendar = Calendar.current

  private func task(id: String, dueDate: Date?, completed: Bool = false, title: String = "Task") -> TaskEntity {
    TaskEntity(
      id: id,
      title: title,
      description: nil,
      completed: completed,
      completedAt: nil,
      priority: .medium,
      dueDate: dueDate,
      projectId: nil,
      tags: [],
      createdAt: Date(),
      updatedAt: Date(),
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }

  func testCompletedAndUndatedTasksProduceNoOccurrence() {
    let occurrences = TaskNotificationPlan.occurrences(
      for: [
        task(id: "undated", dueDate: nil),
        task(id: "done", dueDate: Date().addingTimeInterval(3600), completed: true),
      ],
      calendar: calendar
    )

    XCTAssertTrue(occurrences.isEmpty)
  }

  func testDateOnlyDueDateFiresAtTheDefaultHourNotMidnight() throws {
    let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 2, to: Date())!)

    let occurrence = try XCTUnwrap(
      TaskNotificationPlan.occurrences(for: [task(id: "a", dueDate: midnight)], defaultHour: 9, calendar: calendar).first
    )

    XCTAssertEqual(calendar.component(.hour, from: occurrence.fireDate), 9)
    XCTAssertEqual(occurrence.body, "Due today")
  }

  func testExplicitTimeIsPreserved() throws {
    let due = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date())!)!

    let occurrence = try XCTUnwrap(
      TaskNotificationPlan.occurrences(for: [task(id: "a", dueDate: due)], calendar: calendar).first
    )

    XCTAssertEqual(calendar.component(.hour, from: occurrence.fireDate), 15)
    XCTAssertEqual(calendar.component(.minute, from: occurrence.fireDate), 30)
  }

  func testLeadTimeShiftsTheFireDateEarlier() throws {
    let due = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date())!)!

    let occurrence = try XCTUnwrap(
      TaskNotificationPlan.occurrences(for: [task(id: "a", dueDate: due)], leadMinutes: 30, calendar: calendar).first
    )

    XCTAssertEqual(calendar.component(.hour, from: occurrence.fireDate), 14)
    XCTAssertEqual(calendar.component(.minute, from: occurrence.fireDate), 30)
  }

  func testIdentifiersAreNamespacedByTask() throws {
    let due = Date().addingTimeInterval(7200)

    let occurrence = try XCTUnwrap(
      TaskNotificationPlan.occurrences(for: [task(id: "abc", dueDate: due)], calendar: calendar).first
    )

    XCTAssertEqual(occurrence.id, "task:abc")
  }
}
