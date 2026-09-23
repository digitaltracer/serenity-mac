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

extension SlackMessageReaderTests {
  /// One channel you were removed from must not cost every other channel its cursor.
  func testAFailingChannelKeepsItsCursorAndTheOthersAdvance() async throws {
    let slack = ChannelSlack(channels: ["C_OK": "eng", "C_GONE": "old-team"])
    await slack.setHistory("C_OK", #"{"ok":true,"messages":[{"ts":"300.0","user":"U_JANE","text":"hello"}]}"#)
    await slack.setHistory("C_GONE", #"{"ok":false,"error":"not_in_channel"}"#)

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let cursors = [
      SlackChannelCursor(channelID: "C_OK", channelName: "eng", lastTS: "100.0"),
      SlackChannelCursor(channelID: "C_GONE", channelName: "old-team", lastTS: "90.0"),
    ]
    let batch = try await reader.fetchNewActivity(session: session(), cursors: cursors)

    let byChannel = Dictionary(uniqueKeysWithValues: batch.cursors.map { ($0.channelID, $0.lastTS) })
    XCTAssertEqual(byChannel["C_OK"], "300.0")
    XCTAssertEqual(byChannel["C_GONE"], "90.0")
    XCTAssertEqual(batch.failures.map(\.channelID), ["C_GONE"])
    XCTAssertEqual(batch.messages.map(\.ts), ["300.0"])
  }

  func testARevokedTokenStillFailsTheWholePass() async {
    let slack = ChannelSlack(channels: ["C_OK": "eng"])
    await slack.setHistory("C_OK", #"{"ok":false,"error":"token_revoked"}"#)

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    do {
      _ = try await reader.fetchNewActivity(session: session(), cursors: [])
      XCTFail("Expected the pass to throw")
    } catch {
      XCTAssertNotNil(error as? IntegrationServiceError)
    }
  }

  /// History only lists parents inside the window, so an older thread you replied in is read by id.
  func testRepliesUnderAnOlderThreadYouJoinedAreStillRead() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let slack = ChannelSlack(channels: ["C_OK": "eng"])
    await slack.setHistory("C_OK", #"{"ok":true,"messages":[]}"#)
    await slack.setReplies(
      "1000000.0",
      #"{"ok":true,"messages":[{"ts":"1000000.0","user":"U_ME","text":"parent"},"#
        + #"{"ts":"1995000.0","user":"U_JANE","text":"any update?","thread_ts":"1000000.0"}]}"#
    )

    let reader = SlackMessageReader(client: SlackAPIClient(requestHandler: { try await slack.respond(to: $0) }))
    let cursor = SlackChannelCursor(
      channelID: "C_OK",
      channelName: "eng",
      lastTS: "1990000.0",
      // Inside the two-week horizon, and one well past it.
      participatedThreadTS: ["1000000.0", "500000.0"]
    )
    let batch = try await reader.fetchNewActivity(session: session(), cursors: [cursor], now: now)

    XCTAssertEqual(batch.messages.map(\.ts), ["1995000.0"], "The old parent is not re-read as new")
    let threadsRead = await slack.threadsRead()
    XCTAssertEqual(threadsRead, ["1000000.0"])
    XCTAssertEqual(batch.cursors.first?.participatedThreadTS, ["1000000.0"], "A thread past the horizon is dropped")
  }
}

private actor ChannelSlack {
  private let channels: [String: String]
  private var history: [String: String] = [:]
  private var replies: [String: String] = [:]
  private var repliesRequested: [String] = []

  init(channels: [String: String]) {
    self.channels = channels
  }

  func setHistory(_ channelID: String, _ payload: String) {
    history[channelID] = payload
  }

  func setReplies(_ threadTS: String, _ payload: String) {
    replies[threadTS] = payload
  }

  func threadsRead() -> [String] {
    repliesRequested
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })

    let json: String
    switch url.path {
    case "/api/users.conversations":
      let list = channels.keys.sorted().map { #"{"id":"\#($0)","name":"\#(channels[$0]!)"}"# }.joined(separator: ",")
      json = #"{"ok":true,"channels":[\#(list)]}"#
    case "/api/users.list":
      json = #"{"ok":true,"members":[]}"#
    case "/api/conversations.history":
      json = history[query["channel"] ?? ""] ?? #"{"ok":true,"messages":[]}"#
    case "/api/conversations.replies":
      let ts = query["ts"] ?? ""
      repliesRequested.append(ts)
      json = replies[ts] ?? #"{"ok":true,"messages":[]}"#
    default:
      json = #"{"ok":true}"#
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
