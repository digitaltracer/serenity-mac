import Foundation
import XCTest
@testable import SerenityMac

@MainActor
final class JournalTitleTests: XCTestCase {
  private final class MemorySecrets: SecretStorageBackend {
    private var values: [String: Data] = [:]
    func set(service: String, key: String, data: Data) throws { values["\(service):\(key)"] = data }
    func get(service: String, key: String) throws -> Data? { values["\(service):\(key)"] }
    func delete(service: String, key: String) throws { values.removeValue(forKey: "\(service):\(key)") }
    func contains(service: String, key: String) throws -> Bool { values["\(service):\(key)"] != nil }
  }

  private var cleanups: [() -> Void] = []

  override func tearDown() {
    cleanups.forEach { $0() }
    cleanups = []
    super.tearDown()
  }

  private func makeState(
    generator: @escaping AIWorkflowService.QuickCaptureGenerationHandler = { _, _, _, _, _, _ in
      throw AIProviderAPIError.invalidResponse
    }
  ) throws -> (AppState, AIWorkflowService) {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("serenity-journal-title-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    let suiteName = "serenity.journal.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    cleanups.append {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: baseURL)
    }
    let sqlite = SQLiteBackendAdapter(databaseURL: baseURL.appendingPathComponent("serenity.sqlite"))
    let service = AIWorkflowService(
      sqliteBackendAdapter: sqlite,
      secretStore: KeychainSecretStore(service: "test.journal.\(UUID().uuidString)", backend: MemorySecrets()),
      quickCaptureGenerator: generator
    )
    let state = AppState(
      backendProfileManager: BackendProfileManager(
        defaults: defaults,
        defaultsKey: "journal.backend",
        registry: BackendProfileRegistry(
          descriptors: BackendProfileRegistry.live.descriptors,
          validators: [.sqliteLocal: { .available(message: "ok") }]
        )
      ),
      sqliteBackendAdapter: sqlite,
      serenityCloudAdapter: nil,
      externalPostgresAdapter: nil,
      aiWorkflowService: service
    )
    return (state, service)
  }

  func testTypedTitleIsKept() async throws {
    let (state, _) = try makeState()

    let title = await state.journalTitle("  Morning pages ", content: "Slept well.", date: Date())

    XCTAssertEqual(title, "Morning pages")
  }

  func testUntitledEntryTakesTheModelsTitle() async throws {
    let (state, service) = try makeState { _, _, _, _, _, _ in
      AIProviderTextGenerationResponse(text: #"{"title":"“Better after the walk.”"}"#, promptTokens: 10, completionTokens: 4)
    }
    _ = try await service.addCredential(provider: .openai, name: "OpenAI", apiKey: "sk-test", modelPreference: "gpt-4o")

    let saved = await state.createJournalEntry(title: "", content: "Felt scattered first thing, better after the walk.", mood: nil, tags: [])

    XCTAssertTrue(saved)
    XCTAssertEqual(state.journalEntries.first?.title, "Better after the walk")
  }

  func testWithoutAModelTheDateAndTimeBecomeTheTitle() async throws {
    let (state, _) = try makeState()

    let saved = await state.createJournalEntry(title: "", content: "Quiet day.", mood: nil, tags: [])

    XCTAssertTrue(saved)
    let entry = try XCTUnwrap(state.journalEntries.first)
    XCTAssertEqual(entry.title, AppState.datedJournalTitle(entry.date))
  }

  func testClearingATitleOnEditGivesItOneAgain() async throws {
    let (state, _) = try makeState()
    _ = await state.createJournalEntry(title: "Draft", content: "Quiet day.", mood: nil, tags: [])
    let entry = try XCTUnwrap(state.journalEntries.first)

    await state.updateJournalEntry(id: entry.id, title: " ", content: "Quiet day.", mood: nil, tags: [])

    XCTAssertEqual(state.journalEntries.first?.title, AppState.datedJournalTitle(entry.date))
  }

  func testCleanTitleStripsQuotesAndClosingPunctuation() {
    XCTAssertEqual(AppState.cleanJournalTitle("  \"A slow start!\" "), "A slow start")
    XCTAssertNil(AppState.cleanJournalTitle("  ...  "))
    XCTAssertNil(AppState.cleanJournalTitle(nil))
  }
}
