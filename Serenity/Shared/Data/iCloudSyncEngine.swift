import Foundation
import CloudKit
import GRDB

/// User-visible sync status, surfaced through `AppState` and any settings UI.
enum ICloudSyncState: Equatable, Sendable {
  case idle
  case unavailable(reason: String)
  case syncing
  /// `setAside` counts pulled records that kept failing to apply and are no longer retried.
  case succeeded(at: Date, pending: Int, setAside: Int)
  case failed(message: String)
}

/// Interface that wraps `CKContainer` + private DB. Real impl forwards to
/// `CKContainer.default()`; tests can substitute a fake.
protocol ICloudSyncContainer: Sendable {
  func accountStatus() async throws -> CKAccountStatus
  func privateDatabase() -> CloudSyncDatabase
}

struct LiveICloudSyncContainer: ICloudSyncContainer {
  let container: CKContainer
  init(identifier: String = SerenityCloudKit.containerIdentifier) {
    self.container = CKContainer(identifier: identifier)
  }
  func accountStatus() async throws -> CKAccountStatus {
    try await container.accountStatus()
  }
  func privateDatabase() -> CloudSyncDatabase {
    LiveCloudSyncDatabase(database: container.privateCloudDatabase)
  }
}

/// The CloudKit calls the engine makes, so it can run against a fake server in tests.
protocol CloudSyncDatabase: Sendable {
  func saveZone(_ zoneID: CKRecordZone.ID) async throws
  func saveSubscription(_ subscription: CKSubscription) async throws
  /// Saves only records whose server copy is unchanged since the one they were built from.
  func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CloudSyncModifyResult
  /// `token` is an archived change token, opaque to the engine.
  func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudSyncZoneChanges
  /// A record to push, built on the last server copy's system fields when there is one.
  func record(type: String, id: CKRecord.ID, systemFields: Data?) -> CKRecord
  func systemFields(of record: CKRecord) -> Data
}

struct CloudSyncModifyResult {
  var saved: [(CKRecord.ID, Result<CKRecord, Error>)]
  var deleted: [(CKRecord.ID, Result<Void, Error>)]
  var topLevelError: Error?
}

struct CloudSyncZoneChanges {
  var changed: [CKRecord]
  var deleted: [(id: CKRecord.ID, type: String)]
  var token: Data?
}

struct LiveCloudSyncDatabase: CloudSyncDatabase, @unchecked Sendable {
  let database: CKDatabase

  func saveZone(_ zoneID: CKRecordZone.ID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let op = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zoneID)], recordZoneIDsToDelete: nil)
      op.modifyRecordZonesResultBlock = { result in
        continuation.resume(with: result)
      }
      database.add(op)
    }
  }

  func saveSubscription(_ subscription: CKSubscription) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
      op.modifySubscriptionsResultBlock = { result in
        continuation.resume(with: result)
      }
      database.add(op)
    }
  }

  func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CloudSyncModifyResult {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudSyncModifyResult, Error>) in
      let op = CKModifyRecordsOperation(recordsToSave: saving, recordIDsToDelete: deleting)
      op.savePolicy = .ifServerRecordUnchanged
      op.qualityOfService = .userInitiated

      var saved: [(CKRecord.ID, Result<CKRecord, Error>)] = []
      var deleted: [(CKRecord.ID, Result<Void, Error>)] = []

      op.perRecordSaveBlock = { recordID, result in
        saved.append((recordID, result))
      }
      op.perRecordDeleteBlock = { recordID, result in
        deleted.append((recordID, result))
      }
      op.modifyRecordsResultBlock = { result in
        var topLevelError: Error?
        if case .failure(let error) = result {
          topLevelError = error
        }
        continuation.resume(returning: CloudSyncModifyResult(saved: saved, deleted: deleted, topLevelError: topLevelError))
      }

      database.add(op)
    }
  }

  func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudSyncZoneChanges {
    let previous = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CloudSyncZoneChanges, Error>) in
      let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
      configuration.previousServerChangeToken = previous

      let op = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [zoneID],
        configurationsByRecordZoneID: [zoneID: configuration]
      )
      op.fetchAllChanges = true

      var changes = CloudSyncZoneChanges(changed: [], deleted: [], token: token)
      var zoneError: Error?

      op.recordWasChangedBlock = { _, result in
        if case .success(let record) = result {
          changes.changed.append(record)
        }
      }
      op.recordWithIDWasDeletedBlock = { recordID, recordType in
        changes.deleted.append((recordID, recordType))
      }
      // Per-zone failures such as `zoneNotFound` and `changeTokenExpired` arrive here, not below.
      op.recordZoneFetchResultBlock = { _, result in
        switch result {
        case .success(let payload):
          changes.token = try? NSKeyedArchiver.archivedData(
            withRootObject: payload.serverChangeToken,
            requiringSecureCoding: true
          )
        case .failure(let error):
          zoneError = error
        }
      }
      op.fetchRecordZoneChangesResultBlock = { result in
        if let zoneError {
          continuation.resume(throwing: zoneError)
          return
        }
        switch result {
        case .success:
          continuation.resume(returning: changes)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      database.add(op)
    }
  }

  func record(type: String, id: CKRecord.ID, systemFields: Data?) -> CKRecord {
    if let systemFields,
       let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
      unarchiver.requiresSecureCoding = true
      if let record = CKRecord(coder: unarchiver), record.recordID == id, record.recordType == type {
        return record
      }
    }
    return CKRecord(recordType: type, recordID: id)
  }

  func systemFields(of record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }
}

