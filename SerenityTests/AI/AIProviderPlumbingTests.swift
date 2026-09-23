import XCTest
@testable import SerenityMac

/// Structured outputs, retries and error reporting on the provider path.
final class AIProviderPlumbingTests: XCTestCase {
  private var sleeps: [TimeInterval] = []
  private var originalSleep: ((TimeInterval) async throws -> Void)!

  override func setUp() {
    super.setUp()
    URLProtocol.registerClass(ProviderStubProtocol.self)
    originalSleep = AIProviderAPIClient.sleep
    AIProviderAPIClient.sleep = { [weak self] seconds in self?.sleeps.append(seconds) }
  }

  override func tearDown() {
    URLProtocol.unregisterClass(ProviderStubProtocol.self)
    ProviderStubProtocol.reset()
    ScriptedReplies.reset()
    AIProviderAPIClient.sleep = originalSleep
    super.tearDown()
  }

  // MARK: - Structured outputs

  func testAModelWithStructuredOutputsGetsTheSchemaOnceAndWithoutLimits() async throws {
    ProviderStubProtocol.reply = AIProviderRequestTests.anthropicReply(text: "{}")

    _ = try await generate(provider: .anthropic, model: "claude-sonnet-5", schema: SlackProposalPlanner.schema())

    let body = try XCTUnwrap(ProviderStubProtocol.lastBody)
    let config = try XCTUnwrap(body["output_config"] as? [String: Any])
    let format = try XCTUnwrap(config["format"] as? [String: Any])
    XCTAssertEqual(format["type"] as? String, "json_schema")
    let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: format["schema"]!), as: UTF8.self)
    XCTAssertFalse(schemaText.contains("minimum"))
    XCTAssertFalse(schemaText.contains("maximum"))
    XCTAssertFalse(schemaText.contains("slack_decisions"), "The name is not part of the schema")
    XCTAssertEqual(config["effort"] as? String, "low")
    let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? String)
    XCTAssertFalse(content.contains("JSON Schema"))
  }

  func testAModelWithoutStructuredOutputsKeepsTheSchemaInThePrompt() async throws {
    ProviderStubProtocol.reply = AIProviderRequestTests.anthropicReply(text: "{}")

    _ = try await generate(provider: .anthropic, model: "claude-opus-4-7", schema: SlackProposalPlanner.schema())

    let body = try XCTUnwrap(ProviderStubProtocol.lastBody)
    XCTAssertNil((body["output_config"] as? [String: Any])?["format"])
    let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? String)
    XCTAssertTrue(content.contains("JSON Schema"))
  }

  func testOnlyConstraintKeywordsAreStrippedNotPropertiesWithTheSameName() {
    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "maximum": ["type": "number", "minimum": 0, "maximum": 10],
        "tags": ["type": "array", "items": ["type": "string", "maxLength": 20], "maxItems": 5],
      ],
    ]

    let stripped = AIProviderAPIClient.strippingUnsupportedConstraints(schema)

    let properties = stripped["properties"] as? [String: Any]
    let maximum = properties?["maximum"] as? [String: Any]
    XCTAssertNotNil(maximum)
    XCTAssertNil(maximum?["minimum"])
    XCTAssertNil(maximum?["maximum"])
    let tags = properties?["tags"] as? [String: Any]
    XCTAssertNil(tags?["maxItems"])
    XCTAssertNil((tags?["items"] as? [String: Any])?["maxLength"])
  }

  func testStructuredOutputSupportFollowsTheDocumentedModels() {
    for model in ["claude-sonnet-5", "claude-opus-5", "claude-opus-5-5", "claude-opus-4-8", "claude-haiku-4-5", "claude-fable-5-1"] {
      XCTAssertTrue(AIProviderAPIClient.anthropicSupportsStructuredOutputs(model), model)
    }
    for model in ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-5"] {
      XCTAssertFalse(AIProviderAPIClient.anthropicSupportsStructuredOutputs(model), model)
    }
  }

  // MARK: - Schema names

  func testEachFeatureNamesItsOwnSchemaOnOpenAI() async throws {
    ProviderStubProtocol.reply = Data(#"{"output_text":"{}","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)

    for (schema, name) in [
      (SlackProposalPlanner.schema(), "slack_decisions"),
      (CaptureCommandDrafter.schema(), "capture_drafts"),
      (StandupWriter.schema(), "standup_script"),
    ] {
      _ = try await generate(provider: .openai, model: "gpt-5.5", schema: schema)
      let format = ((ProviderStubProtocol.lastBody?["text"] as? [String: Any])?["format"] as? [String: Any])
      XCTAssertEqual(format?["name"] as? String, name)
      XCTAssertNil((format?["schema"] as? [String: Any])?["title"])
    }
  }

  // MARK: - Retries and status codes

  func testAnOverloadedReplyIsRetried() async throws {
    ScriptedReplies.queue = [
      (529, Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8), [:]),
      (200, AIProviderRequestTests.anthropicReply(text: "{}"), [:]),
    ]
    ProviderStubProtocol.scripted = true

    _ = try await generate(provider: .anthropic, model: "claude-sonnet-5")

    XCTAssertEqual(ProviderStubProtocol.requestCount, 2)
    XCTAssertEqual(sleeps, [1])
  }

  func testRetryAfterIsHonoured() async throws {
    ScriptedReplies.queue = [
      (429, Data("{}".utf8), ["retry-after": "7"]),
      (200, AIProviderRequestTests.anthropicReply(text: "{}"), [:]),
    ]
    ProviderStubProtocol.scripted = true

    _ = try await generate(provider: .anthropic, model: "claude-sonnet-5")

    XCTAssertEqual(sleeps, [7])
  }

  func testServerErrorsGiveUpAfterTheRetryBudget() async {
    ProviderStubProtocol.status = 500
    ProviderStubProtocol.reply = Data(#"{"error":{"message":"boom"}}"#.utf8)

    do {
      _ = try await generate(provider: .anthropic, model: "claude-sonnet-5")
      XCTFail("Expected an error")
    } catch {
      XCTAssertEqual(error as? AIProviderAPIError, .unexpected(500, "boom"))
    }
    XCTAssertEqual(ProviderStubProtocol.requestCount, AIProviderAPIClient.maxRetries + 1)
    XCTAssertEqual(sleeps, [1, 2, 4])
  }

  func testA403IsAPermissionErrorNotABadKey() async {
    ProviderStubProtocol.status = 403
    ProviderStubProtocol.reply = Data(#"{"error":{"message":"model not available to this org"}}"#.utf8)

    do {
      _ = try await generate(provider: .anthropic, model: "claude-sonnet-5")
      XCTFail("Expected an error")
    } catch {
      XCTAssertEqual(error as? AIProviderAPIError, .permissionDenied("model not available to this org"))
    }
    XCTAssertEqual(ProviderStubProtocol.requestCount, 1)
  }

  func testTheRequestTimeoutIsLongerThanTheDefault() async throws {
    ProviderStubProtocol.reply = AIProviderRequestTests.anthropicReply(text: "{}")

    _ = try await generate(provider: .anthropic, model: "claude-sonnet-5")

    XCTAssertEqual(ProviderStubProtocol.lastRequest?.timeoutInterval, AIProviderAPIClient.requestTimeout)
  }

  // MARK: - Credential bookkeeping

  func testUnusableOutputIsNotChargedToTheKey() async throws {
    let (service, credentialID) = try await makeService { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(text: "not json", promptTokens: 1, completionTokens: 1)
    }

    _ = try? await service.classifyQuickCapture(input: "x", credentialID: credentialID, projects: [], availableTags: [], now: Date())

    let credential = try await credentialRow(service, credentialID)
    XCTAssertEqual(credential.errorCount, 0)
    XCTAssertNil(credential.lastError)
    XCTAssertEqual(credential.totalRequests, 1)
  }

  func testARejectedKeyIsChargedToTheKey() async throws {
    let (service, credentialID) = try await makeService { _, _, _, _, _, _ in
      throw AIProviderAPIError.invalidKey
    }

    _ = try? await service.classifyQuickCapture(input: "x", credentialID: credentialID, projects: [], availableTags: [], now: Date())

    let credential = try await credentialRow(service, credentialID)
    XCTAssertEqual(credential.errorCount, 1)
    XCTAssertEqual(credential.lastError, "Invalid API key")
  }

  @MainActor
  func testSlackAndCaptureCommandsPreferTheActiveProvider() {
    let openai = credential(.openai, priority: 0)
    let anthropic = credential(.anthropic, priority: 5)

    XCTAssertEqual(AppState.preferredCredential(in: [openai, anthropic], activeProvider: .anthropic)?.id, anthropic.id)
    XCTAssertEqual(AppState.preferredCredential(in: [openai, anthropic], activeProvider: nil)?.id, openai.id)
  }

  // MARK: - Helpers

  private func generate(
    provider: AICredentialProvider,
    model: String,
    schema: [String: Any] = ["type": "object"]
  ) async throws -> AIProviderTextGenerationResponse {
    try await AIProviderAPIClient.generateQuickCaptureJSON(
      endpoint: AIProviderEndpoint(provider: provider),
      apiKey: "key",
      model: model,
      systemPrompt: "system",
      userPrompt: "user",
      schema: schema
    )
  }

  private func makeService(
    generator: @escaping AIWorkflowService.QuickCaptureGenerationHandler
  ) async throws -> (AIWorkflowService, String) {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-ai-plumbing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let service = AIWorkflowService(
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      secretStore: KeychainSecretStore(service: "test.ai.plumbing", backend: PlumbingSecretBackend()),
      quickCaptureGenerator: generator
    )
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk", modelPreference: "gpt-5.5")
    return (service, credential.id)
  }

  private func credentialRow(_ service: AIWorkflowService, _ id: String) async throws -> AICredentialEntity {
    let snapshot = try await service.fetchSnapshot(limit: 10)
    return try XCTUnwrap(snapshot.credentials.first { $0.id == id })
  }

  private func credential(_ provider: AICredentialProvider, priority: Int) -> AICredentialEntity {
    AICredentialEntity(
      id: UUID().uuidString,
      provider: provider,
      name: provider.rawValue,
      apiKeyEncrypted: "keychain://x",
      modelPreference: nil,
      enabled: true,
      priority: priority,
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

/// Replies handed out in order when `ProviderStubProtocol.scripted` is on.
enum ScriptedReplies {
  static var queue: [(Int, Data, [String: String])] = []

  static func reset() {
    queue = []
  }
}

private final class PlumbingSecretBackend: SecretStorageBackend {
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
