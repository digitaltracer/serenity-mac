import XCTest
@testable import SerenityMac

/// Covers the write end of a capture command: what a Save actually does to the
/// task list, against a real AppState on a temporary database.
@MainActor
final class CaptureCommandFlowTests: XCTestCase {
  func testSavingACreateWritesTheWholeTask() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    let due = Date(timeIntervalSince1970: 1_789_344_000)
    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .create,
        payload: SlackProposalPayload(
          title: "Handle the null case in the retry wrapper",
          description: "Priya requested changes.\n\nhttps://github.com/acme/api/pull/812",
          priority: .high,
          dueDate: due,
          tags: ["github", "github-pr-990001"],
          subtasks: ["Add a test for the 429 path"]
        ),
        confidence: 0.91,
        sourceLabel: "acme/api#812"
      )
    ])

    let saved = await fixture.state.savePendingCaptureDraft()

    XCTAssertTrue(saved)
    XCTAssertNil(fixture.state.pendingCaptureDraft)

    let task = try XCTUnwrap(fixture.state.tasks.first)
    XCTAssertEqual(task.title, "Handle the null case in the retry wrapper")
    XCTAssertEqual(task.priority, .high)
    XCTAssertEqual(task.dueDate, due)
    XCTAssertEqual(task.tags, ["github", "github-pr-990001"])
    XCTAssertEqual(task.subtasks.map(\.title), ["Add a test for the 429 path"])
  }

  /// Without the origin tag on the written task, pasting the same link again
  /// has nothing to recognise and makes a second task.
  func testTheWrittenTaskCarriesItsOriginTagSoARepeatedPasteFindsIt() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .create,
        payload: SlackProposalPayload(title: "Add retry backoff", tags: ["github", "github-pr-990001"]),
        confidence: 0.9,
        sourceLabel: "acme/api#812"
      )
    ])
    _ = await fixture.state.savePendingCaptureDraft()

    let source = githubSource(issueID: 990001)
    XCTAssertNotNil(CaptureCommandDrafter.alreadyTracked(source, in: fixture.state.tasks))
  }

  func testTheTaskHistorySaysWhereItCameFrom() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .create,
        payload: SlackProposalPayload(title: "Add retry backoff"),
        confidence: 0.9,
        sourceLabel: "acme/api#812"
      )
    ])
    _ = await fixture.state.savePendingCaptureDraft()

    let task = try XCTUnwrap(fixture.state.tasks.first)
    let line = try XCTUnwrap(task.activity.first)
    XCTAssertEqual(line.kind, .event)
    XCTAssertTrue(line.text.contains("acme/api#812"))
    XCTAssertTrue(line.text.hasPrefix("Drafted from"))
  }

  func testAnUpdateTouchesOnlyTheFieldsItCarries() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Add retry backoff",
      priority: .low,
      dueDate: nil,
      tags: ["github", "github-pr-990001"],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    let due = Date(timeIntervalSince1970: 1_789_344_000)
    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .update,
        targetTaskID: existing.id,
        payload: SlackProposalPayload(priority: .high, dueDate: due, subtasks: ["Rebase onto main"]),
        confidence: 0.86,
        sourceLabel: "acme/api#812"
      )
    ])

    _ = await fixture.state.savePendingCaptureDraft()

    XCTAssertEqual(fixture.state.tasks.count, 1, "an update must not spawn a second task")
    let updated = try XCTUnwrap(fixture.state.tasks.first)
    XCTAssertEqual(updated.title, "Add retry backoff", "a field the draft left alone stays as it was")
    XCTAssertEqual(updated.priority, .high)
    XCTAssertEqual(updated.dueDate, due)
    XCTAssertEqual(updated.subtasks.map(\.title), ["Rebase onto main"])
  }

  /// One paste can legitimately be part-new and part-already-tracked.
  func testACreateAndAnUpdateInOnePasteBothLand() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Add retry backoff",
      priority: .medium,
      dueDate: nil,
      tags: ["github", "github-pr-990001"],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .update,
        targetTaskID: existing.id,
        payload: SlackProposalPayload(priority: .high),
        confidence: 0.8,
        sourceLabel: "acme/api#812"
      ),
      CaptureDraft(
        kind: .create,
        payload: SlackProposalPayload(title: "Rebase the backoff PR", tags: ["github", "github-pr-990002"]),
        confidence: 0.8,
        sourceLabel: "acme/api#815"
      ),
    ])

    _ = await fixture.state.savePendingCaptureDraft()

    XCTAssertEqual(fixture.state.tasks.count, 2)
    XCTAssertEqual(fixture.state.tasks.first { $0.id == existing.id }?.priority, .high)
    XCTAssertNotNil(fixture.state.tasks.first { $0.title == "Rebase the backoff PR" })
  }

  /// The task can be deleted between drafting and saving. Losing the work
  /// entirely would be worse than writing it as new.
  func testAnUpdateToAVanishedTaskIsWrittenAsACreate() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .update,
        targetTaskID: "a-task-that-was-deleted",
        payload: SlackProposalPayload(title: "Handle the null case", priority: .high),
        confidence: 0.8,
        sourceLabel: "acme/api#812"
      )
    ])

    let saved = await fixture.state.savePendingCaptureDraft()

    XCTAssertTrue(saved)
    XCTAssertEqual(fixture.state.tasks.count, 1)
    XCTAssertEqual(fixture.state.tasks.first?.title, "Handle the null case")
  }

  func testStatusChangeClosesTheTask() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Add retry backoff",
      priority: .medium,
      dueDate: nil,
      tags: ["github-pr-990001"],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .update,
        targetTaskID: existing.id,
        payload: SlackProposalPayload(statusChange: .completed),
        confidence: 0.9,
        sourceLabel: "acme/api#812"
      )
    ])

    _ = await fixture.state.savePendingCaptureDraft()

    XCTAssertTrue(fixture.state.tasks.first?.completed == true)
  }

  func testDiscardingLeavesTheTaskListAlone() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    fixture.state.pendingCaptureDraft = preview(drafts: [
      CaptureDraft(
        kind: .create,
        payload: SlackProposalPayload(title: "Never written"),
        confidence: 0.9,
        sourceLabel: "acme/api#812"
      )
    ])

    fixture.state.discardPendingCaptureDraft()

    XCTAssertNil(fixture.state.pendingCaptureDraft)
    XCTAssertTrue(fixture.state.tasks.isEmpty)
  }

  /// The match can simply be wrong. Saying so has to leave the matched task
  /// untouched and write the drafted work as its own task instead.
  func testRejectingTheMatchLeavesTheMatchedTaskAloneAndWritesANewOne() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Fix incorrect 'Known Lead' tagging",
      priority: .low,
      dueDate: nil,
      tags: ["github", "github-pr-990001"],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    let draft = CaptureDraft(
      kind: .update,
      targetTaskID: existing.id,
      payload: SlackProposalPayload(
        title: "Implement account-domain fallback for CRM routing",
        priority: .high,
        tags: ["github", "github-pr-990001"]
      ),
      confidence: 0.95,
      sourceLabel: "acme/api#812"
    )
    fixture.state.pendingCaptureDraft = preview(drafts: [draft])

    fixture.state.chooseCaptureDraftKind(.create, forDraftID: draft.id)
    let saved = await fixture.state.savePendingCaptureDraft()

    XCTAssertTrue(saved)
    XCTAssertEqual(fixture.state.tasks.count, 2)

    let untouched = try XCTUnwrap(fixture.state.tasks.first { $0.id == existing.id })
    XCTAssertEqual(untouched.title, "Fix incorrect 'Known Lead' tagging")
    XCTAssertEqual(untouched.priority, .low, "the task the user said was the wrong match keeps every field")

    let written = try XCTUnwrap(fixture.state.tasks.first { $0.id != existing.id })
    XCTAssertEqual(written.title, "Implement account-domain fallback for CRM routing")
    XCTAssertEqual(written.priority, .high)
  }

  /// A repeated paste arrives with its title stripped, because renaming the
  /// task it matched is exactly what the redirect exists to prevent.
  func testRejectingARedirectedMatchStillWritesATitledTask() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Add retry backoff",
      priority: .medium,
      dueDate: nil,
      tags: ["github", "github-pr-990001"],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    let source = githubSource(issueID: 990001)
    let drafted = CaptureCommandDrafter.tagged(
      CaptureDraft(kind: .create, payload: .init(title: "Handle the 429 path"), confidence: 0.9, sourceLabel: ""),
      sources: [source],
      coveringKeys: ["s1"]
    )
    let redirected = try XCTUnwrap(
      CaptureCommandDrafter.redirectingDuplicates([drafted], sources: [source], tasks: [existing]).first
    )
    fixture.state.pendingCaptureDraft = preview(drafts: [redirected])

    fixture.state.chooseCaptureDraftKind(.create, forDraftID: redirected.id)
    _ = await fixture.state.savePendingCaptureDraft()

    let written = try XCTUnwrap(fixture.state.tasks.first { $0.id != existing.id })
    XCTAssertEqual(written.title, "Handle the 429 path")
    XCTAssertTrue(written.tags.contains("github-pr-990001"), "the new task has to be findable by the next paste")
  }

  func testChoosingTheUpdateAfterAllStillUpdates() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()
    await fixture.state.refreshCoreWorkflowData()

    await fixture.state.createTask(
      title: "Add retry backoff",
      priority: .low,
      dueDate: nil,
      tags: [],
      subtaskTitles: []
    )
    await fixture.state.refreshCoreWorkflowData()
    let existing = try XCTUnwrap(fixture.state.tasks.first)

    let draft = CaptureDraft(
      kind: .update,
      targetTaskID: existing.id,
      payload: SlackProposalPayload(priority: .high),
      confidence: 0.8,
      sourceLabel: "acme/api#812"
    )
    fixture.state.pendingCaptureDraft = preview(drafts: [draft])

    fixture.state.chooseCaptureDraftKind(.create, forDraftID: draft.id)
    fixture.state.chooseCaptureDraftKind(.update, forDraftID: draft.id)
    _ = await fixture.state.savePendingCaptureDraft()

    XCTAssertEqual(fixture.state.tasks.count, 1)
    XCTAssertEqual(fixture.state.tasks.first?.priority, .high)
  }

  func testSavingWithNothingHeldDoesNothing() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()

    let saved = await fixture.state.savePendingCaptureDraft()

    XCTAssertFalse(saved)
  }

  /// A command must refuse before it fetches when the provider it names is not
  /// connected, so the user gets the fix rather than a transport error.
  func testAGitHubCommandWithNoTokenRefusesBeforeFetching() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()

    let command = try XCTUnwrap(
      try CaptureCommandParser.parse("/github https://github.com/acme/api/pull/812")
    )
    let started = await fixture.state.submitCaptureCommand(command, typedText: "/github …")

    XCTAssertFalse(started)
    XCTAssertNil(fixture.state.pendingCaptureDraft)
    XCTAssertNil(fixture.state.captureCommandProgress)
  }

  func testASlackCommandWithNoConnectionRefusesBeforeFetching() async throws {
    let fixture = try makeState()
    defer { fixture.cleanup() }
    await fixture.state.bootstrapLocalDatabase()

    let command = try XCTUnwrap(
      try CaptureCommandParser.parse("/slack https://acme.slack.com/archives/C05QJ1X2Y/p1726742400123456")
    )
    let started = await fixture.state.submitCaptureCommand(command, typedText: "/slack …")

    XCTAssertFalse(started)
    XCTAssertNil(fixture.state.pendingCaptureDraft)
  }

  // MARK: - Fixtures

  private func preview(drafts: [CaptureDraft]) -> CaptureDraftPreview {
    CaptureDraftPreview(
      typedText: "/github https://github.com/acme/api/pull/812",
      kind: .github,
      drafts: drafts,
      draftedByModel: true
    )
  }

  private func githubSource(issueID: Int64) -> CaptureSource {
    .github(
      GitHubPullSnapshot(
        issueID: issueID,
        owner: "acme",
        repo: "api",
        number: 812,
        title: "Add retry backoff",
        body: nil,
        state: "open",
        isPullRequest: true,
        isDraft: false,
        isMerged: false,
        labels: [],
        assignees: [],
        requestedReviewers: [],
        milestoneTitle: nil,
        milestoneDueOn: nil,
        changedFileNames: [],
        changedFileCount: 0,
        reviews: [],
        comments: [],
        htmlURL: "https://github.com/acme/api/pull/812",
        createdAt: nil,
        updatedAt: nil
      )
    )
  }

  private struct Fixture {
    let state: AppState
    let cleanup: () -> Void
  }

  private func makeState() throws -> Fixture {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-capture-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

    let suiteName = "serenity.capture.flow.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let registry = BackendProfileRegistry(
      descriptors: BackendProfileRegistry.live.descriptors,
      validators: [
        .sqliteLocal: { .available(message: "ok") },
        .serenityCloud: { .unavailable(reason: "not configured") },
        .externalPostgres: { .unavailable(reason: "not configured") },
      ]
    )

    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "capture.flow.backend",
        registry: registry
      ),
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil
    )

    return Fixture(
      state: state,
      cleanup: {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseURL)
      }
    )
  }
}
