import GRDB
import XCTest
@testable import SerenityMac

/// Core, Slack, AI and audit repositories write through the adapter's one queue.
final class SharedDatabaseQueueTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-shared-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  func testEveryRepositorySetSharesOneQueue() async throws {
    let adapter = try await bootstrappedAdapter()

    XCTAssertTrue(try adapter.databaseQueue() === adapter.databaseQueue())
  }

  func testConcurrentWritesFromEveryRepositorySetNeverLock() async throws {
    let adapter = try await bootstrappedAdapter()
    let core = try adapter.makeCoreRepositories()
    let slack = try adapter.makeSlackRepositories()
    let ai = try adapter.makeAIRepositories(pendingStore: core.pendingSyncChanges)
    let audit = try adapter.makeSecurityAuditRepository()
    let errors = ErrorLog()

    DispatchQueue.concurrentPerform(iterations: 80) { index in
      do {
        switch index % 4 {
        case 0:
          try core.tasks.save(Self.task(id: "t\(index)"))
        case 1:
          try slack.cursors.save([SlackChannelCursor(channelID: "C\(index)", channelName: "c", lastTS: "1.0")])
        case 2:
          try ai.modelRates.save(
            AIModelRateEntity(provider: .anthropic, model: "m\(index)", inputUSDPerMillion: 1, outputUSDPerMillion: 1, source: .seeded)
          )
        default:
          try audit.save(
            SecurityAuditEvent(id: "e\(index)", eventType: .backendSwitch, severity: .info, message: "m", metadata: [:], createdAt: Date())
          )
        }
      } catch {
        errors.append(error)
      }
    }

    XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
    XCTAssertEqual(try core.tasks.fetchAll().count, 20)
    XCTAssertEqual(try core.pendingSyncChanges.count(), 20)
    XCTAssertEqual(try audit.fetchRecent(limit: 100).count, 20)
  }

  /// An entity save and its pending change commit together, or neither does.
  func testALedgerFailureRollsTheEntityBack() async throws {
    let adapter = try await bootstrappedAdapter()
    let core = try adapter.makeCoreRepositories()
    try await adapter.databaseQueue().write { db in
      try db.execute(sql: """
        CREATE TRIGGER refuse_pending BEFORE INSERT ON pending_sync_changes
        BEGIN SELECT RAISE(ABORT, 'ledger unavailable'); END;
        """)
    }

    XCTAssertThrowsError(try core.tasks.save(Self.task(id: "t1")))

    XCTAssertNil(try core.tasks.fetchByID("t1"))
  }

  func testABackupTakenDuringWritesPassesIntegrityCheck() async throws {
    let adapter = try await bootstrappedAdapter()
    let core = try adapter.makeCoreRepositories()
    let backupsDirectory = directory.appendingPathComponent("backups", isDirectory: true)
    let writer = Thread {
      for index in 0..<300 {
        try? core.tasks.save(Self.task(id: "w\(index)"))
      }
    }
    writer.start()

    let summary = try adapter.createBackup(in: backupsDirectory)

    let backup = try DatabaseQueue(path: summary.backupPath)
    let check = try await backup.read { try String.fetchOne($0, sql: "PRAGMA integrity_check;") }
    XCTAssertEqual(check, "ok")
    let copied = try await backup.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks;") }
    XCTAssertNotNil(copied)
  }

  func testMigrationsRunOncePerLaunch() async throws {
    let adapter = SQLiteBackendAdapter(databaseURL: directory.appendingPathComponent("serenity.sqlite3"))

    let first = try await adapter.bootstrap()
    let second = try await adapter.bootstrap()

    XCTAssertFalse(first.appliedMigrations.isEmpty)
    XCTAssertTrue(second.appliedMigrations.isEmpty)
    XCTAssertEqual(second.skippedMigrations.count, first.appliedMigrations.count + first.skippedMigrations.count)
  }

  // MARK: - Helpers

  private func bootstrappedAdapter() async throws -> SQLiteBackendAdapter {
    let adapter = SQLiteBackendAdapter(databaseURL: directory.appendingPathComponent("serenity.sqlite3"))
    _ = try await adapter.bootstrap()
    return adapter
  }

  private static func task(id: String) -> TaskEntity {
    TaskEntity(
      id: id,
      title: "Task \(id)",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: [],
      createdAt: Date(),
      updatedAt: Date(),
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }
}

private final class ErrorLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Error] = []

  var values: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func append(_ error: Error) {
    lock.lock()
    stored.append(error)
    lock.unlock()
  }
}
