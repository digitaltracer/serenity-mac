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
    let actionHub = try XCTUnwrap(source.slice(from: "private struct ActionHubSectionView", to: "private struct TodayOverviewView"))

    XCTAssertTrue(sectionView.contains(".inspector(isPresented: editorIsPresented)"))
    XCTAssertFalse(actionHub.contains(".inspector(isPresented:"))
  }

  func testActionHubUsesSingleTaskListContainer() throws {
    let source = try appSceneSource()
    let actionHub = try XCTUnwrap(source.slice(from: "private struct ActionHubSectionView", to: "private struct TodayOverviewView"))
    let taskRow = try XCTUnwrap(String(actionHub).slice(from: "private func taskRow", to: "private func taskEditorButton"))

    XCTAssertTrue(actionHub.contains("LazyVStack(spacing: 0)"))
    XCTAssertTrue(actionHub.contains("taskListShape"))
    XCTAssertFalse(actionHub.contains(".padding(.leading, 58)"))
    XCTAssertFalse(taskRow.contains("RoundedRectangle(cornerRadius: 14"))
  }

  func testHomeOwnsDailyOverviewAndTodayHasNoRoute() throws {
    let source = try appSceneSource()
    let home = try XCTUnwrap(source.slice(from: "private struct HomeSectionView", to: "private struct ActionHubSectionView"))

    XCTAssertTrue(home.contains("TodayOverviewView()"))
    XCTAssertFalse(home.contains("featureGrid"))
    XCTAssertFalse(source.contains("case .today"))
    XCTAssertFalse(source.contains("section: .today"))
  }

  func testHomeDashboardUsesPolishedLayout() throws {
    let source = try appSceneSource()
    let home = try XCTUnwrap(source.slice(from: "private struct HomeSectionView", to: "private struct ActionHubSectionView"))
    let header = try XCTUnwrap(String(home).slice(from: "private var header", to: "private var quickCaptureCard"))
    let quickCaptureCard = try XCTUnwrap(String(home).slice(from: "private var quickCaptureCard", to: "private var quickCaptureProviderDropdown"))
    let overview = try XCTUnwrap(source.slice(from: "private struct TodayOverviewView", to: "private struct SerenityDateRangePicker"))
    let progressCard = try XCTUnwrap(String(overview).slice(from: "private var progressCard", to: "private var focusCard"))
    let focusCard = try XCTUnwrap(String(overview).slice(from: "private var focusCard", to: "private func focusRow"))

    XCTAssertTrue(home.contains("header\n        .padding(.bottom, density.sectionSpacing)"))
    XCTAssertTrue(header.contains("HStack(alignment: .center, spacing: 12)"))
    XCTAssertTrue(header.contains("Text(\"Focus on what matters most right now\")\n          .font(SerenityType.body)"))
    XCTAssertTrue(header.contains("Text(Self.dateFormatter.string(from: Date()))\n          .font(SerenityType.caption)"))
    XCTAssertTrue(quickCaptureCard.contains("HStack(alignment: .center, spacing: 12)"))
    XCTAssertTrue(quickCaptureCard.contains("Text(quickCaptureHelperText)\n            .font(SerenityType.body)"))
    XCTAssertTrue(overview.contains("HStack(alignment: .top, spacing: 16)"))
    XCTAssertTrue(overview.contains(".fixedSize(horizontal: false, vertical: true)"))
    XCTAssertFalse(overview.contains("GridRow"))
    XCTAssertTrue(progressCard.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
    XCTAssertTrue(focusCard.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"))
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
