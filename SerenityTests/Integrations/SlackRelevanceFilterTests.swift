import XCTest
@testable import SerenityMac

final class SlackRelevanceFilterTests: XCTestCase {
  private let me = "U_ME"

  func testAMentionOfYouBecomesASignal() {
    let result = filter([message(ts: "1.0", user: "U_JANE", text: "hey <@U_ME> can you ship the export by Friday")])

    XCTAssertEqual(result.signals.count, 1)
    XCTAssertEqual(result.signals.first?.anchor.ts, "1.0")
    XCTAssertTrue(result.rejected.isEmpty)
  }

  func testAMentionOfSomeoneElseIsRejected() {
    let result = filter([message(ts: "1.0", user: "U_JANE", text: "<@U_RAVI> can you take this one")])

    XCTAssertTrue(result.signals.isEmpty)
    XCTAssertEqual(result.rejected.count, 1)
  }

  func testAGroupMentionYouBelongToBecomesASignal() {
    let result = filter(
      [message(ts: "1.0", user: "U_JANE", text: "<!subteam^S_PLATFORM|@platform> please review")],
      groupIDs: ["S_PLATFORM"]
    )

    XCTAssertEqual(result.signals.count, 1)
  }

  func testAGroupMentionYouDoNotBelongToIsRejected() {
    let result = filter(
      [message(ts: "1.0", user: "U_JANE", text: "<!subteam^S_DESIGN|@design> please review")],
      groupIDs: ["S_PLATFORM"]
    )

    XCTAssertTrue(result.signals.isEmpty)
  }

  func testARepliesInAThreadYouPostedInBecomesASignal() {
    let result = filter(
      [message(ts: "2.0", user: "U_JANE", text: "pushed it to next week", threadTS: "1.0")],
      participatedThreads: ["1.0"]
    )

    XCTAssertEqual(result.signals.count, 1)
  }

  func testAReplyInAThreadYouAreNotInIsRejected() {
    let result = filter(
      [message(ts: "2.0", user: "U_JANE", text: "pushed it to next week", threadTS: "9.0")],
      participatedThreads: ["1.0"]
    )

    XCTAssertTrue(result.signals.isEmpty)
    XCTAssertEqual(result.rejected.count, 1)
  }

  func testYourOwnMessageNeverAnchorsButStillTravelsAsContext() {
    let result = filter([
      message(ts: "1.0", user: me, text: "I'll take the export <@U_ME>", threadTS: "1.0"),
      message(ts: "2.0", user: "U_JANE", text: "thanks <@U_ME>, due Friday", threadTS: "1.0"),
    ])

    XCTAssertEqual(result.signals.count, 1)
    XCTAssertEqual(result.signals.first?.anchor.ts, "2.0")
    XCTAssertEqual(result.signals.first?.context.map(\.ts), ["1.0"])
  }

  func testBotMessagesAreSkippedUnlessAskedFor() {
    let messages = [message(ts: "1.0", user: "B_JIRA", text: "<@U_ME> assigned PROJ-12", isBot: true)]

    XCTAssertTrue(filter(messages).signals.isEmpty)

    let permissive = filter(
      messages,
      settings: SlackRelevanceSettings(includeBroadcastMentions: false, includeBotMessages: true)
    )
    XCTAssertEqual(permissive.signals.count, 1)
  }

  func testHousekeepingSubtypesAreSkipped() {
    let result = filter([
      message(ts: "1.0", user: "U_JANE", text: "<@U_ME> has joined the channel", subtype: "channel_join"),
    ])

    XCTAssertTrue(result.signals.isEmpty)
  }

  func testBroadcastMentionsOnlyCountWhenEnabled() {
    let messages = [message(ts: "1.0", user: "U_JANE", text: "<!channel> deploy freeze starts Monday")]

    XCTAssertTrue(filter(messages).signals.isEmpty)

    let permissive = filter(
      messages,
      settings: SlackRelevanceSettings(includeBroadcastMentions: true, includeBotMessages: false)
    )
    XCTAssertEqual(permissive.signals.count, 1)
  }

  func testAlreadySeenMessagesAreSkippedEntirely() {
    let seen = message(ts: "1.0", user: "U_JANE", text: "<@U_ME> ping")
    let result = filter([seen], seenKeys: [seen.id])

    XCTAssertTrue(result.signals.isEmpty)
    XCTAssertTrue(result.rejected.isEmpty, "A seen message must not be re-recorded")
  }

