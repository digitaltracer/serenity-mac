import Foundation
import XCTest
@testable import SerenityMac

final class TaskActivityRecorderTests: XCTestCase {
  func testNoChangesRecordNoEvents() {
    let task = makeTask()

    XCTAssertTrue(TaskActivityRecorder.events(from: task, to: task).isEmpty)
  }

  func testCompletionAndReopeningAreBothRecorded() {
    let open = makeTask()
    var done = open
    done.completed = true

    XCTAssertEqual(TaskActivityRecorder.events(from: open, to: done).map(\.text), ["Marked complete"])
    XCTAssertEqual(TaskActivityRecorder.events(from: done, to: open).map(\.text), ["Reopened"])
  }

  func testDueDateIsRecordedInAbsoluteTerms() {
    let before = makeTask()
    var after = before
    after.dueDate = DateComponents(
      calendar: Calendar(identifier: .gregorian),
      timeZone: TimeZone(secondsFromGMT: 0),
      year: 2026,
      month: 9,
      day: 11,
      hour: 18,
      minute: 0
    ).date

    let text = try? XCTUnwrap(TaskActivityRecorder.events(from: before, to: after).first?.text)

    // Relative wording would go stale in storage; the stamp has to carry a date.
    XCTAssertNotNil(text)
    XCTAssertTrue(text?.hasPrefix("Due date set to") == true)
    XCTAssertTrue(text?.contains("2026") == true)
    XCTAssertFalse(text?.lowercased().contains("tomorrow") == true)
  }

  func testClearingTheDueDateIsRecorded() {
    var before = makeTask()
    before.dueDate = Date()
    var after = before
    after.dueDate = nil

    XCTAssertEqual(TaskActivityRecorder.events(from: before, to: after).map(\.text), ["Due date cleared"])
  }

  func testPriorityChangeIsRecorded() {
    let before = makeTask()
    var after = before
    after.priority = .high

    XCTAssertEqual(TaskActivityRecorder.events(from: before, to: after).map(\.text), ["Priority set to High"])
  }

  func testProjectMoveUsesTheProjectName() {
    let before = makeTask()
    var after = before
    after.projectId = "project-1"

    XCTAssertEqual(
      TaskActivityRecorder.events(from: before, to: after, projectNames: ["project-1": "Serenity"]).map(\.text),
      ["Moved to Serenity"]
    )
  }

  func testSubtaskLifecycleIsRecorded() {
    var before = makeTask()
    before.subtasks = [TaskSubtask(id: "s1", title: "Wire the provider", completed: false, order: 0)]

    var completed = before
    completed.subtasks[0].completed = true
    XCTAssertEqual(
      TaskActivityRecorder.events(from: before, to: completed).map(\.text),
      ["Subtask done · Wire the provider"]
    )

    var added = before
    added.subtasks.append(TaskSubtask(id: "s2", title: "Surface errors", completed: false, order: 1))
    XCTAssertEqual(
      TaskActivityRecorder.events(from: before, to: added).map(\.text),
      ["Subtask added · Surface errors"]
    )

    var removed = before
    removed.subtasks = []
    XCTAssertEqual(
      TaskActivityRecorder.events(from: before, to: removed).map(\.text),
      ["Subtask removed · Wire the provider"]
    )
  }

  func testTagChangesRecordAdditionsAndRemovalsSeparately() {
    var before = makeTask()
    before.tags = ["ai"]
    var after = before
    after.tags = ["ai", "provider"]

    XCTAssertEqual(TaskActivityRecorder.events(from: before, to: after).map(\.text), ["Tagged provider"])
    XCTAssertEqual(TaskActivityRecorder.events(from: after, to: before).map(\.text), ["Untagged provider"])
  }

  func testEveryRecordedEventIsAnEventNotAComment() {
    var before = makeTask()
    before.tags = []
    var after = before
    after.completed = true
    after.priority = .high
    after.tags = ["ai"]

    let events = TaskActivityRecorder.events(from: before, to: after)

    XCTAssertEqual(events.count, 3)
    XCTAssertTrue(events.allSatisfy { $0.kind == .event })
    XCTAssertEqual(Set(events.map(\.id)).count, 3)
  }

  private func makeTask() -> TaskEntity {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    return TaskEntity(
      id: "task-1",
      title: "Ship the NVIDIA NIM provider",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: [],
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }
}

final class SerenityDateTextElapsedTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  func testFreshEntriesReadAsJustNow() {
    XCTAssertEqual(SerenityDateText.elapsed(now.addingTimeInterval(-5), now: now), "Just now")
  }

  func testRecentEntriesCountMinutesThenHours() {
    XCTAssertEqual(SerenityDateText.elapsed(now.addingTimeInterval(-600), now: now), "10m ago")
    XCTAssertEqual(SerenityDateText.elapsed(now.addingTimeInterval(-7_200), now: now), "2h ago")
  }

