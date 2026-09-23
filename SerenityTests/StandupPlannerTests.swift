import XCTest
@testable import SerenityMac

/// The planner decides what counts as progress, what counts as stuck, and what
/// "yesterday" means on a Monday. All of that is judgement rather than
/// plumbing, so it is tested against a fixed clock rather than the real one.
final class StandupPlannerTests: XCTestCase {
  /// Monday 21 September 2026, 09:30 local. Every date below is built from this
  /// so the weekday arithmetic is real rather than assumed.
  private let calendar = Calendar(identifier: .gregorian)

  private var monday: Date {
    date(year: 2026, month: 9, day: 21, hour: 9, minute: 30)
  }

  private var friday: Date {
    date(year: 2026, month: 9, day: 18, hour: 9, minute: 42)
  }

  // MARK: - The window

  func testMondayLooksBackToFridayOnTheFirstEverRun() {
    let window = StandupPlanner.resolveWindow(lastStandupAt: nil, now: monday, calendar: calendar)

    XCTAssertEqual(window.anchor, .previousWorkingDay)
    XCTAssertEqual(calendar.component(.weekday, from: window.start), 6)
    XCTAssertEqual(window.start, calendar.startOfDay(for: friday))
  }

  func testATuesdayFirstRunLooksBackToMonday() {
    let tuesday = date(year: 2026, month: 9, day: 22, hour: 9, minute: 30)

    let window = StandupPlanner.resolveWindow(lastStandupAt: nil, now: tuesday, calendar: calendar)

    XCTAssertEqual(window.anchor, .previousWorkingDay)
    XCTAssertEqual(window.start, calendar.startOfDay(for: monday))
  }

  func testASundayFirstRunStillLandsOnFriday() {
    let sunday = date(year: 2026, month: 9, day: 20, hour: 11, minute: 0)

    let window = StandupPlanner.resolveWindow(lastStandupAt: nil, now: sunday, calendar: calendar)

    XCTAssertEqual(window.start, calendar.startOfDay(for: friday))
  }

  func testAStoredStandupAnchorsTheWindowToItself() {
    let window = StandupPlanner.resolveWindow(lastStandupAt: friday, now: monday, calendar: calendar)

    XCTAssertEqual(window.anchor, .lastStandup)
    XCTAssertEqual(window.start, friday)
  }

  /// Three weeks of activity after a holiday is a status report, not a
  /// stand-up, and the model will happily try to say all of it.
  func testALongGapIsCappedAndSaysSo() {
    let longAgo = date(year: 2026, month: 8, day: 20, hour: 9, minute: 0)

    let window = StandupPlanner.resolveWindow(lastStandupAt: longAgo, now: monday, calendar: calendar)

    XCTAssertEqual(window.anchor, .capped)
    XCTAssertEqual(
      window.start,
      calendar.date(byAdding: .day, value: -StandupPlanner.windowCapDays, to: monday)
    )
  }

  /// Generating twice in one morning must not replay the first one.
  func testASecondRunTheSameDayAnchorsToTheFirstAndFlagsIt() {
    let earlier = date(year: 2026, month: 9, day: 21, hour: 8, minute: 0)

    let window = StandupPlanner.resolveWindow(lastStandupAt: earlier, now: monday, calendar: calendar)

    XCTAssertEqual(window.anchor, .sameDay)
    XCTAssertEqual(window.start, earlier)
  }

  // MARK: - Since

  func testAFinishedTaskLandsUnderSinceWithWhenItFinished() {
    let done = task(
      id: "t1",
      title: "Ship Slack PKCE token refresh",
      completed: true,
      completedAt: date(year: 2026, month: 9, day: 18, hour: 16, minute: 12)
    )

    let board = build(tasks: [done])

    let card = try? XCTUnwrap(board.cards(in: .since).first)
    XCTAssertEqual(card?.title, "Ship Slack PKCE token refresh")
    XCTAssertEqual(card?.source, .completed)
    XCTAssertTrue(card?.fact.hasPrefix("Finished Friday") == true, card?.fact ?? "")
  }

