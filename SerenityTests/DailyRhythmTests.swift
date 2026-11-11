import Foundation
import XCTest
@testable import SerenityMac

final class DailyRhythmTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// 2026-11-09 is a Monday.
  private func date(_ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
  }

  func testWeeklyReviewIsDueFromFridayAfternoonThroughMonday() {
    XCTAssertFalse(WeeklyReview.isDue(now: date(12), lastReviewedWeek: nil, calendar: calendar), "Thursday")
    XCTAssertFalse(WeeklyReview.isDue(now: date(13, 10), lastReviewedWeek: nil, calendar: calendar), "Friday morning")
    XCTAssertTrue(WeeklyReview.isDue(now: date(13, 16), lastReviewedWeek: nil, calendar: calendar))
    XCTAssertTrue(WeeklyReview.isDue(now: date(15), lastReviewedWeek: nil, calendar: calendar), "Sunday")
    XCTAssertTrue(WeeklyReview.isDue(now: date(16), lastReviewedWeek: nil, calendar: calendar), "Monday")
    XCTAssertFalse(WeeklyReview.isDue(now: date(16), lastReviewedWeek: "2026-W46", calendar: calendar), "already reviewed")
  }

  func testMondayReviewsTheWeekJustFinished() {
    XCTAssertEqual(WeeklyReview.weekKey(for: date(15), calendar: calendar), "2026-W46")
    XCTAssertEqual(WeeklyReview.weekKey(for: date(16), calendar: calendar), "2026-W46")
    XCTAssertEqual(WeeklyReview.reviewedWeekStart(for: date(16), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    XCTAssertEqual(WeeklyReview.nextMonday(after: date(16), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    XCTAssertEqual(WeeklyReview.nextMonday(after: date(13), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
  }

  func testShutdownIsOfferedInTheEveningUntilDone() {
    XCTAssertFalse(TodayBriefing.shutdownDue(now: date(11, 15), lastShutdownDay: nil, calendar: calendar))
    XCTAssertTrue(TodayBriefing.shutdownDue(now: date(11, 18), lastShutdownDay: nil, calendar: calendar))
    XCTAssertTrue(TodayBriefing.shutdownDue(now: date(12, 1), lastShutdownDay: "2026-11-10", calendar: calendar), "after midnight still belongs to the evening")
    XCTAssertFalse(TodayBriefing.shutdownDue(now: date(11, 18), lastShutdownDay: "2026-11-11", calendar: calendar))
  }

  func testReviewJournalCarriesWinsAnswersAndNextWeek() {
    let summary = WeeklyReview.Summary(
      weekStart: date(9),
      weekEnd: date(16),
      completedTasks: [],
      focusHours: 6.5,
      routines: [.init(title: "Walk", done: 4), .init(title: "Read", done: 0)],
      goals: []
    )
    var answers = WeeklyReview.Answers()
    answers.moved = "Sync fixes landed"
    answers.nextWeek = ["Ship 1.0 beta", "", "Book physio"]

    let text = WeeklyReview.journalText(summary: summary, answers: answers)

    XCTAssertTrue(text.contains("- 6.5 h of focus"))
    XCTAssertTrue(text.contains("- Walk: 4 days"))
    XCTAssertFalse(text.contains("Read:"))
    XCTAssertTrue(text.contains("## What moved\nSync fixes landed"))
    XCTAssertTrue(text.hasSuffix("## Next week\n- Ship 1.0 beta\n- Book physio"))
    XCTAssertFalse(text.contains("What stalled"))
  }
}

@MainActor
final class DailyRhythmAppStateTests: XCTestCase {
  func testSomedayLeavesTheInboxAndTopThreeTagsTomorrow() async throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-rhythm-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.rhythm.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "rhythm.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    _ = await state.createTask(title: "Learn Rust", priority: .low, dueDate: nil, tags: [], subtaskTitles: [])
    _ = await state.createTask(title: "Invoice", priority: .medium, dueDate: nil, tags: [], subtaskTitles: [])
    XCTAssertEqual(state.inboxTasks.count, 2)

    let rust = try XCTUnwrap(state.tasks.first { $0.title == "Learn Rust" })
    await state.keepTaskForSomeday(id: rust.id)
    XCTAssertEqual(state.inboxTasks.map(\.title), ["Invoice"])

    let invoice = try XCTUnwrap(state.tasks.first { $0.title == "Invoice" })
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    await state.setTopThree(taskIDs: [invoice.id], for: tomorrow)

    XCTAssertEqual(state.topThreeTasks(on: tomorrow).map(\.title), ["Invoice"])
    XCTAssertEqual(state.tasks.first { $0.id == invoice.id }?.dueDate, tomorrow)
    XCTAssertTrue(state.inboxTasks.isEmpty)

    await state.setTopThree(taskIDs: [], for: tomorrow)
    XCTAssertTrue(state.topThreeTasks(on: tomorrow).isEmpty)
  }
}
