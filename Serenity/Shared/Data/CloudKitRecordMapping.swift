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
