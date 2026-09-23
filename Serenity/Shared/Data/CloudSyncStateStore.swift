import Foundation
import GRDB

/// Local change ledger that backs iCloud sync. Mutations on syncable
/// repositories enqueue an entry here; the engine drains it into CloudKit and
/// marks rows complete. One row per `(entityType, entityId)` — the latest
/// pending operation supersedes earlier ones for the same target.
struct PendingSyncChange: Equatable, Sendable {
  enum Operation: String, Sendable {
    case upsert
    case delete
  }

  let id: String
  let entityType: String
  let entityId: String
  let operation: Operation
  let queuedAt: Date
  let attempts: Int
  let lastAttemptAt: Date?
  let lastError: String?
}

protocol PendingSyncChangeStore: Sendable {
  func enqueue(entityType: String, entityId: String, operation: PendingSyncChange.Operation) throws
  /// Joins the caller's transaction, so the entity write and its ledger row commit together.
  func enqueue(entityType: String, entityId: String, operation: PendingSyncChange.Operation, in db: Database) throws
  func fetchPending(limit: Int) throws -> [PendingSyncChange]
  /// Like `fetchPending`, minus rows still waiting out the delay after a failed push.
  func fetchDue(limit: Int) throws -> [PendingSyncChange]
  func pendingChange(entityType: String, entityId: String, in db: Database) throws -> PendingSyncChange?
  func deletePending(id: String, in db: Database) throws
  func markCompleted(ids: [String]) throws
  func markFailed(ids: [String], error: String) throws
  func count() throws -> Int
}

/// Persisted blobs that the iCloud engine needs across launches — most
/// importantly the `CKServerChangeToken` for incremental zone fetches.
protocol CloudSyncStateStore: Sendable {
  func loadValue(forKey key: String) throws -> Data?
  func saveValue(_ value: Data?, forKey key: String) throws
}

final class GRDBPendingSyncChangeStore: PendingSyncChangeStore, @unchecked Sendable {
  private let dbQueue: DatabaseQueue
  private let clock: () -> Date

  init(dbQueue: DatabaseQueue, clock: @escaping () -> Date = { Date() }) {
    self.dbQueue = dbQueue
    self.clock = clock
  }

  func enqueue(entityType: String, entityId: String, operation: PendingSyncChange.Operation) throws {
    try dbQueue.write { db in
      try enqueue(entityType: entityType, entityId: entityId, operation: operation, in: db)
    }
  }

  /// Every enqueue gives the row a new id. A push that finishes afterwards deletes by the id it
  /// read, so it deletes nothing and the newer edit stays queued — even within the same second.
  func enqueue(entityType: String, entityId: String, operation: PendingSyncChange.Operation, in db: Database) throws {
    let now = clock()
    try db.execute(
      sql: """
      INSERT INTO pending_sync_changes (id, entity_type, entity_id, operation, queued_at, attempts)
      VALUES (?, ?, ?, ?, ?, 0)
      ON CONFLICT(entity_type, entity_id) DO UPDATE SET
        id = excluded.id,
        operation = excluded.operation,
        queued_at = excluded.queued_at,
        attempts = 0,
        last_attempt_at = NULL,
        last_error = NULL,
        next_attempt_at = NULL;
      """,
      arguments: [
        UUID().uuidString,
        entityType,
        entityId,
        operation.rawValue,
        ISO8601DateFormatter().string(from: now),
      ]
    )
  }

  func fetchPending(limit: Int) throws -> [PendingSyncChange] {
    try dbQueue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT id, entity_type, entity_id, operation, queued_at, attempts, last_attempt_at, last_error
        FROM pending_sync_changes
        ORDER BY queued_at ASC
        LIMIT ?;
        """,
        arguments: [limit]
      )
      return rows.compactMap(Self.makeChange(from:))
    }
  }

  func fetchDue(limit: Int) throws -> [PendingSyncChange] {
    let now = ISO8601DateFormatter().string(from: clock())
    return try dbQueue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT id, entity_type, entity_id, operation, queued_at, attempts, last_attempt_at, last_error
        FROM pending_sync_changes
        WHERE next_attempt_at IS NULL OR next_attempt_at <= ?
        ORDER BY queued_at ASC
        LIMIT ?;
        """,
        arguments: [now, limit]
      )
      return rows.compactMap(Self.makeChange(from:))
    }
  }

  func pendingChange(entityType: String, entityId: String, in db: Database) throws -> PendingSyncChange? {
    let row = try Row.fetchOne(
      db,
      sql: """
      SELECT id, entity_type, entity_id, operation, queued_at, attempts, last_attempt_at, last_error
      FROM pending_sync_changes
      WHERE entity_type = ? AND entity_id = ?;
      """,
      arguments: [entityType, entityId]
    )
    return row.flatMap(Self.makeChange(from:))
  }

  func deletePending(id: String, in db: Database) throws {
    try db.execute(sql: "DELETE FROM pending_sync_changes WHERE id = ?;", arguments: [id])
  }

  /// Doubles from 30 seconds to at most an hour.
  static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
    min(3_600, 30 * pow(2, Double(max(0, attempts - 1))))
  }

  func markCompleted(ids: [String]) throws {
    guard !ids.isEmpty else { return }
    try dbQueue.write { db in
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
      try db.execute(
        sql: "DELETE FROM pending_sync_changes WHERE id IN (\(placeholders));",
        arguments: StatementArguments(ids)
      )
    }
  }

  func markFailed(ids: [String], error: String) throws {
    guard !ids.isEmpty else { return }
    let now = clock()
    let formatter = ISO8601DateFormatter()
    try dbQueue.write { db in
      for id in ids {
        guard let attempts = try Int.fetchOne(
          db,
          sql: "SELECT attempts FROM pending_sync_changes WHERE id = ?;",
          arguments: [id]
        ) else { continue }
        let nextAttempt = now.addingTimeInterval(Self.retryDelay(afterAttempts: attempts + 1))
        try db.execute(
          sql: """
          UPDATE pending_sync_changes
          SET attempts = attempts + 1,
              last_attempt_at = ?,
              last_error = ?,
              next_attempt_at = ?
          WHERE id = ?;
          """,
          arguments: [formatter.string(from: now), error, formatter.string(from: nextAttempt), id]
        )
      }
    }
  }

  func count() throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_sync_changes;") ?? 0
    }
  }

  private static func makeChange(from row: Row) -> PendingSyncChange? {
    guard
      let id: String = row["id"],
      let entityType: String = row["entity_type"],
      let entityId: String = row["entity_id"],
      let operationRaw: String = row["operation"],
      let operation = PendingSyncChange.Operation(rawValue: operationRaw),
      let queuedAtRaw: String = row["queued_at"],
      let queuedAt = ISO8601DateFormatter().date(from: queuedAtRaw)
    else {
      return nil
    }

    let attempts: Int = row["attempts"] ?? 0
    let lastAttemptAt: Date? = (row["last_attempt_at"] as String?)
      .flatMap { ISO8601DateFormatter().date(from: $0) }
    let lastError: String? = row["last_error"]

    return PendingSyncChange(
      id: id,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      queuedAt: queuedAt,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
      lastError: lastError
    )
  }
}

