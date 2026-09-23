import Foundation
import GRDB

/// Stable type identifiers used in `pending_sync_changes.entity_type` and as
/// CloudKit `recordType` names. Don't rename these — they're part of the
/// on-disk + on-iCloud schema.
enum SyncEntityType {
  static let task = "Task"
  static let project = "Project"
  static let journalEntry = "JournalEntry"
  static let goal = "Goal"
  static let aiInsight = "AIInsight"
  static let aiRecap = "AIRecap"
  static let summary = "Summary"
  static let standup = "Standup"
}

/// Wraps a `CoreTaskRepository` so every successful save/delete pushes a
/// pending sync change into the local ledger. The iCloud engine drains the
/// ledger and round-trips records to CloudKit. Pulled remote changes go
/// through `applyRemoteUpsert(_:)` / `applyRemoteDelete(id:)`, which write
/// straight to the underlying repo and skip the ledger so we don't echo
/// changes back out.
final class SyncAwareTaskRepository: CoreTaskRepository {
  private let underlying: GRDBTaskRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBTaskRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.dbQueue.write { db in
      try underlying.save(task, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.task, entityId: task.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.task, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ task: TaskEntity) throws {
    try underlying.save(task)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ task: TaskEntity, in db: Database) throws {
    try underlying.save(task, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareProjectRepository: CoreProjectRepository {
  private let underlying: GRDBProjectRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBProjectRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll(includeArchived: Bool = true) throws -> [ProjectEntity] {
    try underlying.fetchAll(includeArchived: includeArchived)
  }

  func fetchByID(_ id: String) throws -> ProjectEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ project: ProjectEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(project, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.project, entityId: project.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.project, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ project: ProjectEntity) throws {
    try underlying.save(project)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ project: ProjectEntity, in db: Database) throws {
    try underlying.save(project, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareJournalRepository: CoreJournalRepository {
  private let underlying: GRDBJournalRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBJournalRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.dbQueue.write { db in
      try underlying.save(entry, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.journalEntry, entityId: entry.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.journalEntry, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ entry: JournalEntryEntity) throws {
    try underlying.save(entry)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ entry: JournalEntryEntity, in db: Database) throws {
    try underlying.save(entry, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareGoalRepository: CoreGoalRepository {
  private let underlying: GRDBGoalRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBGoalRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll() throws -> [GoalEntity] {
    try underlying.fetchAll()
  }

  func fetchActive() throws -> [GoalEntity] {
    try underlying.fetchActive()
  }

  func fetchByID(_ id: String) throws -> GoalEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ goal: GoalEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(goal, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.goal, entityId: goal.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.goal, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ goal: GoalEntity) throws {
    try underlying.save(goal)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ goal: GoalEntity, in db: Database) throws {
    try underlying.save(goal, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}
