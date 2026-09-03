import Foundation

enum AIWorkflowError: Error, LocalizedError, Equatable {
  case noCredentialConfigured
  case missingCredentialSecret(String)
  case credentialNotFound(String)
  case summaryNotFound(String)
  case invalidQuickCaptureResponse(String)

  var errorDescription: String? {
    switch self {
    case .noCredentialConfigured:
      return "No enabled AI credential is configured. Add a provider key in Insights."
    case .missingCredentialSecret(let id):
      return "Credential \(id) is missing its keychain secret."
    case .credentialNotFound(let id):
      return "Credential \(id) was not found."
    case .summaryNotFound(let id):
      return "Summary \(id) was not found."
    case .invalidQuickCaptureResponse(let reason):
      return "AI quick capture response was invalid: \(reason)"
    }
  }
}

struct AIProviderModelCatalog {
  static let models: [AICredentialProvider: [String]] = [
    .openai: [
      "gpt-5.5",
      "gpt-5.5-pro",
      "gpt-5.4",
      "gpt-5.4-pro",
      "gpt-5.4-mini",
      "gpt-5.4-nano",
    ],
    .gemini: [
      "gemini-3-pro-preview",
      "gemini-3-flash-preview",
      "gemini-2.5-pro",
      "gemini-2.5-flash-preview-09-2025",
      "gemini-2.5-flash",
      "gemini-2.5-flash-lite",
    ],
    .nvidia: [
      "nvidia/nemotron-3.5-lightning-30b-a3b",
      "nvidia/nemotron-nano-3-30b-a3b",
      "nvidia/nemotron-3-super-120b-a12b",
      "nvidia/nemotron-3-ultra-550b-a55b",
      "openai/gpt-oss-120b",
      "deepseek-ai/deepseek-v4-flash-0731",
    ],
    .anthropic: [
      "claude-opus-4-7",
      "claude-opus-4-6",
      "claude-sonnet-4-6",
      "claude-opus-4-5",
      "claude-sonnet-4-5",
      "claude-haiku-4-5",
    ],
  ]
}

struct AICredentialSelectionResult {
  let credential: AICredentialEntity
  let apiKey: String
  let model: String
}

struct AIWorkflowSnapshot {
  let credentials: [AICredentialEntity]
  let settings: AISettingsEntity
  let insights: [AIInsightEntity]
  let recaps: [AIRecapEntity]
  let summaries: [SummaryEntity]
  let usage: [AIUsageEntity]
  let modelRates: [AIModelRateEntity]
}

