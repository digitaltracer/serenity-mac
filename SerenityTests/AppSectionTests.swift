import XCTest
@testable import SerenityMac

final class AppSectionTests: XCTestCase {
  func testAllSectionsArePresentInNavigationOrder() {
    XCTAssertEqual(
      AppSection.allCases,
      [.today, .tasks, .projects, .journal, .goals, .insights, .settings],
    )
  }

  func testAllSettingsTabsAreExposed() {
    XCTAssertEqual(SettingsTab.allCases, [.general, .ai, .syncBackend, .advanced])
  }

  func testGlobalSearchResultTypesMapToTargetSections() {
    XCTAssertEqual(GlobalSearchResultType.task.targetSection, .tasks)
    XCTAssertEqual(GlobalSearchResultType.project.targetSection, .projects)
    XCTAssertEqual(GlobalSearchResultType.journal.targetSection, .journal)
    XCTAssertEqual(GlobalSearchResultType.goal.targetSection, .goals)
  }
}
