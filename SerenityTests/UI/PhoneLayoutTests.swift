import Foundation
import XCTest
@testable import SerenityMac

/// The phone layout lives behind `#if os(iOS)`, which a macOS test run never
/// compiles, so these assert against the source the way the other shell tests do.
final class PhoneLayoutTests: XCTestCase {
  func testCompactShellUsesTabsAndRegularShellKeepsTheSplitView() throws {
    let source = try appSceneSource()
    let scene = try XCTUnwrap(source.slice(from: "struct SerenityAppScene: View", to: "private extension AppThemePreference"))

    XCTAssertTrue(scene.contains("if isCompactLayout {"))
    XCTAssertTrue(scene.contains("SerenityPhoneTabShell()"))
    XCTAssertTrue(scene.contains("NavigationSplitView(columnVisibility: $splitViewVisibility)"))
    XCTAssertTrue(source.contains("TabView(selection: tabSelection)"))
  }

  /// The tab bar must not become a second source of truth for the route.
  func testPhoneTabsDeriveFromTheSelectedSection() throws {
    let source = try appSceneSource()
    let shell = try XCTUnwrap(source.slice(from: "private struct SerenityPhoneTabShell", to: "private struct MorePhoneList"))

    XCTAssertTrue(shell.contains("get: { SerenityPhoneTab.containing(appState.selectedSection) }"))
    XCTAssertTrue(shell.contains("set: { appState.setSection($0.rootSection) }"))
  }

  func testTaskEditorIsASheetOnCompactAndAnInspectorOtherwise() throws {
    let source = try appSceneSource()
    let sectionView = try XCTUnwrap(source.slice(from: "private struct SectionView", to: "private struct HomeSectionView"))

    XCTAssertTrue(sectionView.contains(".inspector(isPresented: editorIsPresented)"))
    XCTAssertTrue(sectionView.contains(".sheet(isPresented: editorIsPresented)"))
    XCTAssertTrue(sectionView.contains(".presentationDetents([.medium, .large])"))
    XCTAssertFalse(sectionView.contains(".navigationDestination(isPresented: editorIsPresented)"))
  }

  func testPhoneWidthsGetTheirOwnDensityTier() throws {
    let source = try appSceneSource()
    let density = try XCTUnwrap(source.slice(from: "private enum SerenityContentDensity", to: "private struct SectionView"))

    XCTAssertTrue(density.contains("case phone"))
    XCTAssertTrue(density.contains("if width < 480 {"))
    XCTAssertTrue(density.contains("return .phone"))
  }

  /// Sheets sized for a Mac window clip on a 390pt screen.
  func testDesktopSheetMinimumsAreNotAppliedUnconditionally() throws {
    let source = try appSceneSource()

    XCTAssertFalse(source.contains(".frame(minWidth: 760, minHeight: 560)"))
    XCTAssertFalse(source.contains(".frame(minWidth: 460, minHeight: 380)"))
    XCTAssertFalse(source.contains(".frame(minWidth: 420, minHeight: 260)"))
    XCTAssertTrue(source.contains(".serenityDesktopSheetSize(minWidth: 760, minHeight: 560)"))
  }

  /// Reporting a screen diagonal on iOS shrank every phone to 0.85 scale before
  /// Dynamic Type ran.
  func testIOSReportsNoScreenDiagonalSoTypeIsNotPreShrunk() throws {
    let source = try designSystemSource()
    let metrics = try XCTUnwrap(source.slice(from: "enum SerenityScreenMetrics", to: "typealias SerenityPalette"))

    XCTAssertFalse(metrics.contains("14.9"))
    XCTAssertFalse(metrics.contains("#elseif os(iOS)"))
  }

  func testMacFontScaleStillFollowsTheDisplayDiagonal() {
    XCTAssertEqual(SerenityScreenMetrics.smallScreenFontScale, 0.85, accuracy: 0.0001)
    XCTAssertTrue([0.85, 1.0].contains(SerenityScreenMetrics.fontScale))
  }

  private func appSceneSource() throws -> String {
    try repositoryFile("Serenity/Shared/App/SerenityAppScene.swift")
  }

  private func designSystemSource() throws -> String {
    try repositoryFile("Serenity/Shared/UI/SerenityDesignSystem.swift")
  }

  private func repositoryFile(_ path: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(path)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}

private extension String {
  func slice(from start: String, to end: String) -> Substring? {
    guard let startRange = range(of: start),
          let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
      return nil
    }
    return self[startRange.lowerBound..<endRange.lowerBound]
  }
}
