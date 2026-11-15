import Foundation
#if canImport(SerenityMCPCore)
import SerenityMCPCore
#endif

// Claude starts this over stdio. Stdout carries only MCP messages; anything else goes to stderr.
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
let app = SerenityBridgeClient.enclosingApp(executablePath: executable)
let version = app.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "dev"

func openSerenity(inBackground: Bool) {
  let open = Process()
  open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  let target = app.map { [$0.path] } ?? ["-b", "com.digitaltracer.serenity"]
  open.arguments = (inBackground ? ["-g"] : []) + target
  do {
    try open.run()
    open.waitUntilExit()
  } catch {
    FileHandle.standardError.write(Data("serenity-mcp: couldn't open Serenity: \(error.localizedDescription)\n".utf8))
  }
}

let bridge = SerenityBridgeClient(socketPath: SerenityBridgeClient.defaultSocketPath()) { openSerenity(inBackground: true) }
let server = SerenityMCPServer(bridge: bridge, version: version) { openSerenity(inBackground: false) }

while let line = readLine(strippingNewline: true) {
  guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
  FileHandle.standardOutput.write(Data((reply + "\n").utf8))
}
