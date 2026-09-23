import Foundation
import GRDB

final class SyncAwareAIInsightRepository: AIInsightRepository {
  private let underlying: GRDBAIInsightRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBAIInsightRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll(limit: Int) throws -> [AIInsightEntity] {
    try underlying.fetchAll(limit: limit)
  }

  func fetchFiltered(
    category: AIInsightCategory?,
    type: AIInsightType?,
    dismissed: Bool?,
    limit: Int,
    offset: Int
  ) throws -> [AIInsightEntity] {
    try underlying.fetchFiltered(
      category: category,
      type: type,
      dismissed: dismissed,
      limit: limit,
      offset: offset
    )
  }

  func fetchByID(_ id: String) throws -> AIInsightEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ insight: AIInsightEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(insight, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: insight.id, operation: .upsert, in: db)
    }
  }

  func updateFeedback(
    id: String,
    userRating: Int?,
    dismissed: Bool?,
    markedHelpful: Bool?,
    userNotes: String?
  ) throws {
    try underlying.dbQueue.write { db in
      try underlying.updateFeedback(
        id: id,
        userRating: userRating,
        dismissed: dismissed,
        markedHelpful: markedHelpful,
        userNotes: userNotes,
        in: db
      )
      try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ insight: AIInsightEntity) throws {
    try underlying.save(insight)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ insight: AIInsightEntity, in db: Database) throws {
    try underlying.save(insight, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareAIRecapRepository: AIRecapRepository {
  private let underlying: GRDBAIRecapRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBAIRecapRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll(limit: Int) throws -> [AIRecapEntity] {
    try underlying.fetchAll(limit: limit)
  }

  func fetchFiltered(type: AIRecapType?, favorited: Bool?, limit: Int, offset: Int) throws -> [AIRecapEntity] {
    try underlying.fetchFiltered(type: type, favorited: favorited, limit: limit, offset: offset)
  }

  func fetchByID(_ id: String) throws -> AIRecapEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ recap: AIRecapEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(recap, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: recap.id, operation: .upsert, in: db)
    }
  }

  func updateInteraction(id: String, viewed: Bool?, favorited: Bool?, exported: Bool?) throws {
    try underlying.dbQueue.write { db in
      try underlying.updateInteraction(id: id, viewed: viewed, favorited: favorited, exported: exported, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ recap: AIRecapEntity) throws {
    try underlying.save(recap)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ recap: AIRecapEntity, in db: Database) throws {
    try underlying.save(recap, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareSummaryRepository: SummaryRepository {
  private let underlying: GRDBSummaryRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBSummaryRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll() throws -> [SummaryEntity] {
    try underlying.fetchAll()
  }

  func fetchByID(_ id: String) throws -> SummaryEntity? {
    try underlying.fetchByID(id)
  }

  func fetchByType(_ type: SummaryType) throws -> [SummaryEntity] {
    try underlying.fetchByType(type)
  }

  func fetchByDateRange(startDate: Date, endDate: Date) throws -> [SummaryEntity] {
    try underlying.fetchByDateRange(startDate: startDate, endDate: endDate)
  }

  func save(_ summary: SummaryEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(summary, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.summary, entityId: summary.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.summary, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ summary: SummaryEntity) throws {
    try underlying.save(summary)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ summary: SummaryEntity, in db: Database) throws {
    try underlying.save(summary, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}

final class SyncAwareStandupRepository: StandupRepository {
  private let underlying: GRDBStandupRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBStandupRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll(limit: Int) throws -> [StandupEntity] {
    try underlying.fetchAll(limit: limit)
  }

  func fetchLatest() throws -> StandupEntity? {
    try underlying.fetchLatest()
  }

  func fetchByID(_ id: String) throws -> StandupEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ standup: StandupEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(standup, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.standup, entityId: standup.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.standup, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ standup: StandupEntity) throws {
    try underlying.save(standup)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }

  func applyRemoteUpsert(_ standup: StandupEntity, in db: Database) throws {
    try underlying.save(standup, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}
