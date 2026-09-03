import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable {
  case openai
  case gemini
  case anthropic
  case nvidia
  case local
}

public enum AIInsightType: String, Codable, CaseIterable, Sendable {
  case productivity
  case behavior
  case recommendation
  case warning
}

public enum AIInsightCategory: String, Codable, CaseIterable, Sendable {
  case tasks
  case journal
  case habits
  case goals
}

public struct AIInsightEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var provider: AIProvider
  public var type: AIInsightType
  public var title: String
  public var description: String
  public var confidence: Double
  public var category: AIInsightCategory
  public var actionable: Bool
  public var metadataJSON: String
  public var createdAt: Date
  public var updatedAt: Date
  public var userRating: Int?
  public var dismissed: Bool
  public var markedHelpful: Bool
  public var userNotes: String?
  public var visualizationDataJSON: String?
  public var actionabilitySuggestions: [String]
  public var themeID: String?
  public var isRecurring: Bool
  public var occurrenceNumber: Int

  public init(
    id: String,
    provider: AIProvider,
    type: AIInsightType,
    title: String,
    description: String,
    confidence: Double,
    category: AIInsightCategory,
    actionable: Bool,
    metadataJSON: String,
    createdAt: Date,
    updatedAt: Date,
    userRating: Int?,
    dismissed: Bool,
    markedHelpful: Bool,
    userNotes: String?,
    visualizationDataJSON: String?,
    actionabilitySuggestions: [String],
    themeID: String?,
    isRecurring: Bool,
    occurrenceNumber: Int
  ) {
    self.id = id
    self.provider = provider
    self.type = type
    self.title = title
    self.description = description
    self.confidence = confidence
    self.category = category
    self.actionable = actionable
    self.metadataJSON = metadataJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.userRating = userRating
    self.dismissed = dismissed
    self.markedHelpful = markedHelpful
    self.userNotes = userNotes
    self.visualizationDataJSON = visualizationDataJSON
    self.actionabilitySuggestions = actionabilitySuggestions
    self.themeID = themeID
    self.isRecurring = isRecurring
    self.occurrenceNumber = occurrenceNumber
  }
}

public enum AIRecapType: String, Codable, CaseIterable, Sendable {
  case weekly
  case monthly
}

public struct AIRecapPeriod: Codable, Equatable, Sendable {
  public var start: Date
  public var end: Date

  public init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

public struct AIRecapEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var provider: AIProvider
  public var type: AIRecapType
  public var title: String
  public var summary: String
  public var highlights: [String]
  public var challenges: [String]
  public var recommendations: [String]
  public var period: AIRecapPeriod
  public var metadataJSON: String
  public var createdAt: Date
  public var updatedAt: Date
  public var viewed: Bool
  public var favorited: Bool
  public var exported: Bool

  public init(
    id: String,
    provider: AIProvider,
    type: AIRecapType,
    title: String,
    summary: String,
    highlights: [String],
    challenges: [String],
    recommendations: [String],
    period: AIRecapPeriod,
    metadataJSON: String,
    createdAt: Date,
    updatedAt: Date,
    viewed: Bool,
    favorited: Bool,
    exported: Bool
  ) {
    self.id = id
    self.provider = provider
    self.type = type
    self.title = title
    self.summary = summary
    self.highlights = highlights
    self.challenges = challenges
    self.recommendations = recommendations
    self.period = period
    self.metadataJSON = metadataJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.viewed = viewed
    self.favorited = favorited
    self.exported = exported
  }
}

public enum AIUsageProvider: String, Codable, CaseIterable, Sendable {
  case openai
  case gemini
  case anthropic
  case nvidia

  /// LiteLLM files NIM models under `nvidia_nim`; every other provider matches its raw value.
  var litellmSlug: String {
    switch self {
    case .nvidia:
      return "nvidia_nim"
    case .openai, .gemini, .anthropic:
      return rawValue
    }
  }
}

public enum AIUsageOperation: String, Codable, CaseIterable, Sendable {
  case analyze
  case recap
  case quickadd
  case summary
}

