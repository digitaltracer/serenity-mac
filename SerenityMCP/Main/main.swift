import Foundation
#if canImport(SerenityMCPCore)
import SerenityMCPCore
#endif

// Claude starts this over stdio. Stdout carries only MCP messages; anything else goes to stderr.
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
let app = SerenityBridgeClient.enclosingApp(executablePath: executable)
let version = app.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "dev"

let bridge = SerenityBridgeClient(socketPath: SerenityBridgeClient.defaultSocketPath()) {
  let open = Process()
  open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  open.arguments = app.map { ["-g", $0.path] } ?? ["-g", "-b", "com.digitaltracer.serenity"]
  do {
    try open.run()
    open.waitUntilExit()
  } catch {
    FileHandle.standardError.write(Data("serenity-mcp: couldn't open Serenity: \(error.localizedDescription)\n".utf8))
  }
}
let server = SerenityMCPServer(bridge: bridge, version: version)

while let line = readLine(strippingNewline: true) {
  guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
  FileHandle.standardOutput.write(Data((reply + "\n").utf8))
}
