import XCTest
@testable import SerenityMac

final class CaptureCommandDrafterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_000_000)

  // MARK: - Origin tags

  /// These have to match the tags the two background syncs already write, or a
  /// pasted link has nothing to recognise itself by and duplicates the task.
  func testTheSlackOriginTagMatchesTheOneTheSyncWrites() {
    let source = slackSource(channelID: "C_ENG", rootTS: "1726740000.111222")

    XCTAssertEqual(
      CaptureCommandDrafter.originTag(for: source),
      SlackProposalPlanner.threadTag(channelID: "C_ENG", threadTS: "1726740000.111222")
    )
  }

  func testTheSlackOriginTagIsLowercasedLikeEveryStoredTag() {
    let source = slackSource(channelID: "C_ENG", rootTS: "1726740000.111222")

    XCTAssertEqual(CaptureCommandDrafter.originTag(for: source), "slack-thread-c_eng-1726740000.111222")
  }

  func testTheGitHubOriginTagUsesTheIssueID() {
    XCTAssertEqual(CaptureCommandDrafter.originTag(for: githubSource(issueID: 990001)), "github-pr-990001")
  }

  func testALinkedReplyTagsItsThreadNotItself() {
    let excerpt = excerpt(
      messages: [
        message(ts: "1726740000.111222", text: "parent"),
        message(ts: "1726742400.123456", threadTS: "1726740000.111222", text: "the ask"),
      ],
      anchorTS: "1726742400.123456"
    )

    XCTAssertEqual(
      CaptureCommandDrafter.originTag(for: .slack(excerpt)),
      "slack-thread-c_eng-1726740000.111222"
    )
  }

  // MARK: - Finding the task a source already belongs to

  func testAnOriginTaggedTaskWinsOutrightOverWordOverlap() {
    let source = githubSource(issueID: 990001, title: "Add retry backoff")
    let tagged = task(title: "Something else entirely", tags: ["github", "github-pr-990001"])
    let lexical = task(title: "Add retry backoff to the client")

    let candidates = CaptureCommandDrafter.candidates(for: source, tasks: [lexical, tagged])

    XCTAssertEqual(candidates.map(\.id), [tagged.id])
  }

  func testWordOverlapIsTheFallbackForAHandMadeTask() {
    let source = githubSource(title: "Add retry backoff to the API client")
    let related = task(title: "Retry backoff for the client")
    let unrelated = task(title: "Book the offsite venue")

    let candidates = CaptureCommandDrafter.candidates(for: source, tasks: [unrelated, related])

    XCTAssertEqual(candidates.map(\.id), [related.id])
  }

  func testCompletedTasksAreNeverCandidates() {
    let source = githubSource(issueID: 990001)
    let done = task(title: "Add retry backoff", tags: ["github-pr-990001"], completed: true)

    XCTAssertTrue(CaptureCommandDrafter.candidates(for: source, tasks: [done]).isEmpty)
    XCTAssertNil(CaptureCommandDrafter.alreadyTracked(source, in: [done]))
  }

  func testAlreadyTrackedFindsTheTaskBehindARepeatedPaste() {
    let source = githubSource(issueID: 990001)
    let existing = task(title: "Add retry backoff", tags: ["github", "github-pr-990001"])

    XCTAssertEqual(CaptureCommandDrafter.alreadyTracked(source, in: [existing])?.id, existing.id)
  }

  // MARK: - Rendering

  func testTheLinkedMessageIsMarkedSoTheModelKnowsWhichOneItIs() {
    let excerpt = excerpt(
      messages: [
        message(ts: "1726740000.111222", text: "the retry work is blocked"),
        message(ts: "1726742400.123456", text: "can you take the migration?"),
      ],
      anchorTS: "1726742400.123456"
    )

    let rendered = CaptureCommandDrafter.render(source: .slack(excerpt), now: now)

    XCTAssertTrue(rendered.contains("> jane"))
    XCTAssertTrue(rendered.contains("  jane"))
    XCTAssertTrue(rendered.contains("marked >"))
  }

  func testSlackMarkupNeverReachesThePrompt() {
    let excerpt = excerpt(
      messages: [message(ts: "1726742400.123456", text: "<@U_ME> can you look? see <https://x.test|the doc>")],
      anchorTS: "1726742400.123456",
      names: ["U_ME": "adarsh"]
    )

    let rendered = CaptureCommandDrafter.render(source: .slack(excerpt), now: now)

    XCTAssertTrue(rendered.contains("@adarsh"))
    XCTAssertTrue(rendered.contains("the doc"))
    XCTAssertFalse(rendered.contains("<@U_ME>"))
  }

  func testYourOwnMessagesAreMarkedAsYours() {
    let excerpt = excerpt(
      messages: [message(ts: "1726742400.123456", text: "I'll take it", isOwn: true)],
      anchorTS: "1726742400.123456"
    )

    XCTAssertTrue(CaptureCommandDrafter.render(source: .slack(excerpt), now: now).contains("(you)"))
  }

  func testOverlongSlackThreadsLoseTheirOldestButKeepTheAnchor() {
    let messages = (1...40).map { message(ts: "17267400\(String(format: "%02d", $0)).000000", text: String(repeating: "x", count: 200)) }
    let excerpt = excerpt(messages: messages, anchorTS: messages[0].ts)

    let rendered = CaptureCommandDrafter.render(source: .slack(excerpt), now: now, budget: 1000)

    XCTAssertLessThanOrEqual(rendered.count, 1000)
    XCTAssertTrue(rendered.contains(">"), "the linked message survives even when it is the oldest one")
  }

  func testAPullRequestRendersTheVerdictsAndTheAsks() {
    let source = githubSource(
      title: "Add retry backoff",
      body: "Wraps the client in a retry.",
      reviews: [
        GitHubReviewSummary(reviewer: "priya", state: "CHANGES_REQUESTED", body: "handle the null case", submittedAt: now),
      ],
      comments: [GitHubCommentSummary(author: "ravi", body: "also needs a 429 test", createdAt: now)],
      files: ["Sources/Client.swift"]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("acme/api#812"))
    XCTAssertTrue(rendered.contains("CHANGES_REQUESTED"))
    XCTAssertTrue(rendered.contains("handle the null case"))
    XCTAssertTrue(rendered.contains("also needs a 429 test"))
    XCTAssertTrue(rendered.contains("Sources/Client.swift"))
  }

  func testAMilestoneDueDateIsRenderedAbsolutely() {
    let due = Date(timeIntervalSince1970: 1_789_344_000)
    let source = githubSource(milestone: "0.9 hardening", milestoneDue: due)

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("0.9 hardening"))
    XCTAssertTrue(rendered.contains(CaptureCommandDrafter.stamp(due)))
  }

  /// A long review thread is what overflows the budget, and the comments are
  /// the only part big enough to reclaim space from.
  func testAnOverlongPullRequestShedsItsOldestCommentsFirst() {
    let comments = (1...60).map {
      GitHubCommentSummary(author: "ravi", body: "note \($0) " + String(repeating: "x", count: 200), createdAt: now)
    }
    let source = githubSource(comments: comments, files: ["Sources/Client.swift"])

    let rendered = CaptureCommandDrafter.render(source: source, now: now, budget: 2000)

    XCTAssertLessThanOrEqual(rendered.count, 2000)
    XCTAssertTrue(rendered.contains("note 60"), "the newest comments are the ones worth keeping")
    XCTAssertFalse(rendered.contains("note 1 "))
  }

  /// Every review and comment on a real pull request can be an automated
  /// reviewer. A bot walkthrough is long by habit, so letting length decide the
  /// truncation would drop a person's one-line ask to keep a summary of the diff.
  func testBotCommentsAreShedBeforeHumanOnes() {
    let human = GitHubCommentSummary(author: "priya", body: "please also handle the null case", createdAt: now)
    let bots = (1...8).map {
      GitHubCommentSummary(
        author: "greptile-apps[bot]",
        body: "walkthrough \($0) " + String(repeating: "x", count: 400),
        createdAt: now,
        isBot: true
      )
    }
    let source = githubSource(comments: [bots[0], human] + bots.dropFirst())

    let rendered = CaptureCommandDrafter.render(source: source, now: now, budget: 1200)

    XCTAssertLessThanOrEqual(rendered.count, 1200)
    XCTAssertTrue(rendered.contains("please also handle the null case"), "the person survives the trim")
  }

  func testAutomatedAuthorsAreLabelledSoTheModelCanWeighThem() {
    let source = githubSource(
      reviews: [
        GitHubReviewSummary(reviewer: "cursor[bot]", state: "COMMENTED", body: "nit", submittedAt: now, isBot: true),
        GitHubReviewSummary(reviewer: "priya", state: "CHANGES_REQUESTED", body: "null case", submittedAt: now),
      ],
      comments: [GitHubCommentSummary(author: "codex[bot]", body: "summary", createdAt: now, isBot: true)]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("cursor[bot] (automated)"))
    XCTAssertTrue(rendered.contains("codex[bot] (automated)"))
    XCTAssertFalse(rendered.contains("priya (automated)"))
  }

  func testAPersonsVerdictIsListedBeforeTheBots() throws {
    let source = githubSource(
      reviews: [
        GitHubReviewSummary(reviewer: "cursor[bot]", state: "COMMENTED", submittedAt: now, isBot: true),
        GitHubReviewSummary(reviewer: "priya", state: "CHANGES_REQUESTED", submittedAt: now),
      ]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)
    let human = try XCTUnwrap(rendered.range(of: "priya"))
    let bot = try XCTUnwrap(rendered.range(of: "cursor[bot]"))

    XCTAssertLessThan(human.lowerBound, bot.lowerBound)
  }

  func testBotMarkersAreStrippedFromBotComments() {
    let source = githubSource(
      comments: [
        GitHubCommentSummary(
          author: "entelligence-ai-pr-reviews[bot]",
          body: "<!-- ENTELLIGENCE_WALKTHROUGH -->\n## Walkthrough\nThis PR moves enrichment.",
          createdAt: now,
          isBot: true
        )
      ]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertFalse(rendered.contains("ENTELLIGENCE_WALKTHROUGH"))
    XCTAssertFalse(rendered.contains("<!--"))
    XCTAssertTrue(rendered.contains("This PR moves enrichment."))
  }

  /// An HTML comment a person wrote, they wrote on purpose.
  func testAHumanCommentIsLeftExactlyAsWritten() {
    let source = githubSource(
      comments: [
        GitHubCommentSummary(author: "priya", body: "<!-- note to self --> handle the null case", createdAt: now)
      ]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("<!-- note to self --> handle the null case"))
  }

  func testThePullRequestBodyIsNeverRewritten() {
    let source = githubSource(body: "<!-- Describe your change -->\nWraps the client in a retry.")

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("<!-- Describe your change -->"))
  }

  func testABotCommentThatIsNothingButMarkersIsDropped() {
    let source = githubSource(
      comments: [
        GitHubCommentSummary(author: "cursor[bot]", body: "<!-- CURSOR_SUMMARY -->", createdAt: now, isBot: true),
        GitHubCommentSummary(author: "priya", body: "handle the null case", createdAt: now),
      ]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertFalse(rendered.contains("cursor[bot]"))
    XCTAssertTrue(rendered.contains("handle the null case"))
  }

  /// A bot verdict with nothing readable left still carries its state.
  func testABotVerdictSurvivesLosingItsBody() {
    let source = githubSource(
      reviews: [
        GitHubReviewSummary(
          reviewer: "cursor[bot]",
          state: "CHANGES_REQUESTED",
          body: "<!-- CURSOR -->",
          submittedAt: now,
          isBot: true
        )
      ]
    )

    let rendered = CaptureCommandDrafter.render(source: source, now: now)

    XCTAssertTrue(rendered.contains("cursor[bot] (automated) — CHANGES_REQUESTED"))
    XCTAssertFalse(rendered.contains("<!--"))
  }

  // MARK: - Prompt

  func testTheUsersOwnWordsAreMarkedAsOutrankingTheSource() {
    let prompt = CaptureCommandDrafter.userPrompt(
      sources: [githubSource()],
      context: "needs to land before the demo",
      candidates: [:],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(prompt.contains("needs to land before the demo"))
    XCTAssertTrue(prompt.contains("outrank"))
  }

  func testAnEmptyContextSaysSoRatherThanLeavingABlank() {
    let prompt = CaptureCommandDrafter.userPrompt(
      sources: [githubSource()],
      context: "   ",
      candidates: [:],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(prompt.contains("no words of their own"))
  }

  func testEverySourceGetsItsOwnKeyedBlock() {
    let prompt = CaptureCommandDrafter.userPrompt(
      sources: [githubSource(number: 812), githubSource(number: 815)],
      context: "",
      candidates: [:],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(prompt.contains("--- source s1 (acme/api#812) ---"))
    XCTAssertTrue(prompt.contains("--- source s2 (acme/api#815) ---"))
  }

  func testCandidateTasksArriveWithTheirIDsAndDueDates() {
    let existing = task(title: "Add retry backoff", due: now)
    let prompt = CaptureCommandDrafter.userPrompt(
      sources: [githubSource()],
      context: "",
      candidates: ["s1": [existing]],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(prompt.contains("[\(existing.id)]"))
    XCTAssertTrue(prompt.contains("due \(CaptureCommandDrafter.stamp(now))"))
  }

  func testTodayIsStatedSoRelativeDatesCanBeResolved() {
    let prompt = CaptureCommandDrafter.userPrompt(
      sources: [githubSource()],
      context: "",
      candidates: [:],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(prompt.hasPrefix("Today is \(CaptureCommandDrafter.stamp(now))."))
  }

  func testThePromptForbidsInventingADeadline() {
    let prompt = CaptureCommandDrafter.systemPrompt()

    XCTAssertTrue(prompt.contains("only when there is evidence"))
    XCTAssertTrue(prompt.contains("never invent one"))
    XCTAssertTrue(prompt.contains("more than \(CaptureCommandDrafter.maxDrafts) tasks"))
  }

  func testTheSchemaOffersNoIgnoreAction() throws {
    let schema = CaptureCommandDrafter.schema()
    let tasks = try XCTUnwrap(
      (schema["properties"] as? [String: Any])?["tasks"] as? [String: Any]
    )
    let properties = try XCTUnwrap(
      ((tasks["items"] as? [String: Any])?["properties"]) as? [String: Any]
    )
    let actions = try XCTUnwrap((properties["action"] as? [String: Any])?["enum"] as? [String])

    XCTAssertEqual(actions, ["create", "update"])
  }

  // MARK: - Tagging what comes back

  func testADraftIsTaggedWithTheSourcesItCovers() {
    let sources = [githubSource(issueID: 990001, number: 812), githubSource(issueID: 990002, number: 815)]
    let draft = CaptureDraft(kind: .create, payload: .init(title: "Fix both"), confidence: 0.9, sourceLabel: "")

    let tagged = CaptureCommandDrafter.tagged(draft, sources: sources, coveringKeys: ["s1", "s2"])

    XCTAssertEqual(tagged.payload.tags, ["github", "github-pr-990001", "github-pr-990002"])
    XCTAssertEqual(tagged.sourceLabel, "acme/api#812, acme/api#815")
    XCTAssertEqual(tagged.sourceLinks.count, 2)
  }

  func testADraftCoveringOneSourceIsNotTaggedWithTheOther() {
    let sources = [githubSource(issueID: 990001, number: 812), githubSource(issueID: 990002, number: 815)]
    let draft = CaptureDraft(kind: .create, payload: .init(title: "Only the first"), confidence: 0.9, sourceLabel: "")

    let tagged = CaptureCommandDrafter.tagged(draft, sources: sources, coveringKeys: ["s1"])

    XCTAssertEqual(tagged.payload.tags, ["github", "github-pr-990001"])
    XCTAssertEqual(tagged.sourceLabel, "acme/api#812")
  }

  /// A model that names no source at all still has to produce a tagged task, or
  /// the next paste of the same link duplicates it.
  func testADraftNamingNoSourceIsTaggedWithAllOfThem() {
    let sources = [githubSource(issueID: 990001), githubSource(issueID: 990002)]
    let draft = CaptureDraft(kind: .create, payload: .init(title: "Unattributed"), confidence: 0.9, sourceLabel: "")

    let tagged = CaptureCommandDrafter.tagged(draft, sources: sources, coveringKeys: [])

    XCTAssertTrue(tagged.payload.tags.contains("github-pr-990001"))
    XCTAssertTrue(tagged.payload.tags.contains("github-pr-990002"))
  }

  func testSlackAndGitHubSourcesGetTheirOwnProviderTag() {
    let slack = CaptureCommandDrafter.tagged(
      CaptureDraft(kind: .create, payload: .init(title: "x"), confidence: 1, sourceLabel: ""),
      sources: [slackSource()],
      coveringKeys: ["s1"]
    )

    XCTAssertTrue(slack.payload.tags.contains("slack"))
    XCTAssertFalse(slack.payload.tags.contains("github"))
  }

  // MARK: - Redirecting a duplicate

  func testACreateForAnAlreadyTrackedSourceBecomesAnUpdate() {
    let source = githubSource(issueID: 990001)
    let existing = task(title: "Add retry backoff", tags: ["github", "github-pr-990001"])
    let draft = CaptureCommandDrafter.tagged(
      CaptureDraft(kind: .create, payload: .init(title: "Add retry backoff again"), confidence: 0.9, sourceLabel: ""),
      sources: [source],
      coveringKeys: ["s1"]
    )

    let redirected = CaptureCommandDrafter.redirectingDuplicates([draft], sources: [source], tasks: [existing])

    XCTAssertEqual(redirected.first?.kind, .update)
    XCTAssertEqual(redirected.first?.targetTaskID, existing.id)
    XCTAssertNil(redirected.first?.payload.title, "a repeated paste must not rename the task you already have")
  }

  func testAnUntrackedSourceStaysACreate() {
    let source = githubSource(issueID: 990001)
    let draft = CaptureCommandDrafter.tagged(
      CaptureDraft(kind: .create, payload: .init(title: "Add retry backoff"), confidence: 0.9, sourceLabel: ""),
      sources: [source],
      coveringKeys: ["s1"]
    )

    let result = CaptureCommandDrafter.redirectingDuplicates([draft], sources: [source], tasks: [])

    XCTAssertEqual(result.first?.kind, .create)
    XCTAssertEqual(result.first?.payload.title, "Add retry backoff")
  }

  /// One paste can legitimately be part-new and part-already-tracked, and the
  /// card has to show both.
  func testOnePasteCanProduceACreateAndAnUpdateTogether() {
    let tracked = githubSource(issueID: 990001, number: 812)
    let fresh = githubSource(issueID: 990002, number: 815)
    let existing = task(title: "Add retry backoff", tags: ["github", "github-pr-990001"])

    let drafts = [
      CaptureCommandDrafter.tagged(
        CaptureDraft(kind: .create, payload: .init(title: "Retry backoff"), confidence: 0.9, sourceLabel: ""),
        sources: [tracked, fresh],
        coveringKeys: ["s1"]
      ),
      CaptureCommandDrafter.tagged(
        CaptureDraft(kind: .create, payload: .init(title: "Rebase the backoff PR"), confidence: 0.8, sourceLabel: ""),
        sources: [tracked, fresh],
        coveringKeys: ["s2"]
      ),
    ]

    let result = CaptureCommandDrafter.redirectingDuplicates(drafts, sources: [tracked, fresh], tasks: [existing])

    XCTAssertEqual(result.map(\.kind), [.update, .create])
    XCTAssertEqual(result.first?.targetTaskID, existing.id)
  }

  func testAnUpdateTheModelAlreadyAimedCorrectlyIsLeftAlone() {
    let source = githubSource(issueID: 990001)
    let existing = task(title: "Add retry backoff", tags: ["github", "github-pr-990001"])
    let draft = CaptureCommandDrafter.tagged(
      CaptureDraft(kind: .update, targetTaskID: existing.id, payload: .init(priority: .high), confidence: 0.9, sourceLabel: ""),
      sources: [source],
      coveringKeys: ["s1"]
    )

    let result = CaptureCommandDrafter.redirectingDuplicates([draft], sources: [source], tasks: [existing])

    XCTAssertEqual(result.first?.targetTaskID, existing.id)
    XCTAssertEqual(result.first?.payload.priority, .high)
  }

  // MARK: - Fixtures

  private func message(
    ts: String,
    threadTS: String? = nil,
    text: String,
    isOwn: Bool = false
  ) -> SlackMessage {
    SlackMessage(
      channelID: "C_ENG",
      channelName: "eng-platform",
      ts: ts,
      threadTS: threadTS,
      userID: isOwn ? "U_ME" : "U_JANE",
      authorName: isOwn ? "adarsh" : "jane",
      text: text,
      isOwn: isOwn,
      isBot: false,
      subtype: nil,
      permalink: nil
    )
  }

  private func excerpt(
    messages: [SlackMessage],
    anchorTS: String,
    names: [String: String] = [:]
  ) -> SlackConversationExcerpt {
    SlackConversationExcerpt(
      channelID: "C_ENG",
      channelName: "eng-platform",
      messages: messages,
      anchor: messages.first { $0.ts == anchorTS } ?? messages[0],
      names: names,
      permalink: "https://acme.slack.com/archives/C_ENG/p\(anchorTS.replacingOccurrences(of: ".", with: ""))"
    )
  }

  private func slackSource(
    channelID: String = "C_ENG",
    rootTS: String = "1726740000.111222"
  ) -> CaptureSource {
    .slack(excerpt(messages: [message(ts: rootTS, text: "the ask")], anchorTS: rootTS))
  }

  private func githubSource(
    issueID: Int64 = 990001,
    number: Int = 812,
    title: String = "Add retry backoff",
    body: String? = nil,
    milestone: String? = nil,
    milestoneDue: Date? = nil,
    reviews: [GitHubReviewSummary] = [],
    comments: [GitHubCommentSummary] = [],
    files: [String] = []
  ) -> CaptureSource {
    .github(
      GitHubPullSnapshot(
        issueID: issueID,
        owner: "acme",
        repo: "api",
        number: number,
        title: title,
        body: body,
        state: "open",
        isPullRequest: true,
        isDraft: false,
        isMerged: false,
        labels: [],
        assignees: [],
        requestedReviewers: [],
        milestoneTitle: milestone,
        milestoneDueOn: milestoneDue,
        changedFileNames: files,
        changedFileCount: files.count,
        reviews: reviews,
        comments: comments,
        htmlURL: "https://github.com/acme/api/pull/\(number)",
        createdAt: now,
        updatedAt: now
      )
    )
  }

  private func task(
    title: String,
    tags: [String] = [],
    completed: Bool = false,
    due: Date? = nil
  ) -> TaskEntity {
    TaskEntity(
      id: UUID().uuidString,
      title: title,
      description: nil,
      completed: completed,
      completedAt: nil,
      priority: .medium,
      dueDate: due,
      projectId: nil,
      tags: tags,
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }
}
