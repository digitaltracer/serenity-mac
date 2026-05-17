import XCTest
@testable import SerenityMac

final class AppStateTests: XCTestCase {
  func testBackendProfilesExposeExpectedOrder() {
    XCTAssertEqual(
      BackendProfile.allCases,
      [.sqliteLocal, .serenityCloud, .externalPostgres],
    )
  }

  func testDefaultSettingsUseLocalSQLiteWithoutLocalLock() {
    let settings = AppSettings()

    XCTAssertEqual(settings.backendProfile, .sqliteLocal)
    XCTAssertFalse(settings.localLockEnabled)
  }

  @MainActor
  func testOpeningGlobalSearchClosesHelpCenterAndPrefillsQuery() {
    let state = AppState()
    state.openHelpCenter()

    state.openGlobalSearch(prefill: "parity")

    XCTAssertTrue(state.isGlobalSearchPresented)
    XCTAssertFalse(state.isHelpCenterPresented)
    XCTAssertEqual(state.globalSearchQuery, "parity")
  }

  @MainActor
  func testOpeningHelpCenterClosesGlobalSearch() {
    let state = AppState()
    state.openGlobalSearch(prefill: "task")

    state.openHelpCenter()

    XCTAssertTrue(state.isHelpCenterPresented)
    XCTAssertFalse(state.isGlobalSearchPresented)
  }

  @MainActor
  func testSelectingGlobalSearchResultNavigatesAndClosesSearch() {
    let state = AppState()
    state.openGlobalSearch(prefill: "goal")

    let result = GlobalSearchResult(
      type: .goal,
      entityID: "goal-1",
      title: "Ship mac parity",
      subtitle: "Milestone goal",
      updatedAt: Date()
    )

    state.selectGlobalSearchResult(result)

    XCTAssertEqual(state.selectedSection, .goals)
    XCTAssertFalse(state.isGlobalSearchPresented)
  }

  @MainActor
  func testAIQuickCaptureLowConfidenceCreatesPreviewWithoutSaving() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.61),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "book dentist appointment", credentialID: credential.id)

    XCTAssertFalse(saved)
    XCTAssertNotNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertTrue(fixture.state.tasks.isEmpty)
  }

  @MainActor
  func testAIQuickCaptureTaskModeCreatesMultipleTasks() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.91),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "book dentist and buy groceries", credentialID: credential.id)

    XCTAssertTrue(saved)
    XCTAssertNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertEqual(Set(fixture.state.tasks.map(\.title)), ["Book dentist appointment", "Buy groceries"])
  }

  @MainActor
  func testAIQuickCaptureJournalModeCreatesOneJournalEntry() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: """
        {
          "kind": "journal",
          "confidence": 0.9,
          "tasks": [],
          "journal": {
            "title": "Calm morning",
            "content": "I felt grounded after a quiet walk.",
            "mood": "happy",
            "tags": ["reflection"]
          }
        }
        """,
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "I felt grounded after a quiet walk.", credentialID: credential.id)

    XCTAssertTrue(saved)
    XCTAssertTrue(fixture.state.tasks.isEmpty)
    XCTAssertEqual(fixture.state.journalEntries.count, 1)
    XCTAssertEqual(fixture.state.journalEntries.first?.title, "Calm morning")
  }

  @MainActor
  func testAIQuickCaptureFailureCreatesNothingAndKeepsNoPreview() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      throw AIProviderAPIError.invalidResponse
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "book dentist appointment", credentialID: credential.id)

    XCTAssertFalse(saved)
    XCTAssertTrue(fixture.state.tasks.isEmpty)
    XCTAssertTrue(fixture.state.journalEntries.isEmpty)
    XCTAssertNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertNotNil(fixture.state.activeAlert)
  }

  private struct AIQuickCaptureStateFixture {
    let state: AppState
    let service: AIWorkflowService
    let cleanup: () -> Void
  }

  @MainActor
  private func makeAIQuickCaptureState(
    quickCaptureGenerator: @escaping AIWorkflowService.QuickCaptureGenerationHandler
  ) throws -> AIQuickCaptureStateFixture {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-appstate-ai-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let sqliteAdapter = SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite"))
    let secretStore = KeychainSecretStore(
      service: "test.appstate.ai.\(UUID().uuidString)",
      backend: InMemoryAppStateSecretStorageBackend()
    )
    let service = AIWorkflowService(
      sqliteBackendAdapter: sqliteAdapter,
      secretStore: secretStore,
      quickCaptureGenerator: quickCaptureGenerator
    )
    let suiteName = "serenity.appstate.ai.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let registry = BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: { .unavailable(reason: "not configured") },
        .externalPostgres: { .unavailable(reason: "not configured") },
      ]
    )
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "appstate.ai.backend",
        registry: registry
      ),
      sqliteBackendAdapter: sqliteAdapter,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      aiWorkflowService: service
    )

    return AIQuickCaptureStateFixture(
      state: state,
      service: service,
      cleanup: {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseURL)
      }
    )
  }

  private static func taskClassificationJSON(confidence: Double) -> String {
    """
    {
      "kind": "tasks",
      "confidence": \(confidence),
      "tasks": [
        {
          "title": "Book dentist appointment",
          "description": null,
          "priority": "medium",
          "dueDate": null,
          "projectId": null,
          "tags": ["health"],
          "subtasks": []
        },
        {
          "title": "Buy groceries",
          "description": null,
          "priority": null,
          "dueDate": null,
          "projectId": null,
          "tags": ["errands"],
          "subtasks": []
        }
      ],
      "journal": null
    }
    """
  }
}

private final class InMemoryAppStateSecretStorageBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  private func namespacedKey(service: String, key: String) -> String {
    "\(service):\(key)"
  }

  func set(service: String, key: String, data: Data) throws {
    values[namespacedKey(service: service, key: key)] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values[namespacedKey(service: service, key: key)]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: namespacedKey(service: service, key: key))
  }

  func contains(service: String, key: String) throws -> Bool {
    values[namespacedKey(service: service, key: key)] != nil
  }
}
