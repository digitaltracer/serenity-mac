import Foundation
import CloudKit

/// Stable CloudKit container + zone identifiers. The container ID matches the
/// `com.apple.developer.icloud-container-identifiers` entitlement; the zone
/// is custom (the default zone doesn't return change tokens) and acts as the
/// scope for both fetch-changes and zone subscriptions.
enum SerenityCloudKit {
  static let containerIdentifier = "iCloud.com.digitaltracer.serenity"
  static let zoneName = "SerenityZone"
  static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  static let zoneSubscriptionID = "serenity-zone-subscription"

  enum StateKey {
    static let zoneCreated = "cloudkit.zone.created"
    static let subscriptionCreated = "cloudkit.subscription.created"
    static let serverChangeToken = "cloudkit.serverChangeToken"
    static let initialExportCompleted = "cloudkit.initialExport.completed"
  }
}

enum CloudKitMappingError: Error, LocalizedError {
  case unsupportedRecordType(String)
  case missingField(String, recordType: String)
  case decodingFailure(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedRecordType(let type):
      return "CloudKit record type \(type) is not registered for sync."
    case .missingField(let field, let type):
      return "CloudKit \(type) record is missing required field \(field)."
    case .decodingFailure(let message):
      return "CloudKit decode failed: \(message)"
    }
  }
}

/// Common shape every record adapter implements. The engine looks adapters up
/// by `entityType` (matches `SyncEntityType.*` and `recordType`) when draining
/// the pending ledger and when processing pulled CKRecords.
protocol SyncRecordKind {
  /// Stable name shared across `pending_sync_changes.entity_type`,
  /// `CKRecord.recordType`, and the `SyncEntityType.*` constants.
  var entityType: String { get }

  /// Fetches the local entity by id and serializes it into a `CKRecord` ready
  /// for `CKModifyRecordsOperation`. Returns nil when the local row is gone
  /// (caller should treat as a "delete" rather than an upsert).
  func makeRecord(forID id: String) throws -> CKRecord?

  /// Applies a CKRecord pulled from CloudKit to the local store. Must use the
  /// repository's `applyRemote*` paths so it doesn't re-enqueue.
  func applyPulled(_ record: CKRecord) throws

  /// Applies a CloudKit-side delete (record-id received via fetch-changes
  /// `recordWithIDWasDeletedBlock`). Must use `applyRemote*` paths.
  func applyPulledDelete(recordName: String) throws
}

// MARK: - Tasks

struct TaskSyncRecordKind: SyncRecordKind {
  let repository: SyncAwareTaskRepository

