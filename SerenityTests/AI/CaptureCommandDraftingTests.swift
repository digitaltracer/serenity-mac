import XCTest
@testable import SerenityMac

/// Covers the decode and normalisation path, which is where a model's
/// creativity becomes somebody's task.
final class CaptureCommandDraftingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_000_000)

  func testAWellFormedResponseBecomesOneDraft() async throws {
    let (service, _) = try makeService(returning: [
      draftJSON(title: "Handle the null case in the retry wrapper", priority: "high", dueDate: "2026-09-22")
    ])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "needs the review comments addressed",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.count, 1)
    XCTAssertEqual(drafts.first?.kind, CaptureDraftKind.create)
    XCTAssertEqual(drafts.first?.payload.title, "Handle the null case in the retry wrapper")
    XCTAssertEqual(drafts.first?.payload.priority, TaskPriority.high)
    XCTAssertNotNil(drafts.first?.payload.dueDate)
    XCTAssertTrue(drafts.first?.payload.tags.contains("github-pr-990001") == true)
  }

  /// A model that names a task id nobody has told us it wants a change, not
  /// which one — so it drafts new work rather than editing at random.
  func testAnInventedTaskIDIsDemotedToACreate() async throws {
    let (service, _) = try makeService(returning: [
      draftJSON(action: "update", targetTaskId: "not-a-real-task", title: "Handle the null case")
    ])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [task(title: "Something real")],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.first?.kind, CaptureDraftKind.create)
    XCTAssertNil(drafts.first?.targetTaskID)
  }

  func testAnUpdateAimedAtARealTaskIsKept() async throws {
    let existing = task(title: "Add retry backoff")
    let (service, _) = try makeService(returning: [
      draftJSON(action: "update", targetTaskId: existing.id, title: nil, priority: "high")
    ])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [existing],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.first?.kind, CaptureDraftKind.update)
    XCTAssertEqual(drafts.first?.targetTaskID, existing.id)
    XCTAssertEqual(drafts.first?.payload.priority, TaskPriority.high)
  }

  func testACreateWithNothingToCallItIsDropped() async throws {
    let (service, _) = try makeService(returning: [draftJSON(title: nil)])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(drafts.isEmpty)
  }

  func testAnArchivedProjectIsNotAcceptedAsATarget() async throws {
    let (service, _) = try makeService(returning: [draftJSON(title: "Do the thing", projectId: "archived")])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [AIQuickCaptureProjectContext(id: "archived", name: "Old", description: nil, archived: true)],
      availableTags: [],
      now: now
    )

    XCTAssertNil(drafts.first?.payload.projectId)
  }

  /// Splitting this far means the model found no common thread between the
  /// links. One paste should not flood ActionHub.
  func testMoreDraftsThanTheCapCollapseToTheMostConfidentOne() async throws {
    let tasks = (1...5).map { draftJSON(title: "Task \($0)", confidence: $0 == 3 ? 0.95 : 0.5) }
    let (service, _) = try makeService(returning: ["{\"tasks\":[\(tasks.map(stripWrapper).joined(separator: ","))]}"])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource(issueID: 990001), githubSource(issueID: 990002)],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.count, 1)
    XCTAssertEqual(drafts.first?.payload.title, "Task 3")
    XCTAssertTrue(drafts.first?.payload.tags.contains("github-pr-990001") == true)
    XCTAssertTrue(
      drafts.first?.payload.tags.contains("github-pr-990002") == true,
      "the collapsed draft still has to own every source, or the next paste duplicates it"
    )
  }

  func testTheCapItselfIsAllowed() async throws {
    let tasks = (1...CaptureCommandDrafter.maxDrafts).map { draftJSON(title: "Task \($0)") }
    let (service, _) = try makeService(returning: ["{\"tasks\":[\(tasks.map(stripWrapper).joined(separator: ","))]}"])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.count, CaptureCommandDrafter.maxDrafts)
  }

  /// The same repair shot quick capture takes. A model that answers with prose
  /// on the first attempt should not cost the user their command.
  func testMalformedJSONIsRepairedRatherThanFailed() async throws {
    let (service, calls) = try makeService(returning: [
      "I think you should handle the null case.",
      draftJSON(title: "Handle the null case"),
    ])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.first?.payload.title, "Handle the null case")
    let callCount = await calls.count()
    XCTAssertEqual(callCount, 2)
  }

  func testAnUnrepairableResponseSaysWhatWentWrong() async throws {
    let (service, _) = try makeService(returning: ["not json", "still not json"])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    do {
      _ = try await service.draftCaptureCommand(
        sources: [githubSource()],
        context: "",
        credentialID: credential.id,
        openTasks: [],
        projects: [],
        availableTags: [],
        now: now
      )
      XCTFail("expected a failure")
    } catch let error as AIWorkflowError {
      guard case .invalidCaptureDraftResponse = error else {
        return XCTFail("expected a capture-draft error, got \(error)")
      }
    }
  }

  func testNoSourcesCostsNoAICall() async throws {
    let (service, calls) = try makeService(returning: [draftJSON(title: "Should never run")])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [],
      context: "some words",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertTrue(drafts.isEmpty)
    let callCount = await calls.count()
    XCTAssertEqual(callCount, 0)
  }

  /// Logged against `quickadd` on purpose — `ai_usage.operation` sits behind a
  /// CHECK constraint SQLite cannot widen in place.
  func testTheCallIsBilledToTheCostCenter() async throws {
    let (service, _) = try makeService(returning: [draftJSON(title: "Handle the null case")])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    _ = try await service.draftCaptureCommand(
      sources: [githubSource()],
      context: "",
      credentialID: credential.id,
      openTasks: [],
      projects: [],
      availableTags: [],
      now: now
    )

    let snapshot = try await service.fetchSnapshot()
    let logged = snapshot.usage.filter { $0.operation == .quickadd }
    XCTAssertEqual(logged.count, 1)
    XCTAssertEqual(logged.first?.promptTokens, 20)
  }

  func testARepeatedPasteIsRedirectedAtTheTaskItAlreadyMade() async throws {
    let existing = task(title: "Add retry backoff", tags: ["github", "github-pr-990001"])
    let (service, _) = try makeService(returning: [draftJSON(title: "Add retry backoff again")])
    let credential = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let drafts = try await service.draftCaptureCommand(
      sources: [githubSource(issueID: 990001)],
      context: "",
      credentialID: credential.id,
      openTasks: [existing],
      projects: [],
      availableTags: [],
      now: now
    )

    XCTAssertEqual(drafts.first?.kind, CaptureDraftKind.update)
    XCTAssertEqual(drafts.first?.targetTaskID, existing.id)
  }

  // MARK: - Fixtures

  private func makeService(returning responses: [String]) throws -> (AIWorkflowService, CallLog) {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-capture-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

    let log = CallLog()
    let service = AIWorkflowService(
      sqliteBackendAdapter: SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite")),
      secretStore: KeychainSecretStore(service: "test.capture.ai", backend: InMemorySecretStorageBackend()),
      quickCaptureGenerator: { _, _, _, _, _, _ in
        let index = await log.record()
        return AIProviderTextGenerationResponse(
          text: responses.indices.contains(index) ? responses[index] : responses.last ?? "{}",
          promptTokens: 20,
          completionTokens: 40
        )
      }
    )

    return (service, log)
  }

  private func stripWrapper(_ json: String) -> String {
    json
      .replacingOccurrences(of: "{\"tasks\":[", with: "")
      .replacingOccurrences(of: "]}", with: "")
  }

  private func draftJSON(
    action: String = "create",
    targetTaskId: String? = nil,
    title: String? = "Handle the null case",
    priority: String? = nil,
    dueDate: String? = nil,
    projectId: String? = nil,
    confidence: Double = 0.9
  ) -> String {
    func value(_ raw: String?) -> String { raw.map { "\"\($0)\"" } ?? "null" }

    return """
      {"tasks":[{
        "sourceKeys":["s1"],
        "action":"\(action)",
        "targetTaskId":\(value(targetTaskId)),
        "title":\(value(title)),
        "description":"See https://github.com/acme/api/pull/812",
        "priority":\(value(priority)),
        "dueDate":\(value(dueDate)),
        "projectId":\(value(projectId)),
        "projectName":null,
        "tags":[],
        "subtasks":[],
        "statusChange":"none",
        "confidence":\(confidence),
        "reason":"Priya requested changes."
      }]}
      """
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "  ", with: "")
  }

  private func githubSource(issueID: Int64 = 990001, number: Int = 812) -> CaptureSource {
    .github(
      GitHubPullSnapshot(
        issueID: issueID,
        owner: "acme",
        repo: "api",
        number: number,
        title: "Add retry backoff",
        body: "Wraps the client in a retry.",
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
        changedFileCount: 1,
        reviews: [],
        comments: [],
        htmlURL: "https://github.com/acme/api/pull/\(number)",
        createdAt: now,
        updatedAt: now
      )
    )
  }

  private func task(title: String, tags: [String] = []) -> TaskEntity {
    TaskEntity(
      id: UUID().uuidString,
      title: title,
      description: nil,
      completed: false,
      completedAt: nil,
      priority: .medium,
      dueDate: nil,
      projectId: nil,
      tags: tags,
      createdAt: now,
      updatedAt: now,
      subtasks: [],
      recurring: nil,
      userId: nil
    )
  }
}

private actor CallLog {
  private var calls = 0

  func record() -> Int {
    defer { calls += 1 }
    return calls
  }

  func count() -> Int { calls }
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