actor AIWorkflowService {
  typealias QuickCaptureGenerationHandler = (
    AICredentialProvider,
    String,
    String,
    String,
    String,
    [String: Any]
  ) async throws -> AIProviderTextGenerationResponse

  private let sqliteBackendAdapter: SQLiteBackendAdapter
  private let secretStore: KeychainSecretStore
  private let quickCaptureGenerator: QuickCaptureGenerationHandler
  private var repositories: GRDBAIRepositorySet?
  private var pendingSyncStore: PendingSyncChangeStore?

  init(
    sqliteBackendAdapter: SQLiteBackendAdapter,
    secretStore: KeychainSecretStore = KeychainSecretStore(service: "com.digitaltracer.serenity.ai"),
    quickCaptureGenerator: @escaping QuickCaptureGenerationHandler = AIProviderAPIClient.generateQuickCaptureJSON
  ) {
    self.sqliteBackendAdapter = sqliteBackendAdapter
    self.secretStore = secretStore
    self.quickCaptureGenerator = quickCaptureGenerator
  }

  func modelCatalog() -> [AICredentialProvider: [String]] {
    AIProviderModelCatalog.models
  }

  func validateAPIKey(provider: AICredentialProvider, apiKey: String) async throws -> [String] {
    try await AIProviderAPIClient.fetchModels(provider: provider, apiKey: apiKey)
  }

  func classifyQuickCapture(
    input: String,
    credentialID: String,
    projects: [AIQuickCaptureProjectContext],
    availableTags: [String],
    now: Date = Date()
  ) async throws -> AIQuickCaptureClassification {
    let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else {
      throw AIWorkflowError.invalidQuickCaptureResponse("Input was empty")
    }

    let repositories = try await requireRepositories()
    let selection = try chooseCredential(id: credentialID)
    let schema = quickCaptureSchema()
    let systemPrompt = quickCaptureSystemPrompt()
    let userPrompt = quickCaptureUserPrompt(
      input: trimmedInput,
      projects: projects,
      availableTags: availableTags,
      now: now
    )

    do {
      let response = try await quickCaptureGenerator(
        selection.credential.provider,
        selection.apiKey,
        selection.model,
        systemPrompt,
        userPrompt,
        schema
      )
      do {
        let classification = try decodeQuickCaptureClassification(
          response.text,
          projects: projects,
          availableTags: availableTags
        )
        try recordUsage(
          repositories: repositories,
          selection: selection,
          operation: .quickadd,
          promptTokens: response.promptTokens,
          completionTokens: response.completionTokens
        )
        return classification
      } catch {
        let repairPrompt = quickCaptureRepairPrompt(
          invalidResponse: response.text,
          validationError: error.localizedDescription,
          schema: schema
        )
        let repaired = try await quickCaptureGenerator(
          selection.credential.provider,
          selection.apiKey,
          selection.model,
          systemPrompt,
          repairPrompt,
          schema
        )
        let classification = try decodeQuickCaptureClassification(
          repaired.text,
          projects: projects,
          availableTags: availableTags
        )
        try recordUsage(
          repositories: repositories,
          selection: selection,
          operation: .quickadd,
          promptTokens: response.promptTokens + repaired.promptTokens,
          completionTokens: response.completionTokens + repaired.completionTokens
        )
        return classification
      }
    } catch {
      try? repositories.credentials.recordError(id: selection.credential.id, message: error.localizedDescription, at: Date())
      throw error
    }
  }

  func fetchSnapshot(limit: Int = 200) async throws -> AIWorkflowSnapshot {
    let repositories = try await requireRepositories()
    let settings = try repositories.settings.fetch() ?? .defaultValue
    try AIUsageCostService.seedDefaultRatesIfNeeded(repositories: repositories)
    _ = try AIUsageCostService.backfillMissingCostsIfNeeded(repositories: repositories, settings: settings)
    return AIWorkflowSnapshot(
      credentials: try repositories.credentials.fetchAll(enabledOnly: false),
      settings: settings,
      insights: try repositories.insights.fetchAll(limit: limit),
      recaps: try repositories.recaps.fetchAll(limit: limit),
      summaries: try repositories.summaries.fetchAll(),
      usage: try repositories.usage.fetchAll(limit: limit),
      modelRates: try repositories.modelRates.fetchAll()
    )
  }

  func saveModelRate(_ rate: AIModelRateEntity) async throws {
    let repositories = try await requireRepositories()
    try repositories.modelRates.save(rate)
    let settings = try repositories.settings.fetch() ?? .defaultValue
    _ = try AIUsageCostService.backfillMissingCostsIfNeeded(
      repositories: repositories,
      settings: settings,
      provider: rate.provider,
      model: rate.model
    )
  }

  func deleteModelRate(provider: AIUsageProvider, model: String) async throws {
    let repositories = try await requireRepositories()
    try repositories.modelRates.delete(provider: provider, model: model)
  }

  func resetModelRatesToDefaults() async throws {
    let repositories = try await requireRepositories()
    try AIUsageCostService.resetRatesToDefaults(repositories: repositories)
    let settings = try repositories.settings.fetch() ?? .defaultValue
    _ = try AIUsageCostService.backfillMissingCostsIfNeeded(repositories: repositories, settings: settings)
  }

  func refreshMissingModelRatesFromLiteLLM() async throws -> Int {
    let repositories = try await requireRepositories()
    let settings = try repositories.settings.fetch() ?? .defaultValue
    let usageRows = try repositories.usage.fetchAll(limit: 10_000)
    var savedKeys = Set<String>()

    for usage in usageRows {
      let model = AIUsageCostService.resolvedModel(for: usage, settings: settings)
      guard !model.isEmpty else { continue }
      let key = "\(usage.provider.rawValue)::\(model.lowercased())"
      guard !savedKeys.contains(key) else { continue }
      if try repositories.modelRates.fetch(provider: usage.provider, model: model) != nil {
        continue
      }
      guard let rate = try await AIUsageCostService.fetchLiteLLMRate(provider: usage.provider, model: model) else {
        continue
      }
      try repositories.modelRates.save(rate)
      savedKeys.insert(key)
    }

    _ = try AIUsageCostService.backfillMissingCostsIfNeeded(repositories: repositories, settings: settings)
    return savedKeys.count
  }

  func configureCloudSync(pendingStore: PendingSyncChangeStore) {
    pendingSyncStore = pendingStore
    repositories = nil
  }

  func addCredential(
    provider: AICredentialProvider,
    name: String,
    apiKey: String,
    modelPreference: String?,
    availableModels: [String]? = nil
  ) async throws -> AICredentialEntity {
    let repositories = try await requireRepositories()
    let now = Date()
    let id = UUID().uuidString
    let keychainKey = keychainKeyForCredential(id)

    try secretStore.setSecret(apiKey, for: keychainKey)

    let currentCount = try repositories.credentials.fetchAll(enabledOnly: false).count
    let credential = AICredentialEntity(
      id: id,
      provider: provider,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(provider.rawValue.capitalized) Credential" : name,
      apiKeyEncrypted: "keychain://\(keychainKey)",
      modelPreference: modelPreference,
      enabled: true,
      priority: currentCount,
      metadataJSON: encodeCredentialMetadata(availableModels: availableModels),
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

    try repositories.credentials.save(credential)
    return credential
  }

  private func encodeCredentialMetadata(availableModels: [String]?) -> String {
    guard let availableModels, !availableModels.isEmpty else { return "{}" }
    let payload: [String: Any] = ["availableModels": availableModels]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  func updateCredential(
    id: String,
    enabled: Bool? = nil,
    name: String? = nil,
    modelPreference: String? = nil,
    priority: Int? = nil
  ) async throws -> AICredentialEntity {
    let repositories = try await requireRepositories()
    guard var credential = try repositories.credentials.fetchByID(id) else {
      throw AIWorkflowError.credentialNotFound(id)
    }

    if let enabled {
      credential.enabled = enabled
    }
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        credential.name = trimmed
      }
    }
    if let modelPreference {
      let trimmed = modelPreference.trimmingCharacters(in: .whitespacesAndNewlines)
      credential.modelPreference = trimmed.isEmpty ? nil : trimmed
    }
    if let priority {
      credential.priority = max(0, priority)
    }
    credential.updatedAt = Date()

    try repositories.credentials.save(credential)
    return credential
  }

  func deleteCredential(id: String) async throws {
    let repositories = try await requireRepositories()
    try repositories.credentials.delete(id: id)
    try secretStore.deleteSecret(for: keychainKeyForCredential(id))
  }

  func saveSettings(_ settings: AISettingsEntity) async throws {
    let repositories = try await requireRepositories()
    try repositories.settings.save(settings)
  }

  func generateInsights(
    tasks: [TaskEntity],
    journalEntries: [JournalEntryEntity],
    projects: [ProjectEntity],
    goals: [GoalEntity]
  ) async throws -> [AIInsightEntity] {
    let repositories = try await requireRepositories()
    let settings = try repositories.settings.fetch() ?? .defaultValue
    let selection = try chooseCredential(settings: settings)
    let now = Date()

    let completedTasks = tasks.filter(\.completed).count
    let totalTasks = max(1, tasks.count)
    let completionRate = Double(completedTasks) / Double(totalTasks)
    let overdueTasks = tasks.filter { !$0.completed && ($0.dueDate ?? now) < now }.count
    let pinnedEntries = journalEntries.filter(\.pinned).count
    let activeGoals = goals.filter { $0.status == .active }.count

    var created: [AIInsightEntity] = []

    created.append(
      AIInsightEntity(
        id: UUID().uuidString,
        provider: providerForCredential(selection.credential.provider),
        type: completionRate >= 0.7 ? .productivity : .warning,
        title: completionRate >= 0.7 ? "Strong completion trend" : "Completion trend needs attention",
        description: "You completed \(completedTasks) of \(tasks.count) tasks (\(Int(completionRate * 100))%).",
        confidence: 0.72,
        category: .tasks,
        actionable: true,
        metadataJSON: #"{"metric":"completion_rate"}"#,
        createdAt: now,
        updatedAt: now,
        userRating: nil,
        dismissed: false,
        markedHelpful: false,
        userNotes: nil,
        visualizationDataJSON: nil,
        actionabilitySuggestions: completionRate >= 0.7
          ? ["Keep your daily planning cadence"]
          : ["Reduce scope on daily task list", "Prioritize high-impact tasks first"],
        themeID: "tasks-completion",
        isRecurring: true,
        occurrenceNumber: 1
      )
    )

    created.append(
      AIInsightEntity(
        id: UUID().uuidString,
        provider: providerForCredential(selection.credential.provider),
        type: overdueTasks > 0 ? .warning : .behavior,
        title: overdueTasks > 0 ? "Overdue tasks detected" : "Due-date hygiene is healthy",
        description: overdueTasks > 0
          ? "You currently have \(overdueTasks) overdue task(s)."
          : "You currently have no overdue tasks.",
        confidence: 0.69,
        category: .tasks,
        actionable: overdueTasks > 0,
        metadataJSON: #"{"metric":"overdue_tasks"}"#,
        createdAt: now,
        updatedAt: now,
        userRating: nil,
        dismissed: false,
        markedHelpful: false,
        userNotes: nil,
        visualizationDataJSON: nil,
        actionabilitySuggestions: overdueTasks > 0
          ? ["Schedule a recovery block for overdue items"]
          : ["Maintain current due-date management approach"],
        themeID: "tasks-overdue",
        isRecurring: true,
        occurrenceNumber: 1
      )
    )

    created.append(
      AIInsightEntity(
        id: UUID().uuidString,
        provider: providerForCredential(selection.credential.provider),
        type: .recommendation,
        title: "Cross-surface focus recommendation",
        description: "You have \(activeGoals) active goal(s), \(projects.count) project(s), and \(pinnedEntries) pinned journal entr\(pinnedEntries == 1 ? "y" : "ies").",
        confidence: 0.64,
        category: .goals,
        actionable: true,
        metadataJSON: #"{"metric":"cross_surface_focus"}"#,
        createdAt: now,
        updatedAt: now,
        userRating: nil,
        dismissed: false,
        markedHelpful: false,
        userNotes: nil,
        visualizationDataJSON: nil,
        actionabilitySuggestions: [
          "Link at least one task to each active goal",
          "Write a short daily journal checkpoint for your top project",
        ],
        themeID: "cross-surface",
        isRecurring: false,
        occurrenceNumber: 1
      )
    )

    for insight in created {
      try repositories.insights.save(insight)
    }

    try recordUsage(
      repositories: repositories,
      selection: selection,
      operation: .analyze,
      promptTokens: 180,
      completionTokens: 120
    )

    return created
  }

  func updateInsightFeedback(
    id: String,
    userRating: Int?,
    dismissed: Bool?,
    markedHelpful: Bool?,
    userNotes: String?
  ) async throws {
    let repositories = try await requireRepositories()
    try repositories.insights.updateFeedback(
      id: id,
      userRating: userRating,
      dismissed: dismissed,
      markedHelpful: markedHelpful,
      userNotes: userNotes
    )
  }

  func generateRecap(
    type: AIRecapType,
    tasks: [TaskEntity],
    journalEntries: [JournalEntryEntity],
    projects: [ProjectEntity]
  ) async throws -> AIRecapEntity {
    let repositories = try await requireRepositories()
    let settings = try repositories.settings.fetch() ?? .defaultValue
    let selection = try chooseCredential(settings: settings)
    let now = Date()

    let days = type == .weekly ? 7 : 30
    let periodStart = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    let completedTasks = tasks.filter(\.completed).count

    let recap = AIRecapEntity(
      id: UUID().uuidString,
      provider: providerForCredential(selection.credential.provider),
      type: type,
      title: "\(type == .weekly ? "Weekly" : "Monthly") recap",
      summary: "Completed \(completedTasks) task(s), captured \(journalEntries.count) journal entr\(journalEntries.count == 1 ? "y" : "ies"), and tracked \(projects.count) project(s).",
      highlights: [
        "Task completion this period: \(completedTasks)",
        "Journal consistency: \(journalEntries.count) entries",
      ],
      challenges: tasks.filter { !$0.completed }.isEmpty ? ["No major blockers detected"] : ["\(tasks.filter { !$0.completed }.count) incomplete task(s) remain"],
      recommendations: [
        "Schedule focused work blocks for top-priority tasks",
        "Review project backlog at the start of each week",
      ],
      period: AIRecapPeriod(start: periodStart, end: now),
      metadataJSON: #"{"generated":"deterministic"}"#,
      createdAt: now,
      updatedAt: now,
      viewed: false,
      favorited: false,
      exported: false
    )

    try repositories.recaps.save(recap)
    try recordUsage(
      repositories: repositories,
      selection: selection,
      operation: .recap,
      promptTokens: 120,
      completionTokens: 140
    )

    return recap
  }

  func updateRecapInteraction(id: String, viewed: Bool?, favorited: Bool?, exported: Bool?) async throws {
    let repositories = try await requireRepositories()
    try repositories.recaps.updateInteraction(id: id, viewed: viewed, favorited: favorited, exported: exported)
  }

  func generateSummary(
    type: SummaryType,
    tasks: [TaskEntity],
    journalEntries: [JournalEntryEntity],
    startDate: Date? = nil,
    endDate: Date? = nil
  ) async throws -> SummaryEntity {
    let repositories = try await requireRepositories()
    let settings = try repositories.settings.fetch() ?? .defaultValue
    let selection = try chooseCredential(settings: settings)
    let now = Date()
    let periodStart = startDate ?? Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
    let periodEnd = endDate ?? now

    let taskLines = tasks.prefix(8).map { task in
      "- [\((task.completed ? "x" : " "))] \(task.title)"
    }

    let journalLines = journalEntries.prefix(4).map { entry in
      "- \(entry.title ?? "Entry"): \(entry.content.prefix(120))"
    }

    let content: String
    switch type {
    case .tasks:
      content = (["Task Summary", ""] + taskLines).joined(separator: "\n")
    case .journal:
      content = (["Journal Summary", ""] + journalLines).joined(separator: "\n")
    case .combined:
      content = (["Combined Summary", "", "Tasks:"] + taskLines + ["", "Journal:"] + journalLines).joined(separator: "\n")
    }

    let summary = SummaryEntity(
      id: UUID().uuidString,
      title: "\(type.rawValue.capitalized) Summary",
      content: content,
      summaryType: type,
      startDate: periodStart,
      endDate: periodEnd,
      generatedAt: now,
      wordCount: content.split(separator: " ").count,
      metadataJSON: #"{"generated":"deterministic"}"#,
      provider: providerForCredential(selection.credential.provider),
      promptTokens: 90,
      completionTokens: 160,
      totalTokens: 250,
      createdAt: now,
      updatedAt: now
    )

    try repositories.summaries.save(summary)
    try recordUsage(
      repositories: repositories,
      selection: selection,
      operation: .summary,
      promptTokens: summary.promptTokens,
      completionTokens: summary.completionTokens
    )

    return summary
  }

  func deleteSummary(id: String) async throws {
    let repositories = try await requireRepositories()
    try repositories.summaries.delete(id: id)
  }

  func exportSummary(id: String) async throws -> String {
    let repositories = try await requireRepositories()
    guard let summary = try repositories.summaries.fetchByID(id) else {
      throw AIWorkflowError.summaryNotFound(id)
    }

    let applicationSupportDirectory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let exportsDirectory = applicationSupportDirectory
      .appendingPathComponent("Serenity", isDirectory: true)
      .appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    let filename = "summary-\(summary.id)-\(formatter.string(from: Date())).md"
    let fileURL = exportsDirectory.appendingPathComponent(filename)
    let markdown = "# \(summary.title)\n\n\(summary.content)\n"
    try markdown.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    return fileURL.path
  }

  private struct RawQuickCaptureClassification: Decodable {
    var kind: AIQuickCaptureKind
    var confidence: Double
    var newProjects: [RawQuickCaptureProject]?
    var tasks: [RawQuickCaptureTask]
    var journal: RawQuickCaptureJournal?
  }

  private struct RawQuickCaptureTask: Decodable {
    var title: String
    var description: String?
    var priority: String?
    var dueDate: String?
    var projectId: String?
    var projectName: String?
    var tags: [String]?
    var subtasks: [String]?

    enum CodingKeys: String, CodingKey {
      case title
      case description
      case priority
      case dueDate
      case projectId
      case projectName
      case tags
      case subtasks
    }
  }

  private struct RawQuickCaptureProject: Decodable {
    var name: String
    var description: String?
  }

  private struct RawQuickCaptureJournal: Decodable {
    var title: String?
    var content: String
    var mood: String?
    var tags: [String]?
  }

  private func decodeQuickCaptureClassification(
    _ text: String,
    projects: [AIQuickCaptureProjectContext],
    availableTags: [String]
  ) throws -> AIQuickCaptureClassification {
    let jsonText = extractJSONObject(from: text)
    guard let data = jsonText.data(using: .utf8) else {
      throw AIWorkflowError.invalidQuickCaptureResponse("Response was not UTF-8 text")
    }

    let raw: RawQuickCaptureClassification
    do {
      raw = try JSONDecoder().decode(RawQuickCaptureClassification.self, from: data)
    } catch {
      throw AIWorkflowError.invalidQuickCaptureResponse(error.localizedDescription)
    }

    let activeProjectIDs = Set(projects.filter { !$0.archived }.map(\.id))
    let activeProjectNames = Set(projects.filter { !$0.archived }.map { normalizedProjectName($0.name) }.filter { !$0.isEmpty })
    let newProjects = normalizeProjectDrafts(raw.newProjects ?? [], existingProjectNames: activeProjectNames)
    let confidence = min(1, max(0, raw.confidence))

    switch raw.kind {
    case .tasks:
      let tasks = raw.tasks.compactMap { rawTask -> AIQuickCaptureTaskDraft? in
        let title = rawTask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let projectID = rawTask.projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validProjectID = projectID.flatMap { activeProjectIDs.contains($0) ? $0 : nil }
        let projectName = rawTask.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawTask.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let priority = rawTask.priority
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
          .flatMap(TaskPriority.init(rawValue:)) ?? .medium

        return AIQuickCaptureTaskDraft(
          title: title,
          description: description?.isEmpty == true ? nil : description,
          priority: priority,
          dueDate: parseQuickCaptureDueDate(rawTask.dueDate),
          projectId: validProjectID,
          projectName: projectName?.isEmpty == true ? nil : projectName,
          tags: normalizeTags(rawTask.tags ?? []),
          subtasks: normalizeList(rawTask.subtasks ?? [])
        )
      }
      guard !tasks.isEmpty else {
        throw AIWorkflowError.invalidQuickCaptureResponse("Task classification did not include any valid tasks")
      }
      return AIQuickCaptureClassification(
        kind: .tasks,
        confidence: confidence,
        newProjects: newProjects,
        tasks: tasks,
        journal: nil
      )

    case .journal:
      guard let rawJournal = raw.journal else {
        throw AIWorkflowError.invalidQuickCaptureResponse("Journal classification did not include a journal object")
      }
      let content = rawJournal.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else {
        throw AIWorkflowError.invalidQuickCaptureResponse("Journal classification did not include content")
      }
      let title = rawJournal.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let mood = rawJournal.mood
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap(JournalMood.init(rawValue:))
      let journal = AIQuickCaptureJournalDraft(
        title: title?.isEmpty == true ? nil : title,
        content: content,
        mood: mood,
        tags: normalizeTags(rawJournal.tags ?? [])
      )
      return AIQuickCaptureClassification(kind: .journal, confidence: confidence, tasks: [], journal: journal)
    }
  }

  private func extractJSONObject(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let start = trimmed.firstIndex(of: "{"),
      let end = trimmed.lastIndex(of: "}"),
      start <= end
    else {
      return trimmed
    }
    return String(trimmed[start...end])
  }

  private func normalizeProjectDrafts(
    _ projects: [RawQuickCaptureProject],
    existingProjectNames: Set<String>
  ) -> [AIQuickCaptureProjectDraft] {
    var seen = existingProjectNames
    var normalized: [AIQuickCaptureProjectDraft] = []
    for project in projects {
      let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizedProjectName(name)
      guard !key.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)

      let description = project.description?.trimmingCharacters(in: .whitespacesAndNewlines)
      normalized.append(
        AIQuickCaptureProjectDraft(
          name: name,
          description: description?.isEmpty == true ? nil : description
        )
      )
    }
    return normalized
  }

  private func normalizeTags(_ tags: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    for tag in tags {
      let value = normalizeTag(tag)
      guard !value.isEmpty, !seen.contains(value) else { continue }
      seen.insert(value)
      normalized.append(value)
    }
    return normalized
  }

  private func normalizeTag(_ tag: String) -> String {
    tag
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
  }

  private func normalizedProjectName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func normalizeList(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { continue }
      seen.insert(trimmed.lowercased())
      normalized.append(trimmed)
    }
    return normalized
  }

  private func parseQuickCaptureDueDate(_ rawDate: String?) -> Date? {
    guard let trimmed = rawDate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: trimmed) {
      return date
    }

    let isoFormatter = ISO8601DateFormatter()
    if let date = isoFormatter.date(from: trimmed) {
      return date
    }

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = .current
    dateFormatter.dateFormat = "yyyy-MM-dd"
    return dateFormatter.date(from: trimmed)
  }

  private func quickCaptureSystemPrompt() -> String {
    """
    You classify one quick-capture input for Serenity, a private task and journal app.
    Choose exactly one mode for the whole input: tasks or journal.
    Do not require or rely on the user saying this is a journal or task list.
    If the input is actionable, split it into separate tasks. If it is reflective, emotional, observational, or narrative, return one journal entry.
    Prefer active existing projects and available tags when they fit.
    Do not use archived projects. Return null when no project fits.
    If existing tags are insufficient, create concise new tags in the task or journal tags array.
    Create a new project only when the task clearly belongs to a durable project that is not represented by an active existing project.
    For new projects, add them to newProjects and reference them from tasks by exact projectName.
    Return dueDate as an ISO 8601 string when the user implies a date or time, otherwise null.
    Return concise task titles and preserve journal content faithfully.
    """
  }

  private func quickCaptureUserPrompt(
    input: String,
    projects: [AIQuickCaptureProjectContext],
    availableTags: [String],
    now: Date
  ) -> String {
    let encodedProjects = (try? jsonString(projects)) ?? "[]"
    let encodedTags = (try? jsonString(availableTags)) ?? "[]"
    let nowText = ISO8601DateFormatter().string(from: now)

    return """
    Current time: \(nowText)

    Active and archived project context:
    \(encodedProjects)

    Available tags:
    \(encodedTags)

    User input:
    \(input)
    """
  }

  private func quickCaptureRepairPrompt(
    invalidResponse: String,
    validationError: String,
    schema: [String: Any]
  ) -> String {
    let schemaText = (try? jsonString(schema)) ?? "{}"
    return """
    The previous response could not be decoded or validated.
    Validation error: \(validationError)

    Previous response:
    \(invalidResponse)

    Return only one corrected JSON object matching this schema:
    \(schemaText)
    """
  }

  private func quickCaptureSchema() -> [String: Any] {
    [
      "type": "object",
      "additionalProperties": false,
      "required": ["kind", "confidence", "newProjects", "tasks", "journal"],
      "properties": [
        "kind": [
          "type": "string",
          "enum": ["tasks", "journal"],
        ],
        "confidence": [
          "type": "number",
          "minimum": 0,
          "maximum": 1,
        ],
        "newProjects": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "description"],
            "properties": [
              "name": ["type": "string"],
              "description": ["type": ["string", "null"]],
            ],
          ],
        ],
        "tasks": [
          "type": "array",
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "description", "priority", "dueDate", "projectId", "projectName", "tags", "subtasks"],
            "properties": [
              "title": ["type": "string"],
              "description": ["type": ["string", "null"]],
              "priority": ["type": ["string", "null"], "enum": ["low", "medium", "high", NSNull()]],
              "dueDate": ["type": ["string", "null"]],
              "projectId": ["type": ["string", "null"]],
              "projectName": ["type": ["string", "null"]],
              "tags": ["type": "array", "items": ["type": "string"]],
              "subtasks": ["type": "array", "items": ["type": "string"]],
            ],
          ],
        ],
        "journal": [
          "type": ["object", "null"],
          "additionalProperties": false,
          "required": ["title", "content", "mood", "tags"],
          "properties": [
            "title": ["type": ["string", "null"]],
            "content": ["type": "string"],
            "mood": ["type": ["string", "null"], "enum": ["happy", "neutral", "sad", "excited", "stressed", NSNull()]],
            "tags": ["type": "array", "items": ["type": "string"]],
          ],
        ],
      ],
    ]
  }

  private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw AIWorkflowError.invalidQuickCaptureResponse("Failed to encode context")
    }
    return string
  }

  private func jsonString(_ value: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
      throw AIWorkflowError.invalidQuickCaptureResponse("Failed to encode schema")
    }
    return string
  }

  private func chooseCredential(settings: AISettingsEntity) throws -> AICredentialSelectionResult {
    let repositories = try requireRepositoriesSync()
    let enabledCredentials = try repositories.credentials.fetchAll(enabledOnly: true)
      .sorted { lhs, rhs in
        if lhs.priority == rhs.priority {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.priority < rhs.priority
      }

    var ordered = enabledCredentials
    if let preferred = settings.activeProvider {
      ordered.sort { lhs, rhs in
        if lhs.provider == preferred && rhs.provider != preferred { return true }
        if lhs.provider != preferred && rhs.provider == preferred { return false }
        return lhs.priority < rhs.priority
      }
    }

    for credential in ordered {
      let keychainKey = keychainKeyForCredential(credential.id)
      if let secret = try secretStore.secret(for: keychainKey), !secret.isEmpty {
        let model = credential.modelPreference ?? preferredModel(for: credential.provider, settings: settings)
        return AICredentialSelectionResult(credential: credential, apiKey: secret, model: model)
      }

      try repositories.credentials.recordError(id: credential.id, message: "Missing keychain secret", at: Date())
    }

    throw AIWorkflowError.noCredentialConfigured
  }

  private func chooseCredential(id: String) throws -> AICredentialSelectionResult {
    let repositories = try requireRepositoriesSync()
    guard let credential = try repositories.credentials.fetchByID(id), credential.enabled else {
      throw AIWorkflowError.credentialNotFound(id)
    }

    let keychainKey = keychainKeyForCredential(credential.id)
    guard let secret = try secretStore.secret(for: keychainKey), !secret.isEmpty else {
      try repositories.credentials.recordError(id: credential.id, message: "Missing keychain secret", at: Date())
      throw AIWorkflowError.missingCredentialSecret(credential.id)
    }

    let settings = try repositories.settings.fetch() ?? .defaultValue
    let model = credential.modelPreference ?? preferredModel(for: credential.provider, settings: settings)
    return AICredentialSelectionResult(credential: credential, apiKey: secret, model: model)
  }

  private func preferredModel(for provider: AICredentialProvider, settings: AISettingsEntity) -> String {
    switch provider {
    case .openai:
      return settings.preferredModels?.openai ?? AIProviderModelCatalog.models[.openai]?.first ?? "gpt-5.5"
    case .gemini:
      return settings.preferredModels?.gemini ?? AIProviderModelCatalog.models[.gemini]?.first ?? "gemini-3-pro-preview"
    case .anthropic:
      return settings.preferredModels?.anthropic ?? AIProviderModelCatalog.models[.anthropic]?.first ?? "claude-opus-4-7"
    case .nvidia:
      return settings.preferredModels?.nvidia ?? AIProviderModelCatalog.models[.nvidia]?.first ?? "nvidia/nemotron-3.5-lightning-30b-a3b"
    }
  }

  private func recordUsage(
    repositories: GRDBAIRepositorySet,
    selection: AICredentialSelectionResult,
    operation: AIUsageOperation,
    promptTokens: Int,
    completionTokens: Int
  ) throws {
    let total = promptTokens + completionTokens
    let provider = usageProviderForCredential(selection.credential.provider)
    try AIUsageCostService.seedDefaultRatesIfNeeded(repositories: repositories)
    let cost = try AIUsageCostService.calculateCosts(
      provider: provider,
      model: selection.model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      repositories: repositories
    )
    let usage = AIUsageEntity(
      id: UUID().uuidString,
      timestamp: Date(),
      provider: provider,
      operation: operation,
      model: selection.model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: total,
      inputCostUSD: cost.inputCostUSD,
      outputCostUSD: cost.outputCostUSD,
      totalCostUSD: cost.totalCostUSD
    )
    try repositories.usage.save(usage)
    try repositories.credentials.recordSuccess(id: selection.credential.id, tokensUsed: total, at: Date())
  }

  private func providerForCredential(_ provider: AICredentialProvider) -> AIProvider {
    switch provider {
    case .openai:
      return .openai
    case .gemini:
      return .gemini
    case .anthropic:
      return .anthropic
    case .nvidia:
      return .nvidia
    }
  }

  private func usageProviderForCredential(_ provider: AICredentialProvider) -> AIUsageProvider {
    switch provider {
    case .openai:
      return .openai
    case .gemini:
      return .gemini
    case .anthropic:
      return .anthropic
    case .nvidia:
      return .nvidia
    }
  }

  private func keychainKeyForCredential(_ id: String) -> String {
    "ai.credentials.\(id).apiKey"
  }

  private func requireRepositories() async throws -> GRDBAIRepositorySet {
    if let repositories {
      return repositories
    }

    _ = try await sqliteBackendAdapter.bootstrap()
    let created = try sqliteBackendAdapter.makeAIRepositories(pendingStore: pendingSyncStore)
    repositories = created
    return created
  }

  private func requireRepositoriesSync() throws -> GRDBAIRepositorySet {
    if let repositories {
      return repositories
    }

    throw AIWorkflowError.noCredentialConfigured
  }
}

