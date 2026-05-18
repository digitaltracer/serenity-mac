import Foundation
import XCTest
@testable import SerenityMac

final class AIRepositoriesTests: XCTestCase {
  func testInsightRepositorySaveFilterAndFeedback() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let insight = AIInsightEntity(
      id: UUID().uuidString,
      provider: .openai,
      type: .productivity,
      title: "Consistency gap",
      description: "Task completion drops on weekends.",
      confidence: 0.88,
      category: .tasks,
      actionable: true,
      metadataJSON: #"{"window":"weekly"}"#,
      createdAt: now,
      updatedAt: now,
      userRating: nil,
      dismissed: false,
      markedHelpful: false,
      userNotes: nil,
      visualizationDataJSON: nil,
      actionabilitySuggestions: ["Plan weekend review"],
      themeID: nil,
      isRecurring: false,
      occurrenceNumber: 1
    )

    try repositories.insights.save(insight)

    let fetched = try repositories.insights.fetchByID(insight.id)
    XCTAssertEqual(fetched?.title, insight.title)
    XCTAssertEqual(fetched?.actionabilitySuggestions, insight.actionabilitySuggestions)

    try repositories.insights.updateFeedback(
      id: insight.id,
      userRating: 5,
      dismissed: true,
      markedHelpful: true,
      userNotes: "Useful signal"
    )

    let updated = try repositories.insights.fetchByID(insight.id)
    XCTAssertEqual(updated?.userRating, 5)
    XCTAssertTrue(updated?.dismissed ?? false)
    XCTAssertTrue(updated?.markedHelpful ?? false)
    XCTAssertEqual(updated?.userNotes, "Useful signal")