/// Drives sync of every registered record kind with CloudKit. One actor-confined engine per app.
/// Owns: zone bootstrap, change-token persistence, push subscription, pending-change drain,
/// incremental pull. A conflict goes to the newer `updatedAt`, re-read at the moment of deciding,
/// so an edit made while a sync runs is never overwritten by an older copy.
actor ICloudSyncEngine {
  /// A pulled record that fails this many times is set aside so the change token can advance.
  static let applyAttemptLimit = 5
  static let pushBatchSize = 200
  private static let maxPushPasses = 50

  private let container: ICloudSyncContainer
  private let pendingStore: PendingSyncChangeStore
  private let stateStore: CloudSyncStateStore
  private let recordStore: GRDBCloudSyncRecordStore
  private let recordKinds: [String: SyncRecordKind]
  private let stateUpdate: @Sendable (ICloudSyncState) -> Void
  private let changesApplied: (@Sendable ([String: Set<String>]) -> Void)?
  private let zoneReset: (@Sendable () async throws -> Void)?
  private let logger: (@Sendable (String) -> Void)?
  private var inFlight = false
  private var rerunRequested = false
  private var appliedThisPass: [String: Set<String>] = [:]

  init(
    container: ICloudSyncContainer = LiveICloudSyncContainer(),
    pendingStore: PendingSyncChangeStore,
    stateStore: CloudSyncStateStore,
    recordStore: GRDBCloudSyncRecordStore,
    recordKinds: [SyncRecordKind],
    stateUpdate: @escaping @Sendable (ICloudSyncState) -> Void,
    changesApplied: (@Sendable ([String: Set<String>]) -> Void)? = nil,
    zoneReset: (@Sendable () async throws -> Void)? = nil,
    logger: (@Sendable (String) -> Void)? = nil
  ) {
    self.container = container
    self.pendingStore = pendingStore
    self.stateStore = stateStore
    self.recordStore = recordStore
    self.recordKinds = Dictionary(uniqueKeysWithValues: recordKinds.map { ($0.entityType, $0) })
    self.stateUpdate = stateUpdate
    self.changesApplied = changesApplied
    self.zoneReset = zoneReset
    self.logger = logger
  }

  func registeredEntityTypes() -> Set<String> {
    Set(recordKinds.keys)
  }

  /// Account check → zone + subscription → push pending changes → pull remote changes. A call made
  /// while a sync runs is not dropped: it queues one more pass, so an edit made mid-sync goes out.
  func sync() async {
    guard !inFlight else {
      rerunRequested = true
      return
    }
    inFlight = true
    defer { inFlight = false }

    repeat {
      rerunRequested = false
      await runPass()
    } while rerunRequested
  }

  private func runPass() async {
    stateUpdate(.syncing)
    appliedThisPass = [:]

    do {
      let status = try await container.accountStatus()
      guard status == .available else {
        stateUpdate(.unavailable(reason: describe(accountStatus: status)))
        return
      }

      let database = container.privateDatabase()
      do {
        try await syncOnce(database)
      } catch where Self.isZoneGone(error) {
        logger?("iCloud zone is gone; recreating it and exporting everything again")
        try await resetZone()
        try await syncOnce(database)
      }

      if !appliedThisPass.isEmpty {
        changesApplied?(appliedThisPass)
      }
      let pending = (try? pendingStore.count()) ?? 0
      let setAside = (try? recordStore.setAsideCount()) ?? 0
      stateUpdate(.succeeded(at: Date(), pending: pending, setAside: setAside))
    } catch {
      if !appliedThisPass.isEmpty {
        changesApplied?(appliedThisPass)
      }
      logger?("iCloud sync failed: \(error.localizedDescription)")
      stateUpdate(.failed(message: error.localizedDescription))
    }
  }

  private func syncOnce(_ database: CloudSyncDatabase) async throws {
    try await ensureZone(database)
    try await ensureSubscription(database)
    try await pushPending(database)
    try await pullChanges(database)
  }

  // MARK: - Bootstrap

  private func ensureZone(_ database: CloudSyncDatabase) async throws {
    guard try !flag(SerenityCloudKit.StateKey.zoneCreated) else { return }
    try await database.saveZone(SerenityCloudKit.zoneID)
    try stateStore.saveValue(Data("1".utf8), forKey: SerenityCloudKit.StateKey.zoneCreated)
  }

  private func ensureSubscription(_ database: CloudSyncDatabase) async throws {
    guard try !flag(SerenityCloudKit.StateKey.subscriptionCreated) else { return }

    let subscription = CKRecordZoneSubscription(
      zoneID: SerenityCloudKit.zoneID,
      subscriptionID: SerenityCloudKit.zoneSubscriptionID
    )
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info

    try await database.saveSubscription(subscription)
    try stateStore.saveValue(Data("1".utf8), forKey: SerenityCloudKit.StateKey.subscriptionCreated)
  }

  /// A deleted zone takes the subscription, every server copy and the change history with it, so
  /// all of it is forgotten and every local record is queued again.
  private func resetZone() async throws {
    for key in [
      SerenityCloudKit.StateKey.zoneCreated,
      SerenityCloudKit.StateKey.subscriptionCreated,
      SerenityCloudKit.StateKey.serverChangeToken,
      SerenityCloudKit.StateKey.initialExportCompleted,
    ] {
      try stateStore.saveValue(nil, forKey: key)
    }
    try recordStore.deleteAllSystemFields()
    try await zoneReset?()
  }

  private func flag(_ key: String) throws -> Bool {
    guard let stored = try stateStore.loadValue(forKey: key) else { return false }
    return String(data: stored, encoding: .utf8) == "1"
  }

  // MARK: - Push

  /// Drains the queue in batches until it is empty, and stops early when a pass makes no progress
  /// so a server that rejects everything cannot keep the loop spinning.
  private func pushPending(_ database: CloudSyncDatabase) async throws {
    for _ in 0..<Self.maxPushPasses {
      let batch = try pendingStore.fetchDue(limit: Self.pushBatchSize)
      guard !batch.isEmpty else { return }
      guard try await pushBatch(batch, database) else { return }
    }
  }

  /// Returns whether anything moved: a row completed, or a conflict was settled for the next pass.
  private func pushBatch(_ batch: [PendingSyncChange], _ database: CloudSyncDatabase) async throws -> Bool {
    var recordsToSave: [CKRecord] = []
    var recordIDsToDelete: [CKRecord.ID] = []
    var changeByRecordName: [String: PendingSyncChange] = [:]
    var unknown: [String] = []

    for change in batch {
      guard let kind = recordKinds[change.entityType] else {
        unknown.append(change.id)
        continue
      }
      let recordID = CKRecord.ID(recordName: change.entityId, zoneID: SerenityCloudKit.zoneID)
      changeByRecordName[change.entityId] = change

      switch change.operation {
      case .upsert:
        let base = database.record(
          type: kind.entityType,
          id: recordID,
          systemFields: try recordStore.systemFields(entityType: kind.entityType, entityId: change.entityId)
        )
        if try kind.encodeLocal(id: change.entityId, into: base) {
          recordsToSave.append(base)
        } else {
          // Local row vanished after the upsert was queued; demote to delete.
          recordIDsToDelete.append(recordID)
        }
      case .delete:
        recordIDsToDelete.append(recordID)
      }
    }

    // Changes for types this build does not sync would otherwise come back every pass.
    try pendingStore.markCompleted(ids: unknown)
    guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return !unknown.isEmpty }

    let result = try await database.modifyRecords(saving: recordsToSave, deleting: recordIDsToDelete)

    let perRecordErrors = result.saved.compactMap { $0.1.failure } + result.deleted.compactMap { $0.1.failure }
    if let zoneError = ([result.topLevelError].compactMap { $0 } + perRecordErrors).first(where: Self.isZoneGone) {
      throw zoneError
    }

    var completed: [String] = []
    var failed: [String] = []
    var settled = 0
    var answered: Set<String> = []

    for (recordID, outcome) in result.saved {
      guard let change = changeByRecordName[recordID.recordName], let kind = recordKinds[change.entityType] else { continue }
      answered.insert(recordID.recordName)
      switch outcome {
      case .success(let saved):
        try storeSystemFields(database.systemFields(of: saved), kind: kind, id: change.entityId)
        completed.append(change.id)
      case .failure(let error as CKError) where error.code == .serverRecordChanged && error.serverRecord != nil:
        try resolveConflict(server: error.serverRecord!, kind: kind, database: database)
        settled += 1
      case .failure(let error as CKError) where error.code == .unknownItem:
        // The server copy this push was built on is gone; the next pass creates it afresh.
        try forgetSystemFields(kind: kind, id: change.entityId)
        settled += 1
      case .failure:
        failed.append(change.id)
      }
    }

    for (recordID, outcome) in result.deleted {
      guard let change = changeByRecordName[recordID.recordName], let kind = recordKinds[change.entityType] else { continue }
      answered.insert(recordID.recordName)
      switch outcome {
      case .success:
        completed.append(change.id)
      case .failure(let error as CKError) where error.code == .unknownItem:
        completed.append(change.id)
      case .failure:
        failed.append(change.id)
        continue
      }
      try forgetSystemFields(kind: kind, id: change.entityId)
    }

    // A top-level failure (offline, throttled) answers no record individually.
    for (name, change) in changeByRecordName where !answered.contains(name) {
      failed.append(change.id)
    }

    try pendingStore.markCompleted(ids: completed)
    if !failed.isEmpty {
      try pendingStore.markFailed(ids: failed, error: result.topLevelError?.localizedDescription ?? "partial failure")
    }
    if let topLevelError = result.topLevelError, answered.isEmpty {
      throw topLevelError
    }
    return !completed.isEmpty || settled > 0 || !unknown.isEmpty
  }

  private func storeSystemFields(_ fields: Data, kind: SyncRecordKind, id: String) throws {
    try recordStore.dbQueue.write { db in
      try recordStore.saveSystemFields(fields, entityType: kind.entityType, entityId: id, in: db)
    }
  }

  private func forgetSystemFields(kind: SyncRecordKind, id: String) throws {
    try recordStore.dbQueue.write { db in
      try recordStore.deleteSystemFields(entityType: kind.entityType, entityId: id, in: db)
    }
  }

  /// CloudKit refused a save because the server copy moved on. The local record and its pending
  /// row are read again now, not taken from when the push started, so an edit made in between is
  /// the one compared. The newer side wins; a local win stays queued and goes out on the next pass,
  /// built on the server copy just received.
  private func resolveConflict(server: CKRecord, kind: SyncRecordKind, database: CloudSyncDatabase) throws {
    let id = server.recordID.recordName
    let fields = database.systemFields(of: server)
    let serverUpdatedAt = server["updatedAt"] as? Date

    let appliedRemote = try recordStore.dbQueue.write { db -> Bool in
      try recordStore.saveSystemFields(fields, entityType: kind.entityType, entityId: id, in: db)
      let pending = try pendingStore.pendingChange(entityType: kind.entityType, entityId: id, in: db)
      let localStamp = try pending?.operation == .delete ? pending?.queuedAt : kind.localUpdatedAt(id: id, in: db)
      guard Self.remote(serverUpdatedAt, isNewerThan: localStamp) else { return false }
      try kind.applyPulled(server, in: db)
      if let pending {
        try pendingStore.deletePending(id: pending.id, in: db)
      }
      return true
    }
    if appliedRemote {
      appliedThisPass[kind.entityType, default: []].insert(id)
    }
  }

  // MARK: - Pull

  /// The change token is saved only once every record in the batch has applied or been set aside;
  /// otherwise the next pull fetches the same changes again.
  private func pullChanges(_ database: CloudSyncDatabase) async throws {
    let token = try stateStore.loadValue(forKey: SerenityCloudKit.StateKey.serverChangeToken)
    let changes: CloudSyncZoneChanges
    do {
      changes = try await database.fetchChanges(in: SerenityCloudKit.zoneID, since: token)
    } catch let error as CKError where error.code == .changeTokenExpired {
      logger?("iCloud change token expired; fetching everything again")
      try stateStore.saveValue(nil, forKey: SerenityCloudKit.StateKey.serverChangeToken)
      changes = try await database.fetchChanges(in: SerenityCloudKit.zoneID, since: nil)
    }

    var settled = true

    for record in changes.changed {
      guard let kind = recordKinds[record.recordType] else { continue }
      let id = record.recordID.recordName
      do {
        if try applyPulled(record, kind: kind, database: database) {
          appliedThisPass[kind.entityType, default: []].insert(id)
        }
      } catch {
        settled = try noteApplyFailure(kind: kind, id: id, error: error) && settled
      }
    }

    for deletion in changes.deleted {
      guard let kind = recordKinds[deletion.type] else { continue }
      let id = deletion.id.recordName
      do {
        if try applyPulledDelete(id: id, kind: kind) {
          appliedThisPass[kind.entityType, default: []].insert(id)
        }
      } catch {
        settled = try noteApplyFailure(kind: kind, id: id, error: error) && settled
      }
    }

    if settled {
      try stateStore.saveValue(changes.token, forKey: SerenityCloudKit.StateKey.serverChangeToken)
    }
  }

  /// Returns whether the record is now set aside, which lets the token move past it.
  private func noteApplyFailure(kind: SyncRecordKind, id: String, error: Error) throws -> Bool {
    let attempts = try recordStore.recordApplyFailure(
      entityType: kind.entityType,
      entityId: id,
      error: error.localizedDescription,
      setAsideAfter: Self.applyAttemptLimit
    )
    logger?("apply pulled \(kind.entityType) \(id) failed (attempt \(attempts)): \(error.localizedDescription)")
    return attempts >= Self.applyAttemptLimit
  }

  /// A pending local edit is compared with the pulled copy and the newer one kept; without one,
  /// the pulled copy applies unless the local row is newer. All of it in one transaction, so an
  /// edit cannot slip in between the check and the write.
  private func applyPulled(_ record: CKRecord, kind: SyncRecordKind, database: CloudSyncDatabase) throws -> Bool {
    let id = record.recordID.recordName
    let remoteUpdatedAt = record["updatedAt"] as? Date
    let fields = database.systemFields(of: record)

    return try recordStore.dbQueue.write { db -> Bool in
      if let pending = try pendingStore.pendingChange(entityType: kind.entityType, entityId: id, in: db) {
        let localStamp = try pending.operation == .delete ? pending.queuedAt : kind.localUpdatedAt(id: id, in: db)
        guard Self.remote(remoteUpdatedAt, isNewerThan: localStamp) else {
          // The local edit wins and will be pushed over this server copy.
          try recordStore.saveSystemFields(fields, entityType: kind.entityType, entityId: id, in: db)
          try recordStore.clearApplyFailure(entityType: kind.entityType, entityId: id, in: db)
          return false
        }
        try kind.applyPulled(record, in: db)
        try pendingStore.deletePending(id: pending.id, in: db)
      } else {
        if let local = try kind.localUpdatedAt(id: id, in: db),
           let remoteUpdatedAt,
           remoteUpdatedAt < local {
          try recordStore.clearApplyFailure(entityType: kind.entityType, entityId: id, in: db)
          return false
        }
        try kind.applyPulled(record, in: db)
      }
      try recordStore.saveSystemFields(fields, entityType: kind.entityType, entityId: id, in: db)
      try recordStore.clearApplyFailure(entityType: kind.entityType, entityId: id, in: db)
      return true
    }
  }

  /// A pending local edit outlives a remote delete and recreates the record when it is pushed.
  private func applyPulledDelete(id: String, kind: SyncRecordKind) throws -> Bool {
    try recordStore.dbQueue.write { db -> Bool in
      try recordStore.deleteSystemFields(entityType: kind.entityType, entityId: id, in: db)
      try recordStore.clearApplyFailure(entityType: kind.entityType, entityId: id, in: db)
      let pending = try pendingStore.pendingChange(entityType: kind.entityType, entityId: id, in: db)
      if pending?.operation == .upsert {
        return false
      }
      try kind.applyPulledDelete(recordName: id, in: db)
      if let pending {
        try pendingStore.deletePending(id: pending.id, in: db)
      }
      return true
    }
  }

  // MARK: - Helpers

  private static func remote(_ remote: Date?, isNewerThan local: Date?) -> Bool {
    guard let remote else { return false }
    guard let local else { return true }
    return remote > local
  }

  static func isZoneGone(_ error: Error) -> Bool {
    guard let error = error as? CKError else { return false }
    if error.code == .zoneNotFound || error.code == .userDeletedZone {
      return true
    }
    if error.code == .partialFailure {
      return error.partialErrorsByItemID?.values.contains { isZoneGone($0) } ?? false
    }
    return false
  }

  private func describe(accountStatus: CKAccountStatus) -> String {
    switch accountStatus {
    case .available: return "available"
    case .noAccount: return "No iCloud account is signed in."
    case .restricted: return "iCloud access is restricted on this device."
    case .couldNotDetermine: return "iCloud account status could not be determined."
    case .temporarilyUnavailable: return "iCloud is temporarily unavailable."
    @unknown default: return "iCloud is unavailable."
    }
  }
}

private extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