  func testAFinishedTaskDoesNotAlsoClaimTodayOrBlocked() {
    let done = task(
      id: "t1",
      title: "Done thing",
      completed: true,
      completedAt: date(year: 2026, month: 9, day: 18, hour: 16, minute: 12),
      dueDate: date(year: 2026, month: 9, day: 10, hour: 9, minute: 0)
    )

    let board = build(tasks: [done])

    XCTAssertTrue(board.cards(in: .today).isEmpty)
    XCTAssertTrue(board.cards(in: .blocked).isEmpty)
  }

  /// The line people most often forget, and the only place it is recorded.
  func testClosedSubtasksBecomeProgressWithBothCounts() {
    let moving = task(
      id: "t2",
      title: "Capture commands for GitHub pull requests",
      subtasks: (1...5).map { subtask(id: "s\($0)", completed: $0 <= 3) },
      activity: [
        event("Subtask done \u{00B7} Parse the link", at: date(year: 2026, month: 9, day: 18, hour: 14, minute: 0)),
        event("Subtask done \u{00B7} Fetch the PR", at: date(year: 2026, month: 9, day: 18, hour: 15, minute: 10)),
        event("Subtask done \u{00B7} Draft the task", at: date(year: 2026, month: 9, day: 18, hour: 17, minute: 48)),
      ]
    )

    let board = build(tasks: [moving])

    let card = try? XCTUnwrap(board.cards(in: .since).first)
    XCTAssertEqual(card?.source, .progress)
    XCTAssertEqual(card?.fact, "3 of 5 subtasks done Friday")
  }

  func testYourOwnCommentOutranksAFieldChange() {
    let noted = task(
      id: "t3",
      title: "Postgres adapter connection timeouts",
      activity: [
        event("Priority set to High", at: date(year: 2026, month: 9, day: 18, hour: 11, minute: 0)),
        comment("waiting on infra creds", at: date(year: 2026, month: 9, day: 18, hour: 14, minute: 10)),
      ]
    )

    let board = build(tasks: [noted])

    let card = try? XCTUnwrap(board.cards(in: .since).first)
    XCTAssertEqual(card?.source, .comment)
    XCTAssertTrue(card?.fact.contains("waiting on infra creds") == true, card?.fact ?? "")
  }

  func testActivityFromBeforeTheWindowIsNotClaimed() {
    let stale = task(
      id: "t4",
      title: "Old movement",
      activity: [event("Subtask done \u{00B7} Ancient", at: date(year: 2026, month: 9, day: 10, hour: 9, minute: 0))]
    )

    let board = build(tasks: [stale])

    XCTAssertTrue(board.cards(in: .since).isEmpty)
  }

  // MARK: - Today

  func testAnOverdueTaskLeadsTodayAndCountsTheDays() {
    let late = task(
      id: "t5",
      title: "Review dropdown option density",
      dueDate: date(year: 2026, month: 9, day: 19, hour: 9, minute: 0)
    )
    let dueNow = task(
      id: "t6",
      title: "Refresh model rates in Cost Center",
      dueDate: date(year: 2026, month: 9, day: 21, hour: 17, minute: 0)
    )

    let board = build(tasks: [dueNow, late])

    let todayCards = board.cards(in: .today)
    XCTAssertEqual(todayCards.map(\.title), ["Review dropdown option density", "Refresh model rates in Cost Center"])
    XCTAssertEqual(todayCards.first?.fact, "Overdue by 2 days")
    XCTAssertEqual(todayCards.last?.fact, "Due today")
  }

  /// A task can be genuinely both: three subtasks closed on Friday, two left
  /// today. Forcing a choice loses half the truth.
  func testOneTaskCanHoldBothASinceCardAndATodayCard() {
    let both = task(
      id: "t7",
      title: "Capture commands for GitHub pull requests",
      dueDate: date(year: 2026, month: 9, day: 22, hour: 9, minute: 0),
      subtasks: (1...5).map { subtask(id: "s\($0)", completed: $0 <= 3) },
      activity: [
        event("Subtask done \u{00B7} Draft the task", at: date(year: 2026, month: 9, day: 18, hour: 17, minute: 48)),
      ]
    )

    let board = build(tasks: [both])

    XCTAssertEqual(board.cards(in: .since).count, 1)
    XCTAssertEqual(board.cards(in: .today).count, 1)
    XCTAssertEqual(board.cards(in: .today).first?.fact, "Due Tuesday \u{00B7} 2 subtasks left")
    XCTAssertNotEqual(board.cards(in: .since).first?.id, board.cards(in: .today).first?.id)
  }

