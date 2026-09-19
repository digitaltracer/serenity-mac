import XCTest
@testable import SerenityMac

final class CaptureCommandParserTests: XCTestCase {
  private let permalink = "https://acme.slack.com/archives/C05QJ1X2Y/p1726742400123456"
  private let prLink = "https://github.com/acme/api/pull/812"

  private func slackReference(_ command: CaptureCommand?, at index: Int = 0) throws -> SlackConversationReference {
    let references = try XCTUnwrap(command?.references)
    return try XCTUnwrap(references[index].slackReference, "expected a Slack reference at \(index)")
  }

  private func githubReference(_ command: CaptureCommand?, at index: Int = 0) throws -> GitHubPullReference {
    let references = try XCTUnwrap(command?.references)
    return try XCTUnwrap(references[index].githubReference, "expected a GitHub reference at \(index)")
  }

  private func assertThrows(
    _ expected: CaptureCommandParseError,
    _ input: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try CaptureCommandParser.parse(input), file: file, line: line) { error in
      XCTAssertEqual(error as? CaptureCommandParseError, expected, file: file, line: line)
    }
  }

  // MARK: - Falling through

  func testPlainTextIsNotACommand() throws {
    XCTAssertNil(try CaptureCommandParser.parse("call the bank tomorrow at 3pm"))
  }

  func testJournalPrefixStillFallsThrough() throws {
    XCTAssertNil(try CaptureCommandParser.parse("journal: shipped the retry work today"))
  }

  func testCommandWordMustStandAlone() throws {
    XCTAssertNil(try CaptureCommandParser.parse("/slackers are people too"))
    XCTAssertNil(try CaptureCommandParser.parse("/githubbing the release notes"))
  }

  func testCommandWordIsCaseInsensitive() throws {
    let reference = try slackReference(try CaptureCommandParser.parse("/SLACK \(permalink)"))
    XCTAssertEqual(reference.channelID, "C05QJ1X2Y")
  }

  // MARK: - Slack links

  func testPermalinkRecoversTheTimestamp() throws {
    let reference = try slackReference(try CaptureCommandParser.parse("/slack \(permalink)"))

    XCTAssertEqual(reference.channelID, "C05QJ1X2Y")
    XCTAssertEqual(reference.linkedTS, "1726742400.123456")
    XCTAssertEqual(reference.threadRootTS, "1726742400.123456")
    XCTAssertEqual(reference.workspaceHost, "acme.slack.com")
  }

  /// The parser is the inverse of the permalink builder, so the two are pinned
  /// to each other rather than to a hand-written expectation.
  func testRoundTripsAgainstThePermalinkBuilder() throws {
    let built = try XCTUnwrap(
      SlackMessage.permalink(
        workspaceURL: "https://acme.slack.com",
        channelID: "C05QJ1X2Y",
        ts: "1726742400.123456"
      )
    )

    let reference = try slackReference(try CaptureCommandParser.parse("/slack \(built)"))
    XCTAssertEqual(reference.channelID, "C05QJ1X2Y")
    XCTAssertEqual(reference.linkedTS, "1726742400.123456")
  }

  func testThreadTimestampBecomesTheRootAndTheLinkedMessageIsKept() throws {
    let link = "\(permalink)?thread_ts=1726740000.111222&cid=C05QJ1X2Y"
    let reference = try slackReference(try CaptureCommandParser.parse("/slack \(link)"))

    XCTAssertEqual(reference.threadRootTS, "1726740000.111222", "a link to a reply roots at thread_ts")
    XCTAssertEqual(reference.linkedTS, "1726742400.123456", "the message the user pointed at is not lost")
  }

  func testMalformedThreadTimestampFallsBackToTheLinkedMessage() throws {
    let link = "\(permalink)?thread_ts=not-a-timestamp"
    let reference = try slackReference(try CaptureCommandParser.parse("/slack \(link)"))

    XCTAssertEqual(reference.threadRootTS, "1726742400.123456")
  }

  func testPrivateChannelLinkIsAccepted() throws {
    let link = "https://acme.slack.com/archives/G01PRIVATE/p1726742400123456"
    let reference = try slackReference(try CaptureCommandParser.parse("/slack \(link)"))

    XCTAssertEqual(reference.channelID, "G01PRIVATE")
  }

  func testDirectMessageLinkIsRefused() {
    assertThrows(.directMessage, "/slack https://acme.slack.com/archives/D01ABCDEF/p1726742400123456")
  }

  func testChannelWithoutAMessageIsRefused() {
    assertThrows(.channelWithoutMessage, "/slack https://acme.slack.com/archives/C05QJ1X2Y")
  }

  func testTimestampTooShortToCarryMicrosecondsIsRefused() {
    assertThrows(
      .malformedLink("https://acme.slack.com/archives/C05QJ1X2Y/p123456"),
      "/slack https://acme.slack.com/archives/C05QJ1X2Y/p123456"
    )
  }

  func testNonArchivePathIsRefused() {
    assertThrows(
      .malformedLink("https://acme.slack.com/team/U024BE7LH"),
      "/slack https://acme.slack.com/team/U024BE7LH"
    )
  }

  // MARK: - GitHub links

  func testPullRequestLink() throws {
    let reference = try githubReference(try CaptureCommandParser.parse("/github \(prLink)"))

    XCTAssertEqual(reference.owner, "acme")
    XCTAssertEqual(reference.repo, "api")
    XCTAssertEqual(reference.number, 812)
    XCTAssertTrue(reference.isPullRequest)
    XCTAssertEqual(reference.slug, "acme/api#812")
  }

  func testEverythingPastTheNumberIsDiscarded() throws {
    for suffix in ["/files", "/commits", "#discussion_r1842", "#issuecomment-2384", "/files#diff-abc", "?w=1"] {
      let reference = try githubReference(try CaptureCommandParser.parse("/github \(prLink)\(suffix)"))
      XCTAssertEqual(reference.number, 812, "suffix \(suffix) changed the pull request")
    }
  }

  func testIssueLinkIsAcceptedAndMarked() throws {
    let reference = try githubReference(
      try CaptureCommandParser.parse("/github https://github.com/acme/api/issues/455")
    )

    XCTAssertEqual(reference.number, 455)
    XCTAssertFalse(reference.isPullRequest)
  }

  func testEnterpriseHostIsRefusedByName() {
    assertThrows(
      .enterpriseHost("github.acme-corp.com"),
      "/github https://github.acme-corp.com/acme/api/pull/812"
    )
  }

  func testRepositoryRootIsRefused() {
    assertThrows(
      .malformedLink("https://github.com/acme/api"),
      "/github https://github.com/acme/api"
    )
  }

  func testNonNumericPullNumberIsRefused() {
    assertThrows(
      .malformedLink("https://github.com/acme/api/pull/new"),
      "/github https://github.com/acme/api/pull/new"
    )
  }

  // MARK: - Links and prose together

  func testTrailingProseBecomesContext() throws {
    let command = try CaptureCommandParser.parse("/slack \(permalink) needs to land before the demo")

    XCTAssertEqual(command?.references.count, 1)
    XCTAssertEqual(command?.context, "needs to land before the demo")
  }

  func testProseBeforeAndAfterKeepsItsOrder() throws {
    let command = try CaptureCommandParser.parse("/github urgent \(prLink) before Friday")

    XCTAssertEqual(command?.context, "urgent before Friday")
  }

  func testSeveralLinksAreAllKept() throws {
    let command = try CaptureCommandParser.parse(
      "/github \(prLink) https://github.com/acme/api/pull/815 both need review comments addressed"
    )

    XCTAssertEqual(command?.references.count, 2)
    XCTAssertEqual(try githubReference(command, at: 1).number, 815)
    XCTAssertEqual(command?.context, "both need review comments addressed")
  }

  func testLinkEndingASentenceStillParses() throws {
    let command = try CaptureCommandParser.parse("/github please look at \(prLink).")

    XCTAssertEqual(try githubReference(command).number, 812)
    XCTAssertEqual(command?.context, "please look at")
  }

  func testAngleWrappedLinkStillParses() throws {
    let reference = try slackReference(try CaptureCommandParser.parse("/slack <\(permalink)>"))

    XCTAssertEqual(reference.channelID, "C05QJ1X2Y")
  }

  func testParenthesisedLinkKeepsABalancedPair() throws {
    let command = try CaptureCommandParser.parse("/github (\(prLink))")

    XCTAssertEqual(try githubReference(command).number, 812)
  }

  func testUnrelatedLinkInTheProseIsJustContext() throws {
    let command = try CaptureCommandParser.parse("/github \(prLink) see also https://example.com/spec")

    XCTAssertEqual(command?.references.count, 1)
    XCTAssertEqual(command?.context, "see also https://example.com/spec")
  }

  /// A foreign link alongside a good one is context; a foreign link *alone* is
  /// the user having reached for the wrong command.
  func testForeignLinkAlongsideAGoodOneIsContext() throws {
    let command = try CaptureCommandParser.parse("/github \(prLink) discussed in \(permalink)")

    XCTAssertEqual(command?.references.count, 1)
    XCTAssertTrue(command?.context.contains(permalink) == true)
  }

  func testOnlyAForeignLinkNamesTheRightCommand() {
    assertThrows(.wrongProvider(expected: .github), "/github \(permalink)")
    assertThrows(.wrongProvider(expected: .slack), "/slack \(prLink)")
  }

  // MARK: - Limits

  func testCommandWithNoLinksIsRefused() {
    assertThrows(.noLinks(.slack), "/slack")
    assertThrows(.noLinks(.github), "/github the one about retries")
  }

  func testMoreLinksThanTheLimitIsReportedNotTruncated() {
    let links = (1...6).map { "https://github.com/acme/api/pull/\($0)" }.joined(separator: " ")

    assertThrows(.tooManyLinks(limit: CaptureCommandParser.referenceLimit), "/github \(links)")
  }

  func testLimitItselfIsAllowed() throws {
    let links = (1...CaptureCommandParser.referenceLimit)
      .map { "https://github.com/acme/api/pull/\($0)" }
      .joined(separator: " ")
    let command = try CaptureCommandParser.parse("/github \(links)")

    XCTAssertEqual(command?.references.count, CaptureCommandParser.referenceLimit)
  }

  // MARK: - Messages

  func testEveryRefusalExplainsItself() {
    let errors: [CaptureCommandParseError] = [
      .noLinks(.slack), .noLinks(.github), .directMessage, .channelWithoutMessage,
      .enterpriseHost("github.acme-corp.com"), .wrongProvider(expected: .slack),
      .wrongProvider(expected: .github), .tooManyLinks(limit: 5), .malformedLink("https://x.test"),
    ]

    for error in errors {
      let message = error.errorDescription ?? ""
      XCTAssertFalse(message.isEmpty, "\(error) has no message")
    }
  }
}

private extension CaptureReference {
  var slackReference: SlackConversationReference? {
    guard case .slack(let reference) = self else { return nil }
    return reference
  }

  var githubReference: GitHubPullReference? {
    guard case .github(let reference) = self else { return nil }
    return reference
  }
}
