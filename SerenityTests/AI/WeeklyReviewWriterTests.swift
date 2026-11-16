import Foundation
import XCTest
@testable import SerenityMac

final class WeeklyReviewWriterTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private var weekStart: Date { date(11, 9, hour: 0) }
  private var now: Date { date(11, 16, hour: 8) }

  private func task(_ id: String, done: Date? = nil, due: Date? = nil, moves: [Date] = []) -> TaskEntity {
    TaskEntity(
      id: id, title: "Send \(id) reminder", description: nil, completed: done != nil, completedAt: done, priority: .medium,
      dueDate: due, projectId: nil, tags: [], createdAt: date(11, 4), updatedAt: date(11, 4), subtasks: [], recurring: nil, userId: nil,
      activity: moves.map { TaskActivityEntry(id: UUID().uuidString, kind: .event, text: "Due date set to x", createdAt: $0) }
    )
  }

  private func inputs(journal: Bool) -> WeeklyRecapInputs {
    var inputs = WeeklyRecapInputs()
    inputs.tasks = [
      task("invoice", due: date(11, 17, hour: 0), moves: [date(11, 6), date(11, 10), date(11, 13)]),
      task("hero", done: date(11, 11)),
    ]
    inputs.focusBlocks = [FocusBlockEntity(
      id: "f1", title: "Hero", start: date(11, 10, hour: 9), end: date(11, 10, hour: 11), goalId: nil, taskIds: ["hero"],
      status: .done, startedAt: date(11, 10, hour: 9), finishedAt: date(11, 10, hour: 11), loggedMinutes: 90, createdAt: date(11, 10), updatedAt: date(11, 10)
    )]
    inputs.journalEntries = [JournalEntryEntity(
      id: "j1", title: nil, content: "Chasing the invoice again", date: date(11, 12), tags: ["work"], createdAt: date(11, 12), updatedAt: date(11, 12),
      pinned: false, mood: .sad, attachments: [], userId: nil
    )]
    inputs.useJournal = journal
    return inputs
  }

  private func prepared(journal: Bool = false) throws -> (recap: WeeklyRecap, input: WeeklyReviewWriter.Input, prompt: String) {
    let inputs = inputs(journal: journal)
    let recap = WeeklyRecap.build(inputs: inputs, weekStart: weekStart, now: now, calendar: calendar, goalCalendar: calendar, locale: Locale(identifier: "en_GB"))
    let input = WeeklyReviewWriter.input(recap: recap, inputs: inputs, now: now, calendar: calendar)
    return (recap, input, try WeeklyReviewWriter.userPrompt(input))
  }

  private func merge(_ reply: String, journal: Bool = false) throws -> (WeeklyRecap, WeeklyReviewWriter.Result) {
    let (recap, input, prompt) = try prepared(journal: journal)
    let result = try WeeklyReviewWriter.merge(
      responseText: reply, input: input, userPrompt: prompt, deterministic: recap.findings, feedback: [],
      hasHistory: recap.hasPatterns, weekStart: weekStart, nextWeekday: date(11, 17, hour: 0), calendar: calendar
    )
    return (recap, result)
  }

  private func reply(_ findings: String) -> String {
    #"{"findings":[\#(findings)]}"#
  }

  func testInputCarriesRecordIdsAndLeavesTheJournalOutWhenOff() throws {
    let (_, off, offPrompt) = try prepared(journal: false)
    XCTAssertNil(off.journal)
    XCTAssertFalse(offPrompt.contains("Chasing"))
    XCTAssertEqual(off.recordIDs, ["invoice", "hero", "f1"])
    XCTAssertEqual(off.findings.map(\.id), ["stuckTask:invoice"])
    XCTAssertEqual(off.sessions.first?.hours, 1.5)

    let (_, on, onPrompt) = try prepared(journal: true)
    XCTAssertEqual(on.journal?.first?.mood, 1)
    XCTAssertTrue(onPrompt.contains("Chasing the invoice again"))
    XCTAssertTrue(on.recordIDs.contains("j1"))
  }

  func testARewriteKeepsTheActionAndEvidence() throws {
    let (recap, result) = try merge(reply(#"{"basedOn":"stuckTask:invoice","title":"The invoice reminder keeps slipping","body":"Moved 3 times since 4 Nov.","evidence":["invoice"],"action":{"type":"none","id":""}}"#))

    XCTAssertEqual(result.rewritten, 1)
    XCTAssertEqual(result.findings.first?.title, "The invoice reminder keeps slipping")
    XCTAssertEqual(result.findings.first?.action, recap.findings.first?.action)
    XCTAssertEqual(result.findings.first?.evidence, recap.findings.first?.evidence)
  }

  func testARewriteWithAnInventedNumberKeepsSerenitysText() throws {
    let (recap, result) = try merge(reply(#"{"basedOn":"stuckTask:invoice","title":"Moved 7 times","body":"It has slipped 7 times.","evidence":["invoice"],"action":{"type":"none","id":""}}"#))

    XCTAssertEqual(result.rewritten, 0)
    XCTAssertEqual(result.findings, recap.findings)
    XCTAssertTrue(result.rejected.first?.contains("numbers not in the input: 7") ?? false)
  }

  func testCitingARecordThatWasNotSentIsRejected() throws {
    let (_, result) = try merge(reply(#"{"basedOn":"","title":"Journal shows stress","body":"You wrote about it.","evidence":["j1"],"action":{"type":"none","id":""}}"#), journal: false)

    XCTAssertEqual(result.added, 0)
    XCTAssertTrue(result.rejected.first?.contains("unknown ids j1") ?? false)
  }

  func testANewFindingWithValidEvidenceIsAddedAsNoticed() throws {
    let (_, result) = try merge(reply(#"{"basedOn":"","title":"Your only focus went to the hero","body":"1.5 h on Tuesday, then it was done Wednesday.","evidence":["f1","hero"],"action":{"type":"firstOnToday","id":"invoice"}}"#))

    XCTAssertEqual(result.added, 1)
    let added = try XCTUnwrap(result.findings.first { $0.kind == .observation })
    XCTAssertEqual(added.tag, "Noticed")
    XCTAssertEqual(added.evidence.map(\.ref), ["f1", "hero"])
    XCTAssertEqual(added.evidence.first?.source, .focus)
    XCTAssertEqual(added.action, .firstOnToday(taskId: "invoice"))
  }

  func testANewFindingCannotActOnADoneTaskOrAnUnknownId() throws {
    let (_, result) = try merge(reply(#"{"basedOn":"","title":"Hero is done","body":"Finished Wednesday.","evidence":["hero"],"action":{"type":"firstOnToday","id":"hero"}}"#))

    XCTAssertEqual(result.added, 0)
    XCTAssertTrue(result.rejected.first?.contains("not allowed") ?? false)
  }

  func testFindingsWithNoEvidenceAreDropped() throws {
    let (_, result) = try merge(reply(#"{"basedOn":"","title":"Good week","body":"Nice.","evidence":[],"action":{"type":"none","id":""}}"#))

    XCTAssertEqual(result.added, 0)
    XCTAssertEqual(result.rejected.first, "new finding “Good week”: no evidence")
  }

  func testAnUnreadableReplyThrowsSoTheCallerKeepsSerenitysFindings() throws {
    XCTAssertThrowsError(try merge("I think your week went well!"))
  }

  @MainActor
  func testTheJournalSwitchGatesWhatTheReviewSees() {
    let defaults = UserDefaults.standard
    let stored = defaults.object(forKey: AppState.reviewUsesJournalKey)
    defer { defaults.set(stored, forKey: AppState.reviewUsesJournalKey) }
    defaults.removeObject(forKey: AppState.reviewUsesJournalKey)

    let state = AppState(serenityCloudAdapter: nil, externalPostgresAdapter: nil)
    state.journalEntries = inputs(journal: true).journalEntries

    XCTAssertFalse(state.reviewUsesJournal)
    XCTAssertTrue(state.weeklyRecapInputs().journalEntries.isEmpty)
    XCTAssertFalse(state.weeklyRecapInputs().useJournal)

    state.reviewUsesJournal = true
    XCTAssertEqual(state.weeklyRecapInputs().journalEntries.map(\.id), ["j1"])
    XCTAssertTrue(defaults.bool(forKey: AppState.reviewUsesJournalKey))
  }

  func testNumbersParseDecimalsAndCommas() {
    XCTAssertEqual(WeeklyReviewWriter.numbers(in: "4.5 h of 11,5 on day 9"), [4.5, 11.5, 9])
  }

  func testSchemaRequiresEvidenceAndAnAction() throws {
    let schema = WeeklyReviewWriter.schema()
    let items = try XCTUnwrap(((schema["properties"] as? [String: Any])?["findings"] as? [String: Any])?["items"] as? [String: Any])
    XCTAssertEqual(items["required"] as? [String], ["basedOn", "title", "body", "evidence", "action"])
  }
}
