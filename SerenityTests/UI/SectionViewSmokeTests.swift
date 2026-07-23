import Foundation
import SwiftUI
import XCTest
@testable import SerenityMac

@MainActor
final class SectionViewSmokeTests: XCTestCase {
  func testIntegrationsSectionViewCanBeConstructed() {
    let state = AppState(
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    let view = IntegrationsSectionView().environmentObject(state)
    XCTAssertNotNil(view)
  }

  func testInsightsSectionViewCanBeConstructed() {
    let state = AppState(
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    let view = InsightsSectionView().environmentObject(state)
    XCTAssertNotNil(view)
  }

  func testTaskInspectorIsHostedOutsideActionHubScrollContent() throws {
    let source = try appSceneSource()
    let sectionView = try XCTUnwrap(source.slice(from: "private struct SectionView", to: "private struct HomeSectionView"))
    let actionHub = try XCTUnwrap(source.slice(from: "private struct ActionHubSectionView", to: "private struct TodaySectionView"))

    XCTAssertTrue(sectionView.contains(".inspector(isPresented: editorIsPresented)"))
    XCTAssertFalse(actionHub.contains(".inspector(isPresented:"))
  }

  func testActionHubUsesSingleTaskListContainer() throws {
    let source = try appSceneSource()
    let actionHub = try XCTUnwrap(source.slice(from: "private struct ActionHubSectionView", to: "private struct TodaySectionView"))
    let taskRow = try XCTUnwrap(String(actionHub).slice(from: "private func taskRow", to: "private func taskEditorButton"))

    XCTAssertTrue(actionHub.contains("LazyVStack(spacing: 0)"))
    XCTAssertTrue(actionHub.contains("taskListShape"))
    XCTAssertFalse(actionHub.contains(".padding(.leading, 58)"))
    XCTAssertFalse(taskRow.contains("RoundedRectangle(cornerRadius: 14"))
  }

  private func appSceneSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Serenity/Shared/App/SerenityAppScene.swift")
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