  func testAQuietUndatedTaskIsNotDraggedIntoTheStandup() {
    let idle = task(id: "t8", title: "Someday thing")

    let board = build(tasks: [idle])

    XCTAssertFalse(board.hasAnythingToSay)
  }

  // MARK: - Blocked

  func testATaggedBlockerIsStatedNotGuessed() {
    let stuck = task(id: "t9", title: "Needs a decision", tags: ["blocked"])

    let board = build(tasks: [stuck])

    let card = try? XCTUnwrap(board.cards(in: .blocked).first)
    XCTAssertEqual(card?.source, .stated)
    XCTAssertFalse(card?.source.isGuess == true)
  }

  func testAnOverdueAndSilentTaskIsGuessedAndLabelled() {
    let silent = task(
      id: "t10",
      title: "Postgres adapter connection timeouts",
      dueDate: date(year: 2026, month: 9, day: 18, hour: 9, minute: 0),
      activity: [event("Priority set to High", at: date(year: 2026, month: 9, day: 17, hour: 9, minute: 0))],
      updatedAt: date(year: 2026, month: 9, day: 17, hour: 9, minute: 0)
    )

    let board = build(tasks: [silent])

    let card = try? XCTUnwrap(board.cards(in: .blocked).first)
    XCTAssertEqual(card?.source, .guessed)
    XCTAssertTrue(card?.source.isGuess == true)
    XCTAssertTrue(card?.fact.contains("4 days") == true, card?.fact ?? "")
  }

  /// Something you never picked up is backlog running late, not a blocker.
  /// Calling it one puts a fiction in front of the team every morning.
  func testAnOverdueTaskYouNeverTouchedIsBacklogNotABlocker() {
    let untouched = task(
      id: "t10b",
      title: "Review dropdown option density",
      dueDate: date(year: 2026, month: 9, day: 19, hour: 9, minute: 0)
    )

    let board = build(tasks: [untouched])

    XCTAssertTrue(board.cards(in: .blocked).isEmpty)
    XCTAssertEqual(board.cards(in: .today).first?.fact, "Overdue by 2 days")
  }

  func testAnOverdueTaskThatIsStillMovingIsNotCalledABlocker() {
    let moving = task(
      id: "t11",
      title: "Late but alive",
      dueDate: date(year: 2026, month: 9, day: 19, hour: 9, minute: 0),
      activity: [event("Subtask done \u{00B7} Something", at: date(year: 2026, month: 9, day: 21, hour: 8, minute: 0))]
    )

    let board = build(tasks: [moving])

    XCTAssertTrue(board.cards(in: .blocked).isEmpty)
    XCTAssertEqual(board.cards(in: .today).count, 1)
  }

  func testABlockedTaskIsNotAlsoListedAsTodaysPlan() {
    let stuck = task(
      id: "t12",
      title: "Needs a decision",
      tags: ["blocked"],
      dueDate: date(year: 2026, month: 9, day: 21, hour: 9, minute: 0)
    )

    let board = build(tasks: [stuck])

    XCTAssertEqual(board.cards(in: .blocked).count, 1)
    XCTAssertTrue(board.cards(in: .today).isEmpty)
  }

  // MARK: - Carry-over

  /// The point of knowing you said it before is to say where it got to, not to
  /// drop it — so it stays in Today and carries what was said.
  func testAnItemFromTheLastStandupStaysInTodayAndRemembersWhatWasSaid() {
    let ongoing = task(
      id: "t13",
      title: "Capture commands for GitHub pull requests",
      dueDate: date(year: 2026, month: 9, day: 22, hour: 9, minute: 0)
    )
    let recall = StandupRecall(
      generatedAt: friday,
      mentions: ["t13": StandupMention(column: .today, fact: "Due Tuesday \u{00B7} 4 subtasks left")]
    )

    let board = build(tasks: [ongoing], recall: recall)

    let card = try? XCTUnwrap(board.cards(in: .today).first)
    XCTAssertEqual(card?.source, .carried)
    XCTAssertEqual(card?.saidLast, "Due Tuesday \u{00B7} 4 subtasks left")
  }

