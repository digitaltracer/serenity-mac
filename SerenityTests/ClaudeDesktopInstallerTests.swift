import Foundation
import XCTest
@testable import SerenityMac

final class ClaudeDesktopInstallerTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
    super.tearDown()
  }

  private func makeInstaller(helperExists: Bool = true, claudeInstalled: Bool = true) throws -> ClaudeDesktopInstaller {
    let helper = folder.appendingPathComponent("Serenity.app/Contents/Helpers/serenity-mcp")
    if helperExists {
      try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }
    return ClaudeDesktopInstaller(
      configURL: folder.appendingPathComponent("Claude/claude_desktop_config.json"),
      helperPath: helper.path,
      claudeInstalled: { claudeInstalled }
    )
  }

  private func config(_ installer: ClaudeDesktopInstaller) throws -> [String: Any] {
    let data = try Data(contentsOf: installer.configURL)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testStatesBeforeAdding() throws {
    XCTAssertEqual(try makeInstaller(helperExists: false).state(), .helperMissing)
    XCTAssertEqual(try makeInstaller(claudeInstalled: false).state(), .claudeNotFound)
    XCTAssertEqual(try makeInstaller().state(), .notAdded)
  }

  func testAddingCreatesTheFileWhenThereIsNone() throws {
    let installer = try makeInstaller()

    try installer.install()

    let servers = try XCTUnwrap(try config(installer)["mcpServers"] as? [String: Any])
    XCTAssertEqual((servers["serenity"] as? [String: Any])?["command"] as? String, installer.helperPath)
    XCTAssertEqual(installer.state(), .added)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installer.backupURL.path), "Nothing to back up")
  }

  func testAddingKeepsEverythingElseAndBacksUpFirst() throws {
    let installer = try makeInstaller()
    try FileManager.default.createDirectory(at: installer.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = #"{"globalShortcut":"Cmd+Space","mcpServers":{"files":{"command":"npx","args":["-y","server-files"]}}}"#
    try Data(original.utf8).write(to: installer.configURL)

    try installer.install()

    let updated = try config(installer)
    XCTAssertEqual(updated["globalShortcut"] as? String, "Cmd+Space")
    let servers = try XCTUnwrap(updated["mcpServers"] as? [String: Any])
    XCTAssertEqual((servers["files"] as? [String: Any])?["args"] as? [String], ["-y", "server-files"])
    XCTAssertNotNil(servers["serenity"])
    XCTAssertEqual(try String(contentsOf: installer.backupURL), original)
  }

  func testAnUnreadableFileIsLeftAlone() throws {
    let installer = try makeInstaller()
    try FileManager.default.createDirectory(at: installer.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let broken = #"{"mcpServers": {"files": }"#
    try Data(broken.utf8).write(to: installer.configURL)

    XCTAssertThrowsError(try installer.install())
    XCTAssertEqual(try String(contentsOf: installer.configURL), broken)
  }

  func testAnotherCopyIsNoticedAndCanBeReplaced() throws {
    let installer = try makeInstaller()
    try FileManager.default.createDirectory(at: installer.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"mcpServers":{"serenity":{"command":"/Old/Serenity.app/Contents/Helpers/serenity-mcp"}}}"#.utf8).write(to: installer.configURL)

    XCTAssertEqual(installer.state(), .pointsElsewhere("/Old/Serenity.app/Contents/Helpers/serenity-mcp"))
    try installer.install()
    XCTAssertEqual(installer.state(), .added)
  }

  func testRemovingTakesOnlySerenityOut() throws {
    let installer = try makeInstaller()
    try FileManager.default.createDirectory(at: installer.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"mcpServers":{"files":{"command":"npx"}}}"#.utf8).write(to: installer.configURL)
    try installer.install()

    try installer.remove()

    let servers = try XCTUnwrap(try config(installer)["mcpServers"] as? [String: Any])
    XCTAssertNil(servers["serenity"])
    XCTAssertNotNil(servers["files"])
    XCTAssertEqual(installer.state(), .notAdded)
  }

  func testClaudeCodeCommandQuotesThePath() throws {
    let installer = try makeInstaller()
    XCTAssertEqual(installer.claudeCodeCommand, "claude mcp add --scope user serenity -- \"\(installer.helperPath)\"")
  }
}
