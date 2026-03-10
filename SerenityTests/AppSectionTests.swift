import XCTest
@testable import SerenityMac

final class AppSectionTests: XCTestCase {
  func testAllSectionsArePresentInNavigationOrder() {
    XCTAssertEqual(
      AppSection.allCases,
      [.home, .actionHub, .today, .journal, .goals, .projects, .integrations, .insights, .database, .settings],
    )
  }

  func testGlobalSearchResultTypesMapToTargetSections() {
    XCTAssertEqual(GlobalSearchResultType.task.targetSection, .actionHub)
    XCTAssertEqual(GlobalSearchResultType.project.targetSection, .projects)
    XCTAssertEqual(GlobalSearchResultType.journal.targetSection, .journal)
    XCTAssertEqual(GlobalSearchResultType.goal.targetSection, .goals)
  }
}
