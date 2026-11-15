import Foundation

/// A tools-only MCP server, one JSON-RPC message per line. It speaks the current stateless protocol,
/// where each request names its version and `server/discover` replaces the handshake, and the older
/// `initialize` one, since clients move between them at their own pace.
public final class SerenityMCPServer {
  public static let currentVersion = "2026-07-28"
  public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  public static var supportedVersions: [String] { [currentVersion] + legacyVersions }

  static let versionMetaKey = "io.modelcontextprotocol/protocolVersion"
  static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"

  static let instructions = """
    Serenity is the user's planner on their Mac: tasks, today's plan, focus sessions, routines, goals and a journal. \
    Call get_today first for anything about today. Dates are the user's local time: days as 2026-11-20, times as 2026-11-20T15:30. \
    Every change is saved straight into Serenity, syncs to the user's other devices, and is listed in Serenity › Settings › Claude. \
    There is no way to delete anything from here; point the user to the app for that.
    """

  private let bridge: BridgeTransport
  private let version: String

  public init(bridge: BridgeTransport, version: String = "1.0") {
    self.bridge = bridge
    self.version = version
  }

  /// The reply line for one incoming line, or nil when there is nothing to send back.
  public func handle(_ line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) else {
      return encode(error: -32700, message: "Parse error", id: NSNull())
    }
    guard let object = message as? [String: Any] else {
      return encode(error: -32600, message: "Send one JSON-RPC message per line; batches aren't supported.", id: NSNull())
    }
    guard let method = object["method"] as? String else { return nil }
    // Notifications (initialized, cancelled) need no answer.
    guard let id = object["id"], id is String || id is NSNumber else { return nil }

    let params = object["params"] as? [String: Any] ?? [:]
    if let requested = (params["_meta"] as? [String: Any])?[Self.versionMetaKey] as? String,
       !Self.supportedVersions.contains(requested) {
      return encode(
        error: -32022,
        message: "Unsupported protocol version",
        id: id,
        data: ["supported": Self.supportedVersions, "requested": requested]
      )
    }

    switch method {
    case "initialize":
      return encode(result: initialize(params), id: id)
    case "server/discover":
      return encode(result: discover(), id: id)
    case "ping":
      return encode(result: [:], id: id)
    case "tools/list":
      return encode(result: [
        "tools": SerenityTools.all.map(\.definition),
        "resultType": "complete",
        "ttlMs": 3_600_000,
        "cacheScope": "private",
      ], id: id)
    case "tools/call":
      guard let name = params["name"] as? String, let tool = SerenityTools.byName[name] else {
        return encode(error: -32602, message: "Unknown tool: \(params["name"] as? String ?? "(none)")", id: id)
      }
      let arguments = params["arguments"] as? [String: Any]
      return encode(result: call(tool, arguments: arguments), id: id)
    default:
      return encode(error: -32601, message: "Method not found: \(method)", id: id)
    }
  }

  private var serverInfo: [String: Any] {
    ["name": "serenity", "title": "Serenity", "version": version]
  }

  private var capabilities: [String: Any] {
    ["tools": ["listChanged": false]]
  }

  private func initialize(_ params: [String: Any]) -> [String: Any] {
    let requested = params["protocolVersion"] as? String
    let agreed = requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
    return [
      "protocolVersion": agreed,
      "capabilities": capabilities,
      "serverInfo": serverInfo,
      "instructions": Self.instructions,
    ]
  }

  private func discover() -> [String: Any] {
    [
      "resultType": "complete",
      "supportedVersions": Self.supportedVersions,
      "capabilities": capabilities,
      "instructions": Self.instructions,
      "ttlMs": 3_600_000,
      "cacheScope": "private",
      "_meta": [Self.serverInfoMetaKey: serverInfo],
    ]
  }

  private func call(_ tool: SerenityTool, arguments: [String: Any]?) -> [String: Any] {
    let params = arguments.flatMap { $0.isEmpty ? nil : $0 }
    do {
      switch try bridge.call(method: tool.method, params: params) {
      case let .result(value):
        let text = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
          .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var result: [String: Any] = ["resultType": "complete", "content": [["type": "text", "text": text]]]
        if value is [String: Any] { result["structuredContent"] = value }
        return result
      case let .failure(code, message):
        return toolError(code == "locked" || code == "journal_off" ? message : "\(message) (\(code))")
      }
    } catch {
      return toolError(error.localizedDescription)
    }
  }

  private func toolError(_ message: String) -> [String: Any] {
    ["resultType": "complete", "content": [["type": "text", "text": message]], "isError": true]
  }

  private func encode(result: [String: Any], id: Any) -> String {
    line(["jsonrpc": "2.0", "id": id, "result": result])
  }

  private func encode(error code: Int, message: String, id: Any, data: [String: Any]? = nil) -> String {
    var error: [String: Any] = ["code": code, "message": message]
    if let data { error["data"] = data }
    return line(["jsonrpc": "2.0", "id": id, "error": error])
  }

  private func line(_ object: [String: Any]) -> String {
    // JSONSerialization escapes newlines inside strings, so each message stays on one line.
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}