  func testChannelContextTakesTheNeighbouringMessages() {
    var messages: [SlackMessage] = []
    for index in 1...9 {
      messages.append(message(ts: "\(index).0", user: "U_JANE", text: "line \(index)"))
    }
    messages[4] = message(ts: "5.0", user: "U_JANE", text: "<@U_ME> look at this")

    let result = filter(messages)

    XCTAssertEqual(result.signals.count, 1)
    XCTAssertEqual(result.signals.first?.context.map(\.ts), ["2.0", "3.0", "4.0", "6.0", "7.0", "8.0"])
  }

  func testOversizedContextIsTrimmedFromTheMiddle() {
    let filler = String(repeating: "x", count: 1500)
    let messages = [
      message(ts: "1.0", user: "U_JANE", text: "opener", threadTS: "1.0"),
      message(ts: "2.0", user: "U_JANE", text: filler, threadTS: "1.0"),
      message(ts: "3.0", user: "U_JANE", text: filler, threadTS: "1.0"),
      message(ts: "4.0", user: "U_JANE", text: filler, threadTS: "1.0"),
      message(ts: "5.0", user: "U_JANE", text: "newest", threadTS: "1.0"),
      message(ts: "6.0", user: "U_RAVI", text: "<@U_ME> what is the status", threadTS: "1.0"),
    ]

    let context = try? XCTUnwrap(filter(messages).signals.first).context
    let kept = try? XCTUnwrap(context)

    XCTAssertEqual(kept?.first?.ts, "1.0", "The thread opener carries the original ask")
    XCTAssertEqual(kept?.last?.ts, "5.0", "The newest reply carries the decision")
    XCTAssertLessThanOrEqual(
      kept?.reduce(0) { $0 + $1.text.count } ?? .max,
      SlackRelevanceFilter.contextCharacterBudget
    )
  }

  private func filter(
    _ messages: [SlackMessage],
    groupIDs: Set<String> = [],
    participatedThreads: Set<String> = [],
    seenKeys: Set<String> = [],
    settings: SlackRelevanceSettings = .default
  ) -> SlackFilterResult {
    SlackRelevanceFilter.filter(
      messages: messages,
      ownUserID: me,
      ownGroupIDs: groupIDs,
      participatedThreads: participatedThreads,
      seenKeys: seenKeys,
      settings: settings
    )
  }

  private func message(
    ts: String,
    user: String,
    text: String,
    threadTS: String? = nil,
    isBot: Bool = false,
    subtype: String? = nil
  ) -> SlackMessage {
    SlackMessage(
      channelID: "C_ENG",
      channelName: "eng-platform",
      ts: ts,
      threadTS: threadTS,
      userID: user,
      authorName: user,
      text: text,
      isOwn: user == me,
      isBot: isBot,
      subtype: subtype,
      permalink: nil
    )
  }
}

extension SlackRelevanceFilterTests {
  func testAThreadBecomesOneSignalRatherThanOnePerReply() {
    let messages = [
      message(ts: "1.0", user: "U_JANE", text: "can we ship the release?", threadTS: "1.0"),
      message(ts: "2.0", user: "U_JANE", text: "any update?", threadTS: "1.0"),
      message(ts: "3.0", user: "U_RAVI", text: "merging tonight", threadTS: "1.0"),
    ]

    let result = SlackRelevanceFilter.filter(
      messages: messages,
      ownUserID: "U_ME",
      participatedThreads: ["1.0"]
    )

    XCTAssertEqual(result.signals.count, 1, "One conversation is one piece of work")
    XCTAssertEqual(result.signals.first?.anchor.ts, "3.0", "The newest reply carries the current state")
    XCTAssertEqual(
      result.signals.first?.seenCandidates.map(\.ts),
      ["1.0", "2.0", "3.0"],
      "Every collapsed reply must be marked seen, or it anchors again next pass"
    )
  }

  func testSeparateThreadsStaySeparateSignals() {
    let messages = [
      message(ts: "2.0", user: "U_JANE", text: "update on A?", threadTS: "1.0"),
      message(ts: "4.0", user: "U_JANE", text: "update on B?", threadTS: "3.0"),
    ]

    let result = SlackRelevanceFilter.filter(
      messages: messages,
      ownUserID: "U_ME",
      participatedThreads: ["1.0", "3.0"]
    )

    XCTAssertEqual(result.signals.count, 2)
  }

  func testUnthreadedChannelMentionsStayIndividual() {
    let messages = [
      message(ts: "1.0", user: "U_JANE", text: "<@U_ME> ship the export"),
      message(ts: "2.0", user: "U_RAVI", text: "<@U_ME> also review the doc"),
    ]

    let result = SlackRelevanceFilter.filter(messages: messages, ownUserID: "U_ME")

    XCTAssertEqual(result.signals.count, 2, "Unrelated asks are not one conversation")
  }
}