struct AIUsageCostBreakdown: Equatable, Sendable {
  let inputCostUSD: Double?
  let outputCostUSD: Double?
  let totalCostUSD: Double?

  static let unavailable = AIUsageCostBreakdown(
    inputCostUSD: nil,
    outputCostUSD: nil,
    totalCostUSD: nil
  )
}

enum AIUsageCostService {
  static let liteLLMPricingURL = URL(
    string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  )!

  private static let defaultRates: [AIModelRateEntity] = [
    AIModelRateEntity(provider: .openai, model: "gpt-5.5", inputUSDPerMillion: 5.0, outputUSDPerMillion: 30.0, source: .seeded),
    AIModelRateEntity(provider: .openai, model: "gpt-5.5-pro", inputUSDPerMillion: 30.0, outputUSDPerMillion: 180.0, source: .seeded),
    AIModelRateEntity(provider: .openai, model: "gpt-5.4", inputUSDPerMillion: 2.5, outputUSDPerMillion: 15.0, source: .seeded),
    AIModelRateEntity(provider: .openai, model: "gpt-5.4-pro", inputUSDPerMillion: 30.0, outputUSDPerMillion: 180.0, source: .seeded),
    AIModelRateEntity(provider: .openai, model: "gpt-5.4-mini", inputUSDPerMillion: 0.75, outputUSDPerMillion: 4.5, source: .seeded),
    AIModelRateEntity(provider: .openai, model: "gpt-5.4-nano", inputUSDPerMillion: 0.2, outputUSDPerMillion: 1.25, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-opus-4-7", inputUSDPerMillion: 5.0, outputUSDPerMillion: 25.0, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-opus-4-6", inputUSDPerMillion: 5.0, outputUSDPerMillion: 25.0, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-sonnet-4-6", inputUSDPerMillion: 3.0, outputUSDPerMillion: 15.0, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-opus-4-5", inputUSDPerMillion: 5.0, outputUSDPerMillion: 25.0, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-sonnet-4-5", inputUSDPerMillion: 3.0, outputUSDPerMillion: 15.0, source: .seeded),
    AIModelRateEntity(provider: .anthropic, model: "claude-haiku-4-5", inputUSDPerMillion: 1.0, outputUSDPerMillion: 5.0, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-3-pro-preview", inputUSDPerMillion: 2.0, outputUSDPerMillion: 12.0, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-3-flash-preview", inputUSDPerMillion: 0.5, outputUSDPerMillion: 3.0, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-2.5-pro", inputUSDPerMillion: 1.25, outputUSDPerMillion: 10.0, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-2.5-flash-preview-09-2025", inputUSDPerMillion: 0.3, outputUSDPerMillion: 2.5, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-2.5-flash", inputUSDPerMillion: 0.3, outputUSDPerMillion: 2.5, source: .seeded),
    AIModelRateEntity(provider: .gemini, model: "gemini-2.5-flash-lite", inputUSDPerMillion: 0.1, outputUSDPerMillion: 0.4, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "nvidia/nemotron-3.5-lightning-30b-a3b", inputUSDPerMillion: 0.1, outputUSDPerMillion: 0.4, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "nvidia/nemotron-nano-3-30b-a3b", inputUSDPerMillion: 0.1, outputUSDPerMillion: 0.4, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "nvidia/nemotron-3-super-120b-a12b", inputUSDPerMillion: 0.3, outputUSDPerMillion: 1.2, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "nvidia/nemotron-3-ultra-550b-a55b", inputUSDPerMillion: 0.9, outputUSDPerMillion: 3.6, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "openai/gpt-oss-120b", inputUSDPerMillion: 0.15, outputUSDPerMillion: 0.6, source: .seeded),
    AIModelRateEntity(provider: .nvidia, model: "deepseek-ai/deepseek-v4-flash-0731", inputUSDPerMillion: 0.27, outputUSDPerMillion: 1.1, source: .seeded),
  ]

  static func seedDefaultRatesIfNeeded(repositories: GRDBAIRepositorySet) throws {
    let existing = try repositories.modelRates.fetchAll()
    let defaultKeys = Set(defaultRates.map { rate in
      "\(rate.provider.rawValue)::\(rate.model.lowercased())"
    })

    for rate in existing where rate.source == .seeded {
      let key = "\(rate.provider.rawValue)::\(rate.model.lowercased())"
      if !defaultKeys.contains(key) {
        try repositories.modelRates.delete(provider: rate.provider, model: rate.model)
      }
    }

    for defaultRate in defaultRates {
      if let current = existing.first(where: {
        $0.provider == defaultRate.provider &&
        $0.model.caseInsensitiveCompare(defaultRate.model) == .orderedSame
      }) {
        guard current.source == .seeded else { continue }
        if current.inputUSDPerMillion != defaultRate.inputUSDPerMillion ||
          current.outputUSDPerMillion != defaultRate.outputUSDPerMillion {
          try repositories.modelRates.save(defaultRate)
        }
      } else {
        try repositories.modelRates.save(defaultRate)
      }
    }
  }

  static func resetRatesToDefaults(repositories: GRDBAIRepositorySet) throws {
    try repositories.modelRates.deleteAll()
    try repositories.modelRates.saveMany(defaultRates)
  }

  static func calculateCosts(
    provider: AIUsageProvider,
    model: String?,
    promptTokens: Int,
    completionTokens: Int,
    repositories: GRDBAIRepositorySet
  ) throws -> AIUsageCostBreakdown {
    let model = normalizedModel(model)
    guard !model.isEmpty,
          let rate = try repositories.modelRates.fetch(provider: provider, model: model) else {
      return .unavailable
    }

    let inputCost = (Double(promptTokens) / 1_000_000) * rate.inputUSDPerMillion
    let outputCost = (Double(completionTokens) / 1_000_000) * rate.outputUSDPerMillion
    return AIUsageCostBreakdown(
      inputCostUSD: roundToMicros(inputCost),
      outputCostUSD: roundToMicros(outputCost),
      totalCostUSD: roundToMicros(inputCost + outputCost)
    )
  }

  @discardableResult
  static func backfillMissingCostsIfNeeded(
    repositories: GRDBAIRepositorySet,
    settings: AISettingsEntity,
    provider: AIUsageProvider? = nil,
    model: String? = nil
  ) throws -> Int {
    let usageRows = try repositories.usage.fetchAll(limit: 10_000)
    var updatedCount = 0
    let requestedModel = normalizedModel(model)

    for row in usageRows {
      if let provider, row.provider != provider {
        continue
      }

      let resolvedModel = resolvedModel(for: row, settings: settings)
      if !requestedModel.isEmpty,
         resolvedModel.caseInsensitiveCompare(requestedModel) != .orderedSame {
        continue
      }

      guard !resolvedModel.isEmpty else { continue }
      let hasModel = normalizedModel(row.model).caseInsensitiveCompare(resolvedModel) == .orderedSame
      if hasModel, row.totalCostUSD != nil {
        continue
      }

      let cost = try calculateCosts(
        provider: row.provider,
        model: resolvedModel,
        promptTokens: row.promptTokens,
        completionTokens: row.completionTokens,
        repositories: repositories
      )

      var updated = row
      updated.model = resolvedModel
      updated.inputCostUSD = cost.inputCostUSD
      updated.outputCostUSD = cost.outputCostUSD
      updated.totalCostUSD = cost.totalCostUSD
      try repositories.usage.save(updated)
      updatedCount += 1
    }

    return updatedCount
  }

  static func resolvedModel(for usage: AIUsageEntity, settings: AISettingsEntity) -> String {
    let existing = normalizedModel(usage.model)
    if !existing.isEmpty {
      return existing
    }

    switch usage.provider {
    case .openai:
      return normalizedModel(settings.preferredModels?.openai ?? AIProviderModelCatalog.models[.openai]?.first)
    case .gemini:
      return normalizedModel(settings.preferredModels?.gemini ?? AIProviderModelCatalog.models[.gemini]?.first)
    case .anthropic:
      return normalizedModel(settings.preferredModels?.anthropic ?? AIProviderModelCatalog.models[.anthropic]?.first)
    case .nvidia:
      return normalizedModel(settings.preferredModels?.nvidia ?? AIProviderModelCatalog.models[.nvidia]?.first)
    }
  }

  static func fetchLiteLLMRate(provider: AIUsageProvider, model: String) async throws -> AIModelRateEntity? {
    let (data, _) = try await URLSession.shared.data(from: liteLLMPricingURL)
    return try parseLiteLLMRate(provider: provider, model: model, data: data)
  }

  static func parseLiteLLMRate(provider: AIUsageProvider, model: String, data: Data) throws -> AIModelRateEntity? {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let pricing = object as? [String: Any] else { return nil }
    let normalizedProvider = provider.litellmSlug.lowercased()
    let normalizedModel = normalizedModel(model)
    let candidates = pricing.compactMap { key, value -> (String, [String: Any])? in
      guard let details = value as? [String: Any] else { return nil }
      return (key, details)
    }

    let match = modelLookupAliases(for: normalizedModel, provider: normalizedProvider).lazy.compactMap { modelAlias in
      candidates.first { key, details in
        let providerMatches = (details["litellm_provider"] as? String)?.lowercased() == normalizedProvider
        guard providerMatches else { return false }
        return modelKeyMatches(key, model: modelAlias, provider: normalizedProvider)
      }
    }.first

    guard let match,
          let inputCost = doubleValue(match.1["input_cost_per_token"]),
          let outputCost = doubleValue(match.1["output_cost_per_token"]) else {
      return nil
    }

    return AIModelRateEntity(
      provider: provider,
      model: normalizedModel,
      inputUSDPerMillion: roundToMicros(inputCost * 1_000_000),
      outputUSDPerMillion: roundToMicros(outputCost * 1_000_000),
      source: .litellm
    )
  }

  private static func modelKeyMatches(_ key: String, model: String, provider: String) -> Bool {
    let normalizedKey = key.lowercased()
    let normalizedModel = model.lowercased()
    return normalizedKey == normalizedModel ||
      normalizedKey == "\(provider)/\(normalizedModel)" ||
      normalizedKey.hasSuffix("/\(normalizedModel)")
  }

  private static func modelLookupAliases(for model: String, provider: String) -> [String] {
    var aliases = [model]

    if provider == AIUsageProvider.gemini.rawValue,
       !model.hasSuffix("-preview") {
      aliases.append("\(model)-preview")
    }

    return aliases
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func normalizedModel(_ model: String?) -> String {
    model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func roundToMicros(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
  }
}
