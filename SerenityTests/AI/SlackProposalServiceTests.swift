import XCTest
@testable import SerenityMac

final class SlackProposalServiceTests: XCTestCase {
  // MARK: Shortlisting

  func testAThreadTaggedTaskWinsOutrightOverWordOverlap() {
    let signal = signal(text: "any update on the billing export?", threadTS: "100.0")
    let tagged = task(title: "Something unrelated entirely", tags: ["slack", "slack-thread-c_eng-100.0"])
    let lexical = task(title: "Billing export for finance")

    let shortlist = SlackProposalPlanner.shortlist(tasks: [lexical, tagged], for: signal)

    XCTAssertEqual(shortlist.map(\.id), [tagged.id])
  }

  func testShortlistRanksByOverlapAndStaysSmall() {
    let signal = signal(text: "can you finish the billing export migration today")
    let strong = task(title: "Billing export migration")
    let weak = task(title: "Billing dashboard")
    let unrelated = task(title: "Book the offsite venue")

    let shortlist = SlackProposalPlanner.shortlist(tasks: [unrelated, weak, strong], for: signal, limit: 2)

    XCTAssertEqual(shortlist.first?.id, strong.id)
    XCTAssertEqual(shortlist.count, 2)
    XCTAssertFalse(shortlist.contains { $0.id == unrelated.id })
  }

  func testCompletedTasksAreNotCandidates() {
    let signal = signal(text: "the billing export is still broken")
    let done = task(title: "Billing export", completed: true)

    XCTAssertTrue(SlackProposalPlanner.shortlist(tasks: [done], for: signal).isEmpty)
  }

  // MARK: Batching

  func testSignalsAreBatchedSoOneCallCoversSeveral() {
    let signals = (1...12).map { signal(text: "item \($0)", ts: "\($0).0") }
    let batches = SlackProposalPlanner.batches(of: signals)

    XCTAssertEqual(batches.map(\.count), [5, 5, 2])
  }

  func testAnOversizedSignalGetsItsOwnBatch() {
    let huge = signal(text: String(repeating: "x", count: 13_000), ts: "1.0")
    let small = signal(text: "short", ts: "2.0")

    let batches = SlackProposalPlanner.batches(of: [huge, small])

    XCTAssertEqual(batches.count, 2)
  }

  // MARK: Rendering

  func testSlackMarkupIsResolvedBeforeTheModelSeesIt() {
    let names = ["U_JANE": "jane", "U_ME": "adarsh"]
    let raw = "<@U_ME> see <#C123|general> and <https://example.com/doc|the doc> cc <!subteam^S1|@platform>"

    let cleaned = SlackProposalPlanner.clean(raw, names: names)

    XCTAssertTrue(cleaned.contains("@adarsh"))
    XCTAssertTrue(cleaned.contains("#general"))
    XCTAssertTrue(cleaned.contains("the doc"))
    XCTAssertFalse(cleaned.contains("<@"), "A raw user ID in a task title is unreadable")
    XCTAssertFalse(cleaned.contains("https://example.com/doc"))
  }

  func testUnknownMentionsDegradeRatherThanLeakIDs() {
    let cleaned = SlackProposalPlanner.clean("ping <@U_STRANGER> about it", names: [:])

    XCTAssertEqual(cleaned, "ping @someone about it")
  }

  func testTheAnchorIsMarkedSoTheModelKnowsWhatItIsJudging() {
    let anchor = message(ts: "2.0", user: "U_JANE", text: "<@U_ME> can you ship it")
    let context = [message(ts: "1.0", user: "U_RAVI", text: "the export is ready")]
    let rendered = SlackProposalPlanner.render(
      signal: SlackSignal(anchor: anchor, context: context),
      names: ["U_ME": "adarsh"],
      now: Date()
    )

    XCTAssertTrue(rendered.contains("#eng-platform"))
    XCTAssertTrue(rendered.contains("  U_RAVI: the export is ready"))
    XCTAssertTrue(rendered.contains("> U_JANE ("))
    XCTAssertTrue(rendered.contains("@adarsh can you ship it"))
  }

  // MARK: Mapping decisions to proposals

