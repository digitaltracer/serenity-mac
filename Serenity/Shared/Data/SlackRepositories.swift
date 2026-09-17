import Foundation
import GRDB

public enum SlackProposalKind: String, Codable, Sendable {
  case create
  case update
}

public enum SlackProposalStatus: String, Codable, Sendable {
  case pending
  case accepted
  case dismissed
  case superseded
}

/// `TaskEntity` has no in-progress state, so a proposal can only open or close
/// a task. Anything finer has to live in the description or an activity line.
public enum SlackStatusChange: String, Codable, Sendable {
  case none
  case completed
  case reopened
}

/// What accepting a proposal would do. Every field is optional on purpose: an
/// update writes only what the message actually changed and leaves the rest of
/// the task alone.
public struct SlackProposalPayload: Codable, Equatable, Sendable {
  public var title: String?
  public var description: String?
  public var priority: TaskPriority?
  public var dueDate: Date?
  public var projectId: String?
  public var projectName: String?
  public var tags: [String]
  public var subtasks: [String]
  public var statusChange: SlackStatusChange

  public init(
    title: String? = nil,
    description: String? = nil,
    priority: TaskPriority? = nil,
    dueDate: Date? = nil,
    projectId: String? = nil,
    projectName: String? = nil,
    tags: [String] = [],
    subtasks: [String] = [],
    statusChange: SlackStatusChange = .none
  ) {
    self.title = title
    self.description = description
    self.priority = priority
    self.dueDate = dueDate
    self.projectId = projectId
    self.projectName = projectName
    self.tags = tags
    self.subtasks = subtasks
    self.statusChange = statusChange
  }
}

/// Where the proposal came from. The excerpt is what earns the user's trust —
/// a proposal without visible evidence is one they have to go verify by hand.
public struct SlackProposalSource: Codable, Equatable, Sendable {
  public var channelID: String
  public var channelName: String
  public var messageTS: String
  public var threadTS: String?
  public var author: String
  public var excerpt: String
  public var permalink: String?

  public init(
    channelID: String,
    channelName: String,
    messageTS: String,
    threadTS: String?,
    author: String,
    excerpt: String,
    permalink: String?
  ) {
    self.channelID = channelID
    self.channelName = channelName
    self.messageTS = messageTS
    self.threadTS = threadTS
    self.author = author
    self.excerpt = excerpt
    self.permalink = permalink
  }

  public var sentAt: Date {
    Date(timeIntervalSince1970: Double(messageTS.split(separator: ".").first.map(String.init) ?? "") ?? 0)
  }
}

public struct SlackProposal: Identifiable, Equatable, Sendable {
  public var id: String
  public var kind: SlackProposalKind
  public var targetTaskID: String?
  public var payload: SlackProposalPayload
  public var confidence: Double
  public var reason: String?
  public var status: SlackProposalStatus
  public var source: SlackProposalSource
  public var createdAt: Date
  public var decidedAt: Date?

  public init(
    id: String = UUID().uuidString,
    kind: SlackProposalKind,
    targetTaskID: String?,
    payload: SlackProposalPayload,
    confidence: Double,
    reason: String?,
    status: SlackProposalStatus = .pending,
    source: SlackProposalSource,
    createdAt: Date = Date(),
    decidedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.targetTaskID = targetTaskID
    self.payload = payload
    self.confidence = confidence
    self.reason = reason
    self.status = status
    self.source = source
    self.createdAt = createdAt
    self.decidedAt = decidedAt
  }
}

public enum SlackSeenOutcome: String, Codable, Sendable {
  case filtered
  case proposed
  case ignored
  case failed
}

public struct SlackSeenMessage: Equatable, Sendable {
  public var channelID: String
  public var ts: String
  public var outcome: SlackSeenOutcome

  public init(channelID: String, ts: String, outcome: SlackSeenOutcome) {
    self.channelID = channelID
    self.ts = ts
    self.outcome = outcome
  }

  public var key: String { "\(channelID):\(ts)" }
}