public struct AIUsageEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var timestamp: Date
  public var provider: AIUsageProvider
  public var operation: AIUsageOperation
  public var model: String?
  public var promptTokens: Int
  public var completionTokens: Int
  public var totalTokens: Int
  public var inputCostUSD: Double?
  public var outputCostUSD: Double?
  public var totalCostUSD: Double?

  public init(
    id: String,
    timestamp: Date,
    provider: AIUsageProvider,
    operation: AIUsageOperation,
    model: String? = nil,
    promptTokens: Int,
    completionTokens: Int,
    totalTokens: Int,
    inputCostUSD: Double? = nil,
    outputCostUSD: Double? = nil,
    totalCostUSD: Double? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.provider = provider
    self.operation = operation
    self.model = model
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.inputCostUSD = inputCostUSD
    self.outputCostUSD = outputCostUSD
    self.totalCostUSD = totalCostUSD
  }
}

public enum AIModelRateSource: String, Codable, CaseIterable, Sendable {
  case seeded
  case user
  case litellm
}

public struct AIModelRateEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var provider: AIUsageProvider
  public var model: String
  public var inputUSDPerMillion: Double
  public var outputUSDPerMillion: Double
  public var source: AIModelRateSource
  public var updatedAt: Date

  public init(
    id: String? = nil,
    provider: AIUsageProvider,
    model: String,
    inputUSDPerMillion: Double,
    outputUSDPerMillion: Double,
    source: AIModelRateSource,
    updatedAt: Date = Date()
  ) {
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = id ?? "\(provider.rawValue)::\(trimmedModel.lowercased())"
    self.provider = provider
    self.model = trimmedModel
    self.inputUSDPerMillion = inputUSDPerMillion
    self.outputUSDPerMillion = outputUSDPerMillion
    self.source = source
    self.updatedAt = updatedAt
  }
}

public enum SummaryType: String, Codable, CaseIterable, Sendable {
  case tasks
  case journal
  case combined
}

public struct SummaryEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var content: String
  public var summaryType: SummaryType
  public var startDate: Date
  public var endDate: Date
  public var generatedAt: Date
  public var wordCount: Int
  public var metadataJSON: String
  public var provider: AIProvider
  public var promptTokens: Int
  public var completionTokens: Int
  public var totalTokens: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    title: String,
    content: String,
    summaryType: SummaryType,
    startDate: Date,
    endDate: Date,
    generatedAt: Date,
    wordCount: Int,
    metadataJSON: String,
    provider: AIProvider,
    promptTokens: Int,
    completionTokens: Int,
    totalTokens: Int,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.summaryType = summaryType
    self.startDate = startDate
    self.endDate = endDate
    self.generatedAt = generatedAt
    self.wordCount = wordCount
    self.metadataJSON = metadataJSON
    self.provider = provider
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum AICredentialProvider: String, Codable, CaseIterable, Sendable {
  case openai
  case gemini
  case anthropic
  case nvidia
}

public struct AICredentialEntity: Identifiable, Equatable, Sendable {
  public var id: String
  public var provider: AICredentialProvider
  public var name: String
  public var apiKeyEncrypted: String
  public var modelPreference: String?
  public var enabled: Bool
  public var priority: Int
  public var metadataJSON: String
  public var lastUsedAt: Date?
  public var totalRequests: Int
  public var totalTokens: Int
  public var successCount: Int
  public var errorCount: Int
  public var lastError: String?
  public var lastErrorAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    provider: AICredentialProvider,
    name: String,
    apiKeyEncrypted: String,
    modelPreference: String?,
    enabled: Bool,
    priority: Int,
    metadataJSON: String,
    lastUsedAt: Date?,
    totalRequests: Int,
    totalTokens: Int,
    successCount: Int,
    errorCount: Int,
    lastError: String?,
    lastErrorAt: Date?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.provider = provider
    self.name = name
    self.apiKeyEncrypted = apiKeyEncrypted
    self.modelPreference = modelPreference
    self.enabled = enabled
    self.priority = priority
    self.metadataJSON = metadataJSON
    self.lastUsedAt = lastUsedAt
    self.totalRequests = totalRequests
    self.totalTokens = totalTokens
    self.successCount = successCount
    self.errorCount = errorCount
    self.lastError = lastError
    self.lastErrorAt = lastErrorAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum AIAnalysisFrequency: String, Codable, CaseIterable, Sendable {
  case daily
  case weekly
  case manual
}

public struct AISettingsDataTypes: Codable, Equatable, Sendable {
  public var includeTasks: Bool
  public var includeJournal: Bool
  public var includeProjects: Bool

