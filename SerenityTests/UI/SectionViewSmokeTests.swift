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

    XCTAssertTrue(home.contains("TodayOverviewView("))
    XCTAssertFalse(home.contains("featureGrid"))
    // Asserted against the enum rather than the source text: "case .today" also
    // appears in TodayOverviewView's band kind, which is not a route.
    XCTAssertNil(AppSection(rawValue: "today"))
    XCTAssertFalse(source.contains("section: .today"))
  }

  func testDailyOverviewIsBandedAndCarriesNoZeroValueCards() throws {
    let source = try appSceneSource()
    let overview = try XCTUnwrap(source.slice(from: "private struct TodayOverviewView", to: "private struct SerenityDateRangePicker"))

    // The three bands read straight off AppState, so nothing captured can be
    // absent from Home.
    XCTAssertTrue(overview.contains("appState.overdueTasks"))
    XCTAssertTrue(overview.contains("appState.todayTasks"))
    XCTAssertTrue(overview.contains("appState.upcomingTasks"))
    XCTAssertTrue(overview.contains("appState.inboxTasks"))

    // Empty bands are dropped rather than rendered as zeroes.
    XCTAssertTrue(overview.contains("filter { !$0.tasks.isEmpty }"))

    // The percentage ring and the Planned/Completed tallies are gone; they
    // reported four zeros while real tasks existed elsewhere in the app.
    XCTAssertFalse(overview.contains("progressCard"))
    XCTAssertFalse(overview.contains("focusCard"))
    XCTAssertFalse(overview.contains("completionPercent"))
  }

  func testHomeHeaderAndCaptureCardSurvive() throws {
    let source = try appSceneSource()
    let sectionView = try XCTUnwrap(source.slice(from: "private struct SectionView", to: "private struct HomeSectionHeader"))
    let header = try XCTUnwrap(source.slice(from: "private struct HomeSectionHeader", to: "private struct HomeSectionView"))
    let home = try XCTUnwrap(source.slice(from: "private struct HomeSectionView", to: "private struct ActionHubSectionView"))
    let quickCaptureCard = try XCTUnwrap(String(home).slice(from: "private var quickCaptureCard", to: "private var quickCaptureProviderDropdown"))

    // The title belongs to SectionView's pinned band, not to the scrolling
    // content, so it reads as the screen's title rather than its first row.
    XCTAssertTrue(sectionView.contains("HomeSectionHeader()"))
    XCTAssertTrue(header.contains("HStack(alignment: .firstTextBaseline, spacing: 12)"))
    XCTAssertTrue(quickCaptureCard.contains("Text(quickCaptureHelperText)\n            .font(SerenityType.body)"))
  }

  func testHomeAndActionHubShareOneExpandedTaskPanel() throws {
    let source = try appSceneSource()
    let home = try XCTUnwrap(source.slice(from: "private struct TodayOverviewView", to: "private struct SerenityDateRangePicker"))
    let actionHub = try XCTUnwrap(source.slice(from: "private struct ActionHubSectionView", to: "private struct TodayOverviewView"))

    // Both lists mount the same panel, so an expanded task reads identically
    // wherever you opened it.
    XCTAssertTrue(home.contains("TaskDetailPanel(task: task, onEditTask: onEditTask)"))
    XCTAssertTrue(actionHub.contains("TaskDetailPanel(task: task, onEditTask: onEditTask)"))

    // On Home the whole row opens the task, not just the chevron.
    XCTAssertTrue(home.contains("expandedTaskID"))
    XCTAssertTrue(home.contains("onTapGesture"))
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
