import XCTest
@testable import SerenityMac

/// What reaches the model, and what the app will accept back. The prompt
/// contract matters more than usual here: the whole design rests on a guess
/// never being spoken as a fact.
final class StandupWriterTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)

  private var monday: Date {
    date(year: 2026, month: 9, day: 21, hour: 9, minute: 30)
  }

  private var friday: Date {
    date(year: 2026, month: 9, day: 18, hour: 9, minute: 42)
  }

  // MARK: - The prompt

  func testTheFormatInstructionArrivesVerbatimAndFenced() {
    let instruction = "Name the PR number.\nNever say \"worked on\"."

    let prompt = StandupWriter.userPrompt(
      board: board(cards: [finishedCard]),
      instruction: instruction,
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("<<<FORMAT\n\(instruction)\nFORMAT"), prompt)
  }

  func testAGuessedItemIsMarkedSoTheScriptCannotStateIt() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [guessedCard]),
      instruction: "anything",
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("[guessed]"), prompt)
    XCTAssertTrue(StandupWriter.systemPrompt().contains("Never assert it as fact."))
  }

  func testACarriedItemBringsWhatWasSaidLastTime() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [carriedCard]),
      instruction: "anything",
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("[said last time: Due Tuesday, 4 subtasks left]"), prompt)
  }

  func testAnEmptyColumnSaysSoRatherThanVanishing() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [finishedCard]),
      instruction: "anything",
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("Blocked on:\n- (nothing)"), prompt)
  }

  func testTheLengthTargetIsStatedAndTheInstructionIsSaidToOutrankIt() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [finishedCard]),
      instruction: "anything",
      length: .short,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("about \(StandupLength.short.wordTarget) words"), prompt)
    XCTAssertTrue(StandupWriter.systemPrompt().contains("the format instruction wins"))
  }

  // MARK: - Decoding

  func testACleanResponseDecodes() throws {
    let script = try StandupWriter.decode(#"""
      {"spoken": "Since Friday I shipped it.", "paste": "**Since Friday**\n- Shipped it", "folded": ["PR 812"]}
      """#)

    XCTAssertEqual(script.spoken, "Since Friday I shipped it.")
    XCTAssertEqual(script.folded, ["PR 812"])
  }

  func testAResponseWrappedInProseStillDecodes() throws {
    let script = try StandupWriter.decode("""
      Sure, here you go:
      ```json
      {"spoken": "Shipped it.", "paste": "Shipped it", "folded": []}
      ```
      """)

    XCTAssertEqual(script.spoken, "Shipped it.")
  }

  func testAMissingPasteFallsBackToTheSpokenText() throws {
    let script = try StandupWriter.decode(#"{"spoken": "Shipped it.", "folded": null}"#)

    XCTAssertEqual(script.paste, "Shipped it.")
    XCTAssertTrue(script.folded.isEmpty)
  }

  func testAnEmptySpokenScriptIsRejectedRatherThanShown() {
    XCTAssertThrowsError(try StandupWriter.decode(#"{"spoken": "   ", "paste": "x", "folded": []}"#))
  }

  // MARK: - Without a key

  func testTheFallbackNamesEveryConfirmedItemAndKeepsItsDetail() {
    let script = StandupWriter.fallback(
      board: board(cards: [finishedCard, todayCard, guessedCard]),
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(script.spoken.contains("Ship Slack PKCE token refresh"), script.spoken)
    XCTAssertTrue(script.spoken.contains("Today I'm on Refresh model rates"), script.spoken)
    XCTAssertTrue(script.spoken.contains("I'm blocked on Postgres adapter"), script.spoken)
    // Nothing here can fold a fact into a clause, so every fact is surfaced
    // rather than quietly lost.
    XCTAssertEqual(script.folded.count, 3)
    XCTAssertTrue(script.paste.contains("- Refresh model rates in Cost Center — Due today"), script.paste)
  }

  func testAnEmptyBoardFallsBackToSayingThereIsNothing() {
    let script = StandupWriter.fallback(board: board(cards: []), length: .standard, now: monday, calendar: calendar)

    XCTAssertEqual(script.spoken, "Nothing to report since the last stand-up.")
  }

  func testTheSpokenLengthIsReportedInSecondsForTheScreen() {
    let script = StandupScript(
      spoken: Array(repeating: "word", count: 130).joined(separator: " "),
      paste: "",
      folded: []
    )

    XCTAssertEqual(script.wordCount, 130)
    XCTAssertEqual(script.spokenSeconds, 60)
  }

  // MARK: - Fixtures

  private var finishedCard: StandupCard {
    StandupCard(
      id: "t1:since",
      taskID: "t1",
      column: .since,
      title: "Ship Slack PKCE token refresh",
      fact: "Finished Friday 4:12 PM",
      source: .completed
    )
  }

  private var todayCard: StandupCard {
    StandupCard(
      id: "t2:today",
      taskID: "t2",
      column: .today,
      title: "Refresh model rates in Cost Center",
      fact: "Due today",
      source: .scheduled
    )
  }

  private var guessedCard: StandupCard {
    StandupCard(
      id: "t3:blocked",
      taskID: "t3",
      column: .blocked,
      title: "Postgres adapter connection timeouts",
      fact: "Nothing has moved in 4 days, and it is overdue",
      source: .guessed
    )
  }

  private var carriedCard: StandupCard {
    StandupCard(
      id: "t4:today",
      taskID: "t4",
      column: .today,
      title: "Capture commands for GitHub pull requests",
      fact: "Due Tuesday",
      source: .carried,
      saidLast: "Due Tuesday, 4 subtasks left"
    )
  }

  private func board(cards: [StandupCard]) -> StandupBoard {
    StandupBoard(
      window: StandupWindow(start: friday, end: monday, anchor: .lastStandup),
      cards: cards
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
}
