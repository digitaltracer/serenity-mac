import XCTest
@testable import SerenityMac

/// Fixture-driven through the same injectable request handler the sync uses, so
/// nothing here touches the network.
@MainActor
final class GitHubPullFetchTests: XCTestCase {
  private func reference(number: Int = 812, isPullRequest: Bool = true) -> GitHubPullReference {
    GitHubPullReference(owner: "acme", repo: "api", number: number, isPullRequest: isPullRequest)
  }

  /// `addToken` validates against `/user`, so the fake has to answer that too
  /// before any pull request can be read.
  private func service(
    tokens: [String] = ["ghp_one"],
    _ github: FakeGitHub
  ) async throws -> GitHubIntegrationService {
    let store = KeychainSecretStore(service: "test.integrations", backend: InMemorySecretStorageBackend())
    let service = GitHubIntegrationService(
      secretStore: store,
      requestHandler: { try await github.respond(to: $0) }
    )

    for token in tokens {
      _ = try await service.addToken(token, displayName: token)
    }
    return service
  }

  // MARK: - The whole picture

  func testAPullRequestComesBackWithEverythingADraftNeeds() async throws {
    let github = FakeGitHub()
    await github.setIssue(
      #"{"id":990001,"title":"Add retry backoff","body":"Wraps the client in a retry.","state":"open","#
        + #""html_url":"https://github.com/acme/api/pull/812","created_at":"2026-09-15T09:00:00Z","#
        + #""updated_at":"2026-09-17T10:22:04Z","labels":[{"name":"bug"},{"name":"api"}],"#
        + #""assignees":[{"login":"adarsh"}],"#
        + #""milestone":{"title":"0.9 hardening","due_on":"2026-09-22T07:00:00Z"}}"#
    )
    await github.setPull(
      #"{"draft":false,"merged":false,"changed_files":4,"requested_reviewers":[{"login":"priya"}]}"#
    )
    await github.setReviews(
      #"[{"user":{"login":"priya"},"state":"CHANGES_REQUESTED","body":"handle the null case","#
        + #""submitted_at":"2026-09-17T10:00:00Z"}]"#
    )
    await github.setComments(
      #"[{"user":{"login":"ravi"},"body":"also needs a test for the 429 path","created_at":"2026-09-17T11:00:00Z"}]"#
    )
    await github.setFiles(#"[{"filename":"Sources/Client.swift"},{"filename":"Tests/ClientTests.swift"}]"#)

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.title, "Add retry backoff")
    XCTAssertEqual(snapshot.state, "open")
    XCTAssertEqual(snapshot.labels, ["bug", "api"])
    XCTAssertEqual(snapshot.assignees, ["adarsh"])
    XCTAssertEqual(snapshot.requestedReviewers, ["priya"])
    XCTAssertEqual(snapshot.changedFileCount, 4)
    XCTAssertEqual(snapshot.changedFileNames, ["Sources/Client.swift", "Tests/ClientTests.swift"])
    XCTAssertEqual(snapshot.reviews.first?.reviewer, "priya")
    XCTAssertTrue(snapshot.reviews.first?.requestsChanges == true)
    XCTAssertEqual(snapshot.comments.first?.body, "also needs a test for the 429 path")
    XCTAssertEqual(snapshot.slug, "acme/api#812")
  }

