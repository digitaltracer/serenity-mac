import Foundation

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

final class SyncAwareProjectRepository: CoreProjectRepository {
  private let underlying: CoreProjectRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: CoreProjectRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.save(project)
    try pendingStore.enqueue(entityType: SyncEntityType.project, entityId: project.id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.project, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ project: ProjectEntity) throws {
    try underlying.save(project)
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

final class SyncAwareGoalRepository: CoreGoalRepository {
  private let underlying: CoreGoalRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: CoreGoalRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.save(goal)
    try pendingStore.enqueue(entityType: SyncEntityType.goal, entityId: goal.id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.goal, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ goal: GoalEntity) throws {
    try underlying.save(goal)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}
