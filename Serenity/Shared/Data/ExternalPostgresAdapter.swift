import Foundation
import Network
import NIOSSL
import PostgresNIO

struct ExternalPostgresConfiguration: Equatable, Sendable {
  let host: String
  let port: UInt16
  let database: String
  let username: String
  let password: String
  let sslMode: String
  let timeout: TimeInterval

  init(
    host: String,
    port: UInt16,
    database: String,
    username: String,
    password: String,
    sslMode: String = "require",
    timeout: TimeInterval = 10
  ) {
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
    self.timeout = timeout
  }

  static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ExternalPostgresConfiguration? {
    guard
      let host = environment["POSTGRES_HOST"], !host.isEmpty,
      let database = environment["POSTGRES_DATABASE"], !database.isEmpty,
      let username = environment["POSTGRES_USER"], !username.isEmpty,
      let password = environment["POSTGRES_PASSWORD"], !password.isEmpty
    else {
      return nil
    }

    let port = UInt16(environment["POSTGRES_PORT"] ?? "5432") ?? 5432
    let sslMode = environment["POSTGRES_SSLMODE"] ?? "require"

    return ExternalPostgresConfiguration(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      sslMode: sslMode
    )
  }

  static func fromStoredOrEnvironment(
    store: BackendConfigurationStore = BackendConfigurationStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ExternalPostgresConfiguration? {
    if let stored = store.loadExternalPostgresConfiguration() {
      return stored
    }

    return fromEnvironment(environment)
  }
}

struct ExternalPostgresDiagnostics: Equatable, Sendable {
  let host: String
  let port: UInt16
  let database: String
  let username: String
  let sslMode: String
  let lastHealthyAt: Date?
}

enum ExternalPostgresAdapterError: Error, LocalizedError {
  case invalidJSONPayload
  case decodingFailure(String)

  var errorDescription: String? {
    switch self {
    case .invalidJSONPayload:
      return "Could not encode PostgreSQL JSON payload."
    case .decodingFailure(let detail):
      return "Failed to decode PostgreSQL record: \(detail)"
    }
  }
}

private enum ExternalPostgresEntityType: String {
  case task
  case project
  case journal
  case goal
}

final class ExternalPostgresAdapter {
  typealias ConnectivityProbe = @Sendable (_ host: String, _ port: UInt16, _ timeout: TimeInterval) async -> Bool

  let profile: BackendProfile = .externalPostgres

  private let configuration: ExternalPostgresConfiguration
  private let connectivityProbe: ConnectivityProbe
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var lastHealthyAt: Date?