  func testSomethingBlockedLastTimeAndStillOpenStaysBlockedWithTheDayCount() {
    let stuck = task(
      id: "t14",
      title: "Postgres adapter connection timeouts",
      updatedAt: date(year: 2026, month: 9, day: 17, hour: 9, minute: 0)
    )
    let recall = StandupRecall(
      generatedAt: friday,
      mentions: ["t14": StandupMention(column: .blocked, fact: "Needs infra credentials")]
    )

    let board = build(tasks: [stuck], recall: recall)

    let card = try? XCTUnwrap(board.cards(in: .blocked).first)
    XCTAssertEqual(card?.source, .carried)
    XCTAssertEqual(card?.saidLast, "Needs infra credentials")
    XCTAssertTrue(card?.fact.contains("4 days") == true, card?.fact ?? "")
  }

  // MARK: - Calendar noise

  func testASyncedMeetingStartsInTheLeavingOutTray() {
    let meeting = task(
      id: "t15",
      title: "Standing sync with design",
      tags: ["google-calendar", "gcal-event-abc"],
      dueDate: date(year: 2026, month: 9, day: 21, hour: 14, minute: 0)
    )

    let board = build(tasks: [meeting])

    XCTAssertEqual(board.cards(in: .leftOut).map(\.title), ["Standing sync with design"])
    XCTAssertTrue(board.cards(in: .today).isEmpty)
    XCTAssertFalse(board.hasAnythingToSay)
  }

  // MARK: - The detail behind a card

  func testACardCarriesTheTaskItsDescriptionSubtasksAndComments() throws {
    let detailed = task(
      id: "t9",
      title: "Postgres adapter connection timeouts",
      description: "Pool exhausts under the nightly backfill; suspect the adapter never returns a\nconnection after a statement timeout.",
      dueDate: monday,
      subtasks: [
        subtask(id: "s1", title: "Reproduce against staging", completed: true, order: 0),
        subtask(id: "s2", title: "Patch the release path", completed: false, order: 1),
      ],
      activity: [
        comment("Repro is deterministic with two writers", at: date(year: 2026, month: 9, day: 18, hour: 14, minute: 10)),
        comment("Infra says the pool cap is ours to change", at: date(year: 2026, month: 9, day: 19, hour: 9, minute: 5)),
      ]
    )

    let card = try XCTUnwrap(build(tasks: [detailed]).cards(in: .today).first)

    XCTAssertTrue(card.detail.description?.hasPrefix("Pool exhausts") == true)
    XCTAssertEqual(card.detail.subtasks.map(\.title), ["Reproduce against staging", "Patch the release path"])
    XCTAssertEqual(card.detail.subtasks.map(\.completed), [true, false])
    // Whole, and oldest first: what the writer trims is the writer's call.
    XCTAssertEqual(card.detail.comments.map(\.text), [
      "Repro is deterministic with two writers",
      "Infra says the pool cap is ours to change",
    ])
  }

  /// The one-line fact clips a comment to sixty characters. The detail must
  /// not, or the "detailed" setting has nothing longer to say.
  func testTheDetailKeepsACommentTheFactLineHadToCut() throws {
    let long = String(repeating: "a", count: 200)
    let noted = task(
      id: "t10",
      title: "Postgres adapter connection timeouts",
      activity: [comment(long, at: date(year: 2026, month: 9, day: 18, hour: 14, minute: 10))]
    )

    let card = try XCTUnwrap(build(tasks: [noted]).cards(in: .since).first)

    XCTAssertTrue(card.fact.contains("\u{2026}"), card.fact)
    XCTAssertEqual(card.detail.comments.first?.text, long)
  }