protocol SlackCursorRepository {
  func fetchAll() throws -> [SlackChannelCursor]
  func save(_ cursors: [SlackChannelCursor]) throws
}

protocol SlackSeenMessageRepository {
  func seenKeys() throws -> Set<String>
  func record(_ entries: [SlackSeenMessage], at date: Date) throws
}

protocol SlackProposalRepository {
  func fetchAll() throws -> [SlackProposal]
  func fetchPending() throws -> [SlackProposal]
  func save(_ proposal: SlackProposal) throws
  func updateStatus(id: String, status: SlackProposalStatus, decidedAt: Date) throws
  func supersedePending(channelID: String, threadTS: String?, excluding excludedID: String, at date: Date) throws
}

final class GRDBSlackCursorRepository: SlackCursorRepository {
  private let dbQueue: DatabaseQueue

  init(dbQueue: DatabaseQueue) {
    self.dbQueue = dbQueue
  }

  func fetchAll() throws -> [SlackChannelCursor] {
    try dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM slack_channel_cursors;")
      return try rows.map { row in
        SlackChannelCursor(
          channelID: row["channel_id"],
          channelName: row["channel_name"],
          lastTS: row["last_ts"],
          participatedThreadTS: try CoreRepositoryCodec.decodeJSONOrDefault(
            [String].self,
            from: row["participated_thread_ts_json"],
            default: []
          ),
          updatedAt: try CoreRepositoryCodec.decodeDate(row["updated_at"])
        )
      }
    }
  }

  func save(_ cursors: [SlackChannelCursor]) throws {
    let encoded = try cursors.map { cursor in
      (cursor, try CoreRepositoryCodec.encodeJSON(cursor.participatedThreadTS))
    }

    try dbQueue.write { db in
      for (cursor, threadsJSON) in encoded {
        try db.execute(
          sql: """
          INSERT INTO slack_channel_cursors (
            channel_id, channel_name, last_ts, participated_thread_ts_json, updated_at
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(channel_id) DO UPDATE SET
            channel_name = excluded.channel_name,
            last_ts = excluded.last_ts,
            participated_thread_ts_json = excluded.participated_thread_ts_json,
            updated_at = excluded.updated_at;
          """,
          arguments: [
            cursor.channelID,
            cursor.channelName,
            cursor.lastTS,
            threadsJSON,
            CoreRepositoryCodec.encodeDate(cursor.updatedAt),
          ]
        )
      }
    }
  }
}

final class GRDBSlackSeenMessageRepository: SlackSeenMessageRepository {
  private let dbQueue: DatabaseQueue

  init(dbQueue: DatabaseQueue) {
    self.dbQueue = dbQueue
  }

  func seenKeys() throws -> Set<String> {
    try dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT channel_id, ts FROM slack_seen_messages;")
      return Set(rows.map { row in
        let channelID: String = row["channel_id"]
        let ts: String = row["ts"]
        return "\(channelID):\(ts)"
      })
    }
  }

  func record(_ entries: [SlackSeenMessage], at date: Date) throws {
    let seenAt = CoreRepositoryCodec.encodeDate(date)

    try dbQueue.write { db in
      for entry in entries {
        try db.execute(
          sql: """
          INSERT INTO slack_seen_messages (channel_id, ts, outcome, seen_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(channel_id, ts) DO UPDATE SET
            outcome = excluded.outcome,
            seen_at = excluded.seen_at;
          """,
          arguments: [entry.channelID, entry.ts, entry.outcome.rawValue, seenAt]
        )
      }
    }
  }
}

final class GRDBSlackProposalRepository: SlackProposalRepository {
  private let dbQueue: DatabaseQueue

  init(dbQueue: DatabaseQueue) {
    self.dbQueue = dbQueue
  }

  func fetchAll() throws -> [SlackProposal] {
    try fetch(whereClause: nil)
  }

  func fetchPending() throws -> [SlackProposal] {
    try fetch(whereClause: "WHERE status = 'pending'")
  }

