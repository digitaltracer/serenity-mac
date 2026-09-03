import Foundation
import GRDB
import XCTest
@testable import SerenityMac

final class DatabaseMigrationRunnerTests: XCTestCase {
  func testBootstrapAppliesInitialMigrationsOnFreshDatabase() async throws {
    let databaseURL = try makeTemporaryDatabaseURL()
    let runner = DatabaseMigrationRunner()

    let summary = try await runner.bootstrapDatabase(at: databaseURL)

    XCTAssertEqual(summary.appliedMigrations.count, 8)
    XCTAssertTrue(summary.skippedMigrations.isEmpty)

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    let tables = try await dbQueue.read { db in
      Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table';"))
    }
    let indexes = try await dbQueue.read { db in
      Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index';"))
    }

    XCTAssertTrue(tables.contains("grdb_migrations"))
    XCTAssertTrue(tables.contains("tasks"))
    XCTAssertTrue(tables.contains("projects"))
    XCTAssertTrue(tables.contains("journal_entries"))
    XCTAssertTrue(tables.contains("goals"))
    XCTAssertTrue(tables.contains("app_metadata"))
    XCTAssertTrue(tables.contains("secure_settings"))
    XCTAssertTrue(tables.contains("ai_insights"))
    XCTAssertTrue(tables.contains("ai_recaps"))
    XCTAssertTrue(tables.contains("ai_usage"))
    XCTAssertTrue(tables.contains("summaries"))
    XCTAssertTrue(tables.contains("ai_provider_credentials"))
    XCTAssertTrue(tables.contains("ai_model_rates"))
    XCTAssertTrue(tables.contains("security_audit_events"))
    XCTAssertTrue(tables.contains("pending_sync_changes"))
    XCTAssertTrue(tables.contains("cloud_sync_state"))
    XCTAssertTrue(indexes.contains("idx_tasks_project_id"))
    XCTAssertTrue(indexes.contains("idx_journal_date"))
    XCTAssertTrue(indexes.contains("idx_goals_status"))
    XCTAssertTrue(indexes.contains("idx_ai_insights_created_at"))
    XCTAssertTrue(indexes.contains("idx_ai_recaps_created_at"))
    XCTAssertTrue(indexes.contains("idx_ai_usage_timestamp"))
    XCTAssertTrue(indexes.contains("idx_ai_usage_model"))
    XCTAssertTrue(indexes.contains("idx_ai_model_rates_provider_model"))
    XCTAssertTrue(indexes.contains("idx_summaries_type"))
    XCTAssertTrue(indexes.contains("idx_ai_credentials_provider"))
    XCTAssertTrue(indexes.contains("idx_security_audit_created_at"))

    let usageColumns = try await dbQueue.read { db in
      Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('ai_usage');"))
    }
    XCTAssertTrue(usageColumns.contains("model"))
    XCTAssertTrue(usageColumns.contains("input_cost_usd"))
    XCTAssertTrue(usageColumns.contains("output_cost_usd"))
    XCTAssertTrue(usageColumns.contains("total_cost_usd"))
  }

  func testBootstrapIsIdempotentForExistingDatabase() async throws {
    let databaseURL = try makeTemporaryDatabaseURL()
    let runner = DatabaseMigrationRunner()

    _ = try await runner.bootstrapDatabase(at: databaseURL)
    let secondRun = try await runner.bootstrapDatabase(at: databaseURL)

    XCTAssertTrue(secondRun.appliedMigrations.isEmpty)
    XCTAssertEqual(secondRun.skippedMigrations.count, 8)
  }

  func testNvidiaIsAcceptedByEveryProviderConstrainedTable() async throws {
    let databaseURL = try makeTemporaryDatabaseURL()
    let runner = DatabaseMigrationRunner()
    _ = try await runner.bootstrapDatabase(at: databaseURL)

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    try await dbQueue.write { db in
      for statement in Self.nvidiaRowInserts {
        try db.execute(sql: statement)
      }
    }

    for (table, statement) in Self.unknownProviderRowInserts {
      do {
        try await dbQueue.write { db in try db.execute(sql: statement) }
        XCTFail("\(table) accepted an unknown provider value")
      } catch {
        // Expected: the widened CHECK still rejects anything outside the enum.
      }
    }
  }

