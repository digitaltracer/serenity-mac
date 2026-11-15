import AppKit
import Foundation

/// Adds the bundled connector to Claude Desktop's config, and takes it out again. Every other key
/// in the file is kept, and the file as it was is copied aside before each change.
struct ClaudeDesktopInstaller {
  enum State: Equatable {
    case helperMissing
    case claudeNotFound
    case notAdded
    case added
    /// Added, but from another copy of Serenity, such as a debug build.
    case pointsElsewhere(String)
  }

  enum InstallError: LocalizedError {
    case unreadableConfig

    var errorDescription: String? {
      switch self {
      case .unreadableConfig:
        return "Claude Desktop's settings file isn't valid JSON, so Serenity left it alone. Open it from Claude › Settings › Developer › Edit Config and fix it first."
      }
    }
  }

  static let serverName = "serenity"
  static let claudeBundleID = "com.anthropic.claudefordesktop"

  let configURL: URL
  let helperPath: String
  let claudeInstalled: () -> Bool

  static var live: ClaudeDesktopInstaller {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return ClaudeDesktopInstaller(
      configURL: support.appendingPathComponent("Claude/claude_desktop_config.json"),
      helperPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/serenity-mcp").path,
      claudeInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) != nil }
    )
  }

  var backupURL: URL {
    configURL.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.serenity-backup.json")
  }

  var entry: [String: Any] {
    ["command": helperPath]
  }

  /// What gets added, as it will read in the file.
  var entrySnippet: String {
    let data = (try? JSONSerialization.data(
      withJSONObject: [Self.serverName: entry],
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  func state() -> State {
    guard FileManager.default.isExecutableFile(atPath: helperPath) else { return .helperMissing }
    let configured = (try? readConfig())?["mcpServers"] as? [String: Any]
    if let current = configured?[Self.serverName] as? [String: Any] {
      let command = current["command"] as? String ?? ""
      return command == helperPath ? .added : .pointsElsewhere(command)
    }
    let claudeFolderExists = FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    return claudeInstalled() || claudeFolderExists ? .notAdded : .claudeNotFound
  }

  func install() throws {
    var config = try readConfig() ?? [:]
    var servers = config["mcpServers"] as? [String: Any] ?? [:]
    servers[Self.serverName] = entry
    config["mcpServers"] = servers
    try write(config)
  }

  func remove() throws {
    guard var config = try readConfig(), var servers = config["mcpServers"] as? [String: Any] else { return }
    servers.removeValue(forKey: Self.serverName)
    config["mcpServers"] = servers
    try write(config)
  }

  /// Nil when there is no file yet; throws when there is one that can't be read safely.
  private func readConfig() throws -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: configURL.path) else { return nil }
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InstallError.unreadableConfig
    }
    return object
  }

  private func write(_ config: [String: Any]) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: configURL.path) {
      try? fileManager.removeItem(at: backupURL)
      try fileManager.copyItem(at: configURL, to: backupURL)
    }
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: configURL, options: .atomic)
  }

  /// Claude Desktop reads its config at launch, so a change needs a restart to show.
  static var isClaudeRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
  }

  @MainActor
  static func restartClaude() async {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
    running.forEach { $0.terminate() }
    for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) {
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  /// The one-line setup for Claude Code, available to every project.
  var claudeCodeCommand: String {
    "claude mcp add --scope user \(Self.serverName) -- \"\(helperPath)\""
  }
}