  func save(_ proposal: SlackProposal) throws {
    let payloadJSON = try CoreRepositoryCodec.encodeJSON(proposal.payload)

    try dbQueue.write { db in
      try db.execute(
        sql: """
        INSERT INTO slack_proposals (
          id, kind, target_task_id, payload_json, confidence, reason, status,
          source_channel_id, source_channel_name, source_message_ts, source_thread_ts,
          source_author, source_excerpt, permalink, created_at, decided_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          kind = excluded.kind,
          target_task_id = excluded.target_task_id,
          payload_json = excluded.payload_json,
          confidence = excluded.confidence,
          reason = excluded.reason,
          status = excluded.status,
          decided_at = excluded.decided_at;
        """,
        arguments: [
          proposal.id,
          proposal.kind.rawValue,
          proposal.targetTaskID,
          payloadJSON,
          proposal.confidence,
          proposal.reason,
          proposal.status.rawValue,
          proposal.source.channelID,
          proposal.source.channelName,
          proposal.source.messageTS,
          proposal.source.threadTS,
          proposal.source.author,
          proposal.source.excerpt,
          proposal.source.permalink,
          CoreRepositoryCodec.encodeDate(proposal.createdAt),
          proposal.decidedAt.map(CoreRepositoryCodec.encodeDate),
        ]
      )
    }
  }

  func updateStatus(id: String, status: SlackProposalStatus, decidedAt: Date) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE slack_proposals SET status = ?, decided_at = ? WHERE id = ?;",
        arguments: [status.rawValue, CoreRepositoryCodec.encodeDate(decidedAt), id]
      )
    }
  }

  /// Deciding one proposal settles the conversation it came from. Leaving its
  /// siblings pending means answering the same Slack thread two or three times.
  func supersedePending(channelID: String, threadTS: String?, excluding excludedID: String, at date: Date) throws {
    try dbQueue.write { db in
      if let threadTS {
        try db.execute(
          sql: """
          UPDATE slack_proposals SET status = 'superseded', decided_at = ?
          WHERE status = 'pending' AND id <> ? AND source_channel_id = ? AND source_thread_ts = ?;
          """,
          arguments: [CoreRepositoryCodec.encodeDate(date), excludedID, channelID, threadTS]
        )
      }
    }
  }

  private func fetch(whereClause: String?) throws -> [SlackProposal] {
    let sql = [
      "SELECT * FROM slack_proposals",
      whereClause,
      "ORDER BY created_at DESC;",
    ]
      .compactMap { $0 }
      .joined(separator: " ")

    return try dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: sql)
      return try rows.map { row in
        SlackProposal(
          id: row["id"],
          kind: SlackProposalKind(rawValue: row["kind"]) ?? .create,
          targetTaskID: row["target_task_id"],
          payload: try CoreRepositoryCodec.decodeJSONOrDefault(
            SlackProposalPayload.self,
            from: row["payload_json"],
            default: SlackProposalPayload()
          ),
          confidence: row["confidence"] ?? 0,
          reason: row["reason"],
          status: SlackProposalStatus(rawValue: row["status"]) ?? .pending,
          source: SlackProposalSource(
            channelID: row["source_channel_id"],
            channelName: row["source_channel_name"],
            messageTS: row["source_message_ts"],
            threadTS: row["source_thread_ts"],
            author: row["source_author"],
            excerpt: row["source_excerpt"],
            permalink: row["permalink"]
          ),
          createdAt: try CoreRepositoryCodec.decodeDate(row["created_at"]),
          decidedAt: try CoreRepositoryCodec.decodeOptionalDate(row["decided_at"])
        )
      }
    }
  }
}

struct GRDBSlackRepositorySet {
  let cursors: SlackCursorRepository
  let seenMessages: SlackSeenMessageRepository
  let proposals: SlackProposalRepository

  init(dbQueue: DatabaseQueue) {
    cursors = GRDBSlackCursorRepository(dbQueue: dbQueue)
    seenMessages = GRDBSlackSeenMessageRepository(dbQueue: dbQueue)
    proposals = GRDBSlackProposalRepository(dbQueue: dbQueue)
  }
}
