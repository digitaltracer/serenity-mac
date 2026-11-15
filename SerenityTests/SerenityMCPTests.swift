import Foundation
import XCTest
@testable import SerenityMac
import SerenityMCPCore

private final class FakeBridge: BridgeTransport {
  var calls: [(method: String, params: [String: Any]?)] = []
  var reply: BridgeReply = .result([String: Any]())
  var error: Error?

  func call(method: String, params: [String: Any]?) throws -> BridgeReply {
    calls.append((method, params))
    if let error { throw error }
    return reply
  }
}

final class SerenityMCPServerTests: XCTestCase {
  private func send(_ server: SerenityMCPServer, _ message: [String: Any]) throws -> [String: Any] {
    let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    let reply = try XCTUnwrap(server.handle(line))
    XCTAssertFalse(reply.contains("\n"), "stdio messages must fit on one line")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
  }

  private func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
  }

  func testLegacyHandshakeAgreesOnAVersionBothSpeak() throws {
    let server = SerenityMCPServer(bridge: FakeBridge())

    let known = try send(server, request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]]))
    XCTAssertEqual((known["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")

    let unknown = try send(server, request(2, "initialize", ["protocolVersion": "2031-01-01", "capabilities": [:]]))
    let result = try XCTUnwrap(unknown["result"] as? [String: Any])
    XCTAssertEqual(result["protocolVersion"] as? String, SerenityMCPServer.legacyVersions[0])
    XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "serenity")
    XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
  }

  func testStatelessRequestsCarryTheirVersion() throws {
    let server = SerenityMCPServer(bridge: FakeBridge())
    let meta = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]

    let discover = try XCTUnwrap(try send(server, request(1, "server/discover", meta))["result"] as? [String: Any])
    XCTAssertEqual(discover["supportedVersions"] as? [String], SerenityMCPServer.supportedVersions)
    XCTAssertEqual(discover["resultType"] as? String, "complete")

    let refused = try send(server, request(2, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1999-01-01"]]))
    XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32022)
  }

  func testNotificationsAndStrayResponsesGetNoReply() {
    let server = SerenityMCPServer(bridge: FakeBridge())
    XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","id":3,"result":{}}"#))
  }

  func testMalformedInputIsAnErrorNotACrash() throws {
    let server = SerenityMCPServer(bridge: FakeBridge())
    let garbage = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(server.handle("{nope")).utf8)) as? [String: Any])
    XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
    XCTAssertEqual((try send(server, request(1, "prompts/list"))["error"] as? [String: Any])?["code"] as? Int, -32601)
    XCTAssertEqual((try send(server, request(2, "tools/call", ["name": "delete_everything"]))["error"] as? [String: Any])?["code"] as? Int, -32602)
  }

  func testEveryToolHasAnObjectSchemaAndAKnownMethod() throws {
    let server = SerenityMCPServer(bridge: FakeBridge())
    let tools = try XCTUnwrap((try send(server, request(1, "tools/list"))["result"] as? [String: Any])?["tools"] as? [[String: Any]])

    XCTAssertEqual(tools.count, SerenityTools.all.count)
    for tool in tools {
      let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
      XCTAssertEqual(schema["type"] as? String, "object")
      let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
      XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
      XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)
    }
    let bridgeMethods = Set(ClaudeBridgeRouter.methods)
    for tool in SerenityTools.all where tool.method != SerenityTool.openAppMethod {
      XCTAssertTrue(bridgeMethods.contains(tool.method), "\(tool.name) calls \(tool.method), which the app doesn't answer")
    }
  }

  func testTodayCarriesItsCardAndTheCardIsServed() throws {
    let server = SerenityMCPServer(bridge: FakeBridge())
    let tools = try XCTUnwrap((try send(server, request(1, "tools/list"))["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    let today = try XCTUnwrap(tools.first { $0["name"] as? String == "get_today" })
    let meta = try XCTUnwrap(today["_meta"] as? [String: Any])
    XCTAssertEqual((meta["ui"] as? [String: Any])?["resourceUri"] as? String, TodayCard.uri)
    XCTAssertEqual(meta["ui/resourceUri"] as? String, TodayCard.uri)
    let open = try XCTUnwrap(tools.first { $0["name"] as? String == "open_serenity" })
    XCTAssertEqual(((open["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["visibility"] as? [String], ["app"])

    let listed = try XCTUnwrap((try send(server, request(2, "resources/list"))["result"] as? [String: Any])?["resources"] as? [[String: Any]])
    XCTAssertEqual(listed.first?["mimeType"] as? String, "text/html;profile=mcp-app")

    let read = try XCTUnwrap((try send(server, request(3, "resources/read", ["uri": TodayCard.uri]))["result"] as? [String: Any])?["contents"] as? [[String: Any]])
    XCTAssertEqual(read.first?["mimeType"] as? String, TodayCard.mimeType)
    let html = try XCTUnwrap(read.first?["text"] as? String)
    XCTAssertTrue(html.hasPrefix("<!doctype html>"))
    XCTAssertTrue(html.contains("ui/initialize"))
    XCTAssertFalse(html.contains("<script src"), "The sandbox only runs inline script")

    XCTAssertEqual((try send(server, request(4, "resources/read", ["uri": "ui://serenity/nope"]))["error"] as? [String: Any])?["code"] as? Int, -32602)
  }

  func testTheCardCanOpenTheAppWithoutTouchingTheBridge() throws {
    let bridge = FakeBridge()
    var opened = 0
    let server = SerenityMCPServer(bridge: bridge, openApp: { opened += 1 })

    let result = try XCTUnwrap(try send(server, request(1, "tools/call", ["name": "open_serenity"]))["result"] as? [String: Any])

    XCTAssertNil(result["isError"])
    XCTAssertEqual(opened, 1)
    XCTAssertTrue(bridge.calls.isEmpty)
  }

  func testToolCallsPassArgumentsAndReturnStructuredResults() throws {
    let bridge = FakeBridge()
    bridge.reply = .result(["id": "t1", "title": "Book dentist"])
    let server = SerenityMCPServer(bridge: bridge)

    let reply = try send(server, request(1, "tools/call", ["name": "add_task", "arguments": ["title": "Book dentist", "due": "2026-11-20"]]))

    XCTAssertEqual(bridge.calls.first?.method, "tasks.add")
    XCTAssertEqual(bridge.calls.first?.params?["due"] as? String, "2026-11-20")
    let result = try XCTUnwrap(reply["result"] as? [String: Any])
    XCTAssertNil(result["isError"])
    XCTAssertEqual((result["structuredContent"] as? [String: Any])?["id"] as? String, "t1")
    let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    XCTAssertTrue(text.contains("Book dentist"))
  }

  func testAppErrorsComeBackToClaudeAsToolErrors() throws {
    let bridge = FakeBridge()
    bridge.reply = .failure(code: "journal_off", message: "Journal access is off. Turn it on in Serenity › Settings › Claude.")
    let server = SerenityMCPServer(bridge: bridge)

    let off = try XCTUnwrap(try send(server, request(1, "tools/call", ["name": "search_journal", "arguments": [:]]))["result"] as? [String: Any])
    XCTAssertEqual(off["isError"] as? Bool, true)
    XCTAssertNil(bridge.calls.first?.params, "Empty arguments send no params")

    bridge.error = BridgeClientError.unavailable
    let down = try XCTUnwrap(try send(server, request(2, "tools/call", ["name": "get_today"]))["result"] as? [String: Any])
    XCTAssertEqual(down["isError"] as? Bool, true)
    let text = try XCTUnwrap((down["content"] as? [[String: Any]])?.first?["text"] as? String)
    XCTAssertTrue(text.contains("Connect to Claude"))
  }

  func testFindsTheAppItShipsIn() {
    XCTAssertEqual(
      SerenityBridgeClient.enclosingApp(executablePath: "/Applications/Serenity.app/Contents/Helpers/serenity-mcp")?.path,
      "/Applications/Serenity.app"
    )
    XCTAssertNil(SerenityBridgeClient.enclosingApp(executablePath: "/usr/local/bin/serenity-mcp"))
    XCTAssertEqual(
      SerenityBridgeClient.defaultSocketPath(environment: [SerenityBridgeClient.socketEnvironmentKey: "/tmp/x.sock"]),
      "/tmp/x.sock"
    )
  }

  func testAMissingAppIsReportedAfterTryingToOpenIt() {
    var launched = 0
    let client = SerenityBridgeClient(socketPath: "/tmp/serenity-missing-\(UUID().uuidString.prefix(8)).sock", launchApp: { launched += 1 }, launchWait: 0.3)

    XCTAssertThrowsError(try client.call(method: "today", params: nil)) { error in
      XCTAssertEqual(error.localizedDescription, BridgeClientError.unavailable.localizedDescription)
    }
    XCTAssertEqual(launched, 1)
  }
}

/// The helper and the app together: MCP in, a real socket, the app's own router answering.
@MainActor
final class SerenityMCPEndToEndTests: XCTestCase {
  func testAddingATaskFromClaudeLandsInTheApp() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-mcp-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.mcp.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "mcp.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )
    let router = ClaudeBridgeRouter(appState: state, settings: ClaudeBridgeSettings(defaults: defaults))
    let path = "/tmp/serenity-e2e-\(UUID().uuidString.prefix(8)).sock"
    let socketServer = ClaudeBridgeSocketServer(path: path) { line in await router.handle(line) }
    try socketServer.start()
    defer { socketServer.stop() }

    // The helper blocks on its socket, so it runs off the main actor the app needs.
    let lines = try await Task.detached { () -> [String] in
      let server = SerenityMCPServer(bridge: SerenityBridgeClient(socketPath: path))
      let add = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_task","arguments":{"title":"From Claude"}}}"#
      let today = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tasks","arguments":{"scope":"inbox"}}}"#
      return [try XCTUnwrap(server.handle(add)), try XCTUnwrap(server.handle(today))]
    }.value

    XCTAssertEqual(state.tasks.map(\.title), ["From Claude"])
    let listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
    let items = try XCTUnwrap(((listed["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]])
    XCTAssertEqual(items.first?["title"] as? String, "From Claude")
  }
}
