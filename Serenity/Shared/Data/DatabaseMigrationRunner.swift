import Foundation
import GRDB

struct DatabaseMigration: Sendable {
  let identifier: String
  let statements: [String]
}

struct MigrationRunSummary: Sendable {
  let databasePath: String
  let appliedMigrations: [String]
  let skippedMigrations: [String]

  var isFreshBootstrap: Bool {
    !appliedMigrations.isEmpty && skippedMigrations.isEmpty
  }
}

actor DatabaseMigrationRunner {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func bootstrapDatabase(at databaseURL: URL) throws -> MigrationRunSummary {
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    let identifiers = Self.migrations.map(\.identifier)

    let appliedBefore = try fetchAppliedMigrations(dbQueue)

    var migrator = DatabaseMigrator()
    registerMigrations(on: &migrator)
    try migrator.migrate(dbQueue)

    let appliedAfter = try fetchAppliedMigrations(dbQueue)

    let newlyApplied = identifiers.filter { !appliedBefore.contains($0) && appliedAfter.contains($0) }
    let skipped = identifiers.filter { appliedBefore.contains($0) }

    return MigrationRunSummary(
      databasePath: databaseURL.path,
      appliedMigrations: newlyApplied,
      skippedMigrations: skipped
    )
  }

  static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    let databaseDirectory = applicationSupport
      .appendingPathComponent("SerenityMac", isDirectory: true)
      .appendingPathComponent("Database", isDirectory: true)

    return databaseDirectory.appendingPathComponent("serenity.sqlite3")
  }

  private func fetchAppliedMigrations(_ dbQueue: DatabaseQueue) throws -> Set<String> {
    try dbQueue.read { db in
      let migrationTableExists = try Bool.fetchOne(
        db,
        sql: """
        SELECT EXISTS(
          SELECT 1
          FROM sqlite_master
          WHERE type = 'table' AND name = 'grdb_migrations'
        );
        """
      ) ?? false

      guard migrationTableExists else {
        return []
      }

      return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations;"))
    }
  }

  private func registerMigrations(on migrator: inout DatabaseMigrator) {
    for migration in Self.migrations {
      migrator.registerMigration(migration.identifier) { db in
        for statement in migration.statements {
          try db.execute(sql: statement)
        }
      }
    }
  }

  private static let migrations: [DatabaseMigration] = [
    DatabaseMigration(
      identifier: "20260214_001_core_entities",
      statements: [
        """
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          color TEXT,
          archived INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          notes TEXT,
          completed INTEGER NOT NULL DEFAULT 0,
          due_at TEXT,
          project_id TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY(project_id) REFERENCES projects(id) ON DELETE SET NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS journal_entries (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          mood TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS goals (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          target_value REAL,
          progress_value REAL NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'active',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """,
      ]
    ),
    DatabaseMigration(
      identifier: "20260214_002_bootstrap_metadata",
      statements: [
        """
        CREATE TABLE IF NOT EXISTS app_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        """,
        "INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('schema_version', '2');",
        "INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('bootstrap_source', 'native-macos');",
      ]
    ),
    DatabaseMigration(
      identifier: "20260214_003_core_schema_parity",
      statements: [
        "ALTER TABLE tasks ADD COLUMN description TEXT;",
        "ALTER TABLE tasks ADD COLUMN completed_at TEXT;",
        "ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium';",
        "ALTER TABLE tasks ADD COLUMN due_date TEXT;",
        "ALTER TABLE tasks ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE tasks ADD COLUMN subtasks_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE tasks ADD COLUMN recurring_json TEXT;",
        "ALTER TABLE tasks ADD COLUMN user_id TEXT;",
        "UPDATE tasks SET description = notes WHERE description IS NULL;",
        "UPDATE tasks SET due_date = due_at WHERE due_date IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);",
        "CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed);",
        "ALTER TABLE projects ADD COLUMN description TEXT;",
        "ALTER TABLE projects ADD COLUMN icon TEXT;",
        "ALTER TABLE projects ADD COLUMN user_id TEXT;",
        "CREATE INDEX IF NOT EXISTS idx_projects_archived ON projects(archived);",
        "ALTER TABLE journal_entries ADD COLUMN date TEXT;",
        "ALTER TABLE journal_entries ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE journal_entries ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;",
        "ALTER TABLE journal_entries ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE journal_entries ADD COLUMN user_id TEXT;",
        "UPDATE journal_entries SET date = created_at WHERE date IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_journal_date ON journal_entries(date);",
        "CREATE INDEX IF NOT EXISTS idx_journal_pinned ON journal_entries(pinned);",
        "ALTER TABLE goals ADD COLUMN description TEXT;",
        "ALTER TABLE goals ADD COLUMN type TEXT NOT NULL DEFAULT 'weekly_tasks';",
        "ALTER TABLE goals ADD COLUMN config_json TEXT NOT NULL DEFAULT '{}';",
        "ALTER TABLE goals ADD COLUMN progress_json TEXT NOT NULL DEFAULT '{}';",
        "ALTER TABLE goals ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium';",
        "ALTER TABLE goals ADD COLUMN reminders_json TEXT NOT NULL DEFAULT '[]';",
        "ALTER TABLE goals ADD COLUMN user_id TEXT;",
        "CREATE INDEX IF NOT EXISTS idx_goals_status ON goals(status);",
        "CREATE INDEX IF NOT EXISTS idx_goals_type ON goals(type);",
      ]
    ),
    DatabaseMigration(
      identifier: "20260214_004_ai_entities",
      statements: [
        """
        CREATE TABLE IF NOT EXISTS secure_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_insights (
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
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_recaps (
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
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_usage (
          id TEXT PRIMARY KEY,
          timestamp TEXT NOT NULL,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic')),
          operation TEXT NOT NULL CHECK (operation IN ('analyze', 'recap', 'quickadd', 'summary')),
          prompt_tokens INTEGER DEFAULT 0,
          completion_tokens INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS summaries (
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
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_provider_credentials (
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
        """,
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_created_at ON ai_insights(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_category ON ai_insights(category);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_type ON ai_insights(type);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_theme_id ON ai_insights(theme_id);",
        "CREATE INDEX IF NOT EXISTS idx_ai_recaps_created_at ON ai_recaps(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_recaps_type ON ai_recaps(type);",
        "CREATE INDEX IF NOT EXISTS idx_ai_usage_timestamp ON ai_usage(timestamp DESC);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_type ON summaries(summary_type);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_date_range ON summaries(start_date, end_date);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_generated ON summaries(generated_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_provider ON ai_provider_credentials(provider);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_enabled ON ai_provider_credentials(enabled);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_priority ON ai_provider_credentials(priority);",
        "INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '3');",
      ]
    ),
    DatabaseMigration(
      identifier: "20260215_005_security_audit_events",
      statements: [
        """
        CREATE TABLE IF NOT EXISTS security_audit_events (
          id TEXT PRIMARY KEY,
          event_type TEXT NOT NULL,
          severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
          message TEXT NOT NULL,
          metadata_json TEXT NOT NULL DEFAULT '{}',
          created_at TEXT NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_security_audit_created_at ON security_audit_events(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_security_audit_event_type ON security_audit_events(event_type);",
        "INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '4');",
      ]
    ),
    DatabaseMigration(
      identifier: "20260505_006_cloudkit_sync_state",
      statements: [
        """
        CREATE TABLE IF NOT EXISTS pending_sync_changes (
          id TEXT PRIMARY KEY,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
          queued_at TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_attempt_at TEXT,
          last_error TEXT
        );
        """,
        // One pending row per (entity_type, entity_id) — successive saves coalesce.
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_sync_unique_target ON pending_sync_changes(entity_type, entity_id);",
        "CREATE INDEX IF NOT EXISTS idx_pending_sync_queued_at ON pending_sync_changes(queued_at);",
        """
        CREATE TABLE IF NOT EXISTS cloud_sync_state (
          key TEXT PRIMARY KEY,
          value BLOB,
          updated_at TEXT NOT NULL
        );
        """,
        "INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '5');",
      ]
    ),
    DatabaseMigration(
      identifier: "20260517_007_ai_cost_center",
      statements: [
        "ALTER TABLE ai_usage ADD COLUMN model TEXT;",
        "ALTER TABLE ai_usage ADD COLUMN input_cost_usd REAL;",
        "ALTER TABLE ai_usage ADD COLUMN output_cost_usd REAL;",
        "ALTER TABLE ai_usage ADD COLUMN total_cost_usd REAL;",
        """
        CREATE TABLE IF NOT EXISTS ai_model_rates (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic')),
          model TEXT NOT NULL,
          input_usd_per_million REAL NOT NULL DEFAULT 0,
          output_usd_per_million REAL NOT NULL DEFAULT 0,
          source TEXT NOT NULL DEFAULT 'seeded' CHECK (source IN ('seeded', 'user', 'litellm')),
          updated_at TEXT NOT NULL,
          UNIQUE(provider, model)
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_ai_model_rates_provider_model ON ai_model_rates(provider, model);",
        "CREATE INDEX IF NOT EXISTS idx_ai_usage_model ON ai_usage(provider, model);",
        "INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '6');",
      ]
    ),
    DatabaseMigration(
      identifier: "20260901_008_nvidia_provider",
      statements: [
        // SQLite cannot alter a CHECK constraint, so each provider-constrained table is rebuilt.
        """
        CREATE TABLE ai_insights_new (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia', 'local')),
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
        """,
        """
        INSERT INTO ai_insights_new (
          id, provider, type, title, description, confidence, category, actionable, metadata,
          created_at, updated_at, user_rating, dismissed, marked_helpful, user_notes,
          visualization_data, actionability_suggestions, theme_id, is_recurring, occurrence_number
        )
        SELECT
          id, provider, type, title, description, confidence, category, actionable, metadata,
          created_at, updated_at, user_rating, dismissed, marked_helpful, user_notes,
          visualization_data, actionability_suggestions, theme_id, is_recurring, occurrence_number
        FROM ai_insights;
        """,
        "DROP TABLE ai_insights;",
        "ALTER TABLE ai_insights_new RENAME TO ai_insights;",
        """
        CREATE TABLE ai_recaps_new (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia', 'local')),
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
        """,
        """
        INSERT INTO ai_recaps_new (
          id, provider, type, title, summary, highlights, challenges, recommendations, period,
          metadata, created_at, updated_at, viewed, favorited, exported
        )
        SELECT
          id, provider, type, title, summary, highlights, challenges, recommendations, period,
          metadata, created_at, updated_at, viewed, favorited, exported
        FROM ai_recaps;
        """,
        "DROP TABLE ai_recaps;",
        "ALTER TABLE ai_recaps_new RENAME TO ai_recaps;",
        """
        CREATE TABLE ai_usage_new (
          id TEXT PRIMARY KEY,
          timestamp TEXT NOT NULL,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia')),
          operation TEXT NOT NULL CHECK (operation IN ('analyze', 'recap', 'quickadd', 'summary')),
          prompt_tokens INTEGER DEFAULT 0,
          completion_tokens INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0,
          model TEXT,
          input_cost_usd REAL,
          output_cost_usd REAL,
          total_cost_usd REAL
        );
        """,
        """
        INSERT INTO ai_usage_new (
          id, timestamp, provider, operation, prompt_tokens, completion_tokens, total_tokens,
          model, input_cost_usd, output_cost_usd, total_cost_usd
        )
        SELECT
          id, timestamp, provider, operation, prompt_tokens, completion_tokens, total_tokens,
          model, input_cost_usd, output_cost_usd, total_cost_usd
        FROM ai_usage;
        """,
        "DROP TABLE ai_usage;",
        "ALTER TABLE ai_usage_new RENAME TO ai_usage;",
        """
        CREATE TABLE summaries_new (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          summary_type TEXT NOT NULL CHECK(summary_type IN ('tasks', 'journal', 'combined')),
          start_date TEXT NOT NULL,
          end_date TEXT NOT NULL,
          generated_at TEXT NOT NULL,
          word_count INTEGER,
          metadata TEXT DEFAULT '{}',
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia', 'local')),
          prompt_tokens INTEGER DEFAULT 0,
          completion_tokens INTEGER DEFAULT 0,
          total_tokens INTEGER DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """,
        """
        INSERT INTO summaries_new (
          id, title, content, summary_type, start_date, end_date, generated_at, word_count,
          metadata, provider, prompt_tokens, completion_tokens, total_tokens, created_at, updated_at
        )
        SELECT
          id, title, content, summary_type, start_date, end_date, generated_at, word_count,
          metadata, provider, prompt_tokens, completion_tokens, total_tokens, created_at, updated_at
        FROM summaries;
        """,
        "DROP TABLE summaries;",
        "ALTER TABLE summaries_new RENAME TO summaries;",
        """
        CREATE TABLE ai_provider_credentials_new (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia')),
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
        """,
        """
        INSERT INTO ai_provider_credentials_new (
          id, provider, name, api_key_encrypted, model_preference, enabled, priority, metadata,
          last_used_at, total_requests, total_tokens, success_count, error_count, last_error,
          last_error_at, created_at, updated_at
        )
        SELECT
          id, provider, name, api_key_encrypted, model_preference, enabled, priority, metadata,
          last_used_at, total_requests, total_tokens, success_count, error_count, last_error,
          last_error_at, created_at, updated_at
        FROM ai_provider_credentials;
        """,
        "DROP TABLE ai_provider_credentials;",
        "ALTER TABLE ai_provider_credentials_new RENAME TO ai_provider_credentials;",
        """
        CREATE TABLE ai_model_rates_new (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL CHECK (provider IN ('openai', 'gemini', 'anthropic', 'nvidia')),
          model TEXT NOT NULL,
          input_usd_per_million REAL NOT NULL DEFAULT 0,
          output_usd_per_million REAL NOT NULL DEFAULT 0,
          source TEXT NOT NULL DEFAULT 'seeded' CHECK (source IN ('seeded', 'user', 'litellm')),
          updated_at TEXT NOT NULL,
          UNIQUE(provider, model)
        );
        """,
        """
        INSERT INTO ai_model_rates_new (
          id, provider, model, input_usd_per_million, output_usd_per_million, source, updated_at
        )
        SELECT
          id, provider, model, input_usd_per_million, output_usd_per_million, source, updated_at
        FROM ai_model_rates;
        """,
        "DROP TABLE ai_model_rates;",
        "ALTER TABLE ai_model_rates_new RENAME TO ai_model_rates;",
        // Indexes are dropped with their tables.
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_created_at ON ai_insights(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_category ON ai_insights(category);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_type ON ai_insights(type);",
        "CREATE INDEX IF NOT EXISTS idx_ai_insights_theme_id ON ai_insights(theme_id);",
        "CREATE INDEX IF NOT EXISTS idx_ai_recaps_created_at ON ai_recaps(created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_recaps_type ON ai_recaps(type);",
        "CREATE INDEX IF NOT EXISTS idx_ai_usage_timestamp ON ai_usage(timestamp DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_usage_model ON ai_usage(provider, model);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_type ON summaries(summary_type);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_date_range ON summaries(start_date, end_date);",
        "CREATE INDEX IF NOT EXISTS idx_summaries_generated ON summaries(generated_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_provider ON ai_provider_credentials(provider);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_enabled ON ai_provider_credentials(enabled);",
        "CREATE INDEX IF NOT EXISTS idx_ai_credentials_priority ON ai_provider_credentials(priority);",
        "CREATE INDEX IF NOT EXISTS idx_ai_model_rates_provider_model ON ai_model_rates(provider, model);",
        "INSERT OR REPLACE INTO app_metadata (key, value) VALUES ('schema_version', '7');",
      ]
    ),
  ]
}