  init(
    configuration: ExternalPostgresConfiguration,
    connectivityProbe: ConnectivityProbe? = nil
  ) {
    self.configuration = configuration
    self.connectivityProbe = connectivityProbe ?? Self.defaultConnectivityProbe

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func validateConnection() async -> BackendProfileValidationState {
    let reachable = await connectivityProbe(configuration.host, configuration.port, configuration.timeout)

    if reachable {
      lastHealthyAt = Date()
      return .available(message: "Connected to external PostgreSQL endpoint.")
    }

    return .unavailable(reason: "PostgreSQL endpoint is unreachable at \(configuration.host):\(configuration.port).")
  }

  func diagnostics() -> ExternalPostgresDiagnostics {
    ExternalPostgresDiagnostics(
      host: configuration.host,
      port: configuration.port,
      database: configuration.database,
      username: configuration.username,
      sslMode: configuration.sslMode,
      lastHealthyAt: lastHealthyAt
    )
  }

  func listTasks() async throws -> [TaskEntity] {
    let documents = try await listDocuments(of: ExternalTaskDocument.self, type: .task)
    return documents.map(\.entity)
  }

  func createTask(_ task: TaskEntity) async throws -> TaskEntity {
    try await upsertDocument(
      ExternalTaskDocument(from: task),
      type: .task,
      id: task.id,
      updatedAt: task.updatedAt
    )
    return task
  }

  func updateTask(_ task: TaskEntity) async throws -> TaskEntity {
    try await upsertDocument(
      ExternalTaskDocument(from: task),
      type: .task,
      id: task.id,
      updatedAt: task.updatedAt
    )
    return task
  }

  func deleteTask(id: String) async throws {
    try await deleteDocument(type: .task, id: id)
  }

  func listProjects() async throws -> [ProjectEntity] {
    let documents = try await listDocuments(of: ExternalProjectDocument.self, type: .project)
    return documents.map(\.entity)
  }

  func createProject(_ project: ProjectEntity) async throws -> ProjectEntity {
    try await upsertDocument(
      ExternalProjectDocument(from: project),
      type: .project,
      id: project.id,
      updatedAt: project.updatedAt
    )
    return project
  }

  func updateProject(_ project: ProjectEntity) async throws -> ProjectEntity {
    try await upsertDocument(
      ExternalProjectDocument(from: project),
      type: .project,
      id: project.id,
      updatedAt: project.updatedAt
    )
    return project
  }

  func deleteProject(id: String) async throws {
    try await deleteDocument(type: .project, id: id)
  }

  func listJournalEntries() async throws -> [JournalEntryEntity] {
    let documents = try await listDocuments(of: ExternalJournalDocument.self, type: .journal)
    return documents.map(\.entity)
  }

  func createJournalEntry(_ entry: JournalEntryEntity) async throws -> JournalEntryEntity {
    try await upsertDocument(
      ExternalJournalDocument(from: entry),
      type: .journal,
      id: entry.id,
      updatedAt: entry.updatedAt
    )
    return entry
  }

  func updateJournalEntry(_ entry: JournalEntryEntity) async throws -> JournalEntryEntity {
    try await upsertDocument(
      ExternalJournalDocument(from: entry),
      type: .journal,
      id: entry.id,
      updatedAt: entry.updatedAt
    )
    return entry
  }

  func deleteJournalEntry(id: String) async throws {
    try await deleteDocument(type: .journal, id: id)
  }

  func listGoals() async throws -> [GoalEntity] {
    let documents = try await listDocuments(of: ExternalGoalDocument.self, type: .goal)
    return documents.map(\.entity)
  }

  func createGoal(_ goal: GoalEntity) async throws -> GoalEntity {
    try await upsertDocument(
      ExternalGoalDocument(from: goal),
      type: .goal,
      id: goal.id,
      updatedAt: goal.updatedAt
    )
    return goal
  }

  func updateGoal(_ goal: GoalEntity) async throws -> GoalEntity {
    try await upsertDocument(
      ExternalGoalDocument(from: goal),
      type: .goal,
      id: goal.id,
      updatedAt: goal.updatedAt
    )
    return goal
  }

  func deleteGoal(id: String) async throws {
    try await deleteDocument(type: .goal, id: id)
  }

  private func listDocuments<Document: Decodable>(of type: Document.Type, type entityType: ExternalPostgresEntityType) async throws -> [Document] {
    try await withClient { [self] client in
      try await self.ensureSchema(using: client)
      let rows = try await client.query(
        """
        SELECT payload::text
        FROM serenity_documents
        WHERE entity_type = \(entityType.rawValue)
        ORDER BY updated_at DESC;
        """
      )

      var documents: [Document] = []
      for try await payload in rows.decode(String.self) {
        guard let payloadData = payload.data(using: .utf8) else {
          throw ExternalPostgresAdapterError.invalidJSONPayload
        }
        do {
          documents.append(try self.decoder.decode(Document.self, from: payloadData))
        } catch {
          throw ExternalPostgresAdapterError.decodingFailure(error.localizedDescription)
        }
      }
      return documents
    }
  }

  private func upsertDocument<Document: Encodable>(
    _ document: Document,
    type entityType: ExternalPostgresEntityType,
    id: String,
    updatedAt: Date
  ) async throws {
    let payloadData = try encoder.encode(document)
    guard let payloadText = String(data: payloadData, encoding: .utf8) else {
      throw ExternalPostgresAdapterError.invalidJSONPayload
    }

    try await withClient { [self] client in
      try await self.ensureSchema(using: client)
      _ = try await client.query(
        """
        INSERT INTO serenity_documents (entity_type, entity_id, payload, updated_at)
        VALUES (\(entityType.rawValue), \(id), \(payloadText)::jsonb, \(updatedAt))
        ON CONFLICT (entity_type, entity_id) DO UPDATE
        SET payload = EXCLUDED.payload, updated_at = EXCLUDED.updated_at;
        """
      )
    }
  }

  private func deleteDocument(type entityType: ExternalPostgresEntityType, id: String) async throws {
    try await withClient { [self] client in
      try await self.ensureSchema(using: client)
      _ = try await client.query(
        """
        DELETE FROM serenity_documents
        WHERE entity_type = \(entityType.rawValue)
          AND entity_id = \(id);
        """
      )
    }
  }

  private func withClient<T>(_ operation: @escaping (PostgresClient) async throws -> T) async throws -> T {
    let client = PostgresClient(configuration: makeClientConfiguration())
    let runTask = Task {
      await client.run()
    }
    defer {
      runTask.cancel()
    }

    return try await operation(client)
  }

  private func makeClientConfiguration() -> PostgresClient.Configuration {
    PostgresClient.Configuration(
      host: configuration.host,
      port: Int(configuration.port),
      username: configuration.username,
      password: configuration.password,
      database: configuration.database,
      tls: mapTLSMode(configuration.sslMode)
    )
  }

  private func mapTLSMode(_ mode: String) -> PostgresClient.Configuration.TLS {
    let tlsConfiguration = TLSConfiguration.makeClientConfiguration()

    switch mode.lowercased() {
    case "disable":
      return .disable
    case "verify-ca", "verify-full", "require":
      return .require(tlsConfiguration)
    default:
      return .prefer(tlsConfiguration)
    }
  }

  private func ensureSchema(using client: PostgresClient) async throws {
    _ = try await client.query(
      """
      CREATE TABLE IF NOT EXISTS serenity_documents (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        payload JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (entity_type, entity_id)
      );
      """
    )

    _ = try await client.query(
      """
      CREATE INDEX IF NOT EXISTS idx_serenity_documents_entity_type_updated_at
      ON serenity_documents (entity_type, updated_at DESC);
      """
    )
  }

  private static let defaultConnectivityProbe: ConnectivityProbe = { host, port, timeout in
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      return false
    }

    return await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "serenity.postgres.connectivity")
      let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
      let probeState = ConnectivityProbeState()

