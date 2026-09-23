import Foundation

enum AIProviderAPIError: Error, LocalizedError, Equatable {
  case invalidKey
  /// The key works but may not do this: a model it has no access to, or an org restriction.
  case permissionDenied(String?)
  case rateLimited
  case network(String)
  case decoding
  case invalidResponse
  case incompleteResponse(String)
  case missingCustomDomain
  case invalidCustomDomain(String)
  case unexpected(Int, String?)

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      return "Invalid API key"
    case .permissionDenied(let detail):
      guard let detail, !detail.isEmpty else {
        return "This API key is not allowed to make this request"
      }
      return "This API key is not allowed to make this request: \(detail)"
    case .rateLimited:
      return "Rate limited — try again shortly"
    case .network(let message):
      return "Network error: \(message)"
    case .decoding:
      return "Unexpected response from provider"
    case .invalidResponse:
      return "Provider response did not include usable text"
    case .incompleteResponse(let reason):
      return "Provider response was incomplete: \(reason)"
    case .missingCustomDomain:
      return "This provider needs a domain"
    case .invalidCustomDomain(let value):
      return "\(value) is not a usable domain"
    case .unexpected(let status, let detail):
      guard let detail, !detail.isEmpty else {
        return "Provider returned HTTP \(status)"
      }
      return "Provider returned HTTP \(status): \(detail)"
    }
  }
}

/// Where a call goes. The hosted providers each live at a fixed address; a custom provider carries
/// the domain its owner runs it on.
struct AIProviderEndpoint: Equatable, Sendable {
  let provider: AICredentialProvider
  let baseURL: String?

  init(provider: AICredentialProvider, baseURL: String? = nil) {
    self.provider = provider
    self.baseURL = baseURL
  }

  /// A domain is typed as a host or a path prefix, so the scheme and the OpenAI `/v1` segment are
  /// filled in here: `adarshnb.com/llm/` resolves to `https://adarshnb.com/llm/v1`.
  static func normalizedCustomBase(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let lowered = value.lowercased()
    if !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
      value = "https://" + value
    }
    while value.hasSuffix("/") {
      value.removeLast()
    }
    guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
    if !value.lowercased().hasSuffix("/v1") {
      value += "/v1"
    }
    return value
  }

  func customURL(path: String) throws -> URL {
    guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      throw AIProviderAPIError.missingCustomDomain
    }
    guard let base = Self.normalizedCustomBase(raw), let url = URL(string: base + path) else {
      throw AIProviderAPIError.invalidCustomDomain(raw)
    }
    return url
  }
}

struct AIProviderTextGenerationResponse: Equatable, Sendable {
  let text: String
  let promptTokens: Int
  let completionTokens: Int
}

