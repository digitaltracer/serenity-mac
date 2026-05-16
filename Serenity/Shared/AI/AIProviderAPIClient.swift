import Foundation

enum AIProviderAPIError: Error, LocalizedError, Equatable {
  case invalidKey
  case rateLimited
  case network(String)
  case decoding
  case unexpected(Int)

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
    case .unexpected(let status):
      return "Provider returned HTTP \(status)"
    }
  }
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
      throw AIProviderAPIError.unexpected(http.statusCode)
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AIProviderAPIError.decoding
    }
  }
}
