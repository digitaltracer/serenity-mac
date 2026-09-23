import Foundation
import GRDB

struct SQLiteBackendDiagnostics: Equatable, Sendable {
  let databasePath: String
  let isBootstrapped: Bool
}

struct SQLiteBackupSummary: Equatable, Sendable {
  let sourcePath: String
  let backupPath: String
}

/// Owns the one `DatabaseQueue` for its file. Core, Slack, AI and audit repositories all write
/// through it, so writers queue behind each other instead of failing with "database is locked".
final class SQLiteBackendAdapter {
  let profile: BackendProfile = .sqliteLocal

  private let migrationRunner: DatabaseMigrationRunner
  private var configuredDatabaseURL: URL?
  private var lastBootstrapPath: String?
  private let lock = NSLock()
  private var sharedQueue: DatabaseQueue?
  private var bootstrapSummary: MigrationRunSummary?

  init(
    migrationRunner: DatabaseMigrationRunner = DatabaseMigrationRunner(),
    databaseURL: URL? = nil
  ) {
    self.migrationRunner = migrationRunner
    self.configuredDatabaseURL = databaseURL
  }

  /// Migrations run once per launch; later calls report nothing newly applied.
  func bootstrap() async throws -> MigrationRunSummary {
    try lock.withLock {
      if let bootstrapSummary {
        return MigrationRunSummary(
          databasePath: bootstrapSummary.databasePath,
          appliedMigrations: [],
          skippedMigrations: DatabaseMigrationRunner.migrationIdentifiers
        )
      }

      let databaseURL = try configuredDatabaseURL ?? DatabaseMigrationRunner.defaultDatabaseURL()
      configuredDatabaseURL = databaseURL
      let queue = try openSharedQueue(at: databaseURL)
      let summary = try migrationRunner.migrate(queue, databasePath: databaseURL.path)
      bootstrapSummary = summary
      lastBootstrapPath = summary.databasePath
      return summary
    }
  }

  func databaseQueue() throws -> DatabaseQueue {
    try lock.withLock {
      try openSharedQueue(at: URL(fileURLWithPath: try requireDatabasePath()))
    }
  }

  func makeCoreRepositories() throws -> GRDBCoreRepositorySet {
    GRDBCoreRepositorySet.make(dbQueue: try databaseQueue())
  }

  func makeAIRepositories(pendingStore: PendingSyncChangeStore? = nil) throws -> GRDBAIRepositorySet {
    GRDBAIRepositorySet.make(dbQueue: try databaseQueue(), pendingStore: pendingStore)
  }

  /// Slack cursors and proposals are device-local, so they never go through
  /// the sync-aware decorators the core repositories use.
  func makeSlackRepositories() throws -> GRDBSlackRepositorySet {
    GRDBSlackRepositorySet(dbQueue: try databaseQueue())
  }

  func makeGitHubImportLedger() throws -> GRDBGitHubImportLedger {
    GRDBGitHubImportLedger(dbQueue: try databaseQueue())
  }

  func makeSecurityAuditRepository() throws -> GRDBSecurityAuditRepository {
    GRDBSecurityAuditRepository(dbQueue: try databaseQueue())
  }

  /// Called with `lock` held.
  private func openSharedQueue(at databaseURL: URL) throws -> DatabaseQueue {
    if let sharedQueue, sharedQueue.path == databaseURL.path {
      return sharedQueue
    }
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let queue = try DatabaseQueue(path: databaseURL.path, configuration: DatabaseMigrationRunner.configuration())
    sharedQueue = queue
    return queue
  }

  func diagnostics() throws -> SQLiteBackendDiagnostics {
    let path = try requireDatabasePath()
    return SQLiteBackendDiagnostics(databasePath: path, isBootstrapped: lastBootstrapPath != nil)
  }

  func currentDatabasePath() throws -> String {
    try requireDatabasePath()
  }

  func runQuickIntegrityCheck() throws -> String {
    try databaseQueue().read { db in
      try String.fetchOne(db, sql: "PRAGMA quick_check;") ?? "unknown"
    }
  }

  func createBackup() throws -> SQLiteBackupSummary {
    let applicationSupportDirectory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let backupsDirectory = applicationSupportDirectory
      .appendingPathComponent("Serenity", isDirectory: true)
      .appendingPathComponent("backups", isDirectory: true)
    return try createBackup(in: backupsDirectory)
  }

  /// SQLite's online backup, not a file copy: a copy taken mid-write can capture half a transaction.
  func createBackup(in backupsDirectory: URL) throws -> SQLiteBackupSummary {
    let sourcePath = try requireDatabasePath()
    let sourceURL = URL(fileURLWithPath: sourcePath)
    try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let timestamp = formatter.string(from: Date())

    let destinationURL = backupsDirectory.appendingPathComponent("serenity-\(timestamp).sqlite")
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    let destination = try DatabaseQueue(path: destinationURL.path)
    try databaseQueue().backup(to: destination)
    try destination.close()
    return SQLiteBackupSummary(sourcePath: sourceURL.path, backupPath: destinationURL.path)
  }

  private func requireDatabasePath() throws -> String {
    if let lastBootstrapPath {
      return lastBootstrapPath
    }

    if let configuredDatabaseURL {
      return configuredDatabaseURL.path
    }

    return try DatabaseMigrationRunner.defaultDatabaseURL().path
  }
}
