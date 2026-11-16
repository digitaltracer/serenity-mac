import XCTest
@testable import SerenityMac

final class AppSectionTests: XCTestCase {
  func testAllSectionsArePresentInNavigationOrder() {
    XCTAssertEqual(
      AppSection.allCases,
      [.home, .actionHub, .standup, .journal, .goals, .routines, .projects, .integrations, .settings],
    )
  }

  func testRetiredInsightsAndSummariesScreensAreGone() {
    for rawValue in ["insights", "aiSummaries"] {
      XCTAssertNil(AppSection(rawValue: rawValue))
    }
    XCTAssertEqual(
      AppSection.navigationOrder,
      [.home, .actionHub, .standup, .journal, .goals, .routines, .integrations, .settings]
    )
  }

  func testDatabaseAndCostCenterAreSettingsTabsRatherThanSections() {
    for rawValue in ["database", "costCenter"] {
      XCTAssertFalse(
        AppSection.allCases.contains { $0.rawValue == rawValue },
        "\(rawValue) should no longer be a top-level section"
      )
    }

    XCTAssertTrue(SettingsTab.allCases.contains(.database))
    XCTAssertTrue(SettingsTab.allCases.contains(.costCenter))
  }

  func testGlobalSearchResultTypesMapToTargetSections() {
    XCTAssertEqual(GlobalSearchResultType.task.targetSection, .actionHub)
    XCTAssertEqual(GlobalSearchResultType.project.targetSection, .projects)
    XCTAssertEqual(GlobalSearchResultType.journal.targetSection, .journal)
    XCTAssertEqual(GlobalSearchResultType.goal.targetSection, .goals)
  }
}
