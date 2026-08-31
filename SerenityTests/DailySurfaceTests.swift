import XCTest
@testable import SerenityMac

/// Covers the three collections Home's bands read, plus the due-date wording.
/// The regression that motivated these: capture with no date produced a task
/// that appeared on no surface at all.
@MainActor
final class DailySurfaceTests: XCTestCase {
  private func makeState() -> AppState {
    AppState(serenityCloudAdapter: nil, externalPostgresAdapter: nil)
  }

  private func task(
    id: String,
    dueDate: Date?,
    completed: Bool = false,
    createdAt: Date = Date()
  ) -> TaskEntity {
    TaskEntity(
      id: id,
      title: id,
      description: nil,
      completed: completed,
      completedAt: completed ? Date() : nil,
      priority: .medium,
      dueDate: dueDate,
      projectId: nil,
      tags: [],
      createdAt: createdAt,
      updatedAt: createdAt,
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }

  func testInboxHoldsOnlyUndatedOpenTasks() {
    let state = makeState()
    let calendar = Calendar.current
    state.tasks = [
      task(id: "undated-open", dueDate: nil),
      task(id: "undated-done", dueDate: nil, completed: true),
      task(id: "dated-open", dueDate: calendar.date(byAdding: .day, value: 3, to: Date())),
    ]

    XCTAssertEqual(state.inboxTasks.map(\.id), ["undated-open"])
  }

  func testInboxIsNewestFirst() {
    let state = makeState()
    let now = Date()
    state.tasks = [
      task(id: "older", dueDate: nil, createdAt: now.addingTimeInterval(-600)),
      task(id: "newest", dueDate: nil, createdAt: now),
    ]

    XCTAssertEqual(state.inboxTasks.map(\.id), ["newest", "older"], "the thing you just captured belongs on top")
  }

  func testCapturedUndatedTaskIsVisibleOnHomeEvenThoughItIsNotDueToday() {
    let state = makeState()
    state.tasks = [task(id: "captured", dueDate: nil)]

    XCTAssertTrue(state.todayTasks.isEmpty)
    XCTAssertTrue(state.overdueTasks.isEmpty)
    XCTAssertFalse(state.inboxTasks.isEmpty, "an undated capture must land in a band Home renders")
  }

  /// The band set must partition every open task, or capture can still produce
  /// something invisible. A task due tomorrow originally matched no band at all.
  func testEveryOpenTaskLandsInExactlyOneBand() {
    let state = makeState()
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    state.tasks = [
      task(id: "overdue", dueDate: calendar.date(byAdding: .day, value: -2, to: today)),
      task(id: "today", dueDate: calendar.date(byAdding: .hour, value: 23, to: today)),
      task(id: "tomorrow", dueDate: calendar.date(byAdding: .day, value: 1, to: today)),
      task(id: "in-a-week", dueDate: calendar.date(byAdding: .day, value: 6, to: today)),
      task(id: "undated", dueDate: nil),
    ]

    let banded =
      state.overdueTasks.map(\.id)
      + state.todayTasks.map(\.id)
      + state.upcomingTasks.map(\.id)
      + state.inboxTasks.map(\.id)

    XCTAssertEqual(
      Set(banded),
      Set(state.tasks.map(\.id)),
      "every open task must appear in a band Home renders"
    )
    XCTAssertEqual(banded.count, Set(banded).count, "no task may appear in two bands")
  }

  func testUpcomingCoversTomorrowThroughAWeekOut() {
    let state = makeState()
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    state.tasks = [
      task(id: "today", dueDate: calendar.date(byAdding: .hour, value: 10, to: today)),
      task(id: "tomorrow", dueDate: calendar.date(byAdding: .day, value: 1, to: today)),
      task(id: "far-future", dueDate: calendar.date(byAdding: .day, value: 40, to: today)),
      task(id: "tomorrow-done", dueDate: calendar.date(byAdding: .day, value: 1, to: today), completed: true),
    ]

    XCTAssertEqual(state.upcomingTasks.map(\.id), ["tomorrow"])
  }

  func testOverdueExcludesCompletedAndFutureTasks() {
    let state = makeState()
    let calendar = Calendar.current
    let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())
    state.tasks = [
      task(id: "late", dueDate: yesterday),
      task(id: "late-but-done", dueDate: yesterday, completed: true),
      task(id: "upcoming", dueDate: calendar.date(byAdding: .day, value: 1, to: Date())),
    ]

    XCTAssertEqual(state.overdueTasks.map(\.id), ["late"])
  }

  func testLastSectionRoundTripsThroughDefaults() {
    let state = makeState()
    let key = AppState.lastSectionDefaultsKey
    let original = UserDefaults.standard.string(forKey: key)
    defer {
      if let original {
        UserDefaults.standard.set(original, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    state.setSection(.journal)

    XCTAssertEqual(UserDefaults.standard.string(forKey: key), AppSection.journal.rawValue)
  }

  func testLastSectionIsNotSyncedAcrossDevices() {
    XCTAssertFalse(
      SettingsSyncCoordinator.allowlist.contains(AppState.lastSectionDefaultsKey),
      "which pane this Mac was on should not follow the user to another device"
    )
  }

  // MARK: Due-date wording

  func testDueTextUsesDistanceNotCalendarCoordinates() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!

    XCTAssertEqual(SerenityDateText.due(now, now: now, calendar: calendar), "Today")
    XCTAssertEqual(
      SerenityDateText.due(calendar.date(byAdding: .day, value: 1, to: now)!, now: now, calendar: calendar),
      "Tomorrow"
    )
    XCTAssertEqual(
      SerenityDateText.due(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar),
      "Yesterday"
    )
  }

  func testPastDatesAreMarkedOverdue() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
    let longPast = calendar.date(byAdding: .day, value: -40, to: now)!

    XCTAssertTrue(SerenityDateText.due(longPast, now: now, calendar: calendar).hasPrefix("Overdue · "))
  }

  func testDistantDatesDropToAStampAndGainAYearWhenItDiffers() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
    let sameYear = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5))!
    let nextYear = calendar.date(from: DateComponents(year: 2027, month: 12, day: 5))!

    XCTAssertEqual(SerenityDateText.due(sameYear, now: now, calendar: calendar), "Dec 5")
    XCTAssertEqual(SerenityDateText.due(nextYear, now: now, calendar: calendar), "Dec 5, 2027")
  }

  func testMidnightIsTreatedAsDateOnly() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
    let dateOnly = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)

    XCTAssertEqual(
      SerenityDateText.dueWithTime(dateOnly, now: now, calendar: calendar),
      "Tomorrow",
      "a date-only due date must not claim to be due at midnight"
    )
  }

  func testExplicitTimesAreShown() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
    let afternoon = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 15))!

    let text = SerenityDateText.dueWithTime(afternoon, now: now, calendar: calendar)
    XCTAssertTrue(text.hasPrefix("Today · "), "expected a time to be appended, got \(text)")
  }
}
