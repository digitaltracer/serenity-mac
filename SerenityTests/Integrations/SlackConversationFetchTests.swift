import XCTest
@testable import SerenityMac

/// Everything here runs against canned JSON through the injectable request
/// handler, so the whole fetch path is covered with no network.
final class SlackConversationFetchTests: XCTestCase {
  private func session() -> SlackIntegrationSession {
    SlackIntegrationSession(
      accessToken: "xoxp-token",
      refreshToken: nil,
      expiresAt: nil,
      teamID: "T123",
      teamName: "Acme",
      teamURL: "https://acme.slack.com/",
      userID: "U_ME",
      userName: "adarsh",
      connectedAt: Date()
    )
  }

  private func reference(
    channelID: String = "C_ENG",
    root: String = "1726740000.111222",
    linked: String = "1726742400.123456"
  ) -> SlackConversationReference {
    SlackConversationReference(
      channelID: channelID,
      threadRootTS: root,
      linkedTS: linked,
      workspaceHost: "acme.slack.com"
    )
  }

  private func reader(_ slack: FakeSlackConversation) -> SlackMessageReader {
    SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
  }

  private func assertFetchFails(
    _ expected: SlackConversationFetchError,
    when code: String,
    onPath path: String = "/api/conversations.replies",
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let slack = FakeSlackConversation()
    await slack.setError(code, forPath: path)

    do {
      _ = try await reader(slack).fetchConversation(session: session(), reference: reference())
      XCTFail("expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? SlackConversationFetchError, expected, file: file, line: line)
    }
  }

  // MARK: - Reading a thread

  func testAThreadComesBackWholeAndInOrder() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":["#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"can you take the migration?","thread_ts":"1726740000.111222"},"#
        + #"{"ts":"1726740000.111222","user":"U_RAVI","text":"the retry work is blocked"}"#
        + #"]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.messages.map(\.ts), ["1726740000.111222", "1726742400.123456"])
    XCTAssertEqual(excerpt.channelName, "eng-platform")
  }

  func testTheThreadRootIsWhatSlackIsAskedFor() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"hi","thread_ts":"1726740000.111222"},"#
        + #"{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"}]}"#
    )

    _ = try await reader(slack).fetchConversation(session: session(), reference: reference())

    let asked = await slack.query(forPath: "/api/conversations.replies", name: "ts")
    XCTAssertEqual(asked, "1726740000.111222", "a link to a reply must fetch its thread, not itself")
  }

  func testTheLinkedMessageIsTheAnchorEvenDeepInAThread() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":["#
        + #"{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"},"#
        + #"{"ts":"1726741000.000100","user":"U_JANE","text":"middle","thread_ts":"1726740000.111222"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"the ask","thread_ts":"1726740000.111222"}"#
        + #"]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.anchor.text, "the ask")
  }

  // MARK: - Reading a message that was never threaded

  func testAStandaloneMessageIsToppedUpWithItsNeighbours() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(#"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"alone"}]}"#)
    await slack.setHistory(
        before: #"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"alone"},"#
          + #"{"ts":"1726742300.000000","user":"U_RAVI","text":"older"}]}"#,
        after: #"{"ok":true,"messages":[{"ts":"1726742500.000000","user":"U_RAVI","text":"newer"},"#
          + #"{"ts":"1726742400.123456","user":"U_JANE","text":"alone"}]}"#
    )

    let reference = reference(root: "1726742400.123456", linked: "1726742400.123456")
    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference)

    XCTAssertEqual(
      excerpt.messages.map(\.text),
      ["older", "alone", "newer"],
      "the window runs both ways — the reply after an ask is usually the half that matters"
    )
    XCTAssertEqual(excerpt.anchor.text, "alone")
  }

  func testTheAnchorIsNotDuplicatedByTheOverlappingWindows() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(#"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"alone"}]}"#)
    await slack.setHistory(
      before: #"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"alone"}]}"#,
      after: #"{"ok":true,"messages":[{"ts":"1726742400.123456","user":"U_JANE","text":"alone"}]}"#
    )

    let reference = reference(root: "1726742400.123456", linked: "1726742400.123456")
    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference)

    XCTAssertEqual(excerpt.messages.count, 1)
  }

  func testAThreadIsNotToppedUpFromTheChannel() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"reply","thread_ts":"1726740000.111222"}]}"#
    )

    _ = try await reader(slack).fetchConversation(session: session(), reference: reference())

    let historyCalls = await slack.count(forPath: "/api/conversations.history")
    XCTAssertEqual(historyCalls, 0)
  }

  // MARK: - What the excerpt carries

  func testThePermalinkPointsAtTheMessageTheUserLinked() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"reply","thread_ts":"1726740000.111222"}]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.permalink, "https://acme.slack.com/archives/C_ENG/p1726742400123456")
  }

  func testDisplayNamesAreResolvedForTheDraft() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"reply","thread_ts":"1726740000.111222"}]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.anchor.authorName, "jane")
    XCTAssertEqual(excerpt.names["U_RAVI"], "ravi")
  }

  func testYourOwnMessagesAreStillFlagged() async throws {
    let slack = FakeSlackConversation()
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726740000.111222","user":"U_ME","text":"I will take it"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"thanks","thread_ts":"1726740000.111222"}]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.messages.first?.isOwn, true)
    XCTAssertEqual(excerpt.anchor.isOwn, false)
  }

  // MARK: - Failures the user can act on

  func testNotInChannelSaysSo() async {
    await assertFetchFails(.notInChannel("C_ENG"), when: "not_in_channel")
  }

  func testAnArchivedChannelReadsTheSameWay() async {
    await assertFetchFails(.notInChannel("C_ENG"), when: "is_archived")
  }

  func testAnInvisibleChannelSaysSo() async {
    await assertFetchFails(.channelNotFound, when: "channel_not_found", onPath: "/api/conversations.info")
  }

  func testAMissingScopeAsksForAReconnect() async {
    await assertFetchFails(.missingScope, when: "missing_scope")
  }

  func testADeletedThreadSaysSo() async {
    await assertFetchFails(.messageNotFound, when: "thread_not_found")
  }

  func testAnUnmappedSlackCodeIsLeftAlone() async {
    let slack = FakeSlackConversation()
    await slack.setError("ratelimited_forever", forPath: "/api/conversations.replies")

    do {
      _ = try await reader(slack).fetchConversation(session: session(), reference: reference())
      XCTFail("expected a failure")
    } catch {
      XCTAssertNil(error as? SlackConversationFetchError, "an unrecognised code keeps its original error")
    }
  }

  func testThrottlingIsStillWaitedOut() async throws {
    let slack = FakeSlackConversation()
    await slack.setThrottleFirstRepliesCall(true)
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"1726740000.111222","user":"U_RAVI","text":"parent"},"#
        + #"{"ts":"1726742400.123456","user":"U_JANE","text":"reply","thread_ts":"1726740000.111222"}]}"#
    )

    let excerpt = try await reader(slack).fetchConversation(session: session(), reference: reference())

    XCTAssertEqual(excerpt.messages.count, 2)
    let calls = await slack.count(forPath: "/api/conversations.replies")
    XCTAssertEqual(calls, 2, "the throttled call is retried, not surfaced as a failure")
  }
}

