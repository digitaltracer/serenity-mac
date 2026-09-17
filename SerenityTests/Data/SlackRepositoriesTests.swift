import Foundation
import GRDB
import XCTest
@testable import SerenityMac

final class SlackRepositoriesTests: XCTestCase {
  func testASecondProposalForTheSameThreadSupersedesTheFirst() async throws {
    let repositories = try await makeRepositories()

    let first = proposal(title: "Perform app release", threadTS: "100.0")
    try repositories.proposals.save(first)

    let second = proposal(title: "Merge field mapping and release the app", threadTS: "100.0")
    try repositories.proposals.save(second)
    try repositories.proposals.supersedePending(
      channelID: second.source.channelID,
      threadTS: second.source.threadTS,
      excluding: second.id,
      at: Date()
    )

    let pending = try repositories.proposals.fetchPending()
    XCTAssertEqual(pending.map(\.id), [second.id], "One conversation shows one pending ask")

    let all = try repositories.proposals.fetchAll()
    XCTAssertEqual(all.first(where: { $0.id == first.id })?.status, .superseded)
  }

  func testProposalsFromOtherThreadsAreLeftAlone() async throws {
    let repositories = try await makeRepositories()

    let other = proposal(title: "Review the export doc", threadTS: "900.0")
    try repositories.proposals.save(other)

    let newest = proposal(title: "Release the app", threadTS: "100.0")
    try repositories.proposals.save(newest)
    try repositories.proposals.supersedePending(
      channelID: newest.source.channelID,
      threadTS: newest.source.threadTS,
      excluding: newest.id,
      at: Date()
    )

    XCTAssertEqual(Set(try repositories.proposals.fetchPending().map(\.id)), [other.id, newest.id])
  }

  func testAProposalSurvivesARoundTripWithItsPayloadAndSource() async throws {
    let repositories = try await makeRepositories()

    var payload = SlackProposalPayload(title: "Release the app", tags: ["slack"])
    payload.dueDate = Date(timeIntervalSince1970: 1_789_500_000)
    payload.priority = .high
    payload.statusChange = .completed

    var original = proposal(title: "Release the app", threadTS: "100.0")
    original.payload = payload
    original.reason = "Adarsh committed to it in the thread"
    try repositories.proposals.save(original)

    let stored = try XCTUnwrap(try repositories.proposals.fetchPending().first)
    XCTAssertEqual(stored.payload.title, "Release the app")
    XCTAssertEqual(stored.payload.priority, .high)
    XCTAssertEqual(stored.payload.statusChange, .completed)
    XCTAssertEqual(stored.payload.dueDate?.timeIntervalSince1970, 1_789_500_000)
    XCTAssertEqual(stored.source.channelName, "releases")
    XCTAssertEqual(stored.reason, "Adarsh committed to it in the thread")
  }

  func testCursorsAndSeenMessagesRoundTrip() async throws {
    let repositories = try await makeRepositories()

    try repositories.cursors.save([
      SlackChannelCursor(
        channelID: "C_REL",
        channelName: "releases",
        lastTS: "1789465904.241459",
        participatedThreadTS: ["100.0", "200.0"]
      )
    ])

    let cursor = try XCTUnwrap(try repositories.cursors.fetchAll().first)
    XCTAssertEqual(cursor.lastTS, "1789465904.241459")
    XCTAssertEqual(cursor.participatedThreadTS, ["100.0", "200.0"])

    try repositories.seenMessages.record(
      [SlackSeenMessage(channelID: "C_REL", ts: "1.0", outcome: .proposed)],
      at: Date()
    )
    // Re-recording the same message must not duplicate it, or the "exactly
    // once" guarantee the seen table exists for would not hold.
    try repositories.seenMessages.record(
      [SlackSeenMessage(channelID: "C_REL", ts: "1.0", outcome: .ignored)],
      at: Date()
    )

    XCTAssertEqual(try repositories.seenMessages.seenKeys(), ["C_REL:1.0"])
  }

  private func makeRepositories() async throws -> GRDBSlackRepositorySet {
    let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-slack-repos-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("serenity.sqlite")
    _ = try await DatabaseMigrationRunner().bootstrapDatabase(at: databaseURL)

    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    return GRDBSlackRepositorySet(dbQueue: try DatabaseQueue(path: databaseURL.path, configuration: configuration))
  }

  private func proposal(title: String, threadTS: String) -> SlackProposal {
    SlackProposal(
      kind: .create,
      targetTaskID: nil,
      payload: SlackProposalPayload(title: title),
      confidence: 0.9,
      reason: nil,
      source: SlackProposalSource(
        channelID: "C_REL",
        channelName: "releases",
        messageTS: "\(Double.random(in: 1...1000))",
        threadTS: threadTS,
        author: "Nirdosh",
        excerpt: "merging tonight",
        permalink: nil
      )
    )
  }
}
