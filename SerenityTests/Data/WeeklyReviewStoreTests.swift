import CloudKit
import Foundation
import GRDB
import XCTest
@testable import SerenityMac

final class WeeklyReviewStoreTests: XCTestCase {
  private let weekStart = Date(timeIntervalSince1970: 1_794_182_400)
  private let now = Date(timeIntervalSince1970: 1_794_816_000)

  private func review() -> WeeklyReviewEntity {
    var payload = WeeklyReviewPayload()
    payload.keptLines = ["Agency: Hero copy; Revisions"]
    payload.why = "Agency crowded it out"
    payload.carry = ["task-1": .monday, "task-2": .drop]
    payload.goalNotes = ["goal-1": "Waiting on review"]
    payload.pausedGoalIds = ["goal-2"]
    payload.picks = [WeeklyReviewPayload.Pick(id: "pick-1", title: "Two focus blocks", context: "Ship", effect: "Books both", findingId: "goalAtRisk:goal-1", taskId: nil)]
    payload.findings = [WeeklyFinding(
      id: "stuckTask:task-1",
      kind: .stuckTask,
      subjectId: "task-1",
      linked: "Agency",
      title: "Stuck",
      body: "Moved 3 times",
      evidenceLabel: "Evidence: 1 task history",
      evidence: [WeeklyEvidence(source: .task, ref: "task-1", date: weekStart, when: "4 Nov", what: "Created", meta: "task")],
      action: .firstOnToday(taskId: "task-1"),
      actionTitle: "Make it first on Today",
      score: 2
    )]
    payload.actions = [WeeklyAcceptedAction(
      id: "goalAtRisk:goal-1",
      findingId: "goalAtRisk:goal-1",
      kind: .goalAtRisk,
      action: .bookFocus(title: "Ship focus", goalId: "goal-1", slots: [DateInterval(start: now, duration: 5_400)]),
      title: "Book Tue 17",
      acceptedAt: now,
      focusBlockIds: ["block-1"]
    )]
    payload.feedback = [WeeklyFindingFeedback(findingId: "quietArea:goal-3", kind: .quietArea, reason: .fineThisWeek, weekStart: weekStart)]
    payload.snapshot.tasksDone = 23
    payload.snapshot.focusHours = 11.5
    return WeeklyReviewEntity(weekKey: "2026-W46", weekStart: weekStart, completedAt: now, payload: payload, createdAt: now, updatedAt: now)
  }

  private var databasePath = ""

  private func makeRepositories() async throws -> GRDBCoreRepositorySet {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-review-tests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")
    _ = try await DatabaseMigrationRunner().bootstrapDatabase(at: databaseURL)
    databasePath = databaseURL.path
    return try GRDBCoreRepositorySet.make(databasePath: databaseURL.path)
  }

  func testIdComesFromTheWeekSoDevicesShareOneRecord() {
    XCTAssertEqual(review().id, "review-2026-W46")
  }

  func testRepositoryRoundTripsTheWholePayload() async throws {
    let repositories = try await makeRepositories()
    let saved = review()

    try repositories.weeklyReviews.save(saved)

    XCTAssertEqual(try repositories.weeklyReviews.fetchByID(saved.id), saved)
    XCTAssertEqual(try repositories.weeklyReviews.fetchAll().map(\.id), [saved.id])
  }

  func testSavingAndDeletingQueueSyncButRemoteWritesDoNot() async throws {
    let repositories = try await makeRepositories()
    let saved = review()

    try repositories.weeklyReviews.save(saved)
    let pending = try repositories.pendingSyncChanges.fetchPending(limit: 10)
    XCTAssertEqual(pending.map(\.entityType), [SyncEntityType.weeklyReview])
    XCTAssertEqual(pending.first?.entityId, saved.id)

    try repositories.pendingSyncChanges.markCompleted(ids: pending.map(\.id))
    try repositories.weeklyReviews.delete(id: saved.id)
    XCTAssertEqual(try repositories.pendingSyncChanges.fetchPending(limit: 10).first?.operation, .delete)

    try repositories.pendingSyncChanges.markCompleted(ids: try repositories.pendingSyncChanges.fetchPending(limit: 10).map(\.id))
    let kind = WeeklyReviewSyncRecordKind(repository: repositories.weeklyReviews)
    let record = CKRecord(recordType: SyncEntityType.weeklyReview, recordID: CKRecord.ID(recordName: saved.id, zoneID: SerenityCloudKit.zoneID))
    try WeeklyReviewSyncRecordKind.encode(saved, into: record)
    let queue = try DatabaseQueue(path: databasePath, configuration: DatabaseMigrationRunner.configuration())
    try await queue.write { db in try kind.applyPulled(record, in: db) }

    XCTAssertEqual(try repositories.pendingSyncChanges.count(), 0)
    XCTAssertEqual(try repositories.weeklyReviews.fetchByID(saved.id), saved)
  }