private actor FakeSlackConversation {
  private var repliesPayload = #"{"ok":true,"messages":[]}"#
  private var historyBefore = #"{"ok":true,"messages":[]}"#
  private var historyAfter = #"{"ok":true,"messages":[]}"#
  private var errors: [String: String] = [:]
  private var throttleFirstRepliesCall = false
  private var calls: [(path: String, query: [String: String])] = []

  func setReplies(_ payload: String) {
    repliesPayload = payload
  }

  func setHistory(before: String, after: String) {
    historyBefore = before
    historyAfter = after
  }

  func setError(_ code: String, forPath path: String) {
    errors[path] = code
  }

  func setThrottleFirstRepliesCall(_ value: Bool) {
    throttleFirstRepliesCall = value
  }

  func count(forPath path: String) -> Int {
    calls.filter { $0.path == path }.count
  }

  func query(forPath path: String, name: String) -> String? {
    calls.first { $0.path == path }?.query[name]
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(
      items.compactMap { item in item.value.map { (item.name, $0) } },
      uniquingKeysWith: { first, _ in first }
    )
    calls.append((url.path, query))

    if let code = errors[url.path] {
      return ok(#"{"ok":false,"error":"\#(code)"}"#, url)
    }

    switch url.path {
    case "/api/users.list":
      return ok(
        #"{"ok":true,"members":[{"id":"U_JANE","name":"jane.doe","profile":{"display_name":"jane"}},"#
          + #"{"id":"U_RAVI","name":"ravi","profile":{"display_name":"ravi"}},"#
          + #"{"id":"U_ME","name":"adarsh","profile":{"display_name":"adarsh"}}]}"#,
        url
      )
    case "/api/conversations.info":
      return ok(#"{"ok":true,"channel":{"id":"C_ENG","name":"eng-platform"}}"#, url)
    case "/api/conversations.replies":
      if throttleFirstRepliesCall {
        throttleFirstRepliesCall = false
        return (
          Data(),
          HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!
        )
      }
      return ok(repliesPayload, url)
    case "/api/conversations.history":
      return ok(query["latest"] != nil ? historyBefore : historyAfter, url)
    default:
      return ok(#"{"ok":true}"#, url)
    }
  }

  private func ok(_ json: String, _ url: URL) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
