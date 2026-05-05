import CloudKit
import Foundation
import XCTest
@testable import SerenityMac

final class ICloudSyncTests: XCTestCase {
  // MARK: - Pending change ledger

  func testEnqueueRecordsPendingChangeAndCoalescesUpdates() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-1", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-1", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "task-2", operation: .delete)

    let pending = try store.fetchPending(limit: 10)
    XCTAssertEqual(pending.count, 2)
    XCTAssertEqual(Set(pending.map(\.entityId)), Set(["task-1", "task-2"]))

    // Successive upserts on the same target collapse to a single row, so
    // attempts stays at 0 (the unique index re-keys the row).
    let task1Pending = pending.first { $0.entityId == "task-1" }
    XCTAssertEqual(task1Pending?.operation, .upsert)
    XCTAssertEqual(task1Pending?.attempts, 0)
  }

  func testSyncAwareTaskRepositoryEnqueuesOnSaveAndDelete() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let task = TaskEntity(
      id: UUID().uuidString,
      title: "Sync me",
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

    try repositories.tasks.save(task)
    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 1)

    try repositories.tasks.delete(id: task.id)
    let pending = try repositories.pendingSyncChanges.fetchPending(limit: 10)
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.operation, .delete)
  }

  func testApplyRemoteUpsertSkipsLedger() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let task = TaskEntity(
      id: UUID().uuidString,
      title: "Pulled",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .low,
      dueDate: nil,
      projectId: nil,
      tags: ["from-cloud"],
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )

    try repositories.tasks.applyRemoteUpsert(task)

    let saved = try repositories.tasks.fetchByID(task.id)
    XCTAssertNotNil(saved)
    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 0)
  }

  func testMarkCompletedRemovesEntries() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "a", operation: .upsert)
    try store.enqueue(entityType: SyncEntityType.task, entityId: "b", operation: .upsert)

    let pending = try store.fetchPending(limit: 10)
    try store.markCompleted(ids: pending.map(\.id))

    XCTAssertEqual(try store.count(), 0)
  }

  func testMarkFailedIncrementsAttemptsAndRecordsError() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.pendingSyncChanges

    try store.enqueue(entityType: SyncEntityType.task, entityId: "a", operation: .upsert)
    let initial = try store.fetchPending(limit: 10)

    try store.markFailed(ids: initial.map(\.id), error: "network down")

    let after = try store.fetchPending(limit: 10)
    XCTAssertEqual(after.first?.attempts, 1)
    XCTAssertEqual(after.first?.lastError, "network down")
    XCTAssertNotNil(after.first?.lastAttemptAt)
  }

  // MARK: - Cloud-sync state store

  func testCloudSyncStateRoundTripsBlobs() async throws {
    let repositories = try await makeRepositorySet()
    let store = repositories.cloudSyncState

    XCTAssertNil(try store.loadValue(forKey: "token"))

    let payload = Data([0x01, 0x02, 0x03, 0x04])
    try store.saveValue(payload, forKey: "token")
    XCTAssertEqual(try store.loadValue(forKey: "token"), payload)

    try store.saveValue(nil, forKey: "token")
    XCTAssertNil(try store.loadValue(forKey: "token"))
  }

  // MARK: - CKRecord round-trip

  func testTaskRecordRoundTripPreservesAllFields() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let task = TaskEntity(
      id: "task-1",
      title: "Review PR",
      description: "Look at the journal sync diff",
      completed: false,
      completedAt: nil,
      priority: .high,
      dueDate: now.addingTimeInterval(3600),
      projectId: "proj-x",
      tags: ["review", "p1"],
      createdAt: now.addingTimeInterval(-3600),
      updatedAt: now,
      subtasks: [
        TaskSubtask(id: "s1", title: "Read it", completed: true, order: 0),
        TaskSubtask(id: "s2", title: "Comment", completed: false, order: 1),
      ],
      recurring: TaskRecurringPattern(type: .weekly, interval: 1, endDate: nil),
      userId: "user-7"
    )

    let recordID = CKRecord.ID(recordName: task.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: SyncEntityType.task, recordID: recordID)
    try TaskSyncRecordKind.encode(task, into: record)

    let decoded = try TaskSyncRecordKind.decode(record)
    XCTAssertEqual(decoded, task)
  }

  func testJournalRecordRoundTripPreservesAllFields() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = JournalEntryEntity(
      id: "entry-1",
      title: "Sunday recap",
      content: "Long content body with newline\nand emoji 🎉",
      date: now.addingTimeInterval(-86_400),
      tags: ["personal"],
      createdAt: now.addingTimeInterval(-86_400),
      updatedAt: now,
      pinned: true,
      mood: .happy,
      attachments: [
        JournalAttachmentEntity(
          id: "a1",
          type: .image,
          filename: "photo.jpg",
          originalName: "IMG_0001.jpg",
          path: "Attachments/photo.jpg",
          size: 12_345,
          mimeType: "image/jpeg",
          createdAt: now.addingTimeInterval(-3600)
        )
      ],
      userId: "user-9"
    )

    let recordID = CKRecord.ID(recordName: entry.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: SyncEntityType.journalEntry, recordID: recordID)
    try JournalEntrySyncRecordKind.encode(entry, into: record)

    let decoded = try JournalEntrySyncRecordKind.decode(record)
    XCTAssertEqual(decoded, entry)
  }

  // MARK: - Helpers

  private func makeRepositorySet() async throws -> GRDBCoreRepositorySet {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-icloud-tests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")

    let runner = DatabaseMigrationRunner()
    _ = try await runner.bootstrapDatabase(at: databaseURL)

    return try GRDBCoreRepositorySet.make(databasePath: databaseURL.path)
  }
}