  /// Field changes are the app talking about itself. They are already summarised
  /// into the fact, and repeating them as "comments" would invite the script to
  /// quote Serenity back at the team.
  func testEventsAreNotPassedOffAsSomethingThePersonWrote() throws {
    let moved = task(
      id: "t11",
      title: "Capture commands for GitHub pull requests",
      activity: [event("Priority set to High", at: date(year: 2026, month: 9, day: 18, hour: 11, minute: 0))]
    )

    let card = try XCTUnwrap(build(tasks: [moved]).cards(in: .since).first)

    XCTAssertTrue(card.detail.comments.isEmpty)
  }

  /// Day words come from the board's clock, never the machine's, so the same
  /// board built two weeks apart reads the same.
  func testDayWordsFollowTheGivenClockInAnyWeek() throws {
    let wednesdays = [
      date(year: 2026, month: 9, day: 23, hour: 10, minute: 0),
      date(year: 2026, month: 10, day: 7, hour: 10, minute: 0),
    ]
    for now in wednesdays {
      func shifted(days: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
      }
      let moved = task(
        id: "a",
        title: "Moved yesterday",
        activity: [event("Priority set to High", at: shifted(days: -1, hour: 11))]
      )
      let due = task(id: "b", title: "Due Friday", dueDate: shifted(days: 2, hour: 17), activity: [
        event("Priority set to Low", at: shifted(days: 0, hour: 9)),
      ])
      let done = task(id: "c", title: "Done today", completed: true, completedAt: shifted(days: 0, hour: 9))

      let board = StandupPlanner.build(
        tasks: [moved, due, done],
        window: StandupWindow(start: shifted(days: -2, hour: 0), end: now, anchor: .lastStandup),
        recall: nil,
        now: now,
        calendar: calendar
      )

      let since = Dictionary(uniqueKeysWithValues: board.cards(in: .since).compactMap { card in
        card.taskID.map { ($0, card.fact) }
      })
      XCTAssertEqual(since["a"], "Priority set to High \u{00B7} yesterday")
      XCTAssertTrue(since["c"]?.hasPrefix("Finished today ") ?? false, since["c"] ?? "")
      let today = board.cards(in: .today).first { $0.taskID == "b" }
      XCTAssertEqual(today?.fact, "Due Friday")
      XCTAssertEqual(
        StandupDateText.windowLabel(board.window, now: now, calendar: calendar),
        "Since Monday"
      )
    }
  }

  // MARK: - Helpers

  private func build(tasks: [TaskEntity], recall: StandupRecall? = nil) -> StandupBoard {
    StandupPlanner.build(
      tasks: tasks,
      window: StandupWindow(start: friday, end: monday, anchor: .lastStandup),
      recall: recall,
      now: monday,
      calendar: calendar
    )
  }

  private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }

  private func task(
    id: String,
    title: String,
    description: String? = nil,
    completed: Bool = false,
    completedAt: Date? = nil,
    tags: [String] = [],
    dueDate: Date? = nil,
    subtasks: [TaskSubtask] = [],
    activity: [TaskActivityEntry] = [],
    updatedAt: Date? = nil
  ) -> TaskEntity {
    let created = date(year: 2026, month: 9, day: 1, hour: 9, minute: 0)
    return TaskEntity(
      id: id,
      title: title,
      description: description,
      completed: completed,
      completedAt: completedAt,
      priority: .medium,
      dueDate: dueDate,
      projectId: nil,
      tags: tags,
      createdAt: created,
      updatedAt: updatedAt ?? created,
      subtasks: subtasks,
      recurring: nil,
      userId: nil,
      activity: activity
    )
  }

  private func subtask(id: String, title: String? = nil, completed: Bool, order: Int = 0) -> TaskSubtask {
    TaskSubtask(id: id, title: title ?? id, completed: completed, order: order)
  }

  private func event(_ text: String, at instant: Date) -> TaskActivityEntry {
    TaskActivityEntry(id: UUID().uuidString, kind: .event, text: text, createdAt: instant)
  }

  private func comment(_ text: String, at instant: Date) -> TaskActivityEntry {
    TaskActivityEntry(id: UUID().uuidString, kind: .comment, text: text, createdAt: instant)
  }
}