  let entityType = SyncEntityType.task

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let task = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: task.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(task, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let task = try Self.decode(record)
    try repository.applyRemoteUpsert(task)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  // MARK: encode/decode

  static func encode(_ task: TaskEntity, into record: CKRecord) throws {
    record["title"] = task.title as CKRecordValue
    record["description"] = task.description as CKRecordValue?
    record["completed"] = (task.completed ? 1 : 0) as CKRecordValue
    record["completedAt"] = task.completedAt as CKRecordValue?
    record["priority"] = task.priority.rawValue as CKRecordValue
    record["dueDate"] = task.dueDate as CKRecordValue?
    record["projectId"] = task.projectId as CKRecordValue?
    record["userId"] = task.userId as CKRecordValue?
    record["createdAt"] = task.createdAt as CKRecordValue
    record["updatedAt"] = task.updatedAt as CKRecordValue
    record["tagsJSON"] = try CloudKitJSONCodec.encode(task.tags) as CKRecordValue
    record["subtasksJSON"] = try CloudKitJSONCodec.encode(task.subtasks) as CKRecordValue
    record["recurringJSON"] = try task.recurring.map { try CloudKitJSONCodec.encode($0) as CKRecordValue }
  }

  static func decode(_ record: CKRecord) throws -> TaskEntity {
    let id = record.recordID.recordName
    let title: String = try requireField(record, "title")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")
    let priorityRaw: String = (record["priority"] as? String) ?? TaskPriority.medium.rawValue

    let tags: [String] = try (record["tagsJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let subtasks: [TaskSubtask] = try (record["subtasksJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let recurring: TaskRecurringPattern? = try (record["recurringJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) as TaskRecurringPattern }

    return TaskEntity(
      id: id,
      title: title,
      description: record["description"] as? String,
      completed: (record["completed"] as? Int ?? 0) != 0,
      completedAt: record["completedAt"] as? Date,
      priority: TaskPriority(rawValue: priorityRaw) ?? .medium,
      dueDate: record["dueDate"] as? Date,
      projectId: record["projectId"] as? String,
      tags: tags,
      createdAt: createdAt,
      updatedAt: updatedAt,
      subtasks: subtasks,
      recurring: recurring,
      userId: record["userId"] as? String
    )
  }
}

// MARK: - Projects

struct ProjectSyncRecordKind: SyncRecordKind {
  let repository: SyncAwareProjectRepository

  let entityType = SyncEntityType.project

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let project = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: project.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(project, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let project = try Self.decode(record)
    try repository.applyRemoteUpsert(project)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ project: ProjectEntity, into record: CKRecord) throws {
    record["name"] = project.name as CKRecordValue
    record["description"] = project.description as CKRecordValue?
    record["color"] = project.color as CKRecordValue
    record["icon"] = project.icon as CKRecordValue?
    record["archived"] = (project.archived ? 1 : 0) as CKRecordValue
    record["userId"] = project.userId as CKRecordValue?
    record["createdAt"] = project.createdAt as CKRecordValue
    record["updatedAt"] = project.updatedAt as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> ProjectEntity {
    let id = record.recordID.recordName
    let name: String = try requireField(record, "name")
    let color: String = (record["color"] as? String) ?? "#4A90E2"
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")

    return ProjectEntity(
      id: id,
      name: name,
      description: record["description"] as? String,
      color: color,
      icon: record["icon"] as? String,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archived: (record["archived"] as? Int ?? 0) != 0,
      userId: record["userId"] as? String
    )
  }
}

// MARK: - Journal entries

struct JournalEntrySyncRecordKind: SyncRecordKind {
  let repository: SyncAwareJournalRepository

  let entityType = SyncEntityType.journalEntry

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let entry = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: entry.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(entry, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let entry = try Self.decode(record)
    try repository.applyRemoteUpsert(entry)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ entry: JournalEntryEntity, into record: CKRecord) throws {
    record["title"] = entry.title as CKRecordValue?
    record["content"] = entry.content as CKRecordValue
    record["date"] = entry.date as CKRecordValue
    record["pinned"] = (entry.pinned ? 1 : 0) as CKRecordValue
    record["mood"] = entry.mood?.rawValue as CKRecordValue?
    record["userId"] = entry.userId as CKRecordValue?
    record["createdAt"] = entry.createdAt as CKRecordValue
    record["updatedAt"] = entry.updatedAt as CKRecordValue
    record["tagsJSON"] = try CloudKitJSONCodec.encode(entry.tags) as CKRecordValue
    record["attachmentsJSON"] = try CloudKitJSONCodec.encode(entry.attachments) as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> JournalEntryEntity {
    let id = record.recordID.recordName
    let content: String = try requireField(record, "content")
    let date: Date = try requireField(record, "date")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")

    let tags: [String] = try (record["tagsJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let attachments: [JournalAttachmentEntity] = try (record["attachmentsJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? []
    let mood: JournalMood? = (record["mood"] as? String).flatMap(JournalMood.init(rawValue:))

    return JournalEntryEntity(
      id: id,
      title: record["title"] as? String,
      content: content,
      date: date,
      tags: tags,
      createdAt: createdAt,
      updatedAt: updatedAt,
      pinned: (record["pinned"] as? Int ?? 0) != 0,
      mood: mood,
      attachments: attachments,
      userId: record["userId"] as? String
    )
  }
}

// MARK: - Goals

struct GoalSyncRecordKind: SyncRecordKind {
  let repository: SyncAwareGoalRepository

  let entityType = SyncEntityType.goal

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let goal = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: goal.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(goal, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let goal = try Self.decode(record)
    try repository.applyRemoteUpsert(goal)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ goal: GoalEntity, into record: CKRecord) throws {
    record["title"] = goal.title as CKRecordValue
    record["description"] = goal.description as CKRecordValue?
    record["type"] = goal.type.rawValue as CKRecordValue
    record["status"] = goal.status.rawValue as CKRecordValue
    record["priority"] = goal.priority.rawValue as CKRecordValue
    record["userId"] = goal.userId as CKRecordValue?
    record["createdAt"] = goal.createdAt as CKRecordValue
    record["updatedAt"] = goal.updatedAt as CKRecordValue
    record["configJSON"] = try CloudKitJSONCodec.encode(goal.config) as CKRecordValue
    record["progressJSON"] = try CloudKitJSONCodec.encode(goal.progress) as CKRecordValue
    record["remindersJSON"] = try CloudKitJSONCodec.encode(goal.reminders) as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> GoalEntity {
    let id = record.recordID.recordName
    let title: String = try requireField(record, "title")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")
    let typeRaw: String = (record["type"] as? String) ?? GoalType.weeklyTasks.rawValue
    let statusRaw: String = (record["status"] as? String) ?? GoalStatus.active.rawValue
    let priorityRaw: String = (record["priority"] as? String) ?? GoalPriority.medium.rawValue

    let defaultConfig = GoalConfig(
      targetCount: nil,
      projectId: nil,
      priority: nil,
      streakDays: nil,
      targetRate: nil,
      timeframe: .weekly
    )
    let defaultProgress = GoalProgress(
      current: 0,
      target: 1,
      percentage: 0,
      isCompleted: false,
      periodStart: createdAt,
      periodEnd: updatedAt
    )
    let config: GoalConfig = try (record["configJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? defaultConfig
    let progress: GoalProgress = try (record["progressJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? defaultProgress
    let reminders: [GoalReminder] = try (record["remindersJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? []

    return GoalEntity(
      id: id,
      title: title,
      description: record["description"] as? String,
      type: GoalType(rawValue: typeRaw) ?? .weeklyTasks,
      config: config,
      progress: progress,
      status: GoalStatus(rawValue: statusRaw) ?? .active,
      priority: GoalPriority(rawValue: priorityRaw) ?? .medium,
      reminders: reminders,
      createdAt: createdAt,
      updatedAt: updatedAt,
      userId: record["userId"] as? String
    )
  }
}

// MARK: - AI insights

struct AIInsightSyncRecordKind: SyncRecordKind {
  let repository: SyncAwareAIInsightRepository

  let entityType = SyncEntityType.aiInsight

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let insight = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: insight.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(insight, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let insight = try Self.decode(record)
    try repository.applyRemoteUpsert(insight)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ insight: AIInsightEntity, into record: CKRecord) throws {
    record["provider"] = insight.provider.rawValue as CKRecordValue
    record["type"] = insight.type.rawValue as CKRecordValue
    record["title"] = insight.title as CKRecordValue
    record["description"] = insight.description as CKRecordValue
    record["confidence"] = insight.confidence as CKRecordValue
    record["category"] = insight.category.rawValue as CKRecordValue
    record["actionable"] = (insight.actionable ? 1 : 0) as CKRecordValue
    record["metadataJSON"] = insight.metadataJSON as CKRecordValue
    record["createdAt"] = insight.createdAt as CKRecordValue
    record["updatedAt"] = insight.updatedAt as CKRecordValue
    record["userRating"] = insight.userRating as CKRecordValue?
    record["dismissed"] = (insight.dismissed ? 1 : 0) as CKRecordValue
    record["markedHelpful"] = (insight.markedHelpful ? 1 : 0) as CKRecordValue
    record["userNotes"] = insight.userNotes as CKRecordValue?
    record["visualizationDataJSON"] = insight.visualizationDataJSON as CKRecordValue?
    record["actionabilitySuggestionsJSON"] = try CloudKitJSONCodec.encode(insight.actionabilitySuggestions) as CKRecordValue
    record["themeID"] = insight.themeID as CKRecordValue?
    record["isRecurring"] = (insight.isRecurring ? 1 : 0) as CKRecordValue
    record["occurrenceNumber"] = insight.occurrenceNumber as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> AIInsightEntity {
    let id = record.recordID.recordName
    let title: String = try requireField(record, "title")
    let description: String = try requireField(record, "description")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")
    let providerRaw: String = (record["provider"] as? String) ?? AIProvider.local.rawValue
    let typeRaw: String = (record["type"] as? String) ?? AIInsightType.productivity.rawValue
    let categoryRaw: String = (record["category"] as? String) ?? AIInsightCategory.tasks.rawValue
    let suggestions: [String] = try (record["actionabilitySuggestionsJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? []

    return AIInsightEntity(
      id: id,
      provider: AIProvider(rawValue: providerRaw) ?? .local,
      type: AIInsightType(rawValue: typeRaw) ?? .productivity,
      title: title,
      description: description,
      confidence: record["confidence"] as? Double ?? 0.5,
      category: AIInsightCategory(rawValue: categoryRaw) ?? .tasks,
      actionable: (record["actionable"] as? Int ?? 0) != 0,
      metadataJSON: (record["metadataJSON"] as? String) ?? "{}",
      createdAt: createdAt,
      updatedAt: updatedAt,
      userRating: record["userRating"] as? Int,
      dismissed: (record["dismissed"] as? Int ?? 0) != 0,
      markedHelpful: (record["markedHelpful"] as? Int ?? 0) != 0,
      userNotes: record["userNotes"] as? String,
      visualizationDataJSON: record["visualizationDataJSON"] as? String,
      actionabilitySuggestions: suggestions,
      themeID: record["themeID"] as? String,
      isRecurring: (record["isRecurring"] as? Int ?? 0) != 0,
      occurrenceNumber: record["occurrenceNumber"] as? Int ?? 1
    )
  }
}

// MARK: - AI recaps

struct AIRecapSyncRecordKind: SyncRecordKind {
  let repository: SyncAwareAIRecapRepository

  let entityType = SyncEntityType.aiRecap

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let recap = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: recap.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(recap, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let recap = try Self.decode(record)
    try repository.applyRemoteUpsert(recap)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ recap: AIRecapEntity, into record: CKRecord) throws {
    record["provider"] = recap.provider.rawValue as CKRecordValue
    record["type"] = recap.type.rawValue as CKRecordValue
    record["title"] = recap.title as CKRecordValue
    record["summary"] = recap.summary as CKRecordValue
    record["highlightsJSON"] = try CloudKitJSONCodec.encode(recap.highlights) as CKRecordValue
    record["challengesJSON"] = try CloudKitJSONCodec.encode(recap.challenges) as CKRecordValue
    record["recommendationsJSON"] = try CloudKitJSONCodec.encode(recap.recommendations) as CKRecordValue
    record["periodJSON"] = try CloudKitJSONCodec.encode(recap.period) as CKRecordValue
    record["metadataJSON"] = recap.metadataJSON as CKRecordValue
    record["createdAt"] = recap.createdAt as CKRecordValue
    record["updatedAt"] = recap.updatedAt as CKRecordValue
    record["viewed"] = (recap.viewed ? 1 : 0) as CKRecordValue
    record["favorited"] = (recap.favorited ? 1 : 0) as CKRecordValue
    record["exported"] = (recap.exported ? 1 : 0) as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> AIRecapEntity {
    let id = record.recordID.recordName
    let title: String = try requireField(record, "title")
    let summary: String = try requireField(record, "summary")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")
    let providerRaw: String = (record["provider"] as? String) ?? AIProvider.local.rawValue
    let typeRaw: String = (record["type"] as? String) ?? AIRecapType.weekly.rawValue
    let highlights: [String] = try (record["highlightsJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let challenges: [String] = try (record["challengesJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let recommendations: [String] = try (record["recommendationsJSON"] as? String).map { try CloudKitJSONCodec.decode($0) } ?? []
    let period: AIRecapPeriod = try (record["periodJSON"] as? String)
      .map { try CloudKitJSONCodec.decode($0) } ?? AIRecapPeriod(start: createdAt, end: updatedAt)

    return AIRecapEntity(
      id: id,
      provider: AIProvider(rawValue: providerRaw) ?? .local,
      type: AIRecapType(rawValue: typeRaw) ?? .weekly,
      title: title,
      summary: summary,
      highlights: highlights,
      challenges: challenges,
      recommendations: recommendations,
      period: period,
      metadataJSON: (record["metadataJSON"] as? String) ?? "{}",
      createdAt: createdAt,
      updatedAt: updatedAt,
      viewed: (record["viewed"] as? Int ?? 0) != 0,
      favorited: (record["favorited"] as? Int ?? 0) != 0,
      exported: (record["exported"] as? Int ?? 0) != 0
    )
  }
}

// MARK: - Summaries

struct SummarySyncRecordKind: SyncRecordKind {
  let repository: SyncAwareSummaryRepository

  let entityType = SyncEntityType.summary

  func makeRecord(forID id: String) throws -> CKRecord? {
    guard let summary = try repository.fetchByID(id) else { return nil }
    let recordID = CKRecord.ID(recordName: summary.id, zoneID: SerenityCloudKit.zoneID)
    let record = CKRecord(recordType: entityType, recordID: recordID)
    try Self.encode(summary, into: record)
    return record
  }

  func applyPulled(_ record: CKRecord) throws {
    let summary = try Self.decode(record)
    try repository.applyRemoteUpsert(summary)
  }

  func applyPulledDelete(recordName: String) throws {
    try repository.applyRemoteDelete(id: recordName)
  }

  static func encode(_ summary: SummaryEntity, into record: CKRecord) throws {
    record["title"] = summary.title as CKRecordValue
    record["content"] = summary.content as CKRecordValue
    record["summaryType"] = summary.summaryType.rawValue as CKRecordValue
    record["startDate"] = summary.startDate as CKRecordValue
    record["endDate"] = summary.endDate as CKRecordValue
    record["generatedAt"] = summary.generatedAt as CKRecordValue
    record["wordCount"] = summary.wordCount as CKRecordValue
    record["metadataJSON"] = summary.metadataJSON as CKRecordValue
    record["provider"] = summary.provider.rawValue as CKRecordValue
    record["promptTokens"] = summary.promptTokens as CKRecordValue
    record["completionTokens"] = summary.completionTokens as CKRecordValue
    record["totalTokens"] = summary.totalTokens as CKRecordValue
    record["createdAt"] = summary.createdAt as CKRecordValue
    record["updatedAt"] = summary.updatedAt as CKRecordValue
  }

  static func decode(_ record: CKRecord) throws -> SummaryEntity {
    let id = record.recordID.recordName
    let title: String = try requireField(record, "title")
    let content: String = try requireField(record, "content")
    let startDate: Date = try requireField(record, "startDate")
    let endDate: Date = try requireField(record, "endDate")
    let generatedAt: Date = try requireField(record, "generatedAt")
    let createdAt: Date = try requireField(record, "createdAt")
    let updatedAt: Date = try requireField(record, "updatedAt")
    let summaryTypeRaw: String = (record["summaryType"] as? String) ?? SummaryType.combined.rawValue
    let providerRaw: String = (record["provider"] as? String) ?? AIProvider.local.rawValue

    return SummaryEntity(
      id: id,
      title: title,
      content: content,
      summaryType: SummaryType(rawValue: summaryTypeRaw) ?? .combined,
      startDate: startDate,
      endDate: endDate,
      generatedAt: generatedAt,
      wordCount: record["wordCount"] as? Int ?? 0,
      metadataJSON: (record["metadataJSON"] as? String) ?? "{}",
      provider: AIProvider(rawValue: providerRaw) ?? .local,
      promptTokens: record["promptTokens"] as? Int ?? 0,
      completionTokens: record["completionTokens"] as? Int ?? 0,
      totalTokens: record["totalTokens"] as? Int ?? 0,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

// MARK: - Helpers

private func requireField<T>(_ record: CKRecord, _ field: String) throws -> T {
  guard let value = record[field] as? T else {
    throw CloudKitMappingError.missingField(field, recordType: record.recordType)
  }
  return value
}

enum CloudKitJSONCodec {
  static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw CloudKitMappingError.decodingFailure("non-utf8 JSON")
    }
    return string
  }

  static func decode<T: Decodable>(_ string: String) throws -> T {
    guard let data = string.data(using: .utf8) else {
      throw CloudKitMappingError.decodingFailure("non-utf8 JSON")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }
}
