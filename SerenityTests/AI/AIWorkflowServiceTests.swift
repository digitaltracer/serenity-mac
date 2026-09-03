import XCTest
@testable import SerenityMac

final class AIWorkflowServiceTests: XCTestCase {
  func testGenerateInsightsFailsWithoutCredentials() async throws {
    let (service, _, _) = try makeService()

    do {
      _ = try await service.generateInsights(tasks: [], journalEntries: [], projects: [], goals: [])
      XCTFail("Expected missing credential error")
    } catch let error as AIWorkflowError {
      XCTAssertEqual(error, .noCredentialConfigured)
    }
  }

  func testCredentialFailoverSkipsMissingKeychainSecret() async throws {
    let (service, backend, secretServiceName) = try makeService()

    let first = try await service.addCredential(
      provider: .openai,
      name: "Primary",
      apiKey: "sk-primary",
      modelPreference: "gpt-4o"
    )
    _ = try await service.addCredential(
      provider: .gemini,
      name: "Secondary",
      apiKey: "gm-secondary",
      modelPreference: "gemini-3-flash-preview"
    )

    try backend.delete(service: secretServiceName, key: "ai.credentials.\(first.id).apiKey")

    let task = TaskEntity(
      id: UUID().uuidString,
      title: "Task",
      description: nil,
      completed: true,
      completedAt: Date(),
      priority: .medium,
      dueDate: Date(),
      projectId: nil,
      tags: [],
      createdAt: Date(),
      updatedAt: Date(),
      subtasks: [],
      recurring: nil,
      userId: nil
    )

    let summary = try await service.generateSummary(type: .tasks, tasks: [task], journalEntries: [])
    XCTAssertEqual(summary.provider, .gemini)

    let snapshot = try await service.fetchSnapshot(limit: 20)
    XCTAssertEqual(snapshot.summaries.count, 1)
    XCTAssertEqual(snapshot.usage.count, 1)
    XCTAssertEqual(snapshot.usage.first?.provider, .gemini)
    XCTAssertEqual(snapshot.usage.first?.model, "gemini-3-flash-preview")
    XCTAssertNotNil(snapshot.usage.first?.totalCostUSD)
  }

  func testClassifyQuickCaptureSplitsMultipleTasksAndKeepsNewProject() async throws {
    let (service, _, _) = try makeService { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: """
        {
          "kind": "tasks",
          "confidence": 0.92,
          "newProjects": [
            {
              "name": "Home Ops",
              "description": "Household errands and appointments"
            }
          ],
          "tasks": [
            {
              "title": "Send budget report",
              "description": "Share the latest budget report",
              "priority": "high",
              "dueDate": "2026-05-18T09:00:00Z",
              "projectId": "work",
              "projectName": null,
              "tags": ["Finance", "reports"],
              "subtasks": ["Review numbers", "Email team"]
            },
            {
              "title": "Buy groceries",
              "description": null,
              "priority": null,
              "dueDate": null,
              "projectId": "archived-home",
              "projectName": "Home Ops",
              "tags": ["Errands"],
              "subtasks": []
            }
          ],
          "journal": null
        }
        """,
        promptTokens: 20,
        completionTokens: 40
      )
    }
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let classification = try await service.classifyQuickCapture(
      input: "send budget report tomorrow and buy groceries",
      credentialID: credential.id,
      projects: [
        AIQuickCaptureProjectContext(id: "work", name: "Work", description: nil, archived: false),
        AIQuickCaptureProjectContext(id: "archived-home", name: "Old Home", description: nil, archived: true),
      ],
      availableTags: ["finance"],
      now: Date()
    )