  public init(includeTasks: Bool, includeJournal: Bool, includeProjects: Bool) {
    self.includeTasks = includeTasks
    self.includeJournal = includeJournal
    self.includeProjects = includeProjects
  }
}

public struct AIPreferredModels: Codable, Equatable, Sendable {
  public var openai: String?
  public var gemini: String?
  public var anthropic: String?
  public var nvidia: String?

  public init(openai: String?, gemini: String?, anthropic: String?, nvidia: String? = nil) {
    self.openai = openai
    self.gemini = gemini
    self.anthropic = anthropic
    self.nvidia = nvidia
  }
}

public struct AISettingsEntity: Codable, Equatable, Sendable {
  public var activeProvider: AICredentialProvider?
  public var autoAnalyze: Bool
  public var analysisFrequency: AIAnalysisFrequency
  public var dataTypes: AISettingsDataTypes
  public var preferredModels: AIPreferredModels?

  public init(
    activeProvider: AICredentialProvider?,
    autoAnalyze: Bool,
    analysisFrequency: AIAnalysisFrequency,
    dataTypes: AISettingsDataTypes,
    preferredModels: AIPreferredModels?
  ) {
    self.activeProvider = activeProvider
    self.autoAnalyze = autoAnalyze
    self.analysisFrequency = analysisFrequency
    self.dataTypes = dataTypes
    self.preferredModels = preferredModels
  }

  public static let defaultValue = AISettingsEntity(
    activeProvider: nil,
    autoAnalyze: false,
    analysisFrequency: .manual,
    dataTypes: AISettingsDataTypes(includeTasks: true, includeJournal: true, includeProjects: true),
    preferredModels: nil
  )
}

public enum AIQuickCaptureKind: String, Codable, CaseIterable, Sendable {
  case tasks
  case journal
}

public struct AIQuickCaptureTaskDraft: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var description: String?
  public var priority: TaskPriority
  public var dueDate: Date?
  public var projectId: String?
  public var projectName: String?
  public var tags: [String]
  public var subtasks: [String]

  public init(
    id: String = UUID().uuidString,
    title: String,
    description: String?,
    priority: TaskPriority,
    dueDate: Date?,
    projectId: String?,
    projectName: String? = nil,
    tags: [String],
    subtasks: [String]
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.priority = priority
    self.dueDate = dueDate
    self.projectId = projectId
    self.projectName = projectName
    self.tags = tags
    self.subtasks = subtasks
  }
}

public struct AIQuickCaptureProjectDraft: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var description: String?

  public init(
    id: String = UUID().uuidString,
    name: String,
    description: String?
  ) {
    self.id = id
    self.name = name
    self.description = description
  }
}

public struct AIQuickCaptureJournalDraft: Codable, Equatable, Sendable {
  public var title: String?
  public var content: String
  public var mood: JournalMood?
  public var tags: [String]

  public init(title: String?, content: String, mood: JournalMood?, tags: [String]) {
    self.title = title
    self.content = content
    self.mood = mood
    self.tags = tags
  }
}

public struct AIQuickCaptureClassification: Codable, Equatable, Sendable {
  public var kind: AIQuickCaptureKind
  public var confidence: Double
  public var newProjects: [AIQuickCaptureProjectDraft]
  public var tasks: [AIQuickCaptureTaskDraft]
  public var journal: AIQuickCaptureJournalDraft?

  public init(
    kind: AIQuickCaptureKind,
    confidence: Double,
    newProjects: [AIQuickCaptureProjectDraft] = [],
    tasks: [AIQuickCaptureTaskDraft],
    journal: AIQuickCaptureJournalDraft?
  ) {
    self.kind = kind
    self.confidence = confidence
    self.newProjects = newProjects
    self.tasks = tasks
    self.journal = journal
  }
}

public struct AIQuickCaptureProjectContext: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var archived: Bool

  public init(id: String, name: String, description: String?, archived: Bool) {
    self.id = id
    self.name = name
    self.description = description
    self.archived = archived
  }
}

public struct AIQuickCapturePreview: Identifiable, Equatable, Sendable {
  public var id: String
  public var originalInput: String
  public var classification: AIQuickCaptureClassification

  public init(
    id: String = UUID().uuidString,
    originalInput: String,
    classification: AIQuickCaptureClassification
  ) {
    self.id = id
    self.originalInput = originalInput
    self.classification = classification
  }
}
