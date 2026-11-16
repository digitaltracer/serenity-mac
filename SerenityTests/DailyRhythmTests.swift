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

  func testWeeklyReviewIsDueFromMondayUntilLastWeekIsReviewed() {
    XCTAssertTrue(WeeklyReview.isDue(now: date(16, 7), completedWeeks: [], hadActivity: true, calendar: calendar), "Monday morning")
    XCTAssertTrue(WeeklyReview.isDue(now: date(19), completedWeeks: [], hadActivity: true, calendar: calendar), "still waiting on Thursday")
    XCTAssertFalse(WeeklyReview.isDue(now: date(16), completedWeeks: ["2026-W46"], hadActivity: true, calendar: calendar), "already reviewed")
    XCTAssertTrue(WeeklyReview.isDue(now: date(23), completedWeeks: ["2026-W46"], hadActivity: true, calendar: calendar), "the next Monday asks again")
    XCTAssertFalse(WeeklyReview.isDue(now: date(16), completedWeeks: [], hadActivity: false, calendar: calendar), "nothing to look back at")
  }

  func testTheReviewAlwaysLooksBackAtLastWeek() {
    XCTAssertEqual(WeeklyReview.weekKey(for: date(16), calendar: calendar), "2026-W46")
    XCTAssertEqual(WeeklyReview.weekKey(for: date(22), calendar: calendar), "2026-W46")
    XCTAssertEqual(WeeklyReview.weekKey(for: date(15), calendar: calendar), "2026-W45")
    XCTAssertEqual(WeeklyReview.reviewedWeekStart(for: date(16), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    XCTAssertEqual(WeeklyReview.nextMonday(after: date(16), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    XCTAssertEqual(WeeklyReview.nextMonday(after: date(13), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    XCTAssertEqual(WeeklyReview.nextWeekday(after: date(13), calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
  }

  func testShutdownIsOfferedInTheEveningUntilDone() {
    XCTAssertFalse(TodayBriefing.shutdownDue(now: date(11, 15), lastShutdownDay: nil, calendar: calendar))
    XCTAssertTrue(TodayBriefing.shutdownDue(now: date(11, 18), lastShutdownDay: nil, calendar: calendar))
    XCTAssertTrue(TodayBriefing.shutdownDue(now: date(12, 1), lastShutdownDay: "2026-11-10", calendar: calendar), "after midnight still belongs to the evening")
    XCTAssertFalse(TodayBriefing.shutdownDue(now: date(11, 18), lastShutdownDay: "2026-11-11", calendar: calendar))
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
