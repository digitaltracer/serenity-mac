import Foundation

enum AIProviderAPIError: Error, LocalizedError, Equatable {
  case invalidKey
  case rateLimited
  case network(String)
  case decoding
  case invalidResponse
  case incompleteResponse(String)
  case unexpected(Int, String?)

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      return "Invalid API key"
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
    case .unexpected(let status, let detail):
      guard let detail, !detail.isEmpty else {
        return "Provider returned HTTP \(status)"
      }
      return "Provider returned HTTP \(status): \(detail)"
    }
  }
}

struct AIProviderTextGenerationResponse: Equatable, Sendable {
  let text: String
  let promptTokens: Int
  let completionTokens: Int
}

enum AIProviderAPIClient {
  static func fetchModels(provider: AICredentialProvider, apiKey: String) async throws -> [String] {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIProviderAPIError.invalidKey }
    switch provider {
    case .openai:
      return try await fetchOpenAIModels(apiKey: trimmed)
    case .anthropic:
      return try await fetchAnthropicModels(apiKey: trimmed)
    case .gemini:
      return try await fetchGeminiModels(apiKey: trimmed)
    case .nvidia:
      return try await fetchNvidiaModels(apiKey: trimmed)
    }
  }

  static func generateQuickCaptureJSON(
    provider: AICredentialProvider,
    apiKey: String,
    model: String,
    systemPrompt: String,
    userPrompt: String,
    schema: [String: Any]
  ) async throws -> AIProviderTextGenerationResponse {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIProviderAPIError.invalidKey }

    switch provider {
    case .openai:
      return try await generateOpenAIJSON(
        apiKey: trimmed,
        model: model,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        schema: schema
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
    }
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
    schema: [String: Any]
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
          "name": "quick_capture_classification",
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

    let schemaText = try jsonString(schema)
    request.httpBody = try jsonData([
      "model": model,
      "max_tokens": 1_200,
      "temperature": 0,
      "system": systemPrompt,
      "messages": [
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

    let payload: AnthropicMessagesPayload = try await perform(request)
    let text = payload.content.compactMap(\.text).joined(separator: "\n")
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

  private struct NvidiaChatCompletionPayload: Decodable {
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

    let payload: NvidiaChatCompletionPayload = try await perform(request)
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

  // MARK: - Common

  private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
    let session = URLSession.shared
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
    switch http.statusCode {
    case 200...299:
      break
    case 401, 403:
      throw AIProviderAPIError.invalidKey
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