enum AIProviderAPIClient {
  static func fetchModels(endpoint: AIProviderEndpoint, apiKey: String) async throws -> [String] {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIProviderAPIError.invalidKey }
    switch endpoint.provider {
    case .openai:
      return try await fetchOpenAIModels(apiKey: trimmed)
    case .anthropic:
      return try await fetchAnthropicModels(apiKey: trimmed)
    case .gemini:
      return try await fetchGeminiModels(apiKey: trimmed)
    case .nvidia:
      return try await fetchNvidiaModels(apiKey: trimmed)
    case .custom:
      return try await fetchCustomModels(endpoint: endpoint, apiKey: trimmed)
    }
  }

  static func generateQuickCaptureJSON(
    endpoint: AIProviderEndpoint,
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any]
  ) async throws -> AIProviderTextGenerationResponse {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIProviderAPIError.invalidKey }
    let (schemaName, schema) = namedSchema(schema)

    switch endpoint.provider {
    case .openai:
      return try await generateOpenAIJSON(
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema,
        schemaName: schemaName
      )
    case .anthropic:
      return try await generateAnthropicJSON(
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema
      )
    case .gemini:
      return try await generateGeminiJSON(
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema
      )
    case .nvidia:
      return try await generateNvidiaJSON(
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema
      )
    case .custom:
      return try await generateCustomJSON(
        endpoint: endpoint,
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema,
        schemaName: schemaName
      )
    }
  }

  /// Each feature names its schema in the root `title`. It becomes the name OpenAI-style APIs ask
  /// for and is dropped from the schema itself.
  static func namedSchema(_ schema: [String: Any]) -> (name: String, schema: [String: Any]) {
    var schema = schema
    let name = (schema.removeValue(forKey: "title") as? String) ?? "response"
    return (name, schema)
  }

  // MARK: - OpenAI

  private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
  }

  private struct OpenAIModel: Decodable {
    let id: String
  }

  private static func fetchOpenAIModels(apiKey: String) async throws -> [String] {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let payload: OpenAIModelsResponse = try await perform(request)
    let allIDs = payload.data.map(\.id)
    let chatIDs = allIDs.filter(isLikelyOpenAIChatModel)
    return (chatIDs.isEmpty ? allIDs : chatIDs).sorted()
  }

  private static func isLikelyOpenAIChatModel(_ id: String) -> Bool {
    let lowered = id.lowercased()
    let prefixes = ["gpt-", "o1", "o3", "o4", "chatgpt"]
    return prefixes.contains { lowered.hasPrefix($0) }
  }

  private struct OpenAIResponsesPayload: Decodable {
    struct OutputItem: Decodable {
      struct ContentItem: Decodable {
        let type: String?
        let text: String?
      }

      let content: [ContentItem]?
    }

    struct Usage: Decodable {
      let inputTokens: Int?
      let outputTokens: Int?

      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
      }
    }

    let outputText: String?
    let output: [OutputItem]?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
      case outputText = "output_text"
      case output
      case usage
    }
  }

  private static func generateOpenAIJSON(
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any],
    schemaName: String
  ) async throws -> AIProviderTextGenerationResponse {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    request.httpBody = try jsonData([
      "model": model,
      "temperature": 0,
      "input": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userPrompt],
      ],
      "text": [
        "format": [
          "type": "json_schema",
          "name": schemaName,
          "strict": true,
          "schema": schema,
        ],
      ],
    ])

    let payload: OpenAIResponsesPayload = try await perform(request)
    let text = payload.outputText ?? payload.output?
      .flatMap { $0.content ?? [] }
      .compactMap(\.text)
      .joined(separator: "\n")

    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderAPIError.invalidResponse
    }

    return AIProviderTextGenerationResponse(
      text: text,
      promptTokens: payload.usage?.inputTokens ?? estimateTokenCount(systemPrompt + userPrompt),
      completionTokens: payload.usage?.outputTokens ?? estimateTokenCount(text)
    )
  }

  // MARK: - Anthropic

  private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
  }

  private struct AnthropicModel: Decodable {
    let id: String
  }

  private static func fetchAnthropicModels(apiKey: String) async throws -> [String] {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let payload: AnthropicModelsResponse = try await perform(request)
    return payload.data.map(\.id).sorted(by: >)
  }

  private struct AnthropicMessagesPayload: Decodable {
    struct ContentItem: Decodable {
      let type: String?
      let text: String?
    }

    struct Usage: Decodable {
      let inputTokens: Int?
      let outputTokens: Int?

      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
      }
    }

    let content: [ContentItem]
    let usage: Usage?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
      case content
      case usage
      case stopReason = "stop_reason"
    }
  }

  /// Room for adaptive thinking on the models that think by default, while staying non-streaming.
  static let anthropicMaxTokens = 16_000

  /// Effort arrived with Opus 4.5 and Sonnet 4.6; Haiku and older Sonnets reject the field.
  static func anthropicAcceptsEffort(_ model: String) -> Bool {
    if isFableOrMythos(model) { return true }
    guard let (family, version) = anthropicFamilyVersion(model) else { return false }
    switch family {
    case "opus":
      return version >= 405
    case "sonnet":
      return version >= 406
    default:
      return false
    }
  }

  /// The models Anthropic documents for `output_config.format`; the rest get the schema in the prompt.
  static func anthropicSupportsStructuredOutputs(_ model: String) -> Bool {
    if isFableOrMythos(model) { return true }
    guard let (family, version) = anthropicFamilyVersion(model) else { return false }
    switch family {
    case "opus":
      return version >= 408 || version == 405 || version == 401
    case "sonnet":
      return version >= 500
    case "haiku":
      return version >= 405
    default:
      return false
    }
  }

  private static func isFableOrMythos(_ model: String) -> Bool {
    let lowered = model.lowercased()
    return lowered.contains("fable") || lowered.contains("mythos")
  }

  /// `claude-opus-4-8` → ("opus", 408). A dated id such as `claude-opus-4-20250514` is the .0
  /// release, not minor 20250514.
  private static func anthropicFamilyVersion(_ model: String) -> (String, Int)? {
    let parts = model.lowercased().split(separator: "-").map(String.init)
    guard let familyIndex = parts.firstIndex(where: { ["opus", "sonnet", "haiku"].contains($0) }),
          familyIndex + 1 < parts.count,
          let major = Int(parts[familyIndex + 1])
    else {
      return nil
    }
    let minor = parts.indices.contains(familyIndex + 2)
      ? (parts[familyIndex + 2].count <= 2 ? Int(parts[familyIndex + 2]) ?? 0 : 0)
      : 0
    return (parts[familyIndex], major * 100 + minor)
  }

  /// Structured outputs reject numeric, length and array-size limits. They are dropped here and the
  /// decoders enforce them instead (confidence is clamped to 0...1 where it is read).
  static func strippingUnsupportedConstraints(_ schema: [String: Any]) -> [String: Any] {
    let unsupported: Set<String> = [
      "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
      "minLength", "maxLength", "minItems", "maxItems", "uniqueItems",
    ]
    var node = schema.filter { !unsupported.contains($0.key) }
    if let properties = node["properties"] as? [String: Any] {
      node["properties"] = properties.mapValues { value -> Any in
        (value as? [String: Any]).map(strippingUnsupportedConstraints) ?? value
      }
    }
    if let items = node["items"] as? [String: Any] {
      node["items"] = strippingUnsupportedConstraints(items)
    }
    for key in ["anyOf", "allOf", "oneOf"] {
      if let options = node[key] as? [[String: Any]] {
        node[key] = options.map(strippingUnsupportedConstraints)
      }
    }
    for key in ["$defs", "definitions"] {
      if let definitions = node[key] as? [String: Any] {
        node[key] = definitions.mapValues { value -> Any in
          (value as? [String: Any]).map(strippingUnsupportedConstraints) ?? value
        }
      }
    }
    return node
  }

  private static func generateAnthropicJSON(
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any]
  ) async throws -> AIProviderTextGenerationResponse {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Structured outputs enforce the schema, so it is sent once, there, instead of in the prompt.
    let structured = anthropicSupportsStructuredOutputs(model)
    let content = structured ? userPrompt : """
      \(userPrompt)

      Return only one JSON object matching this JSON Schema. Do not wrap it in markdown:
      \(try jsonString(schema))
      """
    // No sampling parameters: current Claude models reject `temperature` with a 400.
    var body: [String: Any] = [
      "model": model,
      "max_tokens": anthropicMaxTokens,
      "system": systemPrompt,
      "messages": [
        ["role": "user", "content": content],
      ],
    ]
    var outputConfig: [String: Any] = [:]
    if anthropicAcceptsEffort(model) {
      outputConfig["effort"] = "low"
    }
    if structured {
      outputConfig["format"] = ["type": "json_schema", "schema": strippingUnsupportedConstraints(schema)]
    }
    if !outputConfig.isEmpty {
      body["output_config"] = outputConfig
    }
    request.httpBody = try jsonData(body)

    let payload: AnthropicMessagesPayload = try await perform(request)
    switch payload.stopReason {
    case "max_tokens":
      throw AIProviderAPIError.incompleteResponse(
        "the reply hit the \(anthropicMaxTokens)-token limit before it finished"
      )
    case "refusal":
      throw AIProviderAPIError.incompleteResponse("the model declined to answer this request")
    default:
      break
    }
    let text = payload.content
      .filter { $0.type == nil || $0.type == "text" }
      .compactMap(\.text)
      .joined(separator: "\n")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderAPIError.invalidResponse
    }

    return AIProviderTextGenerationResponse(
      text: text,
      promptTokens: payload.usage?.inputTokens ?? estimateTokenCount(systemPrompt + userPrompt),
      completionTokens: payload.usage?.outputTokens ?? estimateTokenCount(text)
    )
  }

  // MARK: - Gemini

  private struct GeminiModelsResponse: Decodable {
    let models: [GeminiModel]
  }

  private struct GeminiModel: Decodable {
    let name: String
    let supportedGenerationMethods: [String]?
  }

  private static func fetchGeminiModels(apiKey: String) async throws -> [String] {
    let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
    let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(encoded)")!
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let payload: GeminiModelsResponse = try await perform(request)
    return payload.models
      .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
      .map { model -> String in
        if let last = model.name.split(separator: "/").last {
          return String(last)
        }
        return model.name
      }
      .sorted()
  }

  private struct GeminiGenerateContentPayload: Decodable {
    struct Candidate: Decodable {
      struct Content: Decodable {
        struct Part: Decodable {
          let text: String?
        }

        let parts: [Part]?
      }

      let content: Content?
    }

    struct UsageMetadata: Decodable {
      let promptTokenCount: Int?
      let candidatesTokenCount: Int?
    }

    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?
  }

  private static func generateGeminiJSON(
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any]
  ) async throws -> AIProviderTextGenerationResponse {
    let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
    let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
    var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent?key=\(encodedKey)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try jsonData([
      "contents": [
        [
          "role": "user",
          "parts": [
            [
              "text": """
              \(systemPrompt)

              \(userPrompt)
              """,
            ],
          ],
        ],
      ],
      "generationConfig": [
        "temperature": 0,
        "responseMimeType": "application/json",
        "responseJsonSchema": schema,
      ],
    ])

    let payload: GeminiGenerateContentPayload = try await perform(request)
    let text = payload.candidates?
      .compactMap(\.content)
      .flatMap { $0.parts ?? [] }
      .compactMap(\.text)
      .joined(separator: "\n")

    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderAPIError.invalidResponse
    }

    return AIProviderTextGenerationResponse(
      text: text,
      promptTokens: payload.usageMetadata?.promptTokenCount ?? estimateTokenCount(systemPrompt + userPrompt),
      completionTokens: payload.usageMetadata?.candidatesTokenCount ?? estimateTokenCount(text)
    )
  }

  // MARK: - NVIDIA NIM

  private static let nvidiaBaseURL = "https://integrate.api.nvidia.com/v1"

  private static func fetchNvidiaModels(apiKey: String) async throws -> [String] {
    var request = URLRequest(url: URL(string: "\(nvidiaBaseURL)/models")!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let payload: OpenAIModelsResponse = try await perform(request)
    let allIDs = payload.data.map(\.id)
    let chatIDs = allIDs.filter(isLikelyNvidiaChatModel)
    return (chatIDs.isEmpty ? allIDs : chatIDs).sorted()
  }

  /// The catalog lists chat, embedding, reranking and OCR models with no capability field, so the
  /// non-conversational families are filtered out by name.
  private static func isLikelyNvidiaChatModel(_ id: String) -> Bool {
    let lowered = id.lowercased()
    let excluded = ["embed", "rerank", "embedqa", "ocr", "asr", "tts", "riva", "guard", "retriever"]
    return !excluded.contains { lowered.contains($0) }
  }

  private struct ChatCompletionPayload: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let content: String?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
          case content
          case reasoningContent = "reasoning_content"
        }
      }

      let message: Message?
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
      }
    }

    struct Usage: Decodable {
      let promptTokens: Int?
      let completionTokens: Int?

      enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
      }
    }

    let choices: [Choice]?
    let usage: Usage?
  }

  private static func generateNvidiaJSON(
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any]
  ) async throws -> AIProviderTextGenerationResponse {
    var request = URLRequest(url: URL(string: "\(nvidiaBaseURL)/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let schemaText = try jsonString(schema)
    request.httpBody = try jsonData([
      "model": model,
      // A reasoning model spends this budget thinking before it answers; 1_200 was not enough to
      // reach the JSON, so content came back empty.
      "max_tokens": 4_096,
      "temperature": 0,
      // This task wants the answer, not the deliberation.
      "chat_template_kwargs": ["enable_thinking": false],
      "messages": [
        ["role": "system", "content": systemPrompt],
        [
          "role": "user",
          "content": """
          \(userPrompt)

          Return only one JSON object matching this JSON Schema. Do not wrap it in markdown:
          \(schemaText)
          """,
        ],
      ],
    ])

    let payload: ChatCompletionPayload = try await perform(request)
    return try chatCompletionText(
      payload,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt
    )
  }

  /// Shared by every OpenAI-compatible service.
  private static func chatCompletionText(
    _ payload: ChatCompletionPayload,
    systemPrompt: String,
    userPrompt: String
  ) throws -> AIProviderTextGenerationResponse {
    let choices = payload.choices ?? []
    let messages = choices.compactMap(\.message)
    let content = messages.compactMap(\.content).joined(separator: "\n")

    guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return AIProviderTextGenerationResponse(
        text: content,
        promptTokens: payload.usage?.promptTokens ?? estimateTokenCount(systemPrompt + userPrompt),
        completionTokens: payload.usage?.completionTokens ?? estimateTokenCount(content)
      )
    }

    // Empty content with reasoning present means the model was still thinking when it stopped.
    // Reasoning text is deliberation, not the answer, so it is only worth mining for an object.
    let reasoning = messages.compactMap(\.reasoningContent).joined(separator: "\n")
    let finishReason = choices.compactMap(\.finishReason).first

    if reasoning.contains("{"), reasoning.contains("}") {
      return AIProviderTextGenerationResponse(
        text: reasoning,
        promptTokens: payload.usage?.promptTokens ?? estimateTokenCount(systemPrompt + userPrompt),
        completionTokens: payload.usage?.completionTokens ?? estimateTokenCount(reasoning)
      )
    }

    guard reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderAPIError.incompleteResponse(
        "the model returned \(reasoning.count) characters of reasoning and no answer"
          + (finishReason == "length" ? " before hitting the token limit" : "")
          + ". Try a non-reasoning model."
      )
    }

    throw AIProviderAPIError.invalidResponse
  }

  // MARK: - Custom domain

  /// An OpenAI-compatible service at a domain the user supplies. Unlike NIM it is asked for strict
  /// JSON Schema output directly, because a proxy that speaks this API normally honours it.
  private static func fetchCustomModels(
    endpoint: AIProviderEndpoint,
    apiKey: String
  ) async throws -> [String] {
    var request = URLRequest(url: try endpoint.customURL(path: "/models"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let payload: OpenAIModelsResponse = try await perform(request)
    let allIDs = payload.data.map(\.id)
    let chatIDs = allIDs.filter(isLikelyChatModel)
    return (chatIDs.isEmpty ? allIDs : chatIDs).sorted()
  }

  /// A catalog behind a proxy mixes chat models with image, audio and embedding ones and carries no
  /// capability field, so the non-conversational families are filtered out by name.
  private static func isLikelyChatModel(_ id: String) -> Bool {
    let lowered = id.lowercased()
    let excluded = [
      "embed", "rerank", "ocr", "asr", "tts", "riva", "guard", "retriever",
      "image", "whisper", "moderation", "audio", "video", "speech", "dall-e",
    ]
    return !excluded.contains { lowered.contains($0) }
  }

  private static func generateCustomJSON(
    endpoint: AIProviderEndpoint,
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any],
    schemaName: String
  ) async throws -> AIProviderTextGenerationResponse {
    var request = URLRequest(url: try endpoint.customURL(path: "/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let schemaText = try jsonString(schema)
    request.httpBody = try jsonData([
      "model": model,
      // A reasoning model behind the domain spends this budget thinking before it answers.
      "max_tokens": 4_096,
      "temperature": 0,
      "response_format": [
        "type": "json_schema",
        "json_schema": [
          "name": schemaName,
          "strict": true,
          "schema": schema,
        ],
      ],
      "messages": [
        ["role": "system", "content": systemPrompt],
        [
          "role": "user",
          "content": """
          \(userPrompt)

          Return only one JSON object matching this JSON Schema. Do not wrap it in markdown:
          \(schemaText)
          """,
        ],
      ],
    ])

    let payload: ChatCompletionPayload = try await perform(request)
    return try chatCompletionText(
      payload,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt
    )
  }

  // MARK: - Common

  /// Long enough for a reasoning model on a long prompt; URLRequest's default is 60 seconds.
  static let requestTimeout: TimeInterval = 180
  static let maxRetries = 3
  /// Tests replace this so backoff costs no wall-clock time.
  static var sleep: (TimeInterval) async throws -> Void = { seconds in
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  /// Retries throttling, server errors and "overloaded" with backoff, honouring `retry-after`.
  private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
    var request = request
    request.timeoutInterval = max(request.timeoutInterval, requestTimeout)
    let session = URLSession.shared
    var attempt = 0

    while true {
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await session.data(for: request)
      } catch {
        throw AIProviderAPIError.network(error.localizedDescription)
      }
      guard let http = response as? HTTPURLResponse else {
        throw AIProviderAPIError.decoding
      }

      if isRetryable(status: http.statusCode, body: data), attempt < maxRetries {
        try await sleep(retryDelay(for: http, attempt: attempt))
        attempt += 1
        continue
      }

      switch http.statusCode {
      case 200...299:
        break
      case 401:
        throw AIProviderAPIError.invalidKey
      case 403:
        throw AIProviderAPIError.permissionDenied(providerErrorDetail(from: data))
      case 429:
        throw AIProviderAPIError.rateLimited
      default:
        throw AIProviderAPIError.unexpected(http.statusCode, providerErrorDetail(from: data))
      }
      do {
        return try JSONDecoder().decode(T.self, from: data)
      } catch {
        throw AIProviderAPIError.decoding
      }
    }
  }

  static func isRetryable(status: Int, body: Data) -> Bool {
    if status == 429 || (500...599).contains(status) {
      return true
    }
    guard !(200...299).contains(status),
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let error = object["error"] as? [String: Any]
    else {
      return false
    }
    return (error["type"] as? String) == "overloaded_error"
  }

  /// The provider's `retry-after` when it gives one (capped at a minute), else 1s, 2s, 4s.
  static func retryDelay(for response: HTTPURLResponse, attempt: Int) -> TimeInterval {
    if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) {
      return min(60, max(0, milliseconds / 1_000))
    }
    if let seconds = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) {
      return min(60, max(0, seconds))
    }
    return pow(2, Double(attempt))
  }

  /// Providers explain a 4xx in the body; without it a bad model id or payload field is unguessable.
  private static func providerErrorDetail(from data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      for key in ["detail", "message", "title"] {
        if let value = object[key] as? String, !value.isEmpty {
          return value
        }
      }
      if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
        return message
      }
    }
    let text = String(decoding: data.prefix(400), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [])
  }

  private static func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
      throw AIProviderAPIError.decoding
    }
    return string
  }

  private static func estimateTokenCount(_ text: String) -> Int {
    max(1, text.count / 4)
  }
}