  func testOlderEntriesCountDays() {
    let calendar = Calendar(identifier: .gregorian)
    let threeDaysBack = calendar.date(byAdding: .day, value: -3, to: now)!

    XCTAssertEqual(SerenityDateText.elapsed(threeDaysBack, now: now, calendar: calendar), "3 days ago")
  }

  func testYesterdayKeepsItsClockTime() {
    let calendar = Calendar(identifier: .gregorian)
    let yesterday = calendar.date(byAdding: .hour, value: -20, to: now)!
    let label = SerenityDateText.elapsed(yesterday, now: now, calendar: calendar)

    XCTAssertTrue(label.hasPrefix("Yesterday · "), label)
  }

  func testHistoryNeverClaimsToBeOverdue() {
    let calendar = Calendar(identifier: .gregorian)
    let longAgo = calendar.date(byAdding: .day, value: -40, to: now)!

    XCTAssertFalse(SerenityDateText.elapsed(longAgo, now: now, calendar: calendar).contains("Overdue"))
  }
}

@MainActor
final class TaskCommentAppStateTests: XCTestCase {
  func testCommentsAreAddedEditedAndDeleted() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let task = try await seedTask(in: fixture.state)

    await fixture.state.addTaskComment(taskID: task.id, text: "  Blocked on the rotated key  ")
    var comments = try comments(of: task.id, in: fixture.state)
    XCTAssertEqual(comments.map(\.text), ["Blocked on the rotated key"])
    XCTAssertNil(comments[0].editedAt)

    await fixture.state.updateTaskComment(taskID: task.id, commentID: comments[0].id, text: "Key is rotated now")
    comments = try self.comments(of: task.id, in: fixture.state)
    XCTAssertEqual(comments.map(\.text), ["Key is rotated now"])
    XCTAssertNotNil(comments[0].editedAt)

    await fixture.state.deleteTaskComment(taskID: task.id, commentID: comments[0].id)
    XCTAssertTrue(try self.comments(of: task.id, in: fixture.state).isEmpty)
  }

  func testBlankCommentsAreIgnored() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let task = try await seedTask(in: fixture.state)
    await fixture.state.addTaskComment(taskID: task.id, text: "   \n  ")

    XCTAssertTrue(try comments(of: task.id, in: fixture.state).isEmpty)
  }

  func testPostingACommentLogsNoEventOfItsOwn() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let task = try await seedTask(in: fixture.state)
    await fixture.state.addTaskComment(taskID: task.id, text: "A note")

    let activity = try currentTask(task.id, in: fixture.state).activity
    XCTAssertEqual(activity.count, 1)
    XCTAssertEqual(activity.first?.kind, .comment)
  }

  func testChangingTheTaskAppendsAnEventToTheLog() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let task = try await seedTask(in: fixture.state)
    await fixture.state.toggleTaskCompletion(id: task.id)

    let events = try currentTask(task.id, in: fixture.state).activity.filter { $0.kind == .event }
    XCTAssertEqual(events.map(\.text), ["Marked complete"])
  }

  func testCommentsSurviveAReloadFromTheDatabase() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let task = try await seedTask(in: fixture.state)
    await fixture.state.addTaskComment(taskID: task.id, text: "Survives a round trip")

    await fixture.state.refreshCoreWorkflowData()

    XCTAssertEqual(try comments(of: task.id, in: fixture.state).map(\.text), ["Survives a round trip"])
  }

  // MARK: helpers

  private struct Fixture {
    let state: AppState
    let cleanup: () -> Void
  }

  private func makeFixture() throws -> Fixture {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-task-activity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

    let registry = BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: { .unavailable(reason: "not configured") },
        .externalPostgres: { .unavailable(reason: "not configured") },
      ]
    )
    let defaults = UserDefaults(suiteName: "serenity.task.activity.\(UUID().uuidString)")!

    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "task.activity.backend",
        registry: registry
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    return Fixture(state: state) {
      try? FileManager.default.removeItem(at: baseURL)
    }
  }

  private func seedTask(in state: AppState) async throws -> TaskEntity {
    await state.bootstrapLocalDatabase()
    await state.refreshCoreWorkflowData()

    let created = await state.createTask(
      title: "Ship the NVIDIA NIM provider",
      priority: .medium,
      dueDate: nil,
      tags: [],
      subtaskTitles: []
    )
    XCTAssertTrue(created)

    return try XCTUnwrap(state.tasks.first)
  }

  private func currentTask(_ id: String, in state: AppState) throws -> TaskEntity {
    try XCTUnwrap(state.tasks.first { $0.id == id })
  }

  private func comments(of id: String, in state: AppState) throws -> [TaskActivityEntry] {
    try currentTask(id, in: state).activity.filter { $0.kind == .comment }
  }
}