    XCTAssertEqual(classification.kind, .tasks)
    XCTAssertEqual(classification.newProjects.count, 1)
    XCTAssertEqual(classification.newProjects.first?.name, "Home Ops")
    XCTAssertEqual(classification.newProjects.first?.description, "Household errands and appointments")
    XCTAssertEqual(classification.tasks.count, 2)
    XCTAssertEqual(classification.tasks[0].projectId, "work")
    XCTAssertNil(classification.tasks[0].projectName)
    XCTAssertEqual(classification.tasks[0].priority, .high)
    XCTAssertEqual(classification.tasks[0].tags, ["finance", "reports"])
    XCTAssertNil(classification.tasks[1].projectId)
    XCTAssertEqual(classification.tasks[1].projectName, "Home Ops")
    XCTAssertEqual(classification.tasks[1].tags, ["errands"])
    XCTAssertEqual(classification.tasks[1].priority, .medium)
  }

  func testClassifyQuickCaptureReturnsSingleJournalEntry() async throws {
    let (service, _, _) = try makeService { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(
        text: """
        {
          "kind": "journal",
          "confidence": 0.88,
          "newProjects": [],
          "tasks": [],
          "journal": {
            "title": "A quieter morning",
            "content": "I felt calmer today after taking a walk before work.",
            "mood": "happy",
            "tags": ["reflection"]
          }
        }
        """,
        promptTokens: 15,
        completionTokens: 30
      )
    }
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let classification = try await service.classifyQuickCapture(
      input: "I felt calmer today after taking a walk before work.",
      credentialID: credential.id,
      projects: [],
      availableTags: [],
      now: Date()
    )

    XCTAssertEqual(classification.kind, .journal)
    XCTAssertEqual(classification.journal?.title, "A quieter morning")
    XCTAssertEqual(classification.journal?.mood, .happy)
    XCTAssertTrue(classification.tasks.isEmpty)
  }

  func testClassifyQuickCaptureRetriesMalformedJSONOnce() async throws {
    var callCount = 0
    let (service, _, _) = try makeService { _, _, _, _, _, _ in
      callCount += 1
      if callCount == 1 {
        return AIProviderTextGenerationResponse(text: "not json", promptTokens: 5, completionTokens: 5)
      }
      return AIProviderTextGenerationResponse(
        text: """
        {
          "kind": "tasks",
          "confidence": 0.81,
          "newProjects": [],
          "tasks": [
            {
              "title": "Book dentist appointment",
              "description": null,
              "priority": "medium",
              "dueDate": null,
              "projectId": null,
              "projectName": null,
              "tags": [],
              "subtasks": []
            }
          ],
          "journal": null
        }
        """,
        promptTokens: 8,
        completionTokens: 16
      )
    }
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let classification = try await service.classifyQuickCapture(
      input: "book dentist appointment",
      credentialID: credential.id,
      projects: [],
      availableTags: [],
      now: Date()
    )

    XCTAssertEqual(callCount, 2)
    XCTAssertEqual(classification.tasks.first?.title, "Book dentist appointment")
  }

  /// A bare status code makes a rejected model id or payload field unguessable, so the provider's
  /// own explanation has to reach the toast.
  func testUnexpectedStatusCarriesProviderDetail() {
    let detailed = AIProviderAPIError.unexpected(400, "invalid model id")
    XCTAssertEqual(detailed.errorDescription, "Provider returned HTTP 400: invalid model id")

    XCTAssertEqual(AIProviderAPIError.unexpected(500, nil).errorDescription, "Provider returned HTTP 500")
    XCTAssertEqual(AIProviderAPIError.unexpected(500, "").errorDescription, "Provider returned HTTP 500")
  }

  private func makeService(
    quickCaptureGenerator: @escaping AIWorkflowService.QuickCaptureGenerationHandler = AIProviderAPIClient.generateQuickCaptureJSON
  ) throws -> (AIWorkflowService, InMemorySecretStorageBackend, String) {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-ai-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let databaseURL = baseURL.appendingPathComponent("serenity.sqlite")

    let sqliteAdapter = SQLiteBackendAdapter(databaseURL: databaseURL)
    let backend = InMemorySecretStorageBackend()
    let secretServiceName = "test.ai.workflow"
    let secretStore = KeychainSecretStore(service: secretServiceName, backend: backend)
    let service = AIWorkflowService(
      sqliteBackendAdapter: sqliteAdapter,
      secretStore: secretStore,
      quickCaptureGenerator: quickCaptureGenerator
    )

    return (service, backend, secretServiceName)
  }
}

private final class InMemorySecretStorageBackend: SecretStorageBackend {
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
