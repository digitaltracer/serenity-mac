import Foundation

/// Stable type identifiers used in `pending_sync_changes.entity_type` and as
/// CloudKit `recordType` names. Don't rename these — they're part of the
/// on-disk + on-iCloud schema.
enum SyncEntityType {
  static let task = "Task"
  static let journalEntry = "JournalEntry"
}

/// Wraps a `CoreTaskRepository` so every successful save/delete pushes a
/// pending sync change into the local ledger. The iCloud engine drains the
/// ledger and round-trips records to CloudKit. Pulled remote changes go
/// through `applyRemoteUpsert(_:)` / `applyRemoteDelete(id:)`, which write
/// straight to the underlying repo and skip the ledger so we don't echo
/// changes back out.
final class SyncAwareTaskRepository: CoreTaskRepository {
  private let underlying: CoreTaskRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: CoreTaskRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll() throws -> [TaskEntity] {
    try underlying.fetchAll()
  }

  func fetchByID(_ id: String) throws -> TaskEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ task: TaskEntity) throws {
    try underlying.save(task)
    try pendingStore.enqueue(entityType: SyncEntityType.task, entityId: task.id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.task, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ task: TaskEntity) throws {
    try underlying.save(task)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}

final class SyncAwareJournalRepository: CoreJournalRepository {
  private let underlying: CoreJournalRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: CoreJournalRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll() throws -> [JournalEntryEntity] {
    try underlying.fetchAll()
  }

  func fetch(in dateRange: DateInterval) throws -> [JournalEntryEntity] {
    try underlying.fetch(in: dateRange)
  }

  func fetchByID(_ id: String) throws -> JournalEntryEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ entry: JournalEntryEntity) throws {
    try underlying.save(entry)
    try pendingStore.enqueue(entityType: SyncEntityType.journalEntry, entityId: entry.id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.journalEntry, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ entry: JournalEntryEntity) throws {
    try underlying.save(entry)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}
