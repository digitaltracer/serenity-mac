import XCTest
@testable import SerenityMac

final class SlackMessageReaderTests: XCTestCase {
  func testHistoryPagesAreFollowedAndTheCursorLandsOnTheNewestMessage() async throws {
    let slack = FakeSlack()
    await slack.setPages([
      #"{"ok":true,"messages":[{"ts":"300.0","user":"U_JANE","text":"third"}],"response_metadata":{"next_cursor":"page2"}}"#,
      #"{"ok":true,"messages":[{"ts":"200.0","user":"U_ME","text":"second"},{"ts":"100.0","user":"U_JANE","text":"first"}]}"#,
    ])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let batch = try await reader.fetchNewActivity(session: session(), cursors: [])

    XCTAssertEqual(batch.messages.map(\.ts), ["100.0", "200.0", "300.0"])
    XCTAssertEqual(batch.cursors.first?.lastTS, "300.0")
    XCTAssertEqual(batch.channelsScanned, 1)
  }

  func testYourOwnMessagesAreFlagged() async throws {
    let slack = FakeSlack()
    await slack.setPages([
      #"{"ok":true,"messages":[{"ts":"200.0","user":"U_ME","text":"mine"},{"ts":"100.0","user":"U_JANE","text":"theirs"}]}"#,
    ])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let batch = try await reader.fetchNewActivity(session: session(), cursors: [])

    XCTAssertEqual(batch.messages.first { $0.ts == "200.0" }?.isOwn, true)
    XCTAssertEqual(batch.messages.first { $0.ts == "100.0" }?.isOwn, false)
  }

  func testDisplayNamesReplaceRawUserIDs() async throws {
    let slack = FakeSlack()
    await slack.setPages([#"{"ok":true,"messages":[{"ts":"100.0","user":"U_JANE","text":"hi"}]}"#])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let batch = try await reader.fetchNewActivity(session: session(), cursors: [])

    XCTAssertEqual(batch.messages.first?.authorName, "jane")
  }

  func testAnExistingCursorIsSentAsOldestSoNothingIsReread() async throws {
    let slack = FakeSlack()
    await slack.setPages([#"{"ok":true,"messages":[{"ts":"400.0","user":"U_JANE","text":"newer"}]}"#])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let cursor = SlackChannelCursor(channelID: "C_ENG", channelName: "eng-platform", lastTS: "300.0")
    _ = try await reader.fetchNewActivity(session: session(), cursors: [cursor])

    let oldest = await slack.query(forPath: "/api/conversations.history", name: "oldest")
    XCTAssertEqual(oldest, "300.0")
  }

  func testThrottlingIsWaitedOutRatherThanTreatedAsFailure() async throws {
    let slack = FakeSlack()
    await slack.setThrottleFirstHistoryCall(true)
    await slack.setPages([#"{"ok":true,"messages":[{"ts":"100.0","user":"U_JANE","text":"survived"}]}"#])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let batch = try await reader.fetchNewActivity(session: session(), cursors: [])

    XCTAssertEqual(batch.messages.map(\.ts), ["100.0"])
    let calls = await slack.count(forPath: "/api/conversations.history")
    XCTAssertEqual(calls, 2, "The throttled call is retried, not skipped")
  }

  func testRepliesAreFetchedForThreadsYouHavePostedIn() async throws {
    let slack = FakeSlack()
    await slack.setPages([
      #"{"ok":true,"messages":[{"ts":"100.0","user":"U_JANE","text":"parent","reply_count":2,"latest_reply":"250.0"}]}"#,
    ])
    await slack.setReplies(
      #"{"ok":true,"messages":[{"ts":"250.0","user":"U_RAVI","text":"pushed to Friday","thread_ts":"100.0"}]}"#
    )

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let cursor = SlackChannelCursor(
      channelID: "C_ENG",
      channelName: "eng-platform",
      lastTS: "50.0",
      participatedThreadTS: ["100.0"]
    )

    let batch = try await reader.fetchNewActivity(session: session(), cursors: [cursor])

    XCTAssertTrue(batch.messages.contains { $0.ts == "250.0" })
    let replyCalls = await slack.count(forPath: "/api/conversations.replies")
    XCTAssertEqual(replyCalls, 1)
  }

  func testThreadsYouHaveNeverTouchedAreNotFetched() async throws {
    let slack = FakeSlack()
    await slack.setPages([
      #"{"ok":true,"messages":[{"ts":"100.0","user":"U_JANE","text":"parent","reply_count":2,"latest_reply":"250.0"}]}"#,
    ])

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let cursor = SlackChannelCursor(channelID: "C_ENG", channelName: "eng-platform", lastTS: "50.0")
    _ = try await reader.fetchNewActivity(session: session(), cursors: [cursor])

    let replyCalls = await slack.count(forPath: "/api/conversations.replies")
    XCTAssertEqual(replyCalls, 0)
  }

  func session() -> SlackIntegrationSession {
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
}

private actor FakeSlack {
  private var historyPages: [String] = []
  private var repliesPayload = #"{"ok":true,"messages":[]}"#
  private var userGroupsPayload = #"{"ok":true,"usergroups":[]}"#
  private var throttleFirstHistoryCall = false
  private var calls: [(path: String, query: [String: String])] = []

  func setPages(_ pages: [String]) {
    historyPages = pages
  }

  func setReplies(_ payload: String) {
    repliesPayload = payload
  }

  func setUserGroups(_ payload: String) {
    userGroupsPayload = payload
  }

  func setThrottleFirstHistoryCall(_ value: Bool) {
    throttleFirstHistoryCall = value
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
    let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
    calls.append((url.path, query))

    switch url.path {
    case "/api/users.conversations":
      return ok(#"{"ok":true,"channels":[{"id":"C_ENG","name":"eng-platform"}]}"#, url)
    case "/api/users.list":
      return ok(
        #"{"ok":true,"members":[{"id":"U_JANE","name":"jane.doe","profile":{"display_name":"jane"}},"#
          + #"{"id":"U_ME","name":"adarsh","profile":{"display_name":"adarsh"}}]}"#,
        url
      )
    case "/api/conversations.history":
      if throttleFirstHistoryCall {
        throttleFirstHistoryCall = false
        return (
          Data(),
          HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!
        )
      }
      let index = query["cursor"] == "page2" ? 1 : 0
      return ok(historyPages.indices.contains(index) ? historyPages[index] : #"{"ok":true,"messages":[]}"#, url)
    case "/api/conversations.replies":
      return ok(repliesPayload, url)
    case "/api/usergroups.list":
      return ok(userGroupsPayload, url)
    default:
      return ok(#"{"ok":true}"#, url)
    }
  }

  private func ok(_ json: String, _ url: URL) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

extension SlackMessageReaderTests {
  func testOnlyTheGroupsYouBelongToCount() async throws {
    let slack = FakeSlack()
    await slack.setUserGroups(
      #"{"ok":true,"usergroups":[{"id":"S_PLATFORM","users":["U_ME","U_JANE"]},{"id":"S_DESIGN","users":["U_RAVI"]}]}"#
    )

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let groups = await reader.ownGroups(session: session())

    XCTAssertEqual(groups, ["S_PLATFORM"])
  }

  func testAMissingUserGroupsScopeDoesNotFailTheSync() async throws {
    let slack = FakeSlack()
    await slack.setUserGroups(#"{"ok":false,"error":"missing_scope"}"#)

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let groups = await reader.ownGroups(session: session())

    XCTAssertTrue(groups.isEmpty)
  }
}
