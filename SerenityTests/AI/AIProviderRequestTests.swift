import XCTest
@testable import SerenityMac

/// What actually goes over the wire to Anthropic, read back through a stubbed URL loader.
final class AIProviderRequestTests: XCTestCase {
  override func setUp() {
    super.setUp()
    URLProtocol.registerClass(ProviderStubProtocol.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(ProviderStubProtocol.self)
    ProviderStubProtocol.reset()
    AppLogger.observer = nil
    super.tearDown()
  }

  func testAnthropicBodyCarriesNoSamplingAndRoomToThink() async throws {
    ProviderStubProtocol.reply = Self.anthropicReply(text: "{}")

    _ = try await generate(model: "claude-sonnet-5")

    let body = try XCTUnwrap(ProviderStubProtocol.lastBody)
    XCTAssertNil(body["temperature"])
    XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
    XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
  }

  func testEffortIsLeftOffForModelsThatRejectIt() async throws {
    ProviderStubProtocol.reply = Self.anthropicReply(text: "{}")

    _ = try await generate(model: "claude-haiku-4-5")

    let body = try XCTUnwrap(ProviderStubProtocol.lastBody)
    XCTAssertNil((body["output_config"] as? [String: Any])?["effort"])
    XCTAssertNil(body["temperature"])
  }

  func testEffortSupportFollowsTheModelFamily() {
    for model in ["claude-opus-4-5", "claude-opus-4-8", "claude-opus-5-5", "claude-sonnet-4-6", "claude-sonnet-5", "claude-fable-5-1"] {
      XCTAssertTrue(AIProviderAPIClient.anthropicAcceptsEffort(model), model)
    }
    for model in ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1", "claude-opus-4-20250514", "claude-3-7-sonnet-latest"] {
      XCTAssertFalse(AIProviderAPIClient.anthropicAcceptsEffort(model), model)
    }
  }

