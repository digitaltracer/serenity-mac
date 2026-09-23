import CloudKit
@testable import SerenityMac

/// A CloudKit private database in memory. Each server record has a version; a pushed record
/// carries the version it was built on (through its system fields), and a mismatch is answered
/// with `serverRecordChanged`, as `.ifServerRecordUnchanged` does. Only changed keys are stored,
/// so a key set to nil clears the server value.
final class FakeCloudDatabase: CloudSyncDatabase, @unchecked Sendable {
  private struct ServerRecord {
    var type: String
    var fields: [String: CKRecordValue]
    var version: Int
  }

  private struct LogEntry {
    var seq: Int
    var name: String
    var type: String
    var deleted: Bool
  }

  private var records: [String: ServerRecord] = [:]
  private var log: [LogEntry] = []
  private var seq = 0
  private var versions: [ObjectIdentifier: Int] = [:]
  private var tracked: [CKRecord] = []

  private(set) var zoneExists = false
  private(set) var zoneSaves = 0
  private(set) var modifyCalls = 0
  private(set) var conflictsReturned = 0
  /// Tokens older than this are answered with `changeTokenExpired`.
  var oldestValidToken = 0
  /// Every save fails with this error when set.
  var rejectSaves: Error?
  /// Runs once, in the middle of the next push: the moment a user edit can land mid-sync.
  var duringNextModify: (() throws -> Void)?

  // MARK: - Server-side helpers for tests

  var recordCount: Int { records.count }

  func value(_ key: String, of name: String) -> CKRecordValue? {
    records[name]?.fields[key]
  }

  func hasRecord(_ name: String) -> Bool {
    records[name] != nil
  }

  /// Another device's write.
  func serverPut(_ record: CKRecord) {
    zoneExists = true
    var fields = records[record.recordID.recordName]?.fields ?? [:]
    for key in record.allKeys() {
      fields[key] = record[key]
    }
    store(name: record.recordID.recordName, type: record.recordType, fields: fields)
  }

  func deleteZone() {
    zoneExists = false
    records = [:]
    log = []
  }

  // MARK: - CloudSyncDatabase

  func saveZone(_ zoneID: CKRecordZone.ID) async throws {
    zoneExists = true
    zoneSaves += 1
  }

  func saveSubscription(_ subscription: CKSubscription) async throws {
    guard zoneExists else { throw CKError(.zoneNotFound) }
  }

  func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> CloudSyncModifyResult {
    modifyCalls += 1
    if let hook = duringNextModify {
      duringNextModify = nil
      try hook()
    }
    guard zoneExists else {
      return CloudSyncModifyResult(saved: [], deleted: [], topLevelError: CKError(.zoneNotFound))
    }

    var saved: [(CKRecord.ID, Result<CKRecord, Error>)] = []
    for record in saving {
      let name = record.recordID.recordName
      if let rejectSaves {
        saved.append((record.recordID, .failure(rejectSaves)))
        continue
      }
      let base = versions[ObjectIdentifier(record)]
      if let existing = records[name], base != existing.version {
        conflictsReturned += 1
        let server = serverCopy(name)
        saved.append((record.recordID, .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))))
        continue
      }
      if records[name] == nil, base != nil {
        saved.append((record.recordID, .failure(CKError(.unknownItem))))
        continue
      }
      var fields = records[name]?.fields ?? [:]
      for key in record.changedKeys() {
        fields[key] = record[key]
      }
      store(name: name, type: record.recordType, fields: fields)
      saved.append((record.recordID, .success(serverCopy(name))))
    }

    var deleted: [(CKRecord.ID, Result<Void, Error>)] = []
    for recordID in deleting {
      guard let existing = records.removeValue(forKey: recordID.recordName) else {
        deleted.append((recordID, .failure(CKError(.unknownItem))))
        continue
      }
      seq += 1
      log.append(LogEntry(seq: seq, name: recordID.recordName, type: existing.type, deleted: true))
      deleted.append((recordID, .success(())))
    }

    return CloudSyncModifyResult(saved: saved, deleted: deleted, topLevelError: nil)
  }

  func fetchChanges(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudSyncZoneChanges {
    guard zoneExists else { throw CKError(.zoneNotFound) }
    let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    if token != nil, since < oldestValidToken {
      throw CKError(.changeTokenExpired)
    }

    var latest: [String: LogEntry] = [:]
    for entry in log where entry.seq > since {
      latest[entry.name] = entry
    }
    var changes = CloudSyncZoneChanges(changed: [], deleted: [], token: Data("\(seq)".utf8))
    for entry in latest.values.sorted(by: { $0.seq < $1.seq }) {
      if entry.deleted {
        changes.deleted.append((CKRecord.ID(recordName: entry.name, zoneID: zoneID), entry.type))
      } else if records[entry.name] != nil {
        changes.changed.append(serverCopy(entry.name))
      }
    }
    return changes
  }

  func record(type: String, id: CKRecord.ID, systemFields: Data?) -> CKRecord {
    let record = CKRecord(recordType: type, recordID: id)
    if let systemFields, let version = Int(String(decoding: systemFields, as: UTF8.self)) {
      track(record, version: version)
    }
    return record
  }

  func systemFields(of record: CKRecord) -> Data {
    Data("\(versions[ObjectIdentifier(record)] ?? 0)".utf8)
  }

  // MARK: - Internals

  private func store(name: String, type: String, fields: [String: CKRecordValue]) {
    let version = (records[name]?.version ?? 0) + 1
    records[name] = ServerRecord(type: type, fields: fields, version: version)
    seq += 1
    log.append(LogEntry(seq: seq, name: name, type: type, deleted: false))
  }

  private func serverCopy(_ name: String) -> CKRecord {
    let stored = records[name]!
    let record = CKRecord(recordType: stored.type, recordID: CKRecord.ID(recordName: name, zoneID: SerenityCloudKit.zoneID))
    for (key, value) in stored.fields {
      record[key] = value
    }
    track(record, version: stored.version)
    return record
  }

  private func track(_ record: CKRecord, version: Int) {
    tracked.append(record)
    versions[ObjectIdentifier(record)] = version
  }
}

struct FakeCloudContainer: ICloudSyncContainer {
  let database: FakeCloudDatabase

  func accountStatus() async throws -> CKAccountStatus {
    .available
  }

  func privateDatabase() -> CloudSyncDatabase {
    database
  }
}
