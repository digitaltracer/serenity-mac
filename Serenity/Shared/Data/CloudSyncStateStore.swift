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
  func fetchPending(limit: Int) throws -> [PendingSyncChange]
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
    let now = clock()
    try dbQueue.write { db in
      try db.execute(
        sql: """
        INSERT INTO pending_sync_changes (id, entity_type, entity_id, operation, queued_at, attempts)
        VALUES (?, ?, ?, ?, ?, 0)
        ON CONFLICT(entity_type, entity_id) DO UPDATE SET
          operation = excluded.operation,
          queued_at = excluded.queued_at,
          attempts = 0,
          last_attempt_at = NULL,
          last_error = NULL;
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
    try dbQueue.write { db in
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
      var arguments: [DatabaseValueConvertible] = [
        ISO8601DateFormatter().string(from: now),
        error,
      ]
      arguments.append(contentsOf: ids)
      try db.execute(
        sql: """
        UPDATE pending_sync_changes
        SET attempts = attempts + 1,
            last_attempt_at = ?,
            last_error = ?
        WHERE id IN (\(placeholders));
        """,
        arguments: StatementArguments(arguments)
      )
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
