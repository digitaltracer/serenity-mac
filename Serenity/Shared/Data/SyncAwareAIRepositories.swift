import Foundation

final class SyncAwareAIInsightRepository: AIInsightRepository {
  private let underlying: AIInsightRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: AIInsightRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.save(insight)
    try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: insight.id, operation: .upsert)
  }

  func updateFeedback(
    id: String,
    userRating: Int?,
    dismissed: Bool?,
    markedHelpful: Bool?,
    userNotes: String?
  ) throws {
    try underlying.updateFeedback(
      id: id,
      userRating: userRating,
      dismissed: dismissed,
      markedHelpful: markedHelpful,
      userNotes: userNotes
    )
    try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.aiInsight, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ insight: AIInsightEntity) throws {
    try underlying.save(insight)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}

final class SyncAwareAIRecapRepository: AIRecapRepository {
  private let underlying: AIRecapRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: AIRecapRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.save(recap)
    try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: recap.id, operation: .upsert)
  }

  func updateInteraction(id: String, viewed: Bool?, favorited: Bool?, exported: Bool?) throws {
    try underlying.updateInteraction(id: id, viewed: viewed, favorited: favorited, exported: exported)
    try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.aiRecap, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ recap: AIRecapEntity) throws {
    try underlying.save(recap)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}

final class SyncAwareSummaryRepository: SummaryRepository {
  private let underlying: SummaryRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: SummaryRepository, pendingStore: PendingSyncChangeStore) {
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
    try underlying.save(summary)
    try pendingStore.enqueue(entityType: SyncEntityType.summary, entityId: summary.id, operation: .upsert)
  }

  func delete(id: String) throws {
    try underlying.delete(id: id)
    try pendingStore.enqueue(entityType: SyncEntityType.summary, entityId: id, operation: .delete)
  }

  func applyRemoteUpsert(_ summary: SummaryEntity) throws {
    try underlying.save(summary)
  }

  func applyRemoteDelete(id: String) throws {
    try underlying.delete(id: id)
  }
}
