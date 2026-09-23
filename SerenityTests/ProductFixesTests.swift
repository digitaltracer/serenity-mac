import XCTest
@testable import SerenityMac

/// GitHub PR tasks, saved sync toggles, the shared capture path and repeating tasks.
@MainActor
final class ProductFixesTests: XCTestCase {
  private var cleanups: [() -> Void] = []
  private let defaultsKeys = [
    AppState.googleSyncEnabledDefaultsKey,
    AppState.githubSyncEnabledDefaultsKey,
    AppState.slackRelevanceDefaultsKey,
  ]

  override func tearDown() {
    cleanups.forEach { $0() }
    cleanups = []
    defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    super.tearDown()
  }

  // MARK: - GitHub pull requests

  func testAnImportedPullRequestHasNoDueDate() async throws {
    let github = SearchGitHub()
    await github.setItems([pullRequest(id: 1, title: "Add retry backoff", state: "open")])
    let service = try await githubService(github)

    let payload = try await service.syncGitHubPullRequests(existingTasks: [], existingProjects: [])

    XCTAssertEqual(payload.tasks.count, 1)
    XCTAssertNil(payload.tasks.first?.dueDate)
    XCTAssertEqual(payload.newlyImportedIDs, [1])
  }

  func testAMergedPullRequestCompletesItsTaskAndTheTitleFollows() async throws {
    let github = SearchGitHub()
    await github.setItems([pullRequest(id: 1, title: "Add retry backoff", state: "open")])
    let service = try await githubService(github)
    let first = try await service.syncGitHubPullRequests(existingTasks: [], existingProjects: [])
    let tracked = try XCTUnwrap(first.tasks.first)

    await github.setItems([pullRequest(id: 1, title: "Add retry backoff with jitter", state: "closed")])
    let second = try await service.syncGitHubPullRequests(
      existingTasks: [tracked],
      existingProjects: [],
      alreadyImported: [1]
    )

    let refreshed = try XCTUnwrap(second.tasks.first)
    XCTAssertEqual(refreshed.id, tracked.id)
    XCTAssertTrue(refreshed.completed)
    XCTAssertEqual(refreshed.title, "Add retry backoff with jitter")
    XCTAssertEqual(second.importedCount, 0)
  }

  func testAnUnchangedPullRequestIsNotRewritten() async throws {
    let github = SearchGitHub()
    await github.setItems([pullRequest(id: 1, title: "Add retry backoff", state: "open")])
    let service = try await githubService(github)
    let first = try await service.syncGitHubPullRequests(existingTasks: [], existingProjects: [])

    let second = try await service.syncGitHubPullRequests(existingTasks: first.tasks, existingProjects: [], alreadyImported: [1])

    XCTAssertTrue(second.tasks.isEmpty)
  }

  func testADeletedPullRequestTaskStaysDeleted() async throws {
    let github = SearchGitHub()
    await github.setItems([pullRequest(id: 1, title: "Add retry backoff", state: "open")])
    let service = try await githubService(github)

    let payload = try await service.syncGitHubPullRequests(existingTasks: [], existingProjects: [], alreadyImported: [1])

    XCTAssertTrue(payload.tasks.isEmpty)
  }

  func testTheImportLedgerRemembersAcrossSyncs() async throws {
    let adapter = try temporarySQLite()
    _ = try await adapter.bootstrap()
    let ledger = try adapter.makeGitHubImportLedger()

    try ledger.record([1, 2])
    try ledger.record([2, 3])

    XCTAssertEqual(try ledger.importedIDs(), [1, 2, 3])
  }

  // MARK: - Saved toggles