  /// The id the sync tags with comes from the search API, which returns issue
  /// objects. Taking the pull id instead would never collide with a task the
  /// sync had already made, and the same PR would exist twice.
  func testTheOriginTagUsesTheIssueIDNotThePullID() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue(id: 990001))
    await github.setPull(#"{"id":555999,"draft":false,"merged":false,"changed_files":1}"#)

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.issueID, 990001)
    XCTAssertEqual(snapshot.originTag, "github-pr-990001")
  }

  func testTheMilestoneDueDateIsCarriedThrough() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue(milestone: #","milestone":{"title":"0.9","due_on":"2026-09-22T07:00:00Z"}"#))

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.milestoneTitle, "0.9")
    XCTAssertEqual(snapshot.milestoneDueOn, ISO8601DateFormatter().date(from: "2026-09-22T07:00:00Z"))
  }

  func testNoMilestoneMeansNoDeadlineToInvent() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertNil(snapshot.milestoneDueOn)
  }

  func testDraftAndMergedFlagsAreRead() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setPull(#"{"draft":true,"merged":true,"changed_files":2}"#)

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertTrue(snapshot.isDraft)
    XCTAssertTrue(snapshot.isMerged)
  }

  func testAnEmptyBodyLeavesTheFileListCarryingTheDescription() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue(body: "   "))
    await github.setFiles(#"[{"filename":"Sources/Retry.swift"}]"#)

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertNil(snapshot.body)
    XCTAssertEqual(snapshot.changedFileNames, ["Sources/Retry.swift"])
  }

  // MARK: - Reviews

  /// GitHub's own review decision counts the latest *verdict* per reviewer, so a
  /// reviewer who requested changes and then left a plain comment is still
  /// blocking.
  func testALaterPlainCommentDoesNotClearAnEarlierVerdict() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setReviews(
      #"[{"user":{"login":"priya"},"state":"CHANGES_REQUESTED","body":"null case","submitted_at":"2026-09-17T10:00:00Z"},"#
        + #"{"user":{"login":"priya"},"state":"COMMENTED","body":"bumping this","submitted_at":"2026-09-18T10:00:00Z"}]"#
    )

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.reviews.count, 1)
    XCTAssertTrue(snapshot.reviews.first?.requestsChanges == true)
  }

  func testALaterVerdictReplacesTheEarlierOne() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setReviews(
      #"[{"user":{"login":"priya"},"state":"CHANGES_REQUESTED","submitted_at":"2026-09-17T10:00:00Z"},"#
        + #"{"user":{"login":"priya"},"state":"APPROVED","submitted_at":"2026-09-18T10:00:00Z"}]"#
    )

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.reviews.count, 1)
    XCTAssertTrue(snapshot.reviews.first?.approves == true)
  }

  func testEveryReviewerKeepsTheirOwnVerdict() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setReviews(
      #"[{"user":{"login":"priya"},"state":"APPROVED","submitted_at":"2026-09-17T10:00:00Z"},"#
        + #"{"user":{"login":"ravi"},"state":"CHANGES_REQUESTED","submitted_at":"2026-09-17T11:00:00Z"}]"#
    )

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.reviews.map(\.reviewer), ["priya", "ravi"])
  }

  func testOnlyTheMostRecentCommentsAreKept() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    let many = (1...40)
      .map { #"{"user":{"login":"ravi"},"body":"note \#($0)"}"# }
      .joined(separator: ",")
    await github.setComments("[\(many)]")

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.comments.count, GitHubIntegrationService.commentLimit)
    XCTAssertEqual(snapshot.comments.last?.body, "note 40", "the newest end is the end worth keeping")
  }

  // MARK: - Issues

  func testAnIssueLinkSkipsThePullEndpoints() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue(id: 770001))

    let snapshot = try await service(github).fetchPullRequest(reference(number: 455, isPullRequest: false))

    XCTAssertFalse(snapshot.isPullRequest)
    XCTAssertEqual(snapshot.issueID, 770001)
    let pullCalls = await github.count { $0.contains("/pulls/") }
    XCTAssertEqual(pullCalls, 0)
  }

  // MARK: - Access

  func testTheFirstTokenThatCanSeeTheRepositoryWins() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setUnauthorizedTokens(["ghp_one"])

    let snapshot = try await service(tokens: ["ghp_one", "ghp_two"], github).fetchPullRequest(reference())

    XCTAssertEqual(snapshot.title, "Add retry backoff")
  }

  func testNoTokenThatCanSeeItReportsBothPossibilities() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setUnauthorizedTokens(["ghp_one", "ghp_two"])

    do {
      _ = try await service(tokens: ["ghp_one", "ghp_two"], github).fetchPullRequest(reference())
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? GitHubFetchError, .noAccess("acme/api#812"))
      let message = (error as? GitHubFetchError)?.errorDescription ?? ""
      XCTAssertTrue(message.contains("does not exist"))
      XCTAssertTrue(message.contains("can reach it"))
    }
  }

  func testNoTokenAtAllSaysWhereToAddOne() async throws {
    let github = FakeGitHub()

    do {
      _ = try await service(tokens: [], github).fetchPullRequest(reference())
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? GitHubFetchError, .noActiveToken)
    }
  }

  func testAnInactiveTokenIsNotTried() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())

    let service = try await service(tokens: ["ghp_one"], github)
    let tokens = try await service.listTokens()
    _ = try await service.toggleTokenActive(id: try XCTUnwrap(tokens.first?.id))

    do {
      _ = try await service.fetchPullRequest(reference())
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? GitHubFetchError, .noActiveToken)
    }
  }

  /// A spent rate limit and a permission problem share a status code, so the
  /// remaining-count header is the only thing that can tell them apart.
  func testASpentRateLimitIsNotReportedAsMissingAccess() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setRateLimited(true)

    do {
      _ = try await service(github).fetchPullRequest(reference())
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? GitHubFetchError, .rateLimited)
    }
  }

  func testAForbiddenResponseWithBudgetLeftIsJustNoAccess() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setForbiddenWithBudgetRemaining(true)

    do {
      _ = try await service(github).fetchPullRequest(reference())
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? GitHubFetchError, .noAccess("acme/api#812"))
    }
  }

  /// Reviews and comments are worth having but not worth failing over — a
  /// readable pull request still drafts a useful task without them.
  func testUnreadableReviewsDoNotSinkTheWholeFetch() async throws {
    let github = FakeGitHub()
    await github.setIssue(minimalIssue())
    await github.setMissingPaths(["/repos/acme/api/pulls/812/reviews"])

    let snapshot = try await service(github).fetchPullRequest(reference())

    XCTAssertTrue(snapshot.reviews.isEmpty)
    XCTAssertEqual(snapshot.title, "Add retry backoff")
  }

  // MARK: - Fixtures

  private func minimalIssue(id: Int64 = 990001, body: String = "Wraps the client in a retry.", milestone: String = "") -> String {
    #"{"id":\#(id),"title":"Add retry backoff","body":"\#(body)","state":"open","#
      + #""html_url":"https://github.com/acme/api/pull/812","created_at":"2026-09-15T09:00:00Z","#
      + #""updated_at":"2026-09-17T10:22:04Z"\#(milestone)}"#
  }
}