final class GRDBCloudSyncStateStore: CloudSyncStateStore, @unchecked Sendable {
  private let dbQueue: DatabaseQueue
  private let clock: () -> Date

  init(dbQueue: DatabaseQueue, clock: @escaping () -> Date = { Date() }) {
    self.dbQueue = dbQueue
    self.clock = clock
  }

  func loadValue(forKey key: String) throws -> Data? {
    try dbQueue.read { db in
      try Data.fetchOne(db, sql: "SELECT value FROM cloud_sync_state WHERE key = ?;", arguments: [key])
    }
  }

  func saveValue(_ value: Data?, forKey key: String) throws {
    let now = ISO8601DateFormatter().string(from: clock())
    try dbQueue.write { db in
      if let value {
        try db.execute(
          sql: """
          INSERT INTO cloud_sync_state (key, value, updated_at)
          VALUES (?, ?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
          """,
          arguments: [key, value, now]
        )
      } else {
        try db.execute(
          sql: "DELETE FROM cloud_sync_state WHERE key = ?;",
          arguments: [key]
        )
      }
    }
  }
}


/// What the engine remembers per record beyond the entity itself: the CloudKit system fields of the
/// last server copy, and pulled records that failed to apply.
final class GRDBCloudSyncRecordStore: @unchecked Sendable {
  let dbQueue: DatabaseQueue
  private let clock: () -> Date

  init(dbQueue: DatabaseQueue, clock: @escaping () -> Date = { Date() }) {
    self.dbQueue = dbQueue
    self.clock = clock
  }

  func systemFields(entityType: String, entityId: String) throws -> Data? {
    try dbQueue.read { db in
      try Data.fetchOne(
        db,
        sql: "SELECT system_fields FROM cloud_sync_record_metadata WHERE entity_type = ? AND entity_id = ?;",
        arguments: [entityType, entityId]
      )
    }
  }

  func saveSystemFields(_ data: Data, entityType: String, entityId: String, in db: Database) throws {
    try db.execute(
      sql: """
      INSERT INTO cloud_sync_record_metadata (entity_type, entity_id, system_fields, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(entity_type, entity_id) DO UPDATE SET
        system_fields = excluded.system_fields,
        updated_at = excluded.updated_at;
      """,
      arguments: [entityType, entityId, data, ISO8601DateFormatter().string(from: clock())]
    )
  }

  func deleteSystemFields(entityType: String, entityId: String, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM cloud_sync_record_metadata WHERE entity_type = ? AND entity_id = ?;",
      arguments: [entityType, entityId]
    )
  }

  /// A zone that was deleted takes every server copy with it.
  func deleteAllSystemFields() throws {
    try dbQueue.write { db in
      try db.execute(sql: "DELETE FROM cloud_sync_record_metadata;")
    }
  }

  /// Returns the attempt count after this failure.
  @discardableResult
  func recordApplyFailure(entityType: String, entityId: String, error: String, setAsideAfter limit: Int) throws -> Int {
    try dbQueue.write { db in
      let previous = try Int.fetchOne(
        db,
        sql: "SELECT attempts FROM cloud_sync_apply_failures WHERE entity_type = ? AND entity_id = ?;",
        arguments: [entityType, entityId]
      ) ?? 0
      let attempts = previous + 1
      try db.execute(
        sql: """
        INSERT INTO cloud_sync_apply_failures (entity_type, entity_id, attempts, last_error, set_aside, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(entity_type, entity_id) DO UPDATE SET
          attempts = excluded.attempts,
          last_error = excluded.last_error,
          set_aside = excluded.set_aside,
          updated_at = excluded.updated_at;
        """,
        arguments: [
          entityType,
          entityId,
          attempts,
          error,
          attempts >= limit ? 1 : 0,
          ISO8601DateFormatter().string(from: clock()),
        ]
      )
      return attempts
    }
  }

  func clearApplyFailure(entityType: String, entityId: String, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM cloud_sync_apply_failures WHERE entity_type = ? AND entity_id = ?;",
      arguments: [entityType, entityId]
    )
  }

  func setAsideCount() throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_sync_apply_failures WHERE set_aside = 1;") ?? 0
    }
  }
}