  func testAnIgnoreDecisionProducesNoProposal() {
    let decision = decision(action: .ignore)

    XCTAssertNil(
      SlackProposalMapper.proposal(from: decision, signal: signal(text: "chat"), workspaceURL: nil, names: [:])
    )
  }

  func testACreateWithoutATitleIsDropped() {
    let decision = decision(action: .create, payload: SlackProposalPayload(title: "   "))

    XCTAssertNil(
      SlackProposalMapper.proposal(from: decision, signal: signal(text: "chat"), workspaceURL: nil, names: [:])
    )
  }

  func testACreateIsTaggedBackToItsThreadAndLinked() throws {
    let decision = decision(action: .create, payload: SlackProposalPayload(title: "Ship the export"))
    let signal = signal(text: "<@U_ME> ship the export", threadTS: "100.0")

    let proposal = try XCTUnwrap(
      SlackProposalMapper.proposal(
        from: decision,
        signal: signal,
        workspaceURL: "https://acme.slack.com/",
        names: ["U_ME": "adarsh"]
      )
    )

    XCTAssertEqual(proposal.kind, .create)
    XCTAssertTrue(proposal.payload.tags.contains("slack"))
    XCTAssertTrue(proposal.payload.tags.contains("slack-thread-c_eng-100.0"))
    XCTAssertEqual(proposal.source.threadTS, "100.0")
    XCTAssertEqual(proposal.source.excerpt, "@adarsh ship the export")
    XCTAssertEqual(proposal.source.permalink, "https://acme.slack.com/archives/C_ENG/p20")
  }

  func testATopLevelMessageIsTaggedWithItsOwnTimestampAsTheThreadRoot() throws {
    let decision = decision(action: .create, payload: SlackProposalPayload(title: "Ship the export"))
    let proposal = try XCTUnwrap(
      SlackProposalMapper.proposal(from: decision, signal: signal(text: "ship it", ts: "77.0"), workspaceURL: nil, names: [:])
    )

    XCTAssertTrue(proposal.payload.tags.contains("slack-thread-c_eng-77.0"))
  }

  func testAnUpdateWithoutATargetIsDropped() {
    let decision = decision(action: .update, targetTaskID: nil, payload: SlackProposalPayload(title: "Ship"))

    XCTAssertNil(
      SlackProposalMapper.proposal(from: decision, signal: signal(text: "chat"), workspaceURL: nil, names: [:])
    )
  }

  // MARK: Decoding the model's answer

  func testAnInventedTaskIDFallsBackToProposingNewWork() async throws {
    let signal = signal(text: "<@U_ME> ship the export")
    let outcome = try await decide(
      signals: [signal],
      responding: """
      {"decisions":[{"signalId":"\(signal.id)","action":"update","targetTaskId":"does-not-exist",
      "title":"Ship the export","description":null,"priority":"high","dueDate":"2026-09-25",
      "projectId":null,"projectName":null,"tags":[],"subtasks":[],"statusChange":"none",
      "confidence":0.8,"reason":"jane asked"}]}
      """
    )

    let decision = try XCTUnwrap(outcome.decisions.first)
    XCTAssertEqual(decision.action, .create)
    XCTAssertNil(decision.targetTaskID)
    XCTAssertEqual(decision.payload.priority, .high)
  }

  func testAnInventedTaskIDWithNoTitleIsIgnoredRatherThanGuessed() async throws {
    let signal = signal(text: "<@U_ME> what is the status")
    let outcome = try await decide(
      signals: [signal],
      responding: """
      {"decisions":[{"signalId":"\(signal.id)","action":"update","targetTaskId":"nope","title":null,
      "description":null,"priority":null,"dueDate":null,"projectId":null,"projectName":null,
      "tags":[],"subtasks":[],"statusChange":"none","confidence":0.4,"reason":"unclear"}]}
      """
    )

    XCTAssertEqual(outcome.decisions.first?.action, .ignore)
  }