  func testWideningProviderConstraintPreservesExistingRows() async throws {
    let databaseURL = try makeTemporaryDatabaseURL()
    try seedPreNvidiaDatabase(at: databaseURL)

    let summary = try await DatabaseMigrationRunner().bootstrapDatabase(at: databaseURL)
    XCTAssertEqual(summary.appliedMigrations, ["20260901_008_nvidia_provider"])

    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    let insight = try await dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM ai_insights WHERE id = 'insight-1';")
    }
    let insightRow = try XCTUnwrap(insight)
    XCTAssertEqual(insightRow["provider"] as String?, "anthropic")
    XCTAssertEqual(insightRow["title"] as String?, "Kept title")
    XCTAssertEqual(insightRow["confidence"] as Double?, 0.75)
    XCTAssertEqual(insightRow["occurrence_number"] as Int?, 3)

    let usage = try await dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM ai_usage WHERE id = 'usage-1';")
    }
    let usageRow = try XCTUnwrap(usage)
    XCTAssertEqual(usageRow["model"] as String?, "gpt-5.4")
    XCTAssertEqual(usageRow["total_tokens"] as Int?, 300)
    XCTAssertEqual(usageRow["total_cost_usd"] as Double?, 0.0042)

    let credential = try await dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM ai_provider_credentials WHERE id = 'cred-1';")
    }
    let credentialRow = try XCTUnwrap(credential)
    XCTAssertEqual(credentialRow["name"] as String?, "Work key")
    XCTAssertEqual(credentialRow["total_requests"] as Int?, 12)

    let rate = try await dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM ai_model_rates WHERE id = 'rate-1';")
    }
    XCTAssertEqual(try XCTUnwrap(rate)["output_usd_per_million"] as Double?, 15.0)

    let recapCount = try await dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_recaps;")
    }
    XCTAssertEqual(recapCount, 1)

    let summaryCount = try await dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries;")
    }
    XCTAssertEqual(summaryCount, 1)

    let indexes = try await dbQueue.read { db in
      Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index';"))
    }
    XCTAssertTrue(indexes.contains("idx_ai_insights_created_at"))
    XCTAssertTrue(indexes.contains("idx_ai_insights_theme_id"))
    XCTAssertTrue(indexes.contains("idx_ai_recaps_type"))
    XCTAssertTrue(indexes.contains("idx_ai_usage_timestamp"))
    XCTAssertTrue(indexes.contains("idx_ai_usage_model"))
    XCTAssertTrue(indexes.contains("idx_summaries_date_range"))
    XCTAssertTrue(indexes.contains("idx_ai_credentials_priority"))
    XCTAssertTrue(indexes.contains("idx_ai_model_rates_provider_model"))

    let uniqueCredentialInsert = """
      INSERT INTO ai_provider_credentials (id, provider, name, api_key_encrypted, created_at, updated_at)
      VALUES ('cred-2', 'openai', 'Work key', 'keychain://x', '2026-09-01', '2026-09-01');
      """
    do {
      try await dbQueue.write { db in try db.execute(sql: uniqueCredentialInsert) }
      XCTFail("ai_provider_credentials lost its UNIQUE(provider, name) constraint")
    } catch {
      // Expected.
    }
  }

  // MARK: - Fixtures

  private static let nvidiaRowInserts = [
    """
    INSERT INTO ai_insights (id, provider, type, title, description, category, created_at, updated_at)
    VALUES ('nim-insight', 'nvidia', 'productivity', 'T', 'D', 'tasks', '2026-09-01', '2026-09-01');
    """,
    """
    INSERT INTO ai_recaps (id, provider, type, title, summary, period, created_at, updated_at)
    VALUES ('nim-recap', 'nvidia', 'weekly', 'T', 'S', '2026-W36', '2026-09-01', '2026-09-01');
    """,
    """
    INSERT INTO ai_usage (id, timestamp, provider, operation)
    VALUES ('nim-usage', '2026-09-01', 'nvidia', 'quickadd');
    """,
    """
    INSERT INTO summaries (id, title, content, summary_type, start_date, end_date, generated_at, provider, created_at, updated_at)
    VALUES ('nim-summary', 'T', 'C', 'tasks', '2026-09-01', '2026-09-01', '2026-09-01', 'nvidia', '2026-09-01', '2026-09-01');
    """,
    """
    INSERT INTO ai_provider_credentials (id, provider, name, api_key_encrypted, created_at, updated_at)
    VALUES ('nim-cred', 'nvidia', 'NIM', 'keychain://nim', '2026-09-01', '2026-09-01');
    """,
    """
    INSERT INTO ai_model_rates (id, provider, model, updated_at)
    VALUES ('nim-rate', 'nvidia', 'meta/llama-3.1-70b-instruct', '2026-09-01');
    """,
  ]

  private static let unknownProviderRowInserts: [(String, String)] = [
    ("ai_insights", """
      INSERT INTO ai_insights (id, provider, type, title, description, category, created_at, updated_at)
      VALUES ('bogus-insight', 'mystery', 'productivity', 'T', 'D', 'tasks', '2026-09-01', '2026-09-01');
      """),
    ("ai_recaps", """
      INSERT INTO ai_recaps (id, provider, type, title, summary, period, created_at, updated_at)
      VALUES ('bogus-recap', 'mystery', 'weekly', 'T', 'S', '2026-W36', '2026-09-01', '2026-09-01');
      """),
    ("ai_usage", """
      INSERT INTO ai_usage (id, timestamp, provider, operation)
      VALUES ('bogus-usage', '2026-09-01', 'mystery', 'quickadd');
      """),
    ("summaries", """
      INSERT INTO summaries (id, title, content, summary_type, start_date, end_date, generated_at, provider, created_at, updated_at)
      VALUES ('bogus-summary', 'T', 'C', 'tasks', '2026-09-01', '2026-09-01', '2026-09-01', 'mystery', '2026-09-01', '2026-09-01');
      """),
    ("ai_provider_credentials", """
      INSERT INTO ai_provider_credentials (id, provider, name, api_key_encrypted, created_at, updated_at)
      VALUES ('bogus-cred', 'mystery', 'X', 'keychain://x', '2026-09-01', '2026-09-01');
      """),
    ("ai_model_rates", """
      INSERT INTO ai_model_rates (id, provider, model, updated_at)
      VALUES ('bogus-rate', 'mystery', 'x', '2026-09-01');
      """),
  ]

  /// Rebuilds the schema as it stood after migration 007 — the narrow provider CHECKs plus a row
  /// in every table 008 rebuilds — then marks 001…007 applied so only 008 runs.
  private func seedPreNvidiaDatabase(at databaseURL: URL) throws {
    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    try dbQueue.write { db in
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);")
      for identifier in [
        "20260214_001_core_entities",
        "20260214_002_bootstrap_metadata",
        "20260214_003_core_schema_parity",
        "20260214_004_ai_entities",
        "20260215_005_security_audit_events",
        "20260505_006_cloudkit_sync_state",
        "20260517_007_ai_cost_center",
      ] {
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?);", arguments: [identifier])
      }

      try db.execute(sql: """
        CREATE TABLE app_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        """)
      try db.execute(sql: "INSERT INTO app_metadata (key, value) VALUES ('schema_version', '6');")

      try db.execute(sql: """
        CREATE TABLE ai_insights (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'local')),
          type TEXT NOT NULL CHECK (type IN ('productivity', 'behavior', 'recommendation', 'warning')),
          title TEXT NOT NULL,
          description TEXT NOT NULL,
          confidence REAL DEFAULT 0.5,
          category TEXT NOT NULL CHECK (category IN ('tasks', 'journal', 'habits', 'goals')),
          actionable INTEGER DEFAULT 0,
          metadata TEXT DEFAULT '{}',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          user_rating INTEGER CHECK (user_rating >= 1 AND user_rating <= 5),
          dismissed INTEGER DEFAULT 0,
          marked_helpful INTEGER DEFAULT 0,
          user_notes TEXT,
          visualization_data TEXT,
          actionability_suggestions TEXT DEFAULT '[]',
          theme_id TEXT,
          is_recurring INTEGER DEFAULT 0,
          occurrence_number INTEGER DEFAULT 1
        );
        """)
      try db.execute(sql: """
        CREATE TABLE ai_recaps (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'local')),
          type TEXT NOT NULL CHECK (type IN ('weekly', 'monthly')),
          title TEXT NOT NULL,
          summary TEXT NOT NULL,
          highlights TEXT DEFAULT '[]',
          challenges TEXT DEFAULT '[]',
          recommendations TEXT DEFAULT '[]',
          period TEXT NOT NULL,
          metadata TEXT DEFAULT '{}',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          viewed INTEGER DEFAULT 0,
          favorited INTEGER DEFAULT 0,
          exported INTEGER DEFAULT 0
        );
        """)
      try db.execute(sql: """
        CREATE TABLE ai_usage (
          id TEXT PRIMARY KEY,
          timestamp TEXT NOT NULL,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic')),
          operation TEXT NOT NULL CHECK (operation IN ('analyze', 'recap', 'quickadd', 'summary')),
          prompt_tokens INTEGER DEFAULT 0,
          completion_tokens INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0,
          model TEXT,
          input_cost_usd REAL,
          output_cost_usd REAL,
          total_cost_usd REAL
        );
        """)
      try db.execute(sql: """
        CREATE TABLE summaries (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          summary_type TEXT NOT NULL CHECK(summary_type IN ('tasks', 'journal', 'combined')),
          start_date TEXT NOT NULL,
          end_date TEXT NOT NULL,
          generated_at TEXT NOT NULL,
          word_count INTEGER,
          metadata TEXT DEFAULT '{}',
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'local')),
          prompt_tokens INTEGER DEFAULT 0,
          completion_tokens INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """)
      try db.execute(sql: """
        CREATE TABLE ai_provider_credentials (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic')),
          name TEXT NOT NULL,
          api_key_encrypted TEXT NOT NULL,
          model_preference TEXT,
          enabled INTEGER DEFAULT 1,
          priority INTEGER DEFAULT 0,
          metadata TEXT DEFAULT '{}',
          last_used_at TEXT,
          total_requests INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0,
          success_count INTEGER DEFAULT 0,
          error_count INTEGER DEFAULT 0,
          last_error TEXT,
          last_error_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(provider, name)
        );
        """)
      try db.execute(sql: """
        CREATE TABLE ai_model_rates (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic')),
          model TEXT NOT NULL,
          input_usd_per_million REAL NOT NULL DEFAULT 0,
          output_usd_per_million REAL NOT NULL DEFAULT 0,
          source TEXT NOT NULL DEFAULT 'seeded' CHECK (source IN ('seeded', 'user', 'litellm')),
          updated_at TEXT NOT NULL,
          UNIQUE(provider, model)
        );
        """)

      try db.execute(sql: """
        INSERT INTO ai_insights (id, provider, type, title, description, confidence, category, created_at, updated_at, theme_id, occurrence_number)
        VALUES ('insight-1', 'anthropic', 'productivity', 'Kept title', 'Kept body', 0.75, 'tasks', '2026-08-01', '2026-08-02', 'theme-a', 3);
        """)
      try db.execute(sql: """
        INSERT INTO ai_recaps (id, provider, type, title, summary, period, created_at, updated_at)
        VALUES ('recap-1', 'gemini', 'weekly', 'Recap', 'Body', '2026-W31', '2026-08-01', '2026-08-01');
        """)
      try db.execute(sql: """
        INSERT INTO ai_usage (id, timestamp, provider, operation, prompt_tokens, completion_tokens, total_tokens, model, input_cost_usd, output_cost_usd, total_cost_usd)
        VALUES ('usage-1', '2026-08-01', 'openai', 'quickadd', 200, 100, 300, 'gpt-5.4', 0.0005, 0.0037, 0.0042);
        """)
      try db.execute(sql: """
        INSERT INTO summaries (id, title, content, summary_type, start_date, end_date, generated_at, provider, created_at, updated_at)
        VALUES ('summary-1', 'Summary', 'Body', 'combined', '2026-08-01', '2026-08-07', '2026-08-07', 'local', '2026-08-07', '2026-08-07');
        """)
      try db.execute(sql: """
        INSERT INTO ai_provider_credentials (id, provider, name, api_key_encrypted, model_preference, priority, total_requests, created_at, updated_at)
        VALUES ('cred-1', 'openai', 'Work key', 'keychain://cred-1', 'gpt-5.4', 2, 12, '2026-08-01', '2026-08-01');
        """)
      try db.execute(sql: """
        INSERT INTO ai_model_rates (id, provider, model, input_usd_per_million, output_usd_per_million, source, updated_at)
        VALUES ('rate-1', 'anthropic', 'claude-sonnet-4-6', 3.0, 15.0, 'seeded', '2026-08-01');
        """)
    }
  }

  private func makeTemporaryDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-macos-tests")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory.appendingPathComponent("serenity.sqlite3")
  }
}
