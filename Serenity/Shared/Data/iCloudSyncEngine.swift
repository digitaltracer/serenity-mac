import Foundation
import CloudKit

/// User-visible sync status, surfaced through `AppState` and any settings UI.
enum ICloudSyncState: Equatable, Sendable {
  case idle
  case unavailable(reason: String)
  case syncing
  case succeeded(at: Date, pending: Int)
  case failed(message: String)
}

/// Interface that wraps `CKContainer` + private DB. Real impl forwards to
/// `CKContainer.default()`; tests can substitute a fake.
protocol ICloudSyncContainer: Sendable {
  func accountStatus() async throws -> CKAccountStatus
  func privateDatabase() -> CKDatabase
}

struct LiveICloudSyncContainer: ICloudSyncContainer {
  let container: CKContainer
  init(identifier: String = SerenityCloudKit.containerIdentifier) {
    self.container = CKContainer(identifier: identifier)
  }
  func accountStatus() async throws -> CKAccountStatus {
    try await container.accountStatus()
  }
  func privateDatabase() -> CKDatabase {
    container.privateCloudDatabase
  }
}

/// Drives Task + Journal sync with CloudKit. One actor-confined engine per
/// app. Owns: zone bootstrap, change-token persistence, push subscription,
/// pending-change drain, incremental pull. Conflicts resolve by `updatedAt`
/// (newest wins), matching the existing remote-backend policy.
actor ICloudSyncEngine {
  private let container: ICloudSyncContainer
  private let pendingStore: PendingSyncChangeStore
  private let stateStore: CloudSyncStateStore
  private let recordKinds: [String: SyncRecordKind]
  private let stateUpdate: @Sendable (ICloudSyncState) -> Void
  private let logger: (@Sendable (String) -> Void)?
  private var inFlight = false

  init(
    container: ICloudSyncContainer = LiveICloudSyncContainer(),
    pendingStore: PendingSyncChangeStore,
    stateStore: CloudSyncStateStore,
    recordKinds: [SyncRecordKind],
    stateUpdate: @escaping @Sendable (ICloudSyncState) -> Void,
    logger: (@Sendable (String) -> Void)? = nil
  ) {
    self.container = container
    self.pendingStore = pendingStore
    self.stateStore = stateStore
    self.recordKinds = Dictionary(uniqueKeysWithValues: recordKinds.map { ($0.entityType, $0) })
    self.stateUpdate = stateUpdate
    self.logger = logger
  }

  /// One-shot sync: account-status check → ensure zone + subscription → push
  /// pending changes → pull remote changes. Coalesces concurrent calls so
  /// only one round-trip is in flight at any time.
  func sync() async {
    guard !inFlight else { return }
    inFlight = true
    defer { inFlight = false }

    stateUpdate(.syncing)

    do {
      let status = try await container.accountStatus()
      guard status == .available else {
        let reason = describe(accountStatus: status)
        stateUpdate(.unavailable(reason: reason))
        return
      }

      try await ensureZone()
      try await ensureSubscription()
      try await pushPending()
      try await pullChanges()

      let pending = (try? pendingStore.count()) ?? 0
      stateUpdate(.succeeded(at: Date(), pending: pending))
    } catch {
      logger?("iCloud sync failed: \(error.localizedDescription)")
      stateUpdate(.failed(message: error.localizedDescription))
    }
  }

  // MARK: - Bootstrap

  private func ensureZone() async throws {
    if let stored = try stateStore.loadValue(forKey: SerenityCloudKit.StateKey.zoneCreated),
       String(data: stored, encoding: .utf8) == "1" {
      return
    }

    let zone = CKRecordZone(zoneID: SerenityCloudKit.zoneID)
    let database = container.privateDatabase()

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
      op.modifyRecordZonesResultBlock = { result in
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
      database.add(op)
    }

    try stateStore.saveValue(Data("1".utf8), forKey: SerenityCloudKit.StateKey.zoneCreated)
  }

  private func ensureSubscription() async throws {
    if let stored = try stateStore.loadValue(forKey: SerenityCloudKit.StateKey.subscriptionCreated),
       String(data: stored, encoding: .utf8) == "1" {
      return
    }

    let subscription = CKRecordZoneSubscription(
      zoneID: SerenityCloudKit.zoneID,
      subscriptionID: SerenityCloudKit.zoneSubscriptionID
    )
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info

    let database = container.privateDatabase()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
      op.modifySubscriptionsResultBlock = { result in
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
      database.add(op)
    }

    try stateStore.saveValue(Data("1".utf8), forKey: SerenityCloudKit.StateKey.subscriptionCreated)
  }

  // MARK: - Push

  private func pushPending() async throws {
    let batch = try pendingStore.fetchPending(limit: 200)
    guard !batch.isEmpty else { return }

    var recordsToSave: [CKRecord] = []
    var recordIDsToDelete: [CKRecord.ID] = []
    var changeIDByRecordName: [String: String] = [:]
    var changeIDByDeleteName: [String: String] = [:]

    for change in batch {
      guard let kind = recordKinds[change.entityType] else { continue }

      switch change.operation {
      case .upsert:
        if let record = try kind.makeRecord(forID: change.entityId) {
          recordsToSave.append(record)
          changeIDByRecordName[record.recordID.recordName] = change.id
        } else {
          // Local row vanished after the upsert was queued; demote to delete.
          let recordID = CKRecord.ID(recordName: change.entityId, zoneID: SerenityCloudKit.zoneID)
          recordIDsToDelete.append(recordID)
          changeIDByDeleteName[change.entityId] = change.id
        }
      case .delete:
        let recordID = CKRecord.ID(recordName: change.entityId, zoneID: SerenityCloudKit.zoneID)
        recordIDsToDelete.append(recordID)
        changeIDByDeleteName[change.entityId] = change.id
      }
    }

    guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else {
      // Every change resolved to a no-op (e.g. unknown entity types). Drop them
      // so we don't loop on the same batch.
      try pendingStore.markCompleted(ids: batch.map(\.id))
      return
    }

    let database = container.privateDatabase()
    let result = try await modifyRecords(
      database: database,
      recordsToSave: recordsToSave,
      recordIDsToDelete: recordIDsToDelete
    )

    var completedIDs: [String] = []
    var failedIDs: [String] = []
    var conflictMerges: [CKRecord] = []

    for (recordID, recordResult) in result.savedResults {
      let changeID = changeIDByRecordName[recordID.recordName]
      switch recordResult {
      case .success:
        if let changeID { completedIDs.append(changeID) }
      case .failure(let error as CKError) where error.code == .serverRecordChanged:
        // CloudKit returned the server copy; pick whichever is newest.
        if let serverRecord = error.serverRecord,
           let local = recordsToSave.first(where: { $0.recordID == recordID }) {
          if let merged = mergedRecord(local: local, server: serverRecord) {
            conflictMerges.append(merged)
          }
        }
        if let changeID { failedIDs.append(changeID) }
      case .failure:
        if let changeID { failedIDs.append(changeID) }
      }
    }

    for (recordID, deleteResult) in result.deletedResults {
      let changeID = changeIDByDeleteName[recordID.recordName]
      switch deleteResult {
      case .success:
        if let changeID { completedIDs.append(changeID) }
      case .failure:
        if let changeID { failedIDs.append(changeID) }
      }
    }

    try pendingStore.markCompleted(ids: completedIDs)
    if !failedIDs.isEmpty {
      try pendingStore.markFailed(
        ids: failedIDs,
        error: result.topLevelError?.localizedDescription ?? "partial failure"
      )
    }

    // Re-push merged conflict winners on the next round; their pending row was
    // already (re-)enqueued via `markFailed` above, but if the merge wants
    // local to win we re-enqueue explicitly to make sure it goes out.
    for merged in conflictMerges {
      try? pendingStore.enqueue(
        entityType: merged.recordType,
        entityId: merged.recordID.recordName,
        operation: .upsert
      )
    }
  }

  private struct ModifyResult {
    let savedResults: [(CKRecord.ID, Result<CKRecord, Error>)]
    let deletedResults: [(CKRecord.ID, Result<Void, Error>)]
    let topLevelError: Error?
  }

  private func modifyRecords(
    database: CKDatabase,
    recordsToSave: [CKRecord],
    recordIDsToDelete: [CKRecord.ID]
  ) async throws -> ModifyResult {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ModifyResult, Error>) in
      let op = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
      op.savePolicy = .changedKeys
      op.qualityOfService = .userInitiated

      var savedResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
      var deletedResults: [(CKRecord.ID, Result<Void, Error>)] = []

      op.perRecordSaveBlock = { recordID, result in
        savedResults.append((recordID, result))
      }
      op.perRecordDeleteBlock = { recordID, result in
        deletedResults.append((recordID, result))
      }
      op.modifyRecordsResultBlock = { result in
        switch result {
        case .success:
          continuation.resume(returning: ModifyResult(
            savedResults: savedResults,
            deletedResults: deletedResults,
            topLevelError: nil
          ))
        case .failure(let error):
          continuation.resume(returning: ModifyResult(
            savedResults: savedResults,
            deletedResults: deletedResults,
            topLevelError: error
          ))
        }
      }

      database.add(op)
    }
  }

  /// Returns the record that should be re-saved to win the conflict. Falls
  /// back to nil when neither side has an `updatedAt` we can compare.
  private func mergedRecord(local: CKRecord, server: CKRecord) -> CKRecord? {
    let localUpdated = local["updatedAt"] as? Date
    let serverUpdated = server["updatedAt"] as? Date
    switch (localUpdated, serverUpdated) {
    case (let l?, let s?) where l > s:
      return local
    default:
      // Server is newer (or we can't tell) — accept it; it'll be applied via
      // the next pull.
      return nil
    }
  }

  // MARK: - Pull

  private func pullChanges() async throws {
    let token = try loadServerChangeToken()
    let database = container.privateDatabase()
    let zoneID = SerenityCloudKit.zoneID

    var newToken: CKServerChangeToken? = token

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
      configuration.previousServerChangeToken = token

      let op = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [zoneID],
        configurationsByRecordZoneID: [zoneID: configuration]
      )
      op.fetchAllChanges = true

      op.recordWasChangedBlock = { [recordKinds, logger] _, result in
        switch result {
        case .success(let record):
          if let kind = recordKinds[record.recordType] {
            do {
              try kind.applyPulled(record)
            } catch {
              logger?("apply pulled \(record.recordType) failed: \(error.localizedDescription)")
            }
          }
        case .failure(let error):
          logger?("recordWasChanged error: \(error.localizedDescription)")
        }
      }

      op.recordWithIDWasDeletedBlock = { [recordKinds, logger] recordID, recordType in
        guard let kind = recordKinds[recordType] else { return }
        do {
          try kind.applyPulledDelete(recordName: recordID.recordName)
        } catch {
          logger?("apply pulled delete failed: \(error.localizedDescription)")
        }
      }

      op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
        newToken = token
      }

      op.recordZoneFetchResultBlock = { _, result in
        if case .success(let payload) = result {
          newToken = payload.serverChangeToken
        }
      }

      op.fetchRecordZoneChangesResultBlock = { result in
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      database.add(op)
    }

    try saveServerChangeToken(newToken)
  }

  private func loadServerChangeToken() throws -> CKServerChangeToken? {
    guard let data = try stateStore.loadValue(forKey: SerenityCloudKit.StateKey.serverChangeToken) else {
      return nil
    }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
  }

  private func saveServerChangeToken(_ token: CKServerChangeToken?) throws {
    guard let token else {
      try stateStore.saveValue(nil, forKey: SerenityCloudKit.StateKey.serverChangeToken)
      return
    }
    let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    try stateStore.saveValue(data, forKey: SerenityCloudKit.StateKey.serverChangeToken)
  }

  // MARK: - Helpers

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