  func testDatesComeBackAbsolute() async throws {
    let signal = signal(text: "<@U_ME> due Friday")
    let outcome = try await decide(
      signals: [signal],
      responding: """
      {"decisions":[{"signalId":"\(signal.id)","action":"create","targetTaskId":null,"title":"Send the report",
      "description":null,"priority":null,"dueDate":"2026-09-25","projectId":null,"projectName":null,
      "tags":[],"subtasks":[],"statusChange":"none","confidence":0.9,"reason":"asked by jane"}]}
      """
    )

    let dueDate = try XCTUnwrap(outcome.decisions.first?.payload.dueDate)
    let components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 9)
    XCTAssertEqual(components.day, 25)
  }

  func testDecisionsForSignalsThatWereNotAskedAboutAreDiscarded() async throws {
    let signal = signal(text: "<@U_ME> ship it")
    let outcome = try await decide(
      signals: [signal],
      responding: """
      {"decisions":[{"signalId":"a-signal-we-never-sent","action":"create","targetTaskId":null,
      "title":"Invented","description":null,"priority":null,"dueDate":null,"projectId":null,
      "projectName":null,"tags":[],"subtasks":[],"statusChange":"none","confidence":1,"reason":"x"}]}
      """
    )

    XCTAssertTrue(outcome.decisions.isEmpty)
  }

  func testAFailingBatchIsReportedWithoutLosingItsSignals() async throws {
    let signal = signal(text: "<@U_ME> ship it")
    let outcome = try await decide(signals: [signal], responding: "not json at all")

    XCTAssertTrue(outcome.decisions.isEmpty)
    XCTAssertEqual(outcome.failedSignalIDs, [signal.id])
    XCTAssertNotNil(outcome.lastError)
  }

  // MARK: Helpers

  private func decide(signals: [SlackSignal], responding text: String) async throws -> SlackDecisionOutcome {
    let service = try makeService { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(text: text, promptTokens: 10, completionTokens: 5)
    }
    let credential = try await service.addCredential(
      provider: .anthropic,
      name: "Test",
      apiKey: "sk-test",
      modelPreference: "claude-haiku-4-5"
    )

    return try await service.proposeSlackDecisions(
      signals: signals,
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      names: ["U_ME": "adarsh"],
      ownName: "adarsh"
    )
  }

  private func makeService(
    generator: @escaping AIWorkflowService.QuickCaptureGenerationHandler
  ) throws -> AIWorkflowService {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-slack-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

    return AIWorkflowService(
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      secretStore: KeychainSecretStore(service: "test.slack.ai", backend: InMemorySlackAISecretBackend()),
      quickCaptureGenerator: generator
    )
  }

  private func decision(
    action: SlackDecisionAction,
    targetTaskID: String? = nil,
    payload: SlackProposalPayload = SlackProposalPayload()
  ) -> SlackDecision {
    SlackDecision(
      signalID: "C_ENG:2.0",
      action: action,
      targetTaskID: targetTaskID,
      payload: payload,
      confidence: 0.8,
      reason: "because"
    )
  }

  private func signal(text: String, ts: String = "2.0", threadTS: String? = nil) -> SlackSignal {
    SlackSignal(anchor: message(ts: ts, user: "U_JANE", text: text, threadTS: threadTS), context: [])
  }

  private func message(ts: String, user: String, text: String, threadTS: String? = nil) -> SlackMessage {
    SlackMessage(
      channelID: "C_ENG",
      channelName: "eng-platform",
      ts: ts,
      threadTS: threadTS,
      userID: user,
      authorName: user,
      text: text,
      isOwn: false,
      isBot: false,
      subtype: nil,
      permalink: nil
    )
  }

  private func task(title: String, tags: [String] = [], completed: Bool = false) -> TaskEntity {
    TaskEntity(
      id: UUID().uuidString,
      title: title,
      description: nil,
      completed: completed,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: tags,
      createdAt: Date(),
      updatedAt: Date(),
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }
}

private final class InMemorySlackAISecretBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  private func key(_ service: String, _ key: String) -> String { "\(service):\(key)" }

  func set(service: String, key: String, data: Data) throws {
    values[self.key(service, key)] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values[self.key(service, key)]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: self.key(service, key))
  }

  func contains(service: String, key: String) throws -> Bool {
    values[self.key(service, key)] != nil
  }
}