  func testATruncatedReplyIsIncompleteRatherThanUnreadable() async {
    ProviderStubProtocol.reply = Self.anthropicReply(text: "{\"kind\": \"ta", stopReason: "max_tokens")

    do {
      _ = try await generate(model: "claude-sonnet-5")
      XCTFail("Expected an incomplete response")
    } catch let error as AIProviderAPIError {
      guard case .incompleteResponse = error else {
        return XCTFail("Expected incompleteResponse, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error \(error)")
    }
  }

  func testARefusalIsIncompleteRatherThanUnreadable() async {
    ProviderStubProtocol.reply = Self.anthropicReply(text: "", stopReason: "refusal")

    do {
      _ = try await generate(model: "claude-sonnet-5")
      XCTFail("Expected an incomplete response")
    } catch let error as AIProviderAPIError {
      guard case .incompleteResponse = error else {
        return XCTFail("Expected incompleteResponse, got \(error)")
      }
    } catch {
      XCTFail("Unexpected error \(error)")
    }
  }

  func testThinkingBlocksAreNotReadAsTheAnswer() async throws {
    ProviderStubProtocol.reply = Data(
      """
      {"content": [{"type": "thinking", "thinking": "", "signature": "x"}, {"type": "text", "text": "{\\"ok\\": true}"}],
       "stop_reason": "end_turn", "usage": {"input_tokens": 3, "output_tokens": 4}}
      """.utf8
    )

    let response = try await generate(model: "claude-opus-5")

    XCTAssertEqual(response.text, "{\"ok\": true}")
  }

  func testDefaultModelPrefersTheCuratedPickOverNameOrder() {
    // Anthropic lists newest-first by id, which put an old Sonnet above every current model.
    let verified = ["claude-sonnet-4-5", "claude-sonnet-5", "claude-opus-4-7", "claude-haiku-4-5"]
    XCTAssertEqual(AIProviderModelCatalog.defaultModel(for: .anthropic, verifiedModels: verified), "claude-sonnet-5")
    XCTAssertEqual(AIProviderModelCatalog.defaultModel(for: .anthropic, verifiedModels: ["claude-opus-4-7"]), "claude-opus-4-7")
    XCTAssertEqual(AIProviderModelCatalog.defaultModel(for: .anthropic, verifiedModels: ["claude-x"]), "claude-x")
    XCTAssertEqual(AIProviderModelCatalog.defaultModel(for: .anthropic, verifiedModels: []), "claude-sonnet-5")
  }

  /// Only an Anthropic key, no model chosen: the call names a current model and sends no temperature.
  func testQuickCaptureWithOnlyAnAnthropicKeyUsesACurrentModel() async throws {
    ProviderStubProtocol.reply = Self.anthropicReply(text: Self.oneTaskJSON)
    let service = try makeService()
    let credential = try await service.addCredential(
      provider: .anthropic,
      name: "Anthropic",
      apiKey: "sk-ant-test",
      modelPreference: nil,
      availableModels: ["claude-sonnet-4-5", "claude-sonnet-5", "claude-opus-4-7", "claude-haiku-4-5"]
    )

    let classification = try await service.classifyQuickCapture(
      input: "Call the dentist",
      credentialID: credential.id,
      projects: [],
      availableTags: [],
      now: Date()
    )

    XCTAssertEqual(classification.tasks.first?.title, "Call the dentist")
    let body = try XCTUnwrap(ProviderStubProtocol.lastBody)
    XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
    XCTAssertNil(body["temperature"])
    XCTAssertEqual(ProviderStubProtocol.lastRequest?.url?.host, "api.anthropic.com")
  }

  func testDecodeFailureLogsTheShapeButNotTheText() async throws {
    var logged: [String] = []
    AppLogger.observer = { logged.append($0) }
    let secret = "my private note about the dentist"
    ProviderStubProtocol.reply = Self.anthropicReply(text: "{\"kind\": 5, \"journal\": \"\(secret)\"}")
    let service = try makeService()
    let credential = try await service.addCredential(
      provider: .anthropic,
      name: "Anthropic",
      apiKey: "sk-ant-test",
      modelPreference: "claude-sonnet-5"
    )

    _ = try? await service.classifyQuickCapture(
      input: "Call the dentist",
      credentialID: credential.id,
      projects: [],
      availableTags: [],
      now: Date()
    )

    let decodeLogs = logged.filter { $0.contains("decode failed") }
    XCTAssertFalse(decodeLogs.isEmpty, logged.joined(separator: "\n"))
    for line in logged {
      XCTAssertFalse(line.contains("private note"), line)
    }
    XCTAssertTrue(decodeLogs.allSatisfy { $0.contains("bytes") && $0.contains("journal") }, decodeLogs.joined())
  }

  // MARK: - Helpers

  private func generate(model: String) async throws -> AIProviderTextGenerationResponse {
    try await AIProviderAPIClient.generateQuickCaptureJSON(
      endpoint: AIProviderEndpoint(provider: .anthropic),
      apiKey: "sk-ant-test",
      model: model,
      systemPrompt: "system",
      userPrompt: "user",
      schema: ["type": "object"]
    )
  }

  private func makeService() throws -> AIWorkflowService {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-ai-request-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    return AIWorkflowService(
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      secretStore: KeychainSecretStore(service: "test.ai.request", backend: MemorySecretBackend())
    )
  }

  static func anthropicReply(text: String, stopReason: String = "end_turn") -> Data {
    let object: [String: Any] = [
      "content": [["type": "text", "text": text]],
      "stop_reason": stopReason,
      "usage": ["input_tokens": 10, "output_tokens": 20],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  static let oneTaskJSON = """
  {
    "kind": "tasks",
    "confidence": 0.9,
    "newProjects": [],
    "tasks": [
      {
        "title": "Call the dentist",
        "description": null,
        "priority": "high",
        "dueDate": null,
        "projectId": null,
        "projectName": null,
        "tags": [],
        "subtasks": []
      }
    ],
    "journal": null
  }
  """
}

final class ProviderStubProtocol: URLProtocol {
  static var reply = Data()
  static var status = 200
  static var headers: [String: String] = [:]
  static var lastRequest: URLRequest?
  static var lastBody: [String: Any]?
  static var requestCount = 0
  /// When on, each request takes the next reply from `ScriptedReplies.queue`.
  static var scripted = false

  static func reset() {
    reply = Data()
    status = 200
    headers = [:]
    lastRequest = nil
    lastBody = nil
    requestCount = 0
    scripted = false
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.requestCount += 1
    Self.lastRequest = request
    if let data = Self.bodyData(of: request) {
      Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    var status = Self.status
    var reply = Self.reply
    var headers = Self.headers
    if Self.scripted, !ScriptedReplies.queue.isEmpty {
      (status, reply, headers) = ScriptedReplies.queue.removeFirst()
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"].merging(headers) { $1 }
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// The loader hands a protocol the body as a stream, not as `httpBody`.
  private static func bodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class MemorySecretBackend: SecretStorageBackend {
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
