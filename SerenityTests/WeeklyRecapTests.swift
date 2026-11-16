import Foundation
import XCTest
@testable import SerenityMac

final class WeeklyRecapTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private let locale = Locale(identifier: "en_GB")

  /// Monday 9 November 2026, the start of the reviewed week.
  private var weekStart: Date { date(11, 9, hour: 0) }
  /// The Monday morning after.
  private var now: Date { date(11, 16, hour: 8) }

  private func date(_ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private func task(
    _ id: String,
    project: String? = nil,
    done: Date? = nil,
    due: Date? = nil,
    tags: [String] = [],
    created: Date? = nil,
    moves: [Date] = []
  ) -> TaskEntity {
    let created = created ?? date(10, 1)
    return TaskEntity(
      id: id,
      title: id,
      description: nil,
      completed: done != nil,
      completedAt: done,
      priority: .medium,
      dueDate: due,
      projectId: project,
      tags: tags,
      createdAt: created,
      updatedAt: done ?? created,
      subtasks: [],
      recurring: nil,
      userId: nil,
      activity: moves.map { TaskActivityEntry(id: UUID().uuidString, kind: .event, text: "Due date set to \($0)", createdAt: $0) }
    )
  }

  private func event(_ id: String, at start: Date) -> TaskEntity {
    task(id, project: "google-calendar-project", due: start, tags: [TodayBriefing.calendarTag], created: date(10, 1))
  }

  private func block(_ id: String, start: Date, minutes: Double, task: String? = nil, goal: String? = nil) -> FocusBlockEntity {
    FocusBlockEntity(
      id: id,
      title: id,
      start: start,
      end: start.addingTimeInterval(minutes * 60),
      goalId: goal,
      taskIds: task.map { [$0] } ?? [],
      status: .done,
      startedAt: start,
      finishedAt: start.addingTimeInterval(minutes * 60),
      loggedMinutes: minutes,
      createdAt: start,
      updatedAt: start
    )
  }

  private func project(_ id: String, _ name: String) -> ProjectEntity {
    ProjectEntity(id: id, name: name, description: nil, color: "#000", icon: nil, createdAt: date(10, 1), updatedAt: date(10, 1), archived: false, userId: nil)
  }

  private func goal(_ id: String, _ title: String, config: GoalConfig, created: Date? = nil) -> GoalEntity {
    let created = created ?? date(10, 1)
    return GoalEntity(
      id: id,
      title: title,
      description: nil,
      type: .weeklyTasks,
      config: config,
      progress: GoalProgress(current: 0, target: 1, percentage: 0, isCompleted: false, periodStart: created, periodEnd: created),
      status: .active,
      priority: .medium,
      reminders: [],
      createdAt: created,
      updatedAt: created,
      userId: nil
    )
  }

  private func routine(_ id: String, _ title: String, time: RoutineTimeOfDay = .morning, schedule: RoutineSchedule = .daily) -> RoutineEntity {
    RoutineEntity(id: id, title: title, schedule: schedule, timeOfDay: time, archived: false, createdAt: date(10, 1), updatedAt: date(10, 1))
  }

  private func check(_ routineId: String, _ day: Date, _ status: RoutineCheckStatus = .done) -> RoutineCheckEntity {
    RoutineCheckEntity(routineId: routineId, day: RoutineDay.key(for: day, calendar: calendar), status: status, createdAt: day, updatedAt: day)
  }

  private func entry(_ id: String, _ day: Date, _ text: String, mood: JournalMood?) -> JournalEntryEntity {
    JournalEntryEntity(id: id, title: nil, content: text, date: day, tags: [], createdAt: day, updatedAt: day, pinned: false, mood: mood, attachments: [], userId: nil)
  }

  private func build(_ inputs: WeeklyRecapInputs, now: Date? = nil) -> WeeklyRecap {
    WeeklyRecap.build(inputs: inputs, weekStart: weekStart, now: now ?? self.now, calendar: calendar, goalCalendar: calendar, locale: locale)
  }

  // MARK: History gate

  func testUnderFourWeeksShowsPlainNumbersAndNoPatterns() {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [task("a", done: date(11, 10), created: date(10, 26))]
    inputs.focusBlocks = [block("f", start: date(11, 10, hour: 9), minutes: 30)]

    let recap = build(inputs)

    XCTAssertEqual(recap.weeksOfHistory, 2)
    XCTAssertFalse(recap.hasPatterns)
    XCTAssertNil(recap.tasks.baseline)
    XCTAssertNil(recap.focus.baseline)
    XCTAssertEqual(recap.tasks.done, 1)
  }

  func testPatternFindingsAreDroppedWithoutHistory() {
    let pattern = WeeklyFinding(id: "deepWorkBelowBaseline:focus", kind: .deepWorkBelowBaseline, subjectId: "focus", linked: "", title: "", body: "", evidenceLabel: "", evidence: [], action: nil, actionTitle: nil, score: 3)
    let stuck = WeeklyFinding(id: "stuckTask:t", kind: .stuckTask, subjectId: "t", linked: "", title: "", body: "", evidenceLabel: "", evidence: [], action: nil, actionTitle: nil, score: 2)

    XCTAssertEqual(WeeklyRecap.rank([pattern, stuck], feedback: [], hasHistory: false, weekStart: weekStart, calendar: calendar).map(\.id), ["stuckTask:t"])
    XCTAssertEqual(WeeklyRecap.rank([pattern, stuck], feedback: [], hasHistory: true, weekStart: weekStart, calendar: calendar).map(\.id), ["deepWorkBelowBaseline:focus", "stuckTask:t"])
  }

  // MARK: Metrics

  func testTaskCountsAgainstTheFourWeeksBeforeAndSkipCalendarEvents() {
    var inputs = WeeklyRecapInputs()
    inputs.projects = [project("agy", "Agency"), project("ser", "Serenity 1.0")]
    inputs.tasks = [
      task("w1", project: "agy", done: date(11, 9)),
      task("w2", project: "agy", done: date(11, 12)),
      task("w3", project: "ser", done: date(11, 15)),
      task("w4", done: date(11, 14)),
      task("next", done: date(11, 16, hour: 7)),
      event("cal", at: date(11, 10, hour: 14)),
      task("b1", done: date(11, 3)),
      task("b2", done: date(10, 27)),
      task("b3", done: date(10, 20)),
      task("b4", done: date(10, 13)),
      task("b5", done: date(10, 13)),
      task("old", done: date(10, 6)),
    ]

    let recap = build(inputs)

    XCTAssertTrue(recap.hasPatterns)
    XCTAssertEqual(recap.tasks.done, 4)
    XCTAssertEqual(recap.tasks.baseline, 5.0 / 4.0)
    XCTAssertEqual(recap.tasks.byProject, [
      WeeklyRecap.ProjectCount(name: "Agency", count: 2),
      WeeklyRecap.ProjectCount(name: "No project", count: 1),
      WeeklyRecap.ProjectCount(name: "Serenity 1.0", count: 1),
    ])
    XCTAssertEqual(recap.sources.calendar, 1)
  }

  func testDaysSplitFocusByProjectThroughTaskOrGoal() {
    var inputs = WeeklyRecapInputs()
    inputs.projects = [project("agy", "Agency"), project("ser", "Serenity 1.0")]
    inputs.tasks = [task("hero", project: "agy")]
    var serenity = GoalConfig(targetCount: 22, projectId: "ser", priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: .outcome, source: .projectTasks)
    serenity.dueDate = date(12, 15)
    inputs.goals = [goal("ship", "Ship Serenity 1.0", config: serenity)]
    inputs.focusBlocks = [
      block("f1", start: date(11, 11, hour: 9), minutes: 90, task: "hero"),
      block("f2", start: date(11, 11, hour: 14), minutes: 90, goal: "ship"),
      block("f3", start: date(11, 11, hour: 17), minutes: 30),
    ]

    let recap = build(inputs)
    let wednesday = recap.days[2]

    XCTAssertEqual(wednesday.focus.map(\.name), ["Agency", "Serenity 1.0", "Other"])
    XCTAssertEqual(wednesday.focusHours, 3.5)
    XCTAssertEqual(recap.focus.hours, 3.5)
    XCTAssertEqual(recap.focus.emptyDays.count, 6)
  }

  func testJournalIsLeftOutUnlessAllowed() {
    var inputs = WeeklyRecapInputs()
    inputs.journalEntries = [entry("j", date(11, 12), "Chasing the invoice again", mood: .sad)]

    let off = build(inputs)
    XCTAssertNil(off.days[3].mood)
    XCTAssertTrue(off.days[3].journal.isEmpty)
    XCTAssertEqual(off.sources.journal, 0)
    XCTAssertFalse(off.usedJournal)

    inputs.useJournal = true
    let on = build(inputs)
    XCTAssertEqual(on.days[3].mood, 1)
    XCTAssertEqual(on.days[3].journal.first?.excerpt, "Chasing the invoice again")
    XCTAssertEqual(on.sources.journal, 1)
  }

  func testRoutineMetricsCountDoneAndMissedScheduledDays() {
    var inputs = WeeklyRecapInputs()
    inputs.routines = [routine("pages", "Morning pages", schedule: .weekdays([2, 3, 4, 5, 6]))]
    inputs.routineChecks = [check("pages", date(11, 9)), check("pages", date(11, 10)), check("pages", date(11, 12)), check("pages", date(11, 13), .skipped)]

    let metric = build(inputs).routines.first

    XCTAssertEqual(metric?.done, 3)
    XCTAssertEqual(metric?.expected, 4)
    XCTAssertEqual(metric?.missed, [date(11, 11, hour: 0)])
  }

  // MARK: Carry-over and goals

  func testCarryOverKeepsOpenItemsDueOrTouchedThisWeekMostMovedFirst() {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [
      task("due", due: date(11, 12, hour: 0)),
      task("moved", due: date(11, 20, hour: 0), moves: [date(11, 6), date(11, 10)]),
      task("later", due: date(11, 30, hour: 0)),
      task("someday", due: date(11, 10, hour: 0), tags: ["someday"]),
      task("done", done: date(11, 12), due: date(11, 12, hour: 0)),
    ]

    let carry = build(inputs).carryOver

    XCTAssertEqual(carry.map(\.taskId), ["moved", "due"])
    XCTAssertEqual(carry.first?.moves, 2)
  }

  func testGoalChangesCompareLastMondayWithThisMonday() {
    var inputs = WeeklyRecapInputs()
    var config = GoalConfig(targetCount: 22, projectId: "ser", priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: .outcome, source: .projectTasks)
    config.startDate = date(10, 1, hour: 0)
    config.dueDate = date(12, 15, hour: 0)
    inputs.goals = [goal("ship", "Ship", config: config)]
    inputs.tasks = (0..<11).map { task("old\($0)", project: "ser", done: date(10, 5 + $0)) } + [task("new", project: "ser", done: date(11, 11))]

    let change = build(inputs).goals.first

    XCTAssertEqual(change?.before.current, 11)
    XCTAssertEqual(change?.after.current, 12)
    XCTAssertEqual(change?.before.pace, .onPace)
    XCTAssertEqual(change?.after.pace, .behind(2))
  }

  // MARK: Detectors

  private func slippingGoalInputs() -> WeeklyRecapInputs {
    var inputs = WeeklyRecapInputs()
    inputs.projects = [project("agy", "Agency"), project("ser", "Serenity 1.0")]
    var config = GoalConfig(targetCount: 22, projectId: "ser", priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: .outcome, source: .projectTasks)
    config.startDate = date(10, 1, hour: 0)
    config.dueDate = date(12, 15, hour: 0)
    inputs.goals = [goal("ship", "Ship Serenity 1.0", config: config)]
    inputs.tasks = (0..<11).map { task("old\($0)", project: "ser", done: date(10, 5 + $0)) } + [
      task("new", project: "ser", done: date(11, 11)),
      task("sync", project: "ser"),
      task("hero", project: "agy"),
      event("standup", at: date(11, 16, hour: 9)),
    ]
    inputs.focusBlocks = [
      block("mon", start: date(11, 9, hour: 9), minutes: 120, task: "hero"),
      block("tue", start: date(11, 10, hour: 9), minutes: 150, task: "hero"),
      block("wed", start: date(11, 11, hour: 9), minutes: 90, task: "sync"),
      block("prev", start: date(11, 4, hour: 9), minutes: 360, task: "sync"),
    ]
    return inputs
  }

  func testGoalAtRiskNamesWhereTheFocusWentAndBooksFreeMornings() throws {
    let recap = build(slippingGoalInputs())
    let finding = try XCTUnwrap(recap.findings.first { $0.kind == .goalAtRisk })

    XCTAssertEqual(finding.id, "goalAtRisk:ship")
    XCTAssertEqual(finding.title, "Other work took the focus Ship Serenity 1.0 needed")
    XCTAssertTrue(finding.body.hasPrefix("4.5 h of your 6 h focus went to Agency. Serenity 1.0 got 1.5 h, down from 6 h the week before,"), finding.body)
    XCTAssertTrue(finding.body.hasSuffix("and fell 2 tasks behind. Tue morning and Thu morning are free this week."), finding.body)
    XCTAssertEqual(Set(finding.evidence.filter { $0.source == .focus }.map(\.ref)), ["mon", "tue", "wed"])
    XCTAssertTrue(finding.evidence.contains { $0.source == .goal && $0.ref == "ship" })

    guard case .bookFocus(let title, let goalId, let slots) = finding.action else { return XCTFail("expected a booking") }
    XCTAssertEqual(title, "Serenity 1.0 focus")
    XCTAssertEqual(goalId, "ship")
    // Monday 9:00 is taken by the stand-up, so the two spread-out free mornings are Tuesday and Thursday.
    XCTAssertEqual(slots.map(\.start), [date(11, 17, hour: 9), date(11, 19, hour: 9)])
    XCTAssertEqual(finding.actionTitle, "Book Tue 17 and Thu 19, 9:00–10:30")
  }

  func testGoalThatHeldItsPaceIsNotAtRisk() {
    var inputs = slippingGoalInputs()
    inputs.tasks += (0..<3).map { task("extra\($0)", project: "ser", done: date(11, 12)) }

    XCTAssertFalse(build(inputs).findings.contains { $0.kind == .goalAtRisk })
  }

  /// Five weeks of a morning routine: four of five late evenings are followed by a miss.
  private func lateEveningInputs() -> WeeklyRecapInputs {
    var inputs = WeeklyRecapInputs()
    inputs.routines = [routine("pages", "Morning pages")]
    let lateEvenings = [date(10, 15, hour: 21), date(10, 19, hour: 19, minute: 30), date(10, 28, hour: 20), date(11, 10, hour: 19, minute: 30), date(11, 12, hour: 20)]
    inputs.tasks = lateEvenings.enumerated().map { event("late\($0.offset)", at: $0.element) }
    let missedMornings: Set<String> = [date(10, 20), date(10, 29), date(11, 11), date(11, 13)].map { RoutineDay.key(for: $0, calendar: calendar) }.reduce(into: []) { $0.insert($1) }
    var day = date(10, 12)
    var otherMisses = 1
    while day < date(11, 16) {
      let key = RoutineDay.key(for: day, calendar: calendar)
      if !missedMornings.contains(key) {
        if otherMisses > 0, key == "2026-10-14" {
          otherMisses -= 1
        } else {
          inputs.routineChecks.append(check("pages", day))
        }
      }
      day = calendar.date(byAdding: .day, value: 1, to: day)!
    }
    return inputs
  }

  func testRoutineMissedAfterLateEveningsIsAPatternWithHonestCounts() throws {
    let recap = build(lateEveningInputs())
    let finding = try XCTUnwrap(recap.findings.first { $0.kind == .routineAfterLateEvening })

    XCTAssertEqual(finding.title, "Morning pages goes undone after late evenings")
    XCTAssertTrue(finding.body.hasPrefix("You missed Wed and Fri, and both came after evening events."), finding.body)
    XCTAssertTrue(finding.body.contains("Since 15 Oct that has happened 4 of the 5 times"), finding.body)
    XCTAssertTrue(finding.body.contains("against 1 miss in 30 other mornings"), finding.body)
    XCTAssertEqual(finding.evidence.count, 5)
    XCTAssertEqual(finding.evidence.first?.what, "late4 at 20:00 → Fri 13 missed")
    XCTAssertEqual(finding.action, .lateEveningReminder(routineId: "pages", hour: 8, minute: 30))
  }

  func testLateEveningPatternIgnoresEveningRoutines() {
    var inputs = lateEveningInputs()
    inputs.routines = [routine("pages", "Morning pages", time: .evening)]

    XCTAssertFalse(build(inputs).findings.contains { $0.kind == .routineAfterLateEvening })
  }

  func testTaskMovedThreeTimesIsStuckAndQuotesTheJournalOnlyWhenAllowed() throws {
    var inputs = WeeklyRecapInputs()
    inputs.projects = [project("agy", "Agency")]
    var invoice = task("Send Northwind invoice reminder", project: "agy", due: date(11, 17, hour: 0), created: date(11, 4), moves: [date(11, 6), date(11, 10), date(11, 13)])
    invoice.id = "inv"
    inputs.tasks = [invoice]
    inputs.journalEntries = [
      entry("j1", date(11, 12), "Chasing Northwind invoice again", mood: .sad),
      entry("j2", date(11, 14), "Still thinking about the Northwind thing", mood: .stressed),
      entry("j3", date(11, 15), "Long run, clear head", mood: .happy),
    ]

    let off = try XCTUnwrap(build(inputs).findings.first { $0.kind == .stuckTask })
    XCTAssertEqual(off.body, "“Send Northwind invoice reminder” has been moved 3 times since 4 Nov.")
    XCTAssertFalse(off.evidence.contains { $0.source == .journal })
    XCTAssertEqual(off.evidence[1].when, "6, 10, 13 Nov")
    XCTAssertEqual(off.action, .firstOnToday(taskId: "inv"))

    inputs.useJournal = true
    let on = try XCTUnwrap(build(inputs).findings.first { $0.kind == .stuckTask })
    XCTAssertEqual(on.title, "“Send Northwind invoice reminder” is weighing on you")
    XCTAssertTrue(on.body.hasSuffix("Your 2 lowest-mood entries this week mention it."), on.body)
    XCTAssertEqual(on.evidence.filter { $0.source == .journal }.map(\.ref), ["j1", "j2"])
    XCTAssertGreaterThan(on.score, off.score)
  }

  func testMovesBeforeThisWeekAreNotStuckThisWeek() {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [task("old", due: date(11, 20, hour: 0), moves: [date(10, 6), date(10, 10), date(10, 13)])]

    XCTAssertFalse(build(inputs).findings.contains { $0.kind == .stuckTask })
  }

  func testDeepWorkWellBelowTheUsualWeekIsFlagged() throws {
    var inputs = WeeklyRecapInputs()
    var config = GoalConfig(targetCount: 15, projectId: nil, priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: .target, source: .focusTime)
    config.unit = "h"
    inputs.goals = [goal("deep", "Deep work 15 h a week", config: config)]
    for back in 1...4 {
      let monday = calendar.date(byAdding: .day, value: -7 * back, to: date(11, 9, hour: 9))!
      inputs.focusBlocks.append(block("b\(back)", start: monday, minutes: 600))
    }
    inputs.focusBlocks.append(block("this", start: date(11, 10, hour: 9), minutes: 240))
    inputs.tasks = [event("standup", at: date(11, 16, hour: 9))]

    let finding = try XCTUnwrap(build(inputs).findings.first { $0.kind == .deepWorkBelowBaseline })

    XCTAssertEqual(finding.body, "4 h of focus against your usual 10 h. That's 11 h short of your 15 h goal. Mon, Wed, Thu, Fri, Sat and Sun had none.")
    XCTAssertEqual(finding.evidence.prefix(4).map(\.meta), ["10.0 h", "10.0 h", "10.0 h", "10.0 h"])
    XCTAssertEqual(finding.linked, "Deep work 15 h a week")
    guard case .bookFocus(_, let goalId, let slots) = finding.action else { return XCTFail("expected a booking") }
    XCTAssertEqual(goalId, "deep")
    XCTAssertEqual(slots.count, 2)
  }

  func testQuietAreaOffersToPlanItsOnlyOpenItem() throws {
    var inputs = WeeklyRecapInputs()
    var config = GoalConfig(targetCount: nil, projectId: nil, priority: nil, streakDays: nil, targetRate: nil, timeframe: .weekly, kind: .area, source: .manual)
    config.areaTag = "health"
    inputs.goals = [goal("health", "Health", config: config)]
    inputs.tasks = [task("physio", done: date(11, 6), tags: ["health"]), task("Book the dentist", tags: ["health"])]

    let finding = try XCTUnwrap(build(inputs).findings.first { $0.kind == .quietArea })

    XCTAssertEqual(finding.title, "Health has been quiet for 10 days")
    XCTAssertEqual(finding.body, "Nothing has touched Health since 6 Nov. “Book the dentist” is the only open item.")
    XCTAssertEqual(finding.action, .scheduleTask(taskId: "Book the dentist", day: date(11, 17, hour: 0)))
    XCTAssertEqual(finding.actionTitle, "Plan “Book the dentist” for Tue")
  }

  func testMoodFindingNeedsTheJournalSwitch() {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [task("seed", created: date(10, 1))]
    let lowDays = [date(10, 14), date(10, 21), date(10, 28), date(11, 11)]
    let otherDays = [date(10, 13), date(10, 20), date(10, 27), date(11, 10), date(11, 12)]
    for (index, day) in lowDays.enumerated() {
      inputs.journalEntries.append(entry("low\(index)", day, "Long day", mood: .stressed))
      for hour in [10, 13, 15] {
        inputs.tasks.append(event("e\(index)-\(hour)", at: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!))
      }
    }
    for (index, day) in otherDays.enumerated() {
      inputs.journalEntries.append(entry("ok\(index)", day, "Fine", mood: .happy))
    }

    XCTAssertFalse(build(inputs).findings.contains { $0.kind == .moodAfterBusyDays })

    inputs.useJournal = true
    let finding = build(inputs).findings.first { $0.kind == .moodAfterBusyDays }
    XCTAssertEqual(finding?.body, "On your 4 low-mood days since 14 Oct you had 3 calendar events on average, against 0 on other days.")
  }

  // MARK: Ranking

  private func finding(_ kind: WeeklyFinding.Kind, _ subject: String, score: Double) -> WeeklyFinding {
    WeeklyFinding(id: "\(kind.rawValue):\(subject)", kind: kind, subjectId: subject, linked: "", title: "", body: "", evidenceLabel: "", evidence: [], action: nil, actionTitle: nil, score: score)
  }

  func testRankKeepsTheTopThree() {
    let findings = [
      finding(.quietArea, "a", score: 1.5),
      finding(.goalAtRisk, "b", score: 3.2),
      finding(.stuckTask, "c", score: 2.4),
      finding(.deepWorkBelowBaseline, "d", score: 2.6),
    ]

    XCTAssertEqual(WeeklyRecap.rank(findings, feedback: [], hasHistory: true, weekStart: weekStart, calendar: calendar).map(\.subjectId), ["b", "d", "c"])
  }

  func testNotUsefulPushesThatKindDownAndTheSameFindingFurther() {
    let lastWeek = date(11, 2, hour: 0)
    let findings = [finding(.goalAtRisk, "ship", score: 3), finding(.stuckTask, "inv", score: 2.5), finding(.quietArea, "health", score: 1.6)]
    let feedback = [WeeklyFindingFeedback(findingId: "goalAtRisk:ship", kind: .goalAtRisk, reason: .knewThis, weekStart: lastWeek)]

    let ranked = WeeklyRecap.rank(findings, feedback: feedback, hasHistory: true, weekStart: weekStart, calendar: calendar)

    XCTAssertEqual(ranked.map(\.subjectId), ["inv", "health", "ship"])
    XCTAssertEqual(ranked.last?.score ?? 0, 3 * 0.36, accuracy: 0.001)
    XCTAssertEqual(WeeklyRecap.feedbackFactor(for: finding(.goalAtRisk, "other", score: 1), feedback: feedback), 0.6, accuracy: 0.001)
  }

  func testOldFeedbackAndFeedbackFromThisWeekDoNotCount() {
    let findings = [finding(.goalAtRisk, "ship", score: 3), finding(.stuckTask, "inv", score: 2.5)]
    let stale = WeeklyFindingFeedback(findingId: "goalAtRisk:ship", kind: .goalAtRisk, reason: .numbersWrong, weekStart: date(8, 31, hour: 0))
    let current = WeeklyFindingFeedback(findingId: "goalAtRisk:ship", kind: .goalAtRisk, reason: .numbersWrong, weekStart: weekStart)

    XCTAssertEqual(WeeklyRecap.rank(findings, feedback: [stale, current], hasHistory: true, weekStart: weekStart, calendar: calendar).first?.subjectId, "ship")
  }

  func testAQuietWeekHasNoFindings() {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [task("a", done: date(11, 10))]

    XCTAssertTrue(build(inputs).findings.isEmpty)
  }

  func testMovedAndStalledLinesForTheGuidedReview() {
    var inputs = slippingGoalInputs()
    inputs.tasks += [task("Hero copy", project: "agy", done: date(11, 9)), task("Revisions", project: "agy", done: date(11, 10)), task("QA pass", project: "agy", done: date(11, 12))]
    inputs.routines = [routine("run", "Stretch", time: .evening, schedule: .weekdays([2, 4]))]
    inputs.routineChecks = [check("run", date(11, 9)), check("run", date(11, 11))]

    let recap = build(inputs)

    XCTAssertEqual(recap.moved.first?.text, "Agency: Hero copy; Revisions and 1 more")
    XCTAssertEqual(recap.moved.first?.source, "3 tasks")
    XCTAssertTrue(recap.moved.contains { $0.text == "Stretch 2 of 2 days" })
    XCTAssertEqual(recap.stalled.first?.id, "goalAtRisk:ship")
    XCTAssertFalse(recap.stalled.contains { $0.id == "goal:ship" })
  }

  func testNoFreeMorningMeansNoBookingAction() throws {
    var inputs = slippingGoalInputs()
    for day in 16...20 {
      inputs.tasks.append(event("busy\(day)", at: date(11, day, hour: 9)))
    }

    let finding = try XCTUnwrap(build(inputs).findings.first { $0.kind == .goalAtRisk })
    XCTAssertNil(finding.action)
    XCTAssertNil(finding.actionTitle)
  }

  // MARK: Pieces

  func testDueMovesCountOnlyDueDateEvents() {
    var item = task("t")
    item.activity = [
      TaskActivityEntry(id: "1", kind: .event, text: "Due date set to 6 Nov 2026", createdAt: date(11, 6)),
      TaskActivityEntry(id: "2", kind: .event, text: "Priority set to High", createdAt: date(11, 7)),
      TaskActivityEntry(id: "3", kind: .comment, text: "Due date set to tomorrow, honestly", createdAt: date(11, 8)),
      TaskActivityEntry(id: "4", kind: .event, text: "Due date cleared", createdAt: date(11, 9)),
    ]

    XCTAssertEqual(WeeklyRecap.dueMoves(item), [date(11, 6), date(11, 9)])
  }

  func testKeywordIsTheLongestDistinctiveWord() {
    XCTAssertEqual(WeeklyRecap.keyword(in: "Send Northwind invoice reminder"), "northwind")
    XCTAssertNil(WeeklyRecap.keyword(in: "Call mum"))
  }

  func testFormatting() {
    let format = RecapFormat(calendar: calendar, locale: locale)

    XCTAssertEqual(format.range(date(11, 9), date(11, 16)), "9–15 Nov")
    XCTAssertEqual(format.range(date(10, 26), date(11, 2)), "26 Oct – 1 Nov")
    XCTAssertEqual(format.dayList([date(11, 13), date(11, 11)]), "Wed and Fri")
    XCTAssertEqual(format.dayNumberList([date(11, 6), date(11, 10), date(11, 13)]), "6, 10, 13 Nov")
    XCTAssertEqual(format.hours(11.5), "11.5 h")
    XCTAssertEqual(format.hours(2), "2 h")
    XCTAssertEqual(format.hoursOneDecimal(2), "2.0 h")
    XCTAssertEqual(format.count(1, "miss", plural: "misses"), "1 miss")
  }

  func testRecapCodablePiecesRoundTrip() throws {
    let action = WeeklyAction.bookFocus(title: "Focus", goalId: nil, slots: [DateInterval(start: date(11, 17, hour: 9), duration: 5_400)])
    let data = try JSONEncoder().encode(action)

    XCTAssertEqual(try JSONDecoder().decode(WeeklyAction.self, from: data), action)
  }
}
