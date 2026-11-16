import Foundation
import GRDB

/// One week's review: what was answered, decided and accepted. The id comes from the ISO week, so
/// two devices reviewing the same week write the same record.
struct WeeklyReviewEntity: Identifiable, Equatable {
  var id: String
  var weekKey: String
  var weekStart: Date
  var completedAt: Date?
  var payload: WeeklyReviewPayload
  var createdAt: Date
  var updatedAt: Date

  static func id(forWeek weekKey: String) -> String {
    "review-\(weekKey)"
  }

  init(weekKey: String, weekStart: Date, completedAt: Date? = nil, payload: WeeklyReviewPayload = WeeklyReviewPayload(), createdAt: Date, updatedAt: Date) {
    self.id = Self.id(forWeek: weekKey)
    self.weekKey = weekKey
    self.weekStart = weekStart
    self.completedAt = completedAt
    self.payload = payload
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct WeeklyReviewPayload: Codable, Equatable {
  enum CarryChoice: String, Codable, CaseIterable {
    case monday
    case thisWeek
    case someday
    case drop

    var label: String {
      switch self {
      case .monday: return "Monday"
      case .thisWeek: return "This week"
      case .someday: return "Someday"
      case .drop: return "Drop"
      }
    }
  }

  /// One of up to three things picked for the week ahead.
  struct Pick: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var context: String
    var effect: String
    var findingId: String?
    /// The task it became, when it was written in rather than picked from a finding.
    var taskId: String?
  }

  /// Numbers kept with the review so its history reads the same after the data moves on.
  struct Snapshot: Codable, Equatable {
    struct GoalLine: Codable, Equatable {
      var goalId: String
      var title: String
      var status: String
    }

    var tasksDone = 0
    var focusHours: Double = 0
    var focusTarget: Double?
    var routineLines: [String] = []
    var goals: [GoalLine] = []
  }

  var keptLines: [String] = []
  var why = ""
  var carry: [String: CarryChoice] = [:]
  var goalNotes: [String: String] = [:]
  var pausedGoalIds: [String] = []
  var picks: [Pick] = []
  var findings: [WeeklyFinding] = []
  var actions: [WeeklyAcceptedAction] = []
  var feedback: [WeeklyFindingFeedback] = []
  var snapshot = Snapshot()
  var journalEntryId: String?
  /// Set when the findings' sentences came from the AI provider rather than Serenity's own text.
  var writtenByModel = false
  /// When the findings were worked out; zero findings is a valid result, so emptiness can't say this.
  var preparedAt: Date?

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keptLines = try container.decodeIfPresent([String].self, forKey: .keptLines) ?? []
    why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
    carry = try container.decodeIfPresent([String: CarryChoice].self, forKey: .carry) ?? [:]
    goalNotes = try container.decodeIfPresent([String: String].self, forKey: .goalNotes) ?? [:]
    pausedGoalIds = try container.decodeIfPresent([String].self, forKey: .pausedGoalIds) ?? []
    picks = try container.decodeIfPresent([Pick].self, forKey: .picks) ?? []
    findings = try container.decodeIfPresent([WeeklyFinding].self, forKey: .findings) ?? []
    actions = try container.decodeIfPresent([WeeklyAcceptedAction].self, forKey: .actions) ?? []
    feedback = try container.decodeIfPresent([WeeklyFindingFeedback].self, forKey: .feedback) ?? []
    snapshot = try container.decodeIfPresent(Snapshot.self, forKey: .snapshot) ?? Snapshot()
    journalEntryId = try container.decodeIfPresent(String.self, forKey: .journalEntryId)
    writtenByModel = try container.decodeIfPresent(Bool.self, forKey: .writtenByModel) ?? false
    preparedAt = try container.decodeIfPresent(Date.self, forKey: .preparedAt)
  }

  /// The accepted actions still in force.
  var liveActions: [WeeklyAcceptedAction] {
    actions.filter { $0.undoneAt == nil }
  }
}

/// An action taken from a finding, with what is needed to take it back.
struct WeeklyAcceptedAction: Codable, Equatable, Identifiable {
  enum Outcome: String, Codable {
    case held
    case partly
    case missed
  }

  var id: String
  var findingId: String?
  var kind: WeeklyFinding.Kind?
  var action: WeeklyAction
  var title: String
  var acceptedAt: Date
  var undoneAt: Date?
  /// Focus blocks this booked, so undo deletes exactly those.
  var focusBlockIds: [String] = []
  /// The task as it was, for actions that moved one.
  var previousDueDate: Date?
  var previousTags: [String]?
  var previousPausedUntil: Date?
  var outcome: Outcome?
  var outcomeText: String?
}

// MARK: - Storage