    let dismissed = try repositories.insights.fetchFiltered(
      category: .tasks,
      type: .productivity,
      dismissed: true,
      limit: 10,
      offset: 0
    )
    XCTAssertEqual(dismissed.count, 1)
    XCTAssertEqual(dismissed.first?.id, insight.id)
  }

  func testRecapRepositorySaveAndInteractionUpdates() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let recap = AIRecapEntity(
      id: UUID().uuidString,
      provider: .anthropic,
      type: .weekly,
      title: "Weekly recap",
      summary: "Strong focus and execution.",
      highlights: ["Finished milestones"],
      challenges: ["Context switching"],
      recommendations: ["Batch similar work"],
      period: AIRecapPeriod(start: now.addingTimeInterval(-604_800), end: now),
      metadataJSON: #"{"quality":"high"}"#,
      createdAt: now,
      updatedAt: now,
      viewed: false,
      favorited: false,
      exported: false
    )

    try repositories.recaps.save(recap)
    try repositories.recaps.updateInteraction(id: recap.id, viewed: true, favorited: true, exported: false)

    let fetched = try repositories.recaps.fetchByID(recap.id)
    XCTAssertTrue(fetched?.viewed ?? false)
    XCTAssertTrue(fetched?.favorited ?? false)
    XCTAssertFalse(fetched?.exported ?? true)

    let favorites = try repositories.recaps.fetchFiltered(type: .weekly, favorited: true, limit: 10, offset: 0)
    XCTAssertEqual(favorites.count, 1)
    XCTAssertEqual(favorites.first?.id, recap.id)
  }

  func testUsageAndSummaryRepositoriesSaveAndQuery() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let usage = AIUsageEntity(
      id: UUID().uuidString,
      timestamp: now,
      provider: .gemini,
      operation: .summary,
      model: "gemini-2.0-flash",
      promptTokens: 120,
      completionTokens: 80,
      totalTokens: 200,
      inputCostUSD: 0.000042,
      outputCostUSD: 0.000084,
      totalCostUSD: 0.000126
    )

    try repositories.usage.save(usage)

    let usageRows = try repositories.usage.fetchAll(limit: 10)
    XCTAssertEqual(usageRows.count, 1)
    XCTAssertEqual(usageRows.first?.totalTokens, 200)
    XCTAssertEqual(usageRows.first?.model, "gemini-2.0-flash")
    XCTAssertEqual(usageRows.first?.totalCostUSD, 0.000126)

    let summary = SummaryEntity(
      id: UUID().uuidString,
      title: "Sprint summary",
      content: "Progress improved.",
      summaryType: .combined,
      startDate: now.addingTimeInterval(-86_400 * 7),
      endDate: now,
      generatedAt: now,
      wordCount: 42,
      metadataJSON: #"{"source":"ai"}"#,
      provider: .openai,
      promptTokens: 300,
      completionTokens: 120,
      totalTokens: 420,
      createdAt: now,
      updatedAt: now
    )

    try repositories.summaries.save(summary)

    let fetchedSummary = try repositories.summaries.fetchByID(summary.id)
    XCTAssertEqual(fetchedSummary?.title, summary.title)

    let byType = try repositories.summaries.fetchByType(.combined)
    XCTAssertEqual(byType.count, 1)

    let byRange = try repositories.summaries.fetchByDateRange(
      startDate: now.addingTimeInterval(-86_400 * 14),
      endDate: now.addingTimeInterval(86_400)
    )
    XCTAssertEqual(byRange.count, 1)
    XCTAssertEqual(byRange.first?.id, summary.id)
  }

  func testModelRateRepositorySaveQueryAndDelete() async throws {
    let repositories = try await makeRepositorySet()
    let rate = AIModelRateEntity(
      provider: .openai,
      model: "gpt-4o-mini",
      inputUSDPerMillion: 0.15,
      outputUSDPerMillion: 0.6,
      source: .user
    )

    try repositories.modelRates.save(rate)

    let fetched = try repositories.modelRates.fetch(provider: .openai, model: "GPT-4O-MINI")
    XCTAssertEqual(fetched?.model, "gpt-4o-mini")
    XCTAssertEqual(fetched?.inputUSDPerMillion, 0.15)
    XCTAssertEqual(fetched?.outputUSDPerMillion, 0.6)
    XCTAssertEqual(fetched?.source, .user)

    let updated = AIModelRateEntity(
      provider: .openai,
      model: "gpt-4o-mini",
      inputUSDPerMillion: 0.2,
      outputUSDPerMillion: 0.8,
      source: .litellm
    )
    try repositories.modelRates.save(updated)

    XCTAssertEqual(try repositories.modelRates.fetchAll().count, 1)
    XCTAssertEqual(try repositories.modelRates.fetch(provider: .openai, model: "gpt-4o-mini")?.inputUSDPerMillion, 0.2)

    try repositories.modelRates.delete(provider: .openai, model: "gpt-4o-mini")
    XCTAssertNil(try repositories.modelRates.fetch(provider: .openai, model: "gpt-4o-mini"))
  }

  func testCostServiceSeedsCalculatesAndBackfillsUsageCosts() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()
    let usage = AIUsageEntity(
      id: UUID().uuidString,
      timestamp: now,
      provider: .gemini,
      operation: .quickadd,
      promptTokens: 100,
      completionTokens: 200,
      totalTokens: 300
    )

    try repositories.usage.save(usage)
    try AIUsageCostService.seedDefaultRatesIfNeeded(repositories: repositories)
    let backfilled = try AIUsageCostService.backfillMissingCostsIfNeeded(
      repositories: repositories,
      settings: .defaultValue
    )

    XCTAssertEqual(backfilled, 1)
    let fetched = try repositories.usage.fetchAll(limit: 1).first
    XCTAssertEqual(fetched?.model, "gemini-3-pro-preview")
    XCTAssertEqual(fetched?.inputCostUSD, 0.0002)
    XCTAssertEqual(fetched?.outputCostUSD, 0.0024)
    XCTAssertEqual(fetched?.totalCostUSD, 0.0026)

    let calculated = try AIUsageCostService.calculateCosts(
      provider: .gemini,
      model: "gemini-3-pro-preview",
      promptTokens: 100,
      completionTokens: 200,
      repositories: repositories
    )
    XCTAssertEqual(calculated.totalCostUSD, 0.0026)
  }

  func testLiteLLMPricingParserConvertsPerTokenRates() throws {
    let json = """
    {
      "openai/gpt-4o-mini": {
        "litellm_provider": "openai",
        "mode": "chat",
        "input_cost_per_token": 0.00000015,
        "output_cost_per_token": 0.0000006
      }
    }
    """

    let rate = try AIUsageCostService.parseLiteLLMRate(
      provider: .openai,
      model: "gpt-4o-mini",
      data: Data(json.utf8)
    )

    XCTAssertEqual(rate?.provider, .openai)
    XCTAssertEqual(rate?.model, "gpt-4o-mini")
    XCTAssertEqual(rate?.inputUSDPerMillion, 0.15)
    XCTAssertEqual(rate?.outputUSDPerMillion, 0.6)
    XCTAssertEqual(rate?.source, .litellm)
  }

  func testCredentialAndSettingsRepositories() async throws {
    let repositories = try await makeRepositorySet()
    let now = Date()

    let credentialA = AICredentialEntity(
      id: UUID().uuidString,
      provider: .openai,
      name: "primary",
      apiKeyEncrypted: "enc_primary",
      modelPreference: "gpt-5",
      enabled: true,
      priority: 1,
      metadataJSON: #"{}"#,
      lastUsedAt: nil,
      totalRequests: 0,
      totalTokens: 0,
      successCount: 0,
      errorCount: 0,
      lastError: nil,
      lastErrorAt: nil,
      createdAt: now,
      updatedAt: now
    )

    let credentialB = AICredentialEntity(
      id: UUID().uuidString,
      provider: .openai,
      name: "secondary",
      apiKeyEncrypted: "enc_secondary",
      modelPreference: nil,
      enabled: true,
      priority: 0,
      metadataJSON: #"{}"#,
      lastUsedAt: nil,
      totalRequests: 0,
      totalTokens: 0,
      successCount: 0,
      errorCount: 0,
      lastError: nil,
      lastErrorAt: nil,
      createdAt: now,
      updatedAt: now
    )

    try repositories.credentials.save(credentialA)
    try repositories.credentials.save(credentialB)

    let ordered = try repositories.credentials.fetchByProvider(.openai, enabledOnly: true)
    XCTAssertEqual(ordered.count, 2)
    XCTAssertEqual(ordered.first?.id, credentialB.id)

    try repositories.credentials.recordSuccess(id: credentialA.id, tokensUsed: 250, at: now)
    try repositories.credentials.recordError(id: credentialA.id, message: "rate_limited", at: now)

    let updatedA = try repositories.credentials.fetchByID(credentialA.id)
    XCTAssertEqual(updatedA?.totalRequests, 2)
    XCTAssertEqual(updatedA?.successCount, 1)
    XCTAssertEqual(updatedA?.errorCount, 1)
    XCTAssertEqual(updatedA?.totalTokens, 250)
    XCTAssertEqual(updatedA?.lastError, "rate_limited")

    try repositories.credentials.updatePriorities([
      (id: credentialA.id, priority: 0),
      (id: credentialB.id, priority: 2),
    ])

    let reprioritized = try repositories.credentials.fetchByProvider(.openai, enabledOnly: true)
    XCTAssertEqual(reprioritized.first?.id, credentialA.id)

    let settings = AISettingsEntity(
      activeProvider: .openai,
      autoAnalyze: true,
      analysisFrequency: .weekly,
      dataTypes: AISettingsDataTypes(includeTasks: true, includeJournal: true, includeProjects: false),
      preferredModels: AIPreferredModels(openai: "gpt-5", gemini: nil, anthropic: nil)
    )

    try repositories.settings.save(settings)
    let loadedSettings = try repositories.settings.fetch()
    XCTAssertEqual(loadedSettings, settings)

    try repositories.settings.clear()
    XCTAssertNil(try repositories.settings.fetch())
  }

  private func makeRepositorySet() async throws -> GRDBAIRepositorySet {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("serenity-macos-ai-repositories")
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("serenity.sqlite3")

    let runner = DatabaseMigrationRunner()
    _ = try await runner.bootstrapDatabase(at: databaseURL)

    return try GRDBAIRepositorySet.make(databasePath: databaseURL.path)
  }
}