  func testCloudKitRecordRoundTripsEveryField() throws {
    let saved = review()
    let record = CKRecord(recordType: SyncEntityType.weeklyReview, recordID: CKRecord.ID(recordName: saved.id, zoneID: SerenityCloudKit.zoneID))

    try WeeklyReviewSyncRecordKind.encode(saved, into: record)

    XCTAssertEqual(Set(record.allKeys()), ["weekKey", "weekStart", "completedAt", "payloadJSON", "createdAt", "updatedAt"])
    XCTAssertEqual(try WeeklyReviewSyncRecordKind.decode(record), saved)
  }

  func testPayloadFromAnOlderOrNewerAppStillReads() {
    let partial = WeeklyReviewCodec.decode(#"{"why":"Busy week","somethingNew":true}"#)
    XCTAssertEqual(partial.why, "Busy week")
    XCTAssertTrue(partial.actions.isEmpty)

    XCTAssertEqual(WeeklyReviewCodec.decode("not json"), WeeklyReviewPayload())
    XCTAssertEqual(WeeklyReviewCodec.decode(nil), WeeklyReviewPayload())
  }

  func testLiveActionsLeaveOutUndoneOnes() {
    var payload = review().payload
    var undone = payload.actions[0]
    undone.id = "other"
    undone.undoneAt = now
    payload.actions.append(undone)

    XCTAssertEqual(payload.liveActions.map(\.id), ["goalAtRisk:goal-1"])
  }

  func testInitialExportQueuesReviews() async throws {
    let repositories = try await makeRepositories()
    try repositories.weeklyReviews.save(review())
    try repositories.pendingSyncChanges.markCompleted(ids: try repositories.pendingSyncChanges.fetchPending(limit: 10).map(\.id))
    let aiRepositories = try GRDBAIRepositorySet.make(databasePath: databasePath, pendingStore: repositories.pendingSyncChanges)

    try CloudSyncInitialExporter(coreRepositories: repositories, aiRepositories: aiRepositories).enqueueIfNeeded()

    XCTAssertTrue(try repositories.pendingSyncChanges.fetchPending(limit: 10).contains { $0.entityType == SyncEntityType.weeklyReview })
  }

  @MainActor
  func testAppStateLoadsAndSavesReviews() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-review-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let suiteName = "serenity.review.state.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: { .unavailable(reason: "not configured") },
        .externalPostgres: { .unavailable(reason: "not configured") },
      ]
    )
    let makeState = {
      AppState(
        backendProfileManager: BackendProfileManager(defaults: defaults, defaultsKey: "review.backend", registry: registry),
        sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
        serenityCloudAdapter: nil,
        externalPostgresAdapter: nil
      )
    }

    let state = makeState()
    await state.bootstrapLocalDatabase()
    await state.refreshCoreWorkflowData()
    XCTAssertTrue(state.weeklyReviews.isEmpty)

    let saved = await state.saveWeeklyReview(review(), now: now)
    XCTAssertTrue(saved)
    XCTAssertEqual(state.weeklyReview(forWeek: "2026-W46")?.payload.why, "Agency crowded it out")

    let reopened = makeState()
    await reopened.bootstrapLocalDatabase()
    await reopened.refreshCoreWorkflowData()
    XCTAssertEqual(reopened.weeklyReviews.map(\.id), ["review-2026-W46"])
  }
}
