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

  func testTheDetailReachesTheModelUnderItsOwnLabels() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [detailedCard]),
      instruction: "anything",
      length: .detailed,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("Description: Pool exhausts under the nightly backfill"), prompt)
    XCTAssertTrue(prompt.contains("Subtasks (1 of 2 done):"), prompt)
    XCTAssertTrue(prompt.contains("- [done] Reproduce against staging"), prompt)
    XCTAssertTrue(prompt.contains("- [not done] Patch the release path"), prompt)
    XCTAssertTrue(prompt.contains("Comments they wrote (oldest first):"), prompt)
    XCTAssertTrue(prompt.contains("\u{201C}Repro is deterministic with two writers\u{201D}"), prompt)
    // Dated, so a week-old note cannot be read out as this morning's news.
    // Built rather than spelled out: the clock format is the machine's.
    let stamp = StandupDateText.dayAndTime(
      date(year: 2026, month: 9, day: 18, hour: 14, minute: 10),
      now: monday,
      calendar: calendar
    )
    XCTAssertTrue(prompt.contains("  - \(stamp): \u{201C}Repro"), prompt)
  }

  func testTheDetailSitsUnderTheItemItBelongsTo() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [detailedCard]),
      instruction: "anything",
      length: .detailed,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(
      prompt.contains("- Postgres adapter connection timeouts \u{2014} Due today\n  Description:"),
      prompt
    )
  }

  func testAnItemWithNoDetailAddsNothingToThePrompt() {
    let prompt = StandupWriter.userPrompt(
      board: board(cards: [todayCard]),
      instruction: "anything",
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertFalse(prompt.contains("Description:"), prompt)
    XCTAssertFalse(prompt.contains("Subtasks ("), prompt)
    XCTAssertFalse(prompt.contains("Comments they wrote"), prompt)
  }

  /// A long backlog cannot be allowed to crowd out the other items, but what is
  /// dropped is counted rather than silently cut.
  func testALongListIsCappedAndSaysHowMuchItLeftOut() {
    let many = StandupCard(
      id: "t5:today",
      taskID: "t5",
      column: .today,
      title: "Migrate the ingest workers",
      fact: "Due today",
      source: .scheduled,
      detail: StandupCardDetail(
        subtasks: (1...15).map { StandupCardDetail.Subtask(title: "Step \($0)", completed: false) },
        comments: (1...8).map {
          StandupCardDetail.Comment(
            text: "Note \($0)",
            writtenAt: date(year: 2026, month: 9, day: 18, hour: 9, minute: $0)
          )
        }
      )
    )

    let prompt = StandupWriter.userPrompt(
      board: board(cards: [many]),
      instruction: "anything",
      length: .detailed,
      now: monday,
      calendar: calendar
    )

    XCTAssertTrue(prompt.contains("Subtasks (0 of 15 done):"), prompt)
    XCTAssertTrue(prompt.contains("(3 more, not listed)"), prompt)
    XCTAssertFalse(prompt.contains("[not done] Step 13"), prompt)
    // The newest comments are the ones kept.
    XCTAssertTrue(prompt.contains("Comments they wrote (oldest first, 3 older not listed):"), prompt)
    XCTAssertTrue(prompt.contains("\u{201C}Note 8\u{201D}"), prompt)
    XCTAssertFalse(prompt.contains("\u{201C}Note 3\u{201D}"), prompt)
  }

  func testTheRulesSayWhatTheLabelledDetailIsFor() {
    let rules = StandupWriter.systemPrompt()

    XCTAssertTrue(rules.contains("[not done] is outstanding"))
    XCTAssertTrue(rules.contains("Spend the length target on that detail"))
  }

  // MARK: - Can it be said out loud

  /// The stand-up is read to a room. Every one of these was in a real script.
  func testTheThingsNobodyCanSayOutLoudAreCaught() {
    let cases: [(String, String)] = [
      ("a link", "P1 is the Known Lead tagging, reported in https://docket-ai.slack.com/archives/C08GQ7YVBK8."),
      ("a file path", "What is left is the account-domain fallback in inbound-se/services/booking/crm_owner_matching.py."),
      ("an identifier", "The alert came through on C08GQ7YVBK8 this morning."),
      ("markdown", "**P0** is the adapter today."),
      ("a bullet list", "P0:\n- Wrap up the adapter.\n- Merge the PRs."),
      ("a numbered list", "P0:\n1. Wrap up the adapter."),
      ("a heading", "## P0\nWrap up the adapter."),
      ("a backtick", "The fix goes in `crm_owner_matching`."),
    ]

    for (name, spoken) in cases {
      XCTAssertFalse(
        StandupWriter.speechProblems(in: spoken).isEmpty,
        "\(name) should have been caught: \(spoken)"
      )
    }
  }

  /// The check has to leave a good stand-up alone, including the numbers and
  /// domains people really do say in one.
  func testASpeakableStandupIsLeftAlone() {
    let spoken = """
      P zero, and the one that has to land today: I’m wrapping up dynamic context injection to UDP.       The review comments took longer than I expected, and those two PRs should merge before this call.

      P one is the Known Lead tagging firing for anonymous visitors — it goes off when there’s no       CRM record at all, rather than on a real match. Three things left on it: the account-domain       fallback in the owner matching code, the Thryv case, and making sure call duration isn’t the only       trigger. That’s PR 812, and I posted the thread in Slack.

      P two, and this one can wait: asking for docket.io hands back docketai.com. I want to agree what       should happen there. Nothing landed since Friday, and I’m not blocked on anyone.
      """

    XCTAssertEqual(StandupWriter.speechProblems(in: spoken), [], "flagged a speakable stand-up")
  }

  func testTheRulesSayWhoIsListeningAndWhereTheLinksGo() {
    let rules = StandupWriter.systemPrompt()

    XCTAssertTrue(rules.contains("said out loud to a room of engineers and product managers"))
    XCTAssertTrue(rules.contains("No URL, no file path"))
    // The identifiers still have to survive somewhere.
    XCTAssertTrue(rules.contains("Keep every number, identifier, PR reference, path and date in \"sections\""))
    XCTAssertTrue(rules.contains("each URL, each path, each identifier"))
  }

  // MARK: - Revising

  func testRevisingCarriesTheFactsTheScriptAndTheAsk() {
    let prompt = StandupWriter.revisePrompt(
      board: board(cards: [detailedCard]),
      instruction: "P0 / P1 / P2 then Blockers.",
      length: .detailed,
      script: sectionedScript,
      ask: "Trim P1 and drop the Slack link",
      now: monday,
      calendar: calendar
    )

    // The board, so a revision cannot drift off what was confirmed.
    XCTAssertTrue(prompt.contains("Postgres adapter connection timeouts \u{2014} Due today"), prompt)
    XCTAssertTrue(prompt.contains("Subtasks (1 of 2 done):"), prompt)
    // What it said last pass, so "trim P1" has something to refer to.
    XCTAssertTrue(prompt.contains("<<<CURRENT"), prompt)
    XCTAssertTrue(prompt.contains("**P1 \u{00B7} Known Lead tagging**"), prompt)
    // And the ask, fenced so it cannot be read as part of the script.
    XCTAssertTrue(prompt.contains("<<<CHANGE\nTrim P1 and drop the Slack link\nCHANGE"), prompt)
  }

  func testRevisingIsToldToChangeOnlyWhatWasAskedAndInventNothing() {
    let rules = StandupWriter.reviseSystemPrompt()

    XCTAssertTrue(rules.contains("leave everything else alone"))
    XCTAssertTrue(rules.contains("cannot introduce a fact"))
    // The standing rules still apply to a revision.
    XCTAssertTrue(rules.contains("Use only the facts given."))
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

  func testSectionsDecodeAndThePasteTextIsBuiltFromThem() throws {
    let script = try StandupWriter.decode(#"""
      {"spoken": "P0 today is the adapter.",
       "sections": [
         {"label": "P0", "title": "Postgres adapter", "body": "Patching the release path today."},
         {"label": "Blockers", "title": "None", "body": ""}
       ],
       "folded": []}
      """#)

    XCTAssertEqual(script.sections.count, 2)
    XCTAssertEqual(script.sections.first?.label, "P0")
    // One source of truth: the pasteable text is built here, not asked for
    // a second time and returned differently.
    XCTAssertEqual(
      script.paste,
      "**P0 \u{00B7} Postgres adapter**\nPatching the release path today.\n\n**Blockers \u{00B7} None**"
    )
  }

  func testAModelThatIgnoresSectionsStillProducesAScript() throws {
    let script = try StandupWriter.decode(#"{"spoken": "Shipped it.", "paste": "**Since Friday**\n- Shipped it"}"#)

    XCTAssertTrue(script.sections.isEmpty)
    XCTAssertEqual(script.paste, "**Since Friday**\n- Shipped it")
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

  /// The no-key path draws in the same shape as the model path, or the screen
  /// would look like two different features.
  func testTheFallbackAlsoComesBackInSections() {
    let script = StandupWriter.fallback(
      board: board(cards: [finishedCard, todayCard]),
      length: .standard,
      now: monday,
      calendar: calendar
    )

    XCTAssertEqual(script.sections.map(\.label), ["Since Friday", "Today"])
    XCTAssertTrue(script.sections.first?.body.hasPrefix("- Ship Slack PKCE token refresh") == true)
    XCTAssertEqual(script.paste, StandupScript.paste(from: script.sections))
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

  private var detailedCard: StandupCard {
    StandupCard(
      id: "t5:today",
      taskID: "t5",
      column: .today,
      title: "Postgres adapter connection timeouts",
      fact: "Due today",
      source: .scheduled,
      detail: StandupCardDetail(
        description: "Pool exhausts under the nightly backfill; suspect the adapter never returns a connection.",
        subtasks: [
          StandupCardDetail.Subtask(title: "Reproduce against staging", completed: true),
          StandupCardDetail.Subtask(title: "Patch the release path", completed: false),
        ],
        comments: [
          StandupCardDetail.Comment(
            text: "Repro is deterministic with two writers",
            writtenAt: date(year: 2026, month: 9, day: 18, hour: 14, minute: 10)
          ),
        ]
      )
    )
  }

  private var sectionedScript: StandupScript {
    StandupScript(
      spoken: "P0 is the adapter today.",
      paste: "",
      sections: [
        StandupSection(label: "P0", title: "Postgres adapter", body: "Patching the release path."),
        StandupSection(label: "P1", title: "Known Lead tagging", body: "The tag fires on absence, not a match."),
      ],
      folded: []
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