private actor FakeGitHub {
  private var issuePayload = #"{"id":1,"title":"x","state":"open","html_url":"https://github.com/acme/api/pull/1"}"#
  private var pullPayload = #"{"draft":false,"merged":false,"changed_files":0}"#
  private var reviewsPayload = "[]"
  private var commentsPayload = "[]"
  private var filesPayload = "[]"
  private var unauthorizedTokens: Set<String> = []
  private var missingPaths: Set<String> = []
  private var rateLimited = false
  private var forbiddenWithBudgetRemaining = false
  private var paths: [String] = []

  func setIssue(_ payload: String) { issuePayload = payload }
  func setPull(_ payload: String) { pullPayload = payload }
  func setReviews(_ payload: String) { reviewsPayload = payload }
  func setComments(_ payload: String) { commentsPayload = payload }
  func setFiles(_ payload: String) { filesPayload = payload }
  func setUnauthorizedTokens(_ tokens: Set<String>) { unauthorizedTokens = tokens }
  func setMissingPaths(_ values: Set<String>) { missingPaths = values }
  func setRateLimited(_ value: Bool) { rateLimited = value }
  func setForbiddenWithBudgetRemaining(_ value: Bool) { forbiddenWithBudgetRemaining = value }

  func count(where predicate: (String) -> Bool) -> Int {
    paths.filter(predicate).count
  }

  func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let path = url.path
    paths.append(path)

    if path == "/user" {
      return response(#"{"login":"adarsh"}"#, 200, url)
    }

    let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
      .replacingOccurrences(of: "Bearer ", with: "")

    if rateLimited {
      return response("{}", 403, url, headers: ["x-ratelimit-remaining": "0"])
    }
    if forbiddenWithBudgetRemaining {
      return response("{}", 403, url, headers: ["x-ratelimit-remaining": "4999"])
    }
    if unauthorizedTokens.contains(token) || missingPaths.contains(path) {
      return response(#"{"message":"Not Found"}"#, 404, url)
    }

    if path.hasSuffix("/reviews") { return response(reviewsPayload, 200, url) }
    if path.hasSuffix("/comments") { return response(commentsPayload, 200, url) }
    if path.hasSuffix("/files") { return response(filesPayload, 200, url) }
    if path.contains("/pulls/") { return response(pullPayload, 200, url) }
    if path.contains("/issues/") { return response(issuePayload, 200, url) }

    return response("{}", 200, url)
  }

  private func response(
    _ json: String,
    _ status: Int,
    _ url: URL,
    headers: [String: String]? = nil
  ) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
  }
}

private final class InMemorySecretStorageBackend: SecretStorageBackend {
  private var values: [String: Data] = [:]

  private func namespacedKey(service: String, key: String) -> String {
    "\(service):\(key)"
  }

  func set(service: String, key: String, data: Data) throws {
    values[namespacedKey(service: service, key: key)] = data
  }

  func get(service: String, key: String) throws -> Data? {
    values[namespacedKey(service: service, key: key)]
  }

  func delete(service: String, key: String) throws {
    values.removeValue(forKey: namespacedKey(service: service, key: key))
  }

  func contains(service: String, key: String) throws -> Bool {
    values[namespacedKey(service: service, key: key)] != nil
  }
}
