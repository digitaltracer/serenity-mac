import XCTest
@testable import SerenityMac

final class AppStateTests: XCTestCase {
  func testTaskEditorDraftDetectsSubtaskEdits() {
    let now = Date()
    let task = TaskEntity(
      id: "task",
      title: "Title",
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: [],
      createdAt: now,
      updatedAt: now,
      subtasks: [TaskSubtask(id: "subtask", title: "Original", completed: false, order: 0)],
      recurring: nil,
      userId: nil
    )
    var draft = TaskEditorDraft(task: task)

    XCTAssertFalse(draft.isDirty)

    draft.subtasks[0].title = "Renamed"

    XCTAssertTrue(draft.isDirty)
  }

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

  func testAIProviderDropdownHasNoOptionsWithoutCredentials() {
    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: []), [])
  }

  func testAIProviderDropdownIgnoresDisabledCredentials() {
    let credentials = [
      makeAICredential(provider: .openai, enabled: false),
    ]

    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: credentials), [])
  }

  func testAIProviderDropdownShowsOnlyEnabledProvider() {
    let credentials = [
      makeAICredential(provider: .gemini, enabled: true),
    ]

    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: credentials), [.gemini])
  }

  func testAIProviderDropdownShowsEnabledProvidersOnly() {
    let credentials = [
      makeAICredential(provider: .openai, enabled: true),
      makeAICredential(provider: .gemini, enabled: false),
      makeAICredential(provider: .anthropic, enabled: true),
    ]

    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: credentials), [.openai, .anthropic])
  }

  func testAIProviderDropdownDeduplicatesEnabledProviders() {
    let credentials = [
      makeAICredential(provider: .openai, enabled: true),
      makeAICredential(provider: .openai, enabled: true),
      makeAICredential(provider: .gemini, enabled: true),
    ]

    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: credentials), [.openai, .gemini])
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
          "newProjects": [],
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
  func testAIQuickCaptureTaskModeCreatesProjectsForSplitTasks() async throws {
    var existingProjectID = ""
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: Self.taskClassificationWithNewProjectJSON(confidence: 0.93, existingProjectID: existingProjectID),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    guard let existingProject = await fixture.state.createProject(name: "Work", description: "", color: "#111111") else {
      return XCTFail("Expected Work project to be created")
    }
    existingProjectID = existingProject.id
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "send report, fix sink, and buy groceries", credentialID: credential.id)

    XCTAssertTrue(saved)
    XCTAssertNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertEqual(Set(fixture.state.tasks.map(\.title)), ["Send budget report", "Fix kitchen sink", "Buy groceries"])
    let homeProject = fixture.state.projects.first { $0.name == "Home Ops" }
    XCTAssertEqual(homeProject?.color, "#4A90E2")
    XCTAssertEqual(homeProject?.description, "Household errands and appointments")
    XCTAssertEqual(fixture.state.projects.filter { $0.name == "Home Ops" }.count, 1)
    XCTAssertEqual(fixture.state.tasks.first { $0.title == "Send budget report" }?.projectId, existingProject.id)
    XCTAssertEqual(fixture.state.tasks.first { $0.title == "Fix kitchen sink" }?.projectId, homeProject?.id)
    XCTAssertEqual(fixture.state.tasks.first { $0.title == "Buy groceries" }?.projectId, homeProject?.id)
    XCTAssertEqual(fixture.state.tasks.first { $0.title == "Buy groceries" }?.tags, ["errands", "weekly-shop"])
  }

  @MainActor
  func testAIQuickCaptureLowConfidenceDefersNewProjectUntilPreviewAccepted() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: Self.taskClassificationWithNewProjectJSON(confidence: 0.61, existingProjectID: nil),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await fixture.state.submitAIQuickCapture(input: "fix sink and buy groceries", credentialID: credential.id)

    XCTAssertFalse(saved)
    XCTAssertNotNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertTrue(fixture.state.tasks.isEmpty)
    XCTAssertFalse(fixture.state.projects.contains { $0.name == "Home Ops" })

    let previewSaved = await fixture.state.savePendingAIQuickCapturePreview()

    XCTAssertTrue(previewSaved)
    XCTAssertNil(fixture.state.pendingAIQuickCapturePreview)
    XCTAssertTrue(fixture.state.projects.contains { $0.name == "Home Ops" })
    XCTAssertFalse(fixture.state.tasks.isEmpty)
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
  func testAIProviderDropdownIncludesNvidia() {
    let credentials = [
      makeAICredential(provider: .anthropic, enabled: true),
      makeAICredential(provider: .nvidia, enabled: true),
    ]

    XCTAssertEqual(AIProviderDropdownAvailability.enabledProviders(from: credentials), [.anthropic, .nvidia])
  }

  @MainActor
  func testAIQuickCaptureRoutesThroughNvidiaCredential() async throws {
    var seenProvider: AICredentialProvider?
    var seenModel: String?
    let fixture = try makeAIQuickCaptureState { provider, _, model, _, _, _ in
      seenProvider = provider
      seenModel = model
      return AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.91),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(
      provider: .nvidia,
      name: "NIM",
      apiKey: "nvapi-test",
      modelPreference: "nvidia/nemotron-3.5-lightning-30b-a3b"
    )

    let saved = await fixture.state.submitAIQuickCapture(input: "book dentist and buy groceries", credentialID: credential.id)

    XCTAssertTrue(saved)
    XCTAssertEqual(seenProvider, .nvidia)
    XCTAssertEqual(seenModel, "nvidia/nemotron-3.5-lightning-30b-a3b")

    let usage = try await fixture.service.fetchSnapshot().usage
    XCTAssertEqual(usage.filter { $0.provider == .nvidia }.count, 1)
  }

  /// A credential saved with "Default" must use the models verified against the live API, not the
  /// compiled-in catalog — the catalog goes stale as hosted models reach end of life.
  @MainActor
  func testDefaultModelPrefersVerifiedModelsOverStaticCatalog() async throws {
    var seenModel: String?
    let fixture = try makeAIQuickCaptureState { _, _, model, _, _, _ in
      seenModel = model
      return AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.91),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(
      provider: .nvidia,
      name: "NIM",
      apiKey: "nvapi-test",
      modelPreference: nil,
      availableModels: ["nvidia/verified-from-api", "nvidia/other"]
    )

    _ = await fixture.state.submitAIQuickCapture(input: "buy milk", credentialID: credential.id)

    XCTAssertEqual(seenModel, "nvidia/verified-from-api")
    XCTAssertNotEqual(seenModel, AIProviderModelCatalog.models[.nvidia]?.first)
  }

  @MainActor
  func testExplicitModelPreferenceBeatsVerifiedModels() async throws {
    var seenModel: String?
    let fixture = try makeAIQuickCaptureState { _, _, model, _, _, _ in
      seenModel = model
      return AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.91),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(
      provider: .nvidia,
      name: "NIM",
      apiKey: "nvapi-test",
      modelPreference: "nvidia/chosen-by-user",
      availableModels: ["nvidia/verified-from-api"]
    )

    _ = await fixture.state.submitAIQuickCapture(input: "buy milk", credentialID: credential.id)

    XCTAssertEqual(seenModel, "nvidia/chosen-by-user")
  }

  /// A journal-mode reply legitimately omits `tasks`; a model not held to the schema by guided
  /// decoding will drop it, and that must not fail the whole capture.
  @MainActor
  func testJournalReplyMissingTasksAndConfidenceStillDecodes() async throws {
    let fixture = try makeAIQuickCaptureState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: """
        {
          "kind": "journal",
          "journal": {
            "title": "Morning pages",
            "content": "Felt good about the release today.",
            "mood": null,
            "tags": []
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
    let credential = try await fixture.service.addCredential(
      provider: .nvidia,
      name: "NIM",
      apiKey: "nvapi-test",
      modelPreference: "nvidia/nemotron-3.5-lightning-30b-a3b"
    )

    let saved = await fixture.state.submitAIQuickCapture(input: "felt good today", credentialID: credential.id)

    // No stated confidence routes to the preview rather than saving unreviewed.
    XCTAssertFalse(saved)
    XCTAssertNotNil(fixture.state.pendingAIQuickCapturePreview)
  }

  /// Sending the time as bare UTC made the model resolve "tonight" to 23:59Z, which is the next
  /// morning in any timezone east of Greenwich.
  @MainActor
  func testQuickCapturePromptStatesLocalTimeAndTimezone() async throws {
    var seenUserPrompt: String?
    let fixture = try makeAIQuickCaptureState { _, _, _, _, userPrompt, _ in
      seenUserPrompt = userPrompt
      return AIProviderTextGenerationResponse(
        text: Self.taskClassificationJSON(confidence: 0.91),
        promptTokens: 10,
        completionTokens: 20
      )
    }
    defer { fixture.cleanup() }

    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()
    let credential = try await fixture.service.addCredential(
      provider: .nvidia,
      name: "NIM",
      apiKey: "nvapi-test",
      modelPreference: "nvidia/nemotron-3.5-lightning-30b-a3b"
    )

    _ = await fixture.state.submitAIQuickCapture(input: "finish it by tonight", credentialID: credential.id)

    let prompt = try XCTUnwrap(seenUserPrompt)
    XCTAssertTrue(prompt.contains(TimeZone.current.identifier), prompt)

    let currentLine = try XCTUnwrap(
      prompt.split(separator: "\n").first { $0.hasPrefix("Current time:") }.map(String.init)
    )
    // A bare Z would mean the offset was lost again — unless the machine really is on UTC.
    if TimeZone.current.secondsFromGMT() != 0 {
      XCTAssertFalse(currentLine.contains("Z ("), currentLine)
      XCTAssertTrue(currentLine.contains("+") || currentLine.contains("-"), currentLine)
    }
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
      "newProjects": [],
      "tasks": [
        {
          "title": "Book dentist appointment",
          "description": null,
          "priority": "medium",
          "dueDate": null,
          "projectId": null,
          "projectName": null,
          "tags": ["health"],
          "subtasks": []
        },
        {
          "title": "Buy groceries",
          "description": null,
          "priority": null,
          "dueDate": null,
          "projectId": null,
          "projectName": null,
          "tags": ["errands"],
          "subtasks": []
        }
      ],
      "journal": null
    }
    """
  }

  private static func taskClassificationWithNewProjectJSON(confidence: Double, existingProjectID: String?) -> String {
    let workProjectID = existingProjectID.map { "\"\($0)\"" } ?? "null"
    return """
    {
      "kind": "tasks",
      "confidence": \(confidence),
      "newProjects": [
        {
          "name": "Home Ops",
          "description": "Household errands and appointments"
        }
      ],
      "tasks": [
        {
          "title": "Send budget report",
          "description": null,
          "priority": "high",
          "dueDate": null,
          "projectId": \(workProjectID),
          "projectName": null,
          "tags": ["finance"],
          "subtasks": []
        },
        {
          "title": "Fix kitchen sink",
          "description": null,
          "priority": "medium",
          "dueDate": null,
          "projectId": null,
          "projectName": "Home Ops",
          "tags": ["repair"],
          "subtasks": []
        },
        {
          "title": "Buy groceries",
          "description": null,
          "priority": null,
          "dueDate": null,
          "projectId": "missing",
          "projectName": "Home Ops",
          "tags": ["Errands", "weekly shop"],
          "subtasks": []
        }
      ],
      "journal": null
    }
    """
  }

  private func makeAICredential(
    provider: AICredentialProvider,
    enabled: Bool,
    id: String = UUID().uuidString
  ) -> AICredentialEntity {
    AICredentialEntity(
      id: id,
      provider: provider,
      name: provider.rawValue,
      apiKeyEncrypted: "keychain://\(id)",
      modelPreference: nil,
      enabled: enabled,
      priority: 0,
      metadataJSON: "{}",
      lastUsedAt: nil,
      totalRequests: 0,
      totalTokens: 0,
      successCount: 0,
      errorCount: 0,
      lastError: nil,
      lastErrorAt: nil,
      createdAt: Date(),
      updatedAt: Date()
    )
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