protocol WeeklyReviewRepository {
  func fetchAll() throws -> [WeeklyReviewEntity]
  func fetchByID(_ id: String) throws -> WeeklyReviewEntity?
  func save(_ review: WeeklyReviewEntity) throws
  func delete(id: String) throws
}

enum WeeklyReviewCodec {
  static func encode(_ payload: WeeklyReviewPayload) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(payload), as: UTF8.self)
  }

  static func decode(_ json: String?) -> WeeklyReviewPayload {
    guard let json, let data = json.data(using: .utf8) else { return WeeklyReviewPayload() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(WeeklyReviewPayload.self, from: data)
    } catch {
      AppLogger.error("Weekly review payload unreadable: \(error.localizedDescription)")
      return WeeklyReviewPayload()
    }
  }
}

final class GRDBWeeklyReviewRepository: WeeklyReviewRepository {
  let dbQueue: DatabaseQueue

  init(dbQueue: DatabaseQueue) {
    self.dbQueue = dbQueue
  }

  func fetchAll() throws -> [WeeklyReviewEntity] {
    try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM weekly_reviews ORDER BY week_start DESC;").map(Self.makeReview(from:))
    }
  }

  func fetchByID(_ id: String) throws -> WeeklyReviewEntity? {
    try dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM weekly_reviews WHERE id = ?;", arguments: [id]).map(Self.makeReview(from:))
    }
  }

  func save(_ review: WeeklyReviewEntity) throws {
    try dbQueue.write { db in
      try save(review, in: db)
    }
  }

  func save(_ review: WeeklyReviewEntity, in db: Database) throws {
    try db.execute(
      sql: """
      INSERT INTO weekly_reviews (id, week_key, week_start, completed_at, payload_json, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        week_key = excluded.week_key,
        week_start = excluded.week_start,
        completed_at = excluded.completed_at,
        payload_json = excluded.payload_json,
        updated_at = excluded.updated_at;
      """,
      arguments: [
        review.id,
        review.weekKey,
        CoreRepositoryCodec.encodeDate(review.weekStart),
        review.completedAt.map(CoreRepositoryCodec.encodeDate),
        try WeeklyReviewCodec.encode(review.payload),
        CoreRepositoryCodec.encodeDate(review.createdAt),
        CoreRepositoryCodec.encodeDate(review.updatedAt),
      ]
    )
  }

  func delete(id: String) throws {
    try dbQueue.write { db in
      try delete(id: id, in: db)
    }
  }

  func delete(id: String, in db: Database) throws {
    try db.execute(sql: "DELETE FROM weekly_reviews WHERE id = ?;", arguments: [id])
  }

  private static func makeReview(from row: Row) throws -> WeeklyReviewEntity {
    let completedAt: String? = row["completed_at"]
    var review = WeeklyReviewEntity(
      weekKey: row["week_key"],
      weekStart: try CoreRepositoryCodec.decodeDate(row["week_start"]),
      completedAt: try completedAt.map { try CoreRepositoryCodec.decodeDate($0) },
      payload: WeeklyReviewCodec.decode(row["payload_json"]),
      createdAt: try CoreRepositoryCodec.decodeDate(row["created_at"]),
      updatedAt: try CoreRepositoryCodec.decodeDate(row["updated_at"])
    )
    review.id = row["id"]
    return review
  }
}

final class SyncAwareWeeklyReviewRepository: WeeklyReviewRepository {
  private let underlying: GRDBWeeklyReviewRepository
  private let pendingStore: PendingSyncChangeStore

  init(underlying: GRDBWeeklyReviewRepository, pendingStore: PendingSyncChangeStore) {
    self.underlying = underlying
    self.pendingStore = pendingStore
  }

  func fetchAll() throws -> [WeeklyReviewEntity] {
    try underlying.fetchAll()
  }

  func fetchByID(_ id: String) throws -> WeeklyReviewEntity? {
    try underlying.fetchByID(id)
  }

  func save(_ review: WeeklyReviewEntity) throws {
    try underlying.dbQueue.write { db in
      try underlying.save(review, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.weeklyReview, entityId: review.id, operation: .upsert, in: db)
    }
  }

  func delete(id: String) throws {
    try underlying.dbQueue.write { db in
      try underlying.delete(id: id, in: db)
      try pendingStore.enqueue(entityType: SyncEntityType.weeklyReview, entityId: id, operation: .delete, in: db)
    }
  }

  func applyRemoteUpsert(_ review: WeeklyReviewEntity, in db: Database) throws {
    try underlying.save(review, in: db)
  }

  func applyRemoteDelete(id: String, in db: Database) throws {
    try underlying.delete(id: id, in: db)
  }
}
