import CloudKit
import XCTest
@testable import SerenityMac

/// The engine against an in-memory CloudKit database and a real SQLite file.
final class ICloudSyncEngineTests: XCTestCase {
  private var directory: URL!
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-icloud-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  // MARK: - Edits during a push

  /// The push finishing deletes the row it read; the edit made meanwhile has a new id and stays.
  func testAnEditMadeDuringAPushSurvivesAndGoesOut() async throws {
    let fixture = try await makeFixture()
    try fixture.core.tasks.save(task("t1", title: "first", updatedAt: base))
    fixture.database.duringNextModify = {
      try fixture.core.tasks.save(self.task("t1", title: "edited mid-push", updatedAt: self.base))
    }

    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.value("title", of: "t1") as? String, "edited mid-push")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
  }

  func testADeleteMadeDuringAPushSurvivesAndGoesOut() async throws {
    let fixture = try await makeFixture()
    try fixture.core.tasks.save(task("t1", title: "first", updatedAt: base))
    fixture.database.duringNextModify = {
      try fixture.core.tasks.delete(id: "t1")
    }

    await fixture.engine.sync()

    XCTAssertFalse(fixture.database.hasRecord("t1"))
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
  }

  // MARK: - Applying pulled records

  func testAFailedApplyKeepsTheTokenAndIsRetried() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(brokenTask("bad"))
    fixture.database.serverPut(serverTask("good", title: "fine", updatedAt: base))

    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.tasks.fetchByID("good")?.title, "fine")
    XCTAssertNil(try token(fixture), "The token stays put while a record has not applied")

    await fixture.engine.sync()
    XCTAssertNil(try token(fixture))

    fixture.database.serverPut(serverTask("bad", title: "repaired", updatedAt: base))
    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.tasks.fetchByID("bad")?.title, "repaired")
    XCTAssertNotNil(try token(fixture))
    XCTAssertEqual(try fixture.core.cloudSyncRecords.setAsideCount(), 0)
  }

  func testARecordThatNeverAppliesIsSetAsideAndTheTokenAdvances() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(brokenTask("bad"))

    for _ in 0..<(ICloudSyncEngine.applyAttemptLimit - 1) {
      await fixture.engine.sync()
      XCTAssertNil(try token(fixture))
    }
    await fixture.engine.sync()

    XCTAssertNotNil(try token(fixture))
    XCTAssertEqual(try fixture.core.cloudSyncRecords.setAsideCount(), 1)
    guard case .succeeded(_, _, let setAside) = fixture.states.last else {
      return XCTFail("Expected a successful pass, got \(String(describing: fixture.states.last))")
    }
    XCTAssertEqual(setAside, 1)
  }

  /// A pending edit waiting out a retry delay meets a newer copy from another device.
  func testANewerRemoteEditBeatsAPendingLocalEditOnPull() async throws {
    let fixture = try await makeFixture()
    try fixture.core.tasks.save(task("t1", title: "local", updatedAt: base))
    let pending = try fixture.core.pendingSyncChanges.fetchPending(limit: 10)
    try fixture.core.pendingSyncChanges.markFailed(ids: pending.map(\.id), error: "offline")
    fixture.database.serverPut(serverTask("t1", title: "remote", updatedAt: base.addingTimeInterval(60)))

    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.tasks.fetchByID("t1")?.title, "remote")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
    XCTAssertEqual(fixture.applied.values["Task"], ["t1"])
  }

  func testAnOlderRemoteEditLosesToAPendingLocalEditOnPull() async throws {
    let fixture = try await makeFixture()
    try fixture.core.tasks.save(task("t1", title: "local", updatedAt: base.addingTimeInterval(60)))
    let pending = try fixture.core.pendingSyncChanges.fetchPending(limit: 10)
    try fixture.core.pendingSyncChanges.markFailed(ids: pending.map(\.id), error: "offline")
    fixture.database.serverPut(serverTask("t1", title: "remote", updatedAt: base))

    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.tasks.fetchByID("t1")?.title, "local")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 1)
  }

  /// The push is refused because the server moved on; the newer server copy is taken.
  func testANewerServerCopyWinsTheConflictOnPush() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(serverTask("t1", title: "remote", updatedAt: base.addingTimeInterval(60)))
    try fixture.core.tasks.save(task("t1", title: "local", updatedAt: base))

    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.conflictsReturned, 1)
    XCTAssertEqual(fixture.database.value("title", of: "t1") as? String, "remote")
    XCTAssertEqual(try fixture.core.tasks.fetchByID("t1")?.title, "remote")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
  }

  /// The local copy is read again when the conflict is settled, so an edit made after the push
  /// started is the one compared — and it wins over the older server copy.
  func testAnEditMadeWhileAConflictIsSettledIsNotLost() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(serverTask("t1", title: "server", updatedAt: base.addingTimeInterval(10)))
    try fixture.core.tasks.save(task("t1", title: "stale local", updatedAt: base))
    fixture.database.duringNextModify = {
      try fixture.core.tasks.save(self.task("t1", title: "mine", updatedAt: self.base.addingTimeInterval(120)))
    }

    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.conflictsReturned, 1)
    XCTAssertEqual(fixture.database.value("title", of: "t1") as? String, "mine")
    XCTAssertEqual(try fixture.core.tasks.fetchByID("t1")?.title, "mine")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
  }

  /// A pulled record is edited afterwards: the push is built on the pulled version, so it lands
  /// without a conflict and nothing reverts.
  func testEditingAPulledRecordDoesNotRevertIt() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(serverTask("t1", title: "from the phone", updatedAt: base))
    await fixture.engine.sync()
    XCTAssertEqual(fixture.applied.values["Task"], ["t1"])

    try fixture.core.tasks.save(task("t1", title: "edited on the mac", updatedAt: base.addingTimeInterval(30)))
    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.conflictsReturned, 0)
    XCTAssertEqual(fixture.database.value("title", of: "t1") as? String, "edited on the mac")
    XCTAssertEqual(try fixture.core.tasks.fetchByID("t1")?.title, "edited on the mac")
  }

  func testClearingADueDateClearsItOnTheServer() async throws {
    let fixture = try await makeFixture()
    try fixture.core.tasks.save(task("t1", title: "due", updatedAt: base, dueDate: base.addingTimeInterval(86_400)))
    await fixture.engine.sync()
    XCTAssertNotNil(fixture.database.value("dueDate", of: "t1"))

    try fixture.core.tasks.save(task("t1", title: "due", updatedAt: base.addingTimeInterval(10), dueDate: nil))
    await fixture.engine.sync()

    XCTAssertNil(fixture.database.value("dueDate", of: "t1"))
  }

  // MARK: - Draining

  func testMoreThanOneBatchDrainsInOneSync() async throws {
    let fixture = try await makeFixture()
    for index in 0..<450 {
      try fixture.core.tasks.save(task("t\(index)", title: "task \(index)", updatedAt: base))
    }

    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
    XCTAssertEqual(fixture.database.recordCount, 450)
    XCTAssertEqual(fixture.database.modifyCalls, 3)
  }

  func testAPassThatMakesNoProgressStops() async throws {
    let fixture = try await makeFixture()
    fixture.database.rejectSaves = CKError(.serverRejectedRequest)
    for index in 0..<5 {
      try fixture.core.tasks.save(task("t\(index)", title: "task", updatedAt: base))
    }

    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.modifyCalls, 1)
    let pending = try fixture.core.pendingSyncChanges.fetchPending(limit: 10)
    XCTAssertEqual(pending.count, 5)
    XCTAssertTrue(pending.allSatisfy { $0.attempts == 1 })
    XCTAssertTrue(try fixture.core.pendingSyncChanges.fetchDue(limit: 10).isEmpty, "Failed rows wait before the next try")
  }

  // MARK: - CloudKit errors

  func testADeletedZoneIsRecreatedAndEverythingExportedAgain() async throws {
    let fixture = try await makeFixture()
    for index in 0..<3 {
      try fixture.core.tasks.save(task("t\(index)", title: "task \(index)", updatedAt: base))
    }
    try fixture.exporter.enqueueIfNeeded()
    await fixture.engine.sync()
    XCTAssertEqual(fixture.database.recordCount, 3)

    fixture.database.deleteZone()
    try fixture.core.tasks.save(task("t0", title: "edited after the zone went", updatedAt: base.addingTimeInterval(5)))
    await fixture.engine.sync()

    XCTAssertEqual(fixture.database.zoneSaves, 2)
    XCTAssertEqual(fixture.database.recordCount, 3)
    XCTAssertEqual(fixture.database.value("title", of: "t0") as? String, "edited after the zone went")
    XCTAssertEqual(try fixture.core.pendingSyncChanges.count(), 0)
  }

  func testAnExpiredTokenTriggersAFullRefetch() async throws {
    let fixture = try await makeFixture()
    fixture.database.serverPut(serverTask("r1", title: "one", updatedAt: base))
    await fixture.engine.sync()
    XCTAssertNotNil(try token(fixture))

    fixture.database.serverPut(serverTask("r2", title: "two", updatedAt: base))
    fixture.database.oldestValidToken = 100
    await fixture.engine.sync()

    XCTAssertEqual(try fixture.core.tasks.fetchByID("r2")?.title, "two")
    guard case .succeeded = fixture.states.last else {
      return XCTFail("Expected a successful pass, got \(String(describing: fixture.states.last))")
    }
  }

  // MARK: - Helpers

  private struct Fixture {
    let core: GRDBCoreRepositorySet
    let exporter: CloudSyncInitialExporter
    let database: FakeCloudDatabase
    let engine: ICloudSyncEngine
    let applied: AppliedLog
    let states: StateLog
  }

  private func makeFixture() async throws -> Fixture {
    let adapter = SQLiteBackendAdapter(databaseURL: directory.appendingPathComponent("serenity.sqlite3"))
    _ = try await adapter.bootstrap()
    let core = try adapter.makeCoreRepositories()
    let ai = try adapter.makeAIRepositories(pendingStore: core.pendingSyncChanges)
    let exporter = CloudSyncInitialExporter(coreRepositories: core, aiRepositories: ai)
    let database = FakeCloudDatabase()
    let applied = AppliedLog()
    let states = StateLog()
    let engine = ICloudSyncEngine(
      container: FakeCloudContainer(database: database),
      pendingStore: core.pendingSyncChanges,
      stateStore: core.cloudSyncState,
      recordStore: core.cloudSyncRecords,
      recordKinds: [TaskSyncRecordKind(repository: core.tasks)],
      stateUpdate: { states.append($0) },
      changesApplied: { applied.merge($0) },
      zoneReset: { try exporter.enqueueIfNeeded() }
    )
    return Fixture(core: core, exporter: exporter, database: database, engine: engine, applied: applied, states: states)
  }

  private func token(_ fixture: Fixture) throws -> Data? {
    try fixture.core.cloudSyncState.loadValue(forKey: SerenityCloudKit.StateKey.serverChangeToken)
  }

  private func task(_ id: String, title: String, updatedAt: Date, dueDate: Date? = nil) -> TaskEntity {
    TaskEntity(
      id: id,
      title: title,
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: dueDate,
      projectId: nil,
      tags: [],
      createdAt: base,
      updatedAt: updatedAt,
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }

  private func serverTask(_ id: String, title: String, updatedAt: Date) -> CKRecord {
    let record = CKRecord(recordType: SyncEntityType.task, recordID: CKRecord.ID(recordName: id, zoneID: SerenityCloudKit.zoneID))
    try! TaskSyncRecordKind.encode(task(id, title: title, updatedAt: updatedAt), into: record)
    return record
  }

  /// No title: decoding it always fails.
  private func brokenTask(_ id: String) -> CKRecord {
    let record = CKRecord(recordType: SyncEntityType.task, recordID: CKRecord.ID(recordName: id, zoneID: SerenityCloudKit.zoneID))
    record["createdAt"] = base as CKRecordValue
    record["updatedAt"] = base as CKRecordValue
    return record
  }
}

private final class AppliedLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: Set<String>] = [:]

  var values: [String: Set<String>] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func merge(_ applied: [String: Set<String>]) {
    lock.lock()
    stored.merge(applied) { $0.union($1) }
    lock.unlock()
  }
}

private final class StateLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ICloudSyncState] = []

  var last: ICloudSyncState? {
    lock.lock()
    defer { lock.unlock() }
    return stored.last
  }

  func append(_ state: ICloudSyncState) {
    lock.lock()
    stored.append(state)
    lock.unlock()
  }
}