      let finish: @Sendable (Bool) -> Void = { isReachable in
        queue.async {
          guard !probeState.didResume else { return }
          probeState.didResume = true
          connection.cancel()
          continuation.resume(returning: isReachable)
        }
      }

      connection.stateUpdateHandler = { connectionState in
        switch connectionState {
        case .ready:
          finish(true)
        case .failed, .cancelled:
          finish(false)
        default:
          break
        }
      }

      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) {
        finish(false)
      }
    }
  }
}

private final class ConnectivityProbeState: @unchecked Sendable {
  var didResume = false
}

private struct ExternalTaskDocument: Codable {
  let id: String
  let title: String
  let description: String?
  let completed: Bool
  let completedAt: Date?
  let priority: TaskPriority
  let dueDate: Date?
  let projectId: String?
  let tags: [String]
  let createdAt: Date
  let updatedAt: Date
  let subtasks: [TaskSubtask]
  let recurring: TaskRecurringPattern?
  let userId: String?

  init(from entity: TaskEntity) {
    id = entity.id
    title = entity.title
    description = entity.description
    completed = entity.completed
    completedAt = entity.completedAt
    priority = entity.priority
    dueDate = entity.dueDate
    projectId = entity.projectId
    tags = entity.tags
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
    subtasks = entity.subtasks
    recurring = entity.recurring
    userId = entity.userId
  }

  var entity: TaskEntity {
    TaskEntity(
      id: id,
      title: title,
      description: description,
      completed: completed,
      completedAt: completedAt,
      priority: priority,
      dueDate: dueDate,
      projectId: projectId,
      tags: tags,
      createdAt: createdAt,
      updatedAt: updatedAt,
      subtasks: subtasks,
      recurring: recurring,
      userId: userId
    )
  }
}

private struct ExternalProjectDocument: Codable {
  let id: String
  let name: String
  let description: String?
  let color: String
  let icon: String?
  let createdAt: Date
  let updatedAt: Date
  let archived: Bool
  let userId: String?

  init(from entity: ProjectEntity) {
    id = entity.id
    name = entity.name
    description = entity.description
    color = entity.color
    icon = entity.icon
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
    archived = entity.archived
    userId = entity.userId
  }

  var entity: ProjectEntity {
    ProjectEntity(
      id: id,
      name: name,
      description: description,
      color: color,
      icon: icon,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archived: archived,
      userId: userId
    )
  }
}

private struct ExternalJournalDocument: Codable {
  let id: String
  let title: String?
  let content: String
  let date: Date
  let tags: [String]
  let createdAt: Date
  let updatedAt: Date
  let pinned: Bool
  let mood: JournalMood?
  let attachments: [JournalAttachmentEntity]
  let userId: String?

  init(from entity: JournalEntryEntity) {
    id = entity.id
    title = entity.title
    content = entity.content
    date = entity.date
    tags = entity.tags
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
    pinned = entity.pinned
    mood = entity.mood
    attachments = entity.attachments
    userId = entity.userId
  }

  var entity: JournalEntryEntity {
    JournalEntryEntity(
      id: id,
      title: title,
      content: content,
      date: date,
      tags: tags,
      createdAt: createdAt,
      updatedAt: updatedAt,
      pinned: pinned,
      mood: mood,
      attachments: attachments,
      userId: userId
    )
  }
}

private struct ExternalGoalDocument: Codable {
  let id: String
  let title: String
  let description: String?
  let type: GoalType
  let config: GoalConfig
  let progress: GoalProgress
  let status: GoalStatus
  let priority: GoalPriority
  let reminders: [GoalReminder]
  let createdAt: Date
  let updatedAt: Date
  let userId: String?

  init(from entity: GoalEntity) {
    id = entity.id
    title = entity.title
    description = entity.description
    type = entity.type
    config = entity.config
    progress = entity.progress
    status = entity.status
    priority = entity.priority
    reminders = entity.reminders
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
    userId = entity.userId
  }

  var entity: GoalEntity {
    GoalEntity(
      id: id,
      title: title,
      description: description,
      type: type,
      config: config,
      progress: progress,
      status: status,
      priority: priority,
      reminders: reminders,
      createdAt: createdAt,
      updatedAt: updatedAt,
      userId: userId
    )
  }
}