  func testSyncTogglesSurviveARelaunch() async throws {
    let first = try makeState()
    await first.setGitHubIntegrationSyncEnabled(true)
    await first.setGoogleIntegrationSyncEnabled(true)
    first.setSlackRelevanceSettings(SlackRelevanceSettings(includeBroadcastMentions: true, includeBotMessages: true))

    let store = memoryStore()
    let session = SlackIntegrationSession(
      accessToken: "xoxp", refreshToken: nil, expiresAt: nil, teamID: "T1", teamName: "Acme",
      teamURL: nil, userID: "U_ME", userName: "me", connectedAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try store.setSecret(String(decoding: try encoder.encode(session), as: UTF8.self), for: "integrations.slack.session")
    let relaunched = try makeState(
      slack: SlackIntegrationService(secretStore: store, requestHandler: { _ in throw URLError(.notConnectedToInternet) }, clientID: "cid")
    )
    await relaunched.bootstrapIntegrations()

    XCTAssertTrue(relaunched.githubIntegrationState.syncEnabled)
    XCTAssertEqual(relaunched.slackRelevanceSettings, SlackRelevanceSettings(includeBroadcastMentions: true, includeBotMessages: true))
    XCTAssertTrue(UserDefaults.standard.bool(forKey: AppState.googleSyncEnabledDefaultsKey))
  }

  // MARK: - One capture path

  func testAPlainCaptureWithNoKeyBecomesATaskWithItsDate() async throws {
    let state = try makeState()
    await state.bootstrapLocalDatabase()

    let used = await state.submitCapture("call the bank tomorrow at 3pm", credentialID: nil)

    XCTAssertTrue(used)
    let task = try XCTUnwrap(state.tasks.first { $0.title == "call the bank" })
    XCTAssertNotNil(task.dueDate)
  }

  func testACommandGoesThroughTheCommandPathEvenWithAKey() async throws {
    let state = try makeState()
    await state.bootstrapLocalDatabase()

    let used = await state.submitCapture("/github https://github.com/acme/api/pull/812", credentialID: "any-key")

    // No GitHub token is connected, so the command path refuses before any AI call.
    XCTAssertFalse(used)
    XCTAssertTrue(state.tasks.isEmpty)
  }

  func testTheSharedCapturePathUsesTheAIWhenAKeyIsGiven() async throws {
    let calls = CallCount()
    let state = try makeState { _, _, _, _, _, _ in
      calls.increment()
      return AIProviderTextGenerationResponse(
        text: """
        {"kind":"tasks","confidence":0.95,"newProjects":[],"journal":null,
         "tasks":[{"title":"Call the dentist","description":null,"priority":null,"dueDate":null,
         "projectId":null,"projectName":null,"tags":[],"subtasks":[]}]}
        """,
        promptTokens: 1,
        completionTokens: 1
      )
    }
    await state.bootstrapLocalDatabase()
    await state.bootstrapAIWorkflows()
    let credential = try await lastService.addCredential(
      provider: .openai, name: "OpenAI", apiKey: "sk", modelPreference: "gpt-5.5"
    )
    await state.refreshAIWorkflows()

    let used = await state.submitCapture("remember to call the dentist", credentialID: state.defaultQuickCaptureCredentialID)

    XCTAssertEqual(state.defaultQuickCaptureCredentialID, credential.id)
    XCTAssertTrue(used)
    XCTAssertEqual(calls.value, 1)
    XCTAssertTrue(state.tasks.contains { $0.title == "Call the dentist" })
  }

  // MARK: - Repeating tasks

  func testCompletingARepeatingTaskInBulkCreatesTheNextOne() async throws {
    let state = try makeState()
    await state.bootstrapLocalDatabase()
    let id = try await repeatingTask(in: state)

    state.toggleTaskSelection(id: id)
    await state.markSelectedTasksCompleted()

    XCTAssertEqual(state.tasks.filter { $0.title == "Water the plants" && !$0.completed }.count, 1)
    XCTAssertEqual(state.tasks.filter { $0.title == "Water the plants" && $0.completed }.count, 1)
  }

  func testADraftThatMarksARepeatingTaskDoneCreatesTheNextOne() async throws {
    let state = try makeState()
    await state.bootstrapLocalDatabase()
    let id = try await repeatingTask(in: state)

    try await state.applyDraftUpdate(
      SlackProposalPayload(statusChange: .completed),
      taskID: id,
      attribution: TaskActivityEntry(id: "a", kind: .event, text: "From Slack", createdAt: Date()),
      at: Date()
    )
    await state.refreshCoreWorkflowData()

    XCTAssertEqual(state.tasks.filter { $0.title == "Water the plants" && !$0.completed }.count, 1)
  }

  // MARK: - Helpers

  private func repeatingTask(in state: AppState) async throws -> String {
    let created = await state.createTask(title: "Water the plants", priority: .medium, dueDate: Date(), tags: [], subtaskTitles: [])
    XCTAssertTrue(created)
    let task = try XCTUnwrap(state.tasks.first { $0.title == "Water the plants" })
    let updated = await state.updateTask(
      id: task.id,
      title: task.title,
      description: "",
      priority: .medium,
      dueDate: task.dueDate,
      projectID: nil,
      tags: [],
      recurring: TaskRecurringPattern(type: .daily, interval: 1, endDate: nil)
    )
    XCTAssertTrue(updated)
    return task.id
  }

  private func pullRequest(id: Int64, title: String, state: String) -> String {
    #"{"id":\#(id),"title":"\#(title)","body":null,"state":"\#(state)","html_url":"https://github.com/acme/api/pull/\#(id)","created_at":"2026-09-15T09:00:00Z"}"#
  }

  private func githubService(_ github: SearchGitHub) async throws -> GitHubIntegrationService {
    let service = GitHubIntegrationService(secretStore: memoryStore(), requestHandler: { try await github.respond(to: $0) })
    _ = try await service.addToken("ghp", displayName: "Work")
    return service
  }

  private func memoryStore() -> KeychainSecretStore {
    KeychainSecretStore(service: "test.product.\(UUID().uuidString)", backend: ProductSecretBackend())
  }

  private func temporarySQLite() throws -> SQLiteBackendAdapter {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-product-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    cleanups.append { try? FileManager.default.removeItem(at: baseURL) }
    return SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite"))
  }

  private func makeState(
    slack: SlackIntegrationService? = nil,
    generator: AIWorkflowService.QuickCaptureGenerationHandler? = nil
  ) throws -> AppState {
    let suiteName = "serenity.product.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append { defaults.removePersistentDomain(forName: suiteName) }
    let sqlite = try temporarySQLite()
    let registry = BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: { .unavailable(reason: "not configured") },
        .externalPostgres: { .unavailable(reason: "not configured") },
      ]
    )
    let service = AIWorkflowService(
      sqliteBackendAdapter: sqlite,
      secretStore: memoryStore(),
      quickCaptureGenerator: generator ?? { _, _, _, _, _, _ in throw AIProviderAPIError.invalidKey }
    )
    let state = AppState(
      backendProfileManager: BackendProfileManager(defaults: defaults, defaultsKey: "backend", registry: registry),
      sqliteBackendAdapter: sqlite,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      googleIntegrationService: GoogleIntegrationService(secretStore: memoryStore(), requestHandler: { _ in throw URLError(.badURL) }),
      githubIntegrationService: GitHubIntegrationService(secretStore: memoryStore(), requestHandler: { _ in throw URLError(.badURL) }),
      slackIntegrationService: slack ?? SlackIntegrationService(secretStore: memoryStore(), requestHandler: { _ in throw URLError(.badURL) }, clientID: "cid"),
      aiWorkflowService: service
    )
    lastService = service
    return state
  }

  /// The AI service the most recent `makeState` built its state with.
  private var lastService: AIWorkflowService!
}

private actor SearchGitHub {
  private var items: [String] = []

  func setItems(_ items: [String]) {
    self.items = items
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let json: String
    switch url.path {
    case "/user":
      json = #"{"login":"octocat"}"#
    case "/search/issues":
      json = #"{"items":[\#(items.joined(separator: ","))]}"#
    default:
      json = "{}"
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private final class CallCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private final class ProductSecretBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  func set(service: String, key: String, data: Data) throws {
    values["\(service):\(key)"] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values["\(service):\(key)"]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: "\(service):\(key)")
  }

  func contains(service: String, key: String) throws -> Bool {
    values["\(service):\(key)"] != nil
  }
}
