import CloudKit
import Foundation
import XCTest
@testable import SerenityMac

/// The stored stand-up is what makes the window anchor and the carry-over
/// phrasing possible, so the round trip and the recall it produces are the
/// parts worth holding still.
final class StandupRepositoryTests: XCTestCase {
  func testAStandupSurvivesTheRoundTripIntact() async throws {
    let repositories = try await makeRepositorySet()
    let standup = makeStandup()

    try repositories.standups.save(standup)

    let fetched = try XCTUnwrap(repositories.standups.fetchByID(standup.id))
    XCTAssertEqual(fetched.spoken, standup.spoken)
    XCTAssertEqual(fetched.paste, standup.paste)
    XCTAssertEqual(fetched.folded, standup.folded)
    XCTAssertEqual(fetched.items, standup.items)
    XCTAssertEqual(fetched.formatInstruction, standup.formatInstruction)
    XCTAssertEqual(fetched.length, .detailed)
    XCTAssertTrue(fetched.writtenByModel)
  }

  func testTheLatestStandupIsTheMostRecentlyGeneratedNotTheMostRecentlyWritten() async throws {
    let repositories = try await makeRepositorySet()
    let older = makeStandup(generatedAt: Date(timeIntervalSince1970: 1_000_000))
    let newer = makeStandup(generatedAt: Date(timeIntervalSince1970: 2_000_000))

    // Saved out of order on purpose: a record pulled from another device
    // arrives late but does not become "the last stand-up".
    try repositories.standups.save(newer)
    try repositories.standups.save(older)

    XCTAssertEqual(try repositories.standups.fetchLatest()?.id, newer.id)
  }

  func testSavingEnqueuesTheStandupForSync() async throws {
    let databaseURL = try await makeDatabase()
    let core = try GRDBCoreRepositorySet.make(databasePath: databaseURL.path)
    let repositories = try GRDBAIRepositorySet.make(
      databasePath: databaseURL.path,
      pendingStore: core.pendingSyncChanges
    )

    try repositories.standups.save(makeStandup())

    let pending = try core.pendingSyncChanges.fetchPending(limit: 10)
    XCTAssertEqual(pending.map(\.entityType), [SyncEntityType.standup])
  }

  /// Being stuck outranks being planned, which outranks having moved — so a
  /// task that produced two items comes back as the one tomorrow should react
  /// to.
  func testRecallPrefersTheBlockedMentionOverTheProgressOne() {
    let standup = makeStandup(items: [
      StandupItem(id: "a:since", taskID: "a", column: .since, title: "A", fact: "moved", source: .progress),
      StandupItem(id: "a:blocked", taskID: "a", column: .blocked, title: "A", fact: "needs creds", source: .stated),
    ])

    let recall = standup.recall

    XCTAssertEqual(recall.mentions["a"], StandupMention(column: .blocked, fact: "needs creds"))
  }

  func testRecallIgnoresWhatYouLeftOut() {
    let standup = makeStandup(items: [
      StandupItem(id: "b:leftOut", taskID: "b", column: .leftOut, title: "B", fact: "calendar", source: .calendar),
    ])

    XCTAssertTrue(standup.recall.mentions.isEmpty)
  }

  func testTheCloudKitRecordSurvivesEncodingAndDecoding() throws {
    let standup = makeStandup()
    let record = CKRecord(
      recordType: SyncEntityType.standup,
      recordID: CKRecord.ID(recordName: standup.id, zoneID: SerenityCloudKit.zoneID)
    )

    try StandupSyncRecordKind.encode(standup, into: record)
    let decoded = try StandupSyncRecordKind.decode(record)

    XCTAssertEqual(decoded.id, standup.id)
    XCTAssertEqual(decoded.spoken, standup.spoken)
    XCTAssertEqual(decoded.folded, standup.folded)
    XCTAssertEqual(decoded.items, standup.items)
    XCTAssertEqual(decoded.length, standup.length)
    XCTAssertEqual(decoded.writtenByModel, standup.writtenByModel)
    XCTAssertEqual(decoded.totalTokens, standup.totalTokens)
  }

  // MARK: - Helpers

  private func makeStandup(
    generatedAt: Date = Date(timeIntervalSince1970: 1_789_000_000),
    items: [StandupItem]? = nil
  ) -> StandupEntity {
    StandupEntity(
      id: UUID().uuidString,
      generatedAt: generatedAt,
      windowStart: generatedAt.addingTimeInterval(-86_400 * 3),
      windowEnd: generatedAt,
      spoken: "Since Friday I shipped the token refresh.",
      paste: "**Since Friday**\n- Shipped the token refresh",
      folded: ["Rotates on every sync", "30-day expiry still stands"],
      items: items ?? [
        StandupItem(
          id: "t1:since",
          taskID: "t1",
          column: .since,
          title: "Ship Slack PKCE token refresh",
          fact: "Finished Friday 4:12 PM",
          source: .completed
        ),
      ],
      formatInstruction: "Name the PR number when there is one.",
      length: .detailed,
      writtenByModel: true,
      provider: .anthropic,
      promptTokens: 420,
      completionTokens: 180,
      totalTokens: 600,
      createdAt: generatedAt,
      updatedAt: generatedAt
    )
  }

  private func makeRepositorySet() async throws -> GRDBAIRepositorySet {
    try GRDBAIRepositorySet.make(databasePath: try await makeDatabase().path)
  }

  private func makeDatabase() async throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-standup-repository")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")

    _ = try await DatabaseMigrationRunner().bootstrapDatabase(at: databaseURL)
    return databaseURL
  }
}
