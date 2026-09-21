import Foundation

public enum BackendProfile: String, CaseIterable, Identifiable, Sendable {
  case sqliteLocal
  case serenityCloud
  case externalPostgres

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .sqliteLocal:
      return "SQLite (Local)"
    case .serenityCloud:
      return "Serenity Cloud"
    case .externalPostgres:
      return "External PostgreSQL"
    }
  }
}

struct AppSettings {
  var backendProfile: BackendProfile = .sqliteLocal
  var localLockEnabled = false
}

enum AppThemePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }
}

enum DatabaseBootstrapState: Equatable {
  case idle
  case bootstrapping
  case ready(path: String, appliedCount: Int)
  case failed(message: String)
}

enum CoreWorkflowState: Equatable {
  case idle
  case loading
  case ready
  case failed(message: String)
}

enum BackendSwitchState: Equatable {
  case idle
  case switching(target: BackendProfile)
  case succeeded(message: String)
  case failed(message: String)
}

struct AppAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

struct AppToast: Identifiable {
  let id = UUID()
  let message: String
}

enum CoreWorkflowError: Error, LocalizedError {
  case unavailableBackend(String)
  case unsupportedBackend(BackendProfile)

  var errorDescription: String? {
    switch self {
    case .unavailableBackend(let reason):
      return reason
    case .unsupportedBackend(let profile):
      return "\(profile.title) data workflows are not implemented yet."
    }
  }
}

enum OAuthConfigurationValidationError: Error, LocalizedError {
  case missingField(String)
  case invalidBaseURL
  case invalidRedirectURI

  var errorDescription: String? {
    switch self {
    case .missingField(let field):
      return "\(field) is required."
    case .invalidBaseURL:
      return "OAuth base URL must be a valid http(s) URL."
    case .invalidRedirectURI:
      return "OAuth redirect URI must be a valid URI."
    }
  }
}

@MainActor
final class AppState: ObservableObject {
  static let themePreferenceDefaultsKey = "serenity.ui.themePreference"
  static let lastSectionDefaultsKey = "serenity.ui.lastSection"
  static let notificationsEnabledDefaultsKey = "serenity.notifications.enabled"
  static let slackSyncEnabledDefaultsKey = "serenity.slack.syncEnabled"
  static let slackPollIntervalDefaultsKey = "serenity.slack.pollIntervalMinutes"
  static let notificationLeadMinutesDefaultsKey = "serenity.notifications.leadMinutes"
  static let localLockEnabledDefaultsKey = "serenity.security.localLock.enabled"
  static let aiQuickCapturePreviewThreshold = 0.75
  private let settingsSync: SettingsSyncCoordinator
  private var settingsSyncObserver: NSObjectProtocol?

  @Published var selectedSection: AppSection? = .home
  @Published var pendingSettingsTab: SettingsTab?
  @Published var settings = AppSettings()
  @Published var themePreference: AppThemePreference = .system
  @Published var backendSelectionState = BackendProfileSelectionState(
    activeProfile: .sqliteLocal,
    descriptors: BackendProfileRegistry.live.orderedDescriptors,
    validations: [:],
    lastValidatedAt: [:]
  )
  @Published var activeAlert: AppAlert?
  @Published var activeToast: AppToast?
  @Published var databaseBootstrapState: DatabaseBootstrapState = .idle
  @Published var backendSwitchState: BackendSwitchState = .idle
  @Published var backendDiagnosticsLines: [String] = []
  @Published var authSessionState: AuthSessionState = .unauthenticated
  @Published var localLockStatus: LocalLockStatus = .disabled
  @Published var biometricAvailability: BiometricAuthAvailability = .unavailable(reason: "Not checked")

  @Published var coreWorkflowState: CoreWorkflowState = .idle
  @Published var tasks: [TaskEntity] = []
  @Published var projects: [ProjectEntity] = []
  @Published var journalEntries: [JournalEntryEntity] = []
  @Published var goals: [GoalEntity] = []
  @Published var taskFilter = TaskWorkflowFilter()
  @Published var selectedTaskIDs: Set<String> = []
  @Published var journalDateRangeEnabled = false
  @Published var journalRangeStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
  @Published var journalRangeEndDate: Date = Date()
  @Published var includeArchivedProjects = true
  /// Set by ⇧⌘N; `HomeSectionView` consumes and clears it.
  @Published var shouldFocusQuickCapture = false
  /// Set by ⌘F; the active section's list view consumes and clears it.
  @Published var shouldFocusSectionSearch = false
  @Published var notificationsEnabled = false
  @Published var notificationLeadMinutes = 0
  @Published var isGlobalSearchPresented = false
  @Published var isHelpCenterPresented = false
  @Published var globalSearchQuery = ""
  @Published var globalSearchResults: [GlobalSearchResult] = []
  @Published var databaseManagementLines: [String] = []
  @Published var databaseIntegrityCheckResult = "Not run"
  @Published var lastDatabaseBackupPath: String?
  @Published var lastDatabaseExportPath: String?
  @Published var googleIntegrationState: GoogleIntegrationState = .disconnected
  @Published var githubIntegrationState: GitHubIntegrationState = .empty
  @Published var slackIntegrationState: SlackIntegrationState = .disconnected
  @Published var slackProposals: [SlackProposal] = []
  @Published var pendingCaptureDraft: CaptureDraftPreview?
  @Published var captureCommandProgress: CaptureCommandProgress?
  @Published var slackRelevanceSettings: SlackRelevanceSettings = .default
  @Published var slackConfigured = false
  @Published var slackChannelsWatched = 0
  @Published var slackLastPass: SlackSyncPass?
  @Published var slackPollIntervalMinutes = 15
  @Published var integrationSyncInProgress = false
  @Published var integrationDiagnosticsLines: [String] = []
  @Published var googleCalendarConfigured = false
  @Published var aiModelCatalog: [AICredentialProvider: [String]] = [:]
  @Published var aiCredentials: [AICredentialEntity] = []
  @Published var aiSettings: AISettingsEntity = .defaultValue
  @Published var aiInsights: [AIInsightEntity] = []
  @Published var aiRecaps: [AIRecapEntity] = []
  @Published var aiSummaries: [SummaryEntity] = []
  @Published var standups: [StandupEntity] = []
  @Published var standupBoard: StandupBoard?
  @Published var standupScript: StandupScript?
  @Published var standupWrittenByModel = false
  @Published var standupIsWriting = false
  @Published var standupSaveToJournal = true
  /// Once you have moved or added a card, the board stops regathering itself
  /// underneath you.
  @Published var standupBoardEdited = false
  private var pendingStandupDraft: StandupDraft?
  @Published var aiUsageEntries: [AIUsageEntity] = []
  @Published var aiModelRates: [AIModelRateEntity] = []
  @Published var aiStatusMessage = "AI features require a configured provider key."
  @Published var pendingAIQuickCapturePreview: AIQuickCapturePreview?
  @Published var lastSummaryExportPath: String?
  @Published var iCloudSyncState: ICloudSyncState = .idle

  private let sqliteBackendAdapter: SQLiteBackendAdapter
  private var serenityCloudAdapter: SerenityCloudAdapter?
  private var externalPostgresAdapter: ExternalPostgresAdapter?
  private let backendProfileManager: BackendProfileManager
  private let backendConfigurationStore: BackendConfigurationStore
  private let authSessionManager: AuthSessionManager
  private let localLockManager: LocalLockManager
  private let biometricAuthService: BiometricAuthService
  private let securityAuditService: SecurityAuditService
  private let sensitiveOperationRateGuard: SensitiveOperationRateGuard
  private let googleIntegrationService: GoogleIntegrationService
  private let githubIntegrationService: GitHubIntegrationService
  private let slackIntegrationService: SlackIntegrationService
  private var slackMessageReader: SlackMessageReader?
  private var slackRepositories: GRDBSlackRepositorySet?
  private var slackPollTask: Task<Void, Never>?
  private let aiWorkflowService: AIWorkflowService
  private let notificationCenter: NotificationCenterAdapter = SystemNotificationCenter()
  private lazy var notificationScheduler = NotificationScheduler(center: notificationCenter)
  private var iCloudSyncEngine: ICloudSyncEngine?

  private var sqliteCoreRepositories: GRDBCoreRepositorySet?
  private var globalSearchDocuments: [GlobalSearchDocument] = []

  init(
    backendProfileManager: BackendProfileManager = BackendProfileManager(),
    sqliteBackendAdapter: SQLiteBackendAdapter = SQLiteBackendAdapter(),
    serenityCloudAdapter: SerenityCloudAdapter? = SerenityCloudConfiguration.fromStoredOrEnvironment().map {
      SerenityCloudAdapter(configuration: $0)
    },
    externalPostgresAdapter: ExternalPostgresAdapter? = ExternalPostgresConfiguration.fromStoredOrEnvironment().map {
      ExternalPostgresAdapter(configuration: $0)
    },
    backendConfigurationStore: BackendConfigurationStore = BackendConfigurationStore(),
    authSessionManager: AuthSessionManager = AuthSessionManager(),
    localLockManager: LocalLockManager = LocalLockManager(),
    biometricAuthService: BiometricAuthService = BiometricAuthService(),
    securityAuditService: SecurityAuditService? = nil,
    sensitiveOperationRateGuard: SensitiveOperationRateGuard = SensitiveOperationRateGuard(),
    googleIntegrationService: GoogleIntegrationService? = nil,
    githubIntegrationService: GitHubIntegrationService = GitHubIntegrationService(),
    slackIntegrationService: SlackIntegrationService? = nil,
    aiWorkflowService: AIWorkflowService? = nil,
    settingsSync: SettingsSyncCoordinator = .shared
  ) {
    self.settingsSync = settingsSync
    self.backendProfileManager = backendProfileManager
    self.sqliteBackendAdapter = sqliteBackendAdapter
    self.serenityCloudAdapter = serenityCloudAdapter
    self.externalPostgresAdapter = externalPostgresAdapter
    self.backendConfigurationStore = backendConfigurationStore
    self.authSessionManager = authSessionManager
    self.localLockManager = localLockManager
    self.biometricAuthService = biometricAuthService
    self.securityAuditService = securityAuditService ?? SecurityAuditService(sqliteBackendAdapter: sqliteBackendAdapter)
    self.sensitiveOperationRateGuard = sensitiveOperationRateGuard
    self.googleIntegrationService = googleIntegrationService ?? GoogleIntegrationService()
    self.githubIntegrationService = githubIntegrationService
    self.slackIntegrationService = slackIntegrationService ?? SlackIntegrationService()
    self.aiWorkflowService = aiWorkflowService ?? AIWorkflowService(sqliteBackendAdapter: sqliteBackendAdapter)

    if let storedTheme = UserDefaults.standard.string(forKey: Self.themePreferenceDefaultsKey),
       let preference = AppThemePreference(rawValue: storedTheme) {
      themePreference = preference
    }

    settings.localLockEnabled = UserDefaults.standard.bool(forKey: Self.localLockEnabledDefaultsKey)

    if let storedSection = UserDefaults.standard.string(forKey: Self.lastSectionDefaultsKey),
       let section = AppSection(rawValue: storedSection) {
      selectedSection = section
    }

    notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationsEnabledDefaultsKey)
    notificationLeadMinutes = UserDefaults.standard.integer(forKey: Self.notificationLeadMinutesDefaultsKey)

    settingsSyncObserver = NotificationCenter.default.addObserver(
      forName: .settingsDidChangeRemotely,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let keys = (notification.userInfo?["changedKeys"] as? [String]) ?? []
      Task { @MainActor [weak self] in
        self?.applyRemoteSettingChanges(Set(keys))
      }
    }
  }

  deinit {
    if let settingsSyncObserver {
      NotificationCenter.default.removeObserver(settingsSyncObserver)
    }
  }

  private func applyRemoteSettingChanges(_ keys: Set<String>) {
    if keys.contains(Self.themePreferenceDefaultsKey) {
      if let storedTheme = UserDefaults.standard.string(forKey: Self.themePreferenceDefaultsKey),
         let preference = AppThemePreference(rawValue: storedTheme) {
        themePreference = preference
      }
    }
    if keys.contains(Self.localLockEnabledDefaultsKey) {
      settings.localLockEnabled = UserDefaults.standard.bool(forKey: Self.localLockEnabledDefaultsKey)
    }
  }

  var filteredTasks: [TaskEntity] {
    tasks.filter { task in
      switch taskFilter.completion {
      case .all:
        break
      case .open:
        if task.completed { return false }
      case .completed:
        if !task.completed { return false }
      }

      if let priority = taskFilter.priority.matches,
         task.priority != priority {
        return false
      }

      let query = taskFilter.query.trimmingCharacters(in: .whitespacesAndNewlines)
      if query.isEmpty {
        return true
      }

      let haystack = [
        task.title,
        task.description ?? "",
        task.tags.joined(separator: " "),
        task.subtasks.map(\.title).joined(separator: " "),
      ]
        .joined(separator: " ")
        .lowercased()

      return haystack.contains(query.lowercased())
    }
  }

  var todayTasks: [TaskEntity] {
    let today = Calendar.current.startOfDay(for: Date())
    return tasks
      .filter { task in
        guard let dueDate = task.dueDate else { return false }
        return Calendar.current.isDate(dueDate, inSameDayAs: today)
      }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  var overdueTasks: [TaskEntity] {
    let startOfToday = Calendar.current.startOfDay(for: Date())
    return tasks
      .filter { task in
        guard let dueDate = task.dueDate else { return false }
        return !task.completed && dueDate < startOfToday
      }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  /// Dated beyond today but close enough to matter. Without this band a task
  /// captured as "tomorrow" would belong to no band at all and vanish from Home
  /// the moment it was saved.
  var upcomingTasks: [TaskEntity] {
    let calendar = Calendar.current
    let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
    guard
      let startOfTomorrow,
      let horizon = calendar.date(byAdding: .day, value: 7, to: startOfTomorrow)
    else {
      return []
    }

    return tasks
      .filter { task in
        guard !task.completed, let dueDate = task.dueDate else { return false }
        return dueDate >= startOfTomorrow && dueDate < horizon
      }
      .sorted { ($0.dueDate ?? $0.createdAt) < ($1.dueDate ?? $1.createdAt) }
  }

  /// What the menu bar shows at a glance: everything still owed today.
  var menuBarRemainingCount: Int {
    overdueTasks.count + todayTasks.filter { !$0.completed }.count
  }

  /// Captured but not yet scheduled. Quick capture lands here, so Home has to
  /// show it — otherwise anything typed without a date disappears on send.
  var inboxTasks: [TaskEntity] {
    tasks
      .filter { !$0.completed && $0.dueDate == nil }
      .sorted { $0.createdAt > $1.createdAt }
  }

  var filteredJournalEntries: [JournalEntryEntity] {
    guard journalDateRangeEnabled else {
      return journalEntries
    }

    let interval = DateInterval(start: min(journalRangeStartDate, journalRangeEndDate), end: max(journalRangeStartDate, journalRangeEndDate))
    return journalEntries.filter { interval.contains($0.date) }
  }

  func setSection(_ section: AppSection?) {
    selectedSection = section

    if let section {
      AppLogger.info("Section selected: \(section.rawValue)")
      // Deliberately not synced through iCloud: theme should follow you between
      // devices, but which pane this Mac was on should not.
      UserDefaults.standard.set(section.rawValue, forKey: Self.lastSectionDefaultsKey)
    }
  }

  func setSection(_ section: AppSection?, settingsTab tab: SettingsTab) {
    pendingSettingsTab = tab
    setSection(section)
  }

  func openGlobalSearch(prefill query: String? = nil) {
    isHelpCenterPresented = false
    isGlobalSearchPresented = true

    if let query {
      setGlobalSearchQuery(query)
    }
  }

  func closeGlobalSearch() {
    isGlobalSearchPresented = false
  }

  func openHelpCenter() {
    isGlobalSearchPresented = false
    isHelpCenterPresented = true
  }

  func closeHelpCenter() {
    isHelpCenterPresented = false
  }

  func selectGlobalSearchResult(_ result: GlobalSearchResult) {
    setSection(result.type.targetSection)
    closeGlobalSearch()
  }

  func setThemePreference(_ preference: AppThemePreference) {
    themePreference = preference
    settingsSync.setSyncable(preference.rawValue, forKey: Self.themePreferenceDefaultsKey)
    AppLogger.info("Theme preference updated: \(preference.rawValue)")
  }

  func showError(title: String, message: String) {
    AppLogger.error("\(title): \(message)")
    activeAlert = AppAlert(title: title, message: message)
  }

  func showToast(_ message: String) {
    AppLogger.info("Toast: \(message)")
    activeToast = AppToast(message: message)

    Task {
      try? await Task.sleep(for: .seconds(3))
      if activeToast?.message == message {
        activeToast = nil
      }
    }
  }

  func loadBackendSelectionState() async {
    var state = await backendProfileManager.currentState()
    backendSelectionState = state
    settings.backendProfile = state.activeProfile

    state = await backendProfileManager.refreshValidation()
    backendSelectionState = state

    if state.activeProfile != .sqliteLocal,
       let validation = state.validations[state.activeProfile],
       !validation.isAvailable {
      let fallback = await backendProfileManager.switchProfile(to: .sqliteLocal)
      backendSelectionState = fallback.state
      settings.backendProfile = fallback.activeProfile
      showToast("Falling back to SQLite because \(state.activeProfile.title) is unavailable.")
    }

    await refreshBackendDiagnostics()
  }

  func bootstrapAuthSession() async {
    await authSessionManager.updateConfiguration(OAuthEnvironmentConfiguration.fromStoredOrEnvironment())
    authSessionState = await authSessionManager.bootstrap()
  }

  func oauthConfigurationForSettings() -> OAuthEnvironmentConfiguration? {
    OAuthEnvironmentConfiguration.fromStoredOrEnvironment()
  }

  func saveOAuthConfiguration(baseURL: String, clientID: String, redirectURI: String) async throws {
    let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedBaseURL.isEmpty else {
      throw OAuthConfigurationValidationError.missingField("OAuth base URL")
    }
    guard !trimmedClientID.isEmpty else {
      throw OAuthConfigurationValidationError.missingField("OAuth client ID")
    }
    guard !trimmedRedirectURI.isEmpty else {
      throw OAuthConfigurationValidationError.missingField("OAuth redirect URI")
    }

    guard
      let parsedBaseURL = URL(string: trimmedBaseURL),
      let scheme = parsedBaseURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      throw OAuthConfigurationValidationError.invalidBaseURL
    }

    guard
      let parsedRedirect = URL(string: trimmedRedirectURI),
      parsedRedirect.scheme != nil
    else {
      throw OAuthConfigurationValidationError.invalidRedirectURI
    }

    let configuration = OAuthEnvironmentConfiguration(
      baseURL: parsedBaseURL,
      clientID: trimmedClientID,
      redirectURI: trimmedRedirectURI
    )
    configuration.persist()
    await authSessionManager.updateConfiguration(configuration)
    if case .failed(let message) = authSessionState, message == OAuthClientError.notConfigured.localizedDescription {
      authSessionState = .unauthenticated
    }
    showToast("OAuth configuration saved")
  }

  func clearOAuthConfiguration() async {
    OAuthEnvironmentConfiguration.clearStored()
    let fallback = OAuthEnvironmentConfiguration.fromEnvironment()
    await authSessionManager.updateConfiguration(fallback)
    if case .failed(let message) = authSessionState, message == OAuthClientError.notConfigured.localizedDescription {
      authSessionState = .unauthenticated
    }

    if fallback == nil {
      showToast("OAuth configuration cleared")
    } else {
      showToast("Using environment OAuth defaults")
    }
  }

  func loginWithAuthorizationCode(_ code: String) async {
    guard await assertRateLimit(for: .signIn, operationName: "Sign in") else { return }

    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      showToast("Authorization code is required")
      return
    }

    authSessionState = await authSessionManager.login(withAuthorizationCode: trimmed)
    let succeeded: Bool = {
      if case .authenticated = authSessionState {
        return true
      }
      return false
    }()

    await securityAuditService.record(
      eventType: .authentication,
      severity: succeeded ? .info : .warning,
      message: succeeded ? "User signed in" : "Sign in failed",
      metadata: ["source": "settings"]
    )
  }

  func logout() async {
    guard await assertRateLimit(for: .signOut, operationName: "Sign out") else { return }

    authSessionState = await authSessionManager.logout()
    await securityAuditService.record(
      eventType: .authentication,
      severity: .info,
      message: "User signed out",
      metadata: ["source": "settings"]
    )
  }

  func bootstrapLocalLockState() async {
    localLockStatus = await localLockManager.bootstrap(isEnabled: settings.localLockEnabled)
    biometricAvailability = biometricAuthService.availability()
  }

  func handleLocalLockToggle(_ enabled: Bool, password: String? = nil) async {
    guard await assertRateLimit(for: .localLockToggle, operationName: "Local lock toggle") else { return }

    if enabled {
      let trimmed = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty else {
        settings.localLockEnabled = false
        showToast("Set a local lock password first")
        return
      }

      localLockStatus = await localLockManager.setEnabled(true, password: trimmed)
      settings.localLockEnabled = true
      settingsSync.setSyncable(true, forKey: Self.localLockEnabledDefaultsKey)
      await securityAuditService.record(
        eventType: .localLock,
        severity: .info,
        message: "Local lock enabled"
      )
      showToast("Local lock enabled")
    } else {
      localLockStatus = await localLockManager.setEnabled(false, password: nil)
      settings.localLockEnabled = false
      settingsSync.setSyncable(false, forKey: Self.localLockEnabledDefaultsKey)
      await securityAuditService.record(
        eventType: .localLock,
        severity: .warning,
        message: "Local lock disabled"
      )
      showToast("Local lock disabled")
    }
  }

  func lockAppNow() async {
    guard settings.localLockEnabled else {
      showToast("Enable local lock first")
      return
    }

    localLockStatus = await localLockManager.lock()
    await securityAuditService.record(
      eventType: .localLock,
      severity: .info,
      message: "App locked manually"
    )
  }

  func unlockAppWithPassword(_ password: String) async {
    guard await assertRateLimit(for: .passwordUnlock, operationName: "Password unlock") else { return }

    let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPassword.isEmpty else {
      showToast("Enter your local lock password")
      return
    }

    localLockStatus = await localLockManager.unlock(password: trimmedPassword)
    let severity: SecurityAuditSeverity = {
      if case .unlocked = localLockStatus { return .info }
      if case .lockedOut = localLockStatus { return .critical }
      return .warning
    }()

    await securityAuditService.record(
      eventType: .localLock,
      severity: severity,
      message: "Password unlock attempt",
      metadata: ["status": statusMessage(for: localLockStatus)]
    )
  }

  func unlockAppWithBiometrics() async {
    guard await assertRateLimit(for: .biometricUnlock, operationName: "Biometric unlock") else { return }

    biometricAvailability = biometricAuthService.availability()

    guard case .available = biometricAvailability else {
      showToast("Biometric or device authentication is unavailable on this Mac")
      return
    }

    let authenticated = await biometricAuthService.authenticate(reason: "Unlock Serenity")
    if authenticated {
      localLockStatus = await localLockManager.unlockWithBiometric()
      showToast("Unlocked with biometrics")
      await securityAuditService.record(
        eventType: .biometricUnlock,
        severity: .info,
        message: "Unlocked with biometrics"
      )
    } else {
      showToast("Biometric authentication failed")
      await securityAuditService.record(
        eventType: .biometricUnlock,
        severity: .warning,
        message: "Biometric authentication failed"
      )
    }
  }

  var isLockOverlayVisible: Bool {
    guard settings.localLockEnabled else { return false }
    switch localLockStatus {
    case .locked, .lockedOut:
      return true
    case .disabled, .unlocked:
      return false
    }
  }

  func statusMessage(for lockStatus: LocalLockStatus) -> String {
    switch lockStatus {
    case .disabled:
      return "Local lock disabled"
    case .unlocked:
      return "Unlocked"
    case .locked(let attemptsRemaining):
      return "Locked (\(attemptsRemaining) attempts remaining before lockout)"
    case .lockedOut(let until):
      return "Locked out until \(Self.backendDiagnosticsDateFormatter.string(from: until))"
    }
  }

  func handleBackendProfileSelection(_ profile: BackendProfile) async {
    guard profile != backendSelectionState.activeProfile else { return }
    guard await assertRateLimit(for: .backendSwitch, operationName: "Backend switch") else { return }

    backendSwitchState = .switching(target: profile)
    let switchResult = await backendProfileManager.switchProfile(to: profile)
    backendSelectionState = switchResult.state
    settings.backendProfile = switchResult.activeProfile

    if switchResult.switched {
      let message = "Primary backend switched to \(switchResult.activeProfile.title)"
      backendSwitchState = .succeeded(message: message)
      showToast(message)
      AppLogger.info("Backend profile changed to: \(switchResult.activeProfile.rawValue)")
      await securityAuditService.record(
        eventType: .backendSwitch,
        severity: .info,
        message: "Primary backend switched",
        metadata: ["activeProfile": switchResult.activeProfile.rawValue]
      )
    } else {
      let message = switchResult.validationState.message
      backendSwitchState = .failed(message: message)
      showToast("\(profile.title): \(message)")
      AppLogger.error("Backend switch to \(profile.rawValue) failed: \(message)")
      await securityAuditService.record(
        eventType: .backendSwitch,
        severity: .warning,
        message: "Primary backend switch rejected",
        metadata: [
          "requestedProfile": profile.rawValue,
          "reason": message,
        ]
      )
    }

    await refreshBackendDiagnostics()
    await refreshCoreWorkflowData()
    await refreshDatabaseManagement()
  }

  func configureSerenityCloud(baseURL: String, accessToken: String) async {
    do {
      let configuration = try backendConfigurationStore.saveSerenityCloudConfiguration(
        baseURLString: baseURL,
        accessToken: accessToken
      )
      serenityCloudAdapter = SerenityCloudAdapter(configuration: configuration)
      showToast("Serenity Cloud configuration saved")

      await refreshActiveBackendValidation()
      await refreshBackendDiagnostics()

      if backendSelectionState.activeProfile == .serenityCloud {
        await refreshCoreWorkflowData()
      }
    } catch {
      showError(title: "Cloud configuration failed", message: error.localizedDescription)
    }
  }

  func configureSerenityCloudFromSignedInSession(baseURLOverride: String? = nil) async {
    let trimmedOverride = baseURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolvedBaseURL: String
    if !trimmedOverride.isEmpty {
      resolvedBaseURL = trimmedOverride
    } else if let oauthConfiguration = OAuthEnvironmentConfiguration.fromStoredOrEnvironment() {
      resolvedBaseURL = oauthConfiguration.baseURL.absoluteString
    } else {
      showError(
        title: "Cloud configuration failed",
        message: "Provide a cloud base URL or save OAuth configuration first."
      )
      return
    }

    authSessionState = await authSessionManager.refreshSessionIfNeeded()
    guard case .authenticated(let session) = authSessionState else {
      showError(
        title: "Sign in required",
        message: "Sign in from the Auth Session section, then click Use signed-in session."
      )
      return
    }

    await configureSerenityCloud(baseURL: resolvedBaseURL, accessToken: session.accessToken)
  }

  func clearSerenityCloudConfiguration() async {
    backendConfigurationStore.clearSerenityCloudConfiguration()
    serenityCloudAdapter = nil

    if settings.backendProfile == .serenityCloud {
      await handleBackendProfileSelection(.sqliteLocal)
    }

    await refreshActiveBackendValidation()
    await refreshBackendDiagnostics()
    showToast("Serenity Cloud configuration cleared")
  }

  func configureExternalPostgres(
    host: String,
    port: String,
    database: String,
    username: String,
    password: String,
    sslMode: String
  ) async {
    let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedPort = UInt16(trimmedPort.isEmpty ? "5432" : trimmedPort)
    guard let parsedPort else {
      showToast("PostgreSQL port must be a valid number")
      return
    }

    do {
      let configuration = try backendConfigurationStore.saveExternalPostgresConfiguration(
        host: host,
        port: parsedPort,
        database: database,
        username: username,
        password: password,
        sslMode: sslMode
      )
      externalPostgresAdapter = ExternalPostgresAdapter(configuration: configuration)
      showToast("PostgreSQL configuration saved")

      await refreshActiveBackendValidation()
      await refreshBackendDiagnostics()

      if backendSelectionState.activeProfile == .externalPostgres {
        await refreshCoreWorkflowData()
      }
    } catch {
      showError(title: "PostgreSQL configuration failed", message: error.localizedDescription)
    }
  }

  func clearExternalPostgresConfiguration() async {
    backendConfigurationStore.clearExternalPostgresConfiguration()
    externalPostgresAdapter = nil

    if settings.backendProfile == .externalPostgres {
      await handleBackendProfileSelection(.sqliteLocal)
    }

    await refreshActiveBackendValidation()
    await refreshBackendDiagnostics()
    showToast("PostgreSQL configuration cleared")
  }

  func cloudBaseURLForSettings() -> String {
    serenityCloudAdapter?.diagnostics().baseURL ?? ""
  }

  func externalPostgresDiagnosticsForSettings() -> ExternalPostgresDiagnostics? {
    externalPostgresAdapter?.diagnostics()
  }

  func refreshActiveBackendValidation() async {
    let updatedState = await backendProfileManager.refreshValidation()
    backendSelectionState = updatedState
    await refreshBackendDiagnostics()
  }

  func validationState(for profile: BackendProfile) -> BackendProfileValidationState {
    backendSelectionState.validations[profile] ?? .unknown
  }

  func bootstrapLocalDatabaseIfNeeded() async {
    guard settings.backendProfile == .sqliteLocal else { return }
    guard case .idle = databaseBootstrapState else { return }

    await bootstrapLocalDatabase()
  }

  func bootstrapLocalDatabase() async {
    databaseBootstrapState = .bootstrapping

    do {
      let summary = try await sqliteBackendAdapter.bootstrap()
      let repositories = try sqliteBackendAdapter.makeCoreRepositories()
      sqliteCoreRepositories = repositories
      await installICloudSyncEngine(using: repositories)

      databaseBootstrapState = .ready(
        path: summary.databasePath,
        appliedCount: summary.appliedMigrations.count
      )

      if summary.appliedMigrations.isEmpty {
        showToast("Local database ready")
      } else {
        showToast("Applied \(summary.appliedMigrations.count) migration(s)")
      }

      AppLogger.info(
        "Database bootstrap complete at \(summary.databasePath). Applied: \(summary.appliedMigrations.count), Skipped: \(summary.skippedMigrations.count)"
      )
      await refreshBackendDiagnostics()
      await refreshDatabaseManagement()
    } catch {
      sqliteCoreRepositories = nil
      let message = (error as NSError).localizedDescription
      databaseBootstrapState = .failed(message: message)
      showError(title: "Database bootstrap failed", message: message)
      await refreshBackendDiagnostics()
      await refreshDatabaseManagement()
    }
  }

  func bootstrapIntegrations() async {
    googleCalendarConfigured = googleIntegrationService.isConfigured

    do {
      let restoredSession = await googleIntegrationService.restorePreviousSession()
      let storedSession = try await googleIntegrationService.currentSession()
      if let googleSession = restoredSession ?? storedSession {
        googleIntegrationState.connected = true
        googleIntegrationState.userEmail = googleSession.userEmail
        googleIntegrationState.expiresAt = googleSession.expiresAt
      } else {
        googleIntegrationState = .disconnected
      }
    } catch {
      googleIntegrationState.lastError = error.localizedDescription
    }

    slackConfigured = slackIntegrationService.isConfigured

    if let slackSession = try? slackIntegrationService.currentSession() {
      slackIntegrationState.connected = true
      slackIntegrationState.teamName = slackSession.teamName
      slackIntegrationState.userName = slackSession.userName
      slackIntegrationState.expiresAt = slackSession.expiresAt
      // A stored session means the user connected on purpose, so default the
      // toggle on rather than restoring it silently off.
      slackIntegrationState.syncEnabled = UserDefaults.standard.object(
        forKey: Self.slackSyncEnabledDefaultsKey
      ) as? Bool ?? true
      if let stored = UserDefaults.standard.object(forKey: Self.slackPollIntervalDefaultsKey) as? Int {
        slackPollIntervalMinutes = max(1, stored)
      }
    } else {
      slackIntegrationState = .disconnected
    }
    await loadSlackProposals()
    restartSlackPolling()
    if slackIntegrationState.connected, slackIntegrationState.syncEnabled {
      Task { _ = await self.syncSlackNow() }
    }

    do {
      let tokens = try await githubIntegrationService.listTokens()
      githubIntegrationState.tokens = tokens
    } catch {
      githubIntegrationState.lastError = error.localizedDescription
    }

    await refreshIntegrationDiagnostics()
  }

  func connectGoogleIntegration() async {
    AppLogger.info("connectGoogleIntegration: starting")
    do {
      let session = try await googleIntegrationService.signIn()
      AppLogger.info("connectGoogleIntegration: signIn returned email=\(session.userEmail ?? "nil")")
      googleIntegrationState.connected = true
      googleIntegrationState.userEmail = session.userEmail
      googleIntegrationState.expiresAt = session.expiresAt
      googleIntegrationState.lastError = nil
      showToast("Google connected")
      await refreshIntegrationDiagnostics()
    } catch {
      AppLogger.error("connectGoogleIntegration: signIn threw \(error)")
      googleIntegrationState.lastError = error.localizedDescription
      showError(title: "Google sign-in failed", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func connectGoogleWithAccessToken(
    accessToken: String,
    refreshToken: String?,
    userEmail: String?,
    expiresInHours: Int
  ) async {
    let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      showToast("Google access token is required")
      return
    }

    let expiresAt = Calendar.current.date(byAdding: .hour, value: max(1, expiresInHours), to: Date())
    do {
      _ = try await googleIntegrationService.connectWithToken(
        accessToken: trimmedToken,
        refreshToken: refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : refreshToken,
        expiresAt: expiresAt,
        userEmail: userEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : userEmail
      )
      googleIntegrationState.connected = true
      googleIntegrationState.userEmail = userEmail
      googleIntegrationState.expiresAt = expiresAt
      googleIntegrationState.lastError = nil
      showToast("Google token connected")
      await refreshIntegrationDiagnostics()
    } catch {
      googleIntegrationState.lastError = error.localizedDescription
      showError(title: "Google token connect failed", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func disconnectGoogleIntegration() async {
    do {
      try await googleIntegrationService.disconnect()
      googleIntegrationState = .disconnected
      showToast("Google disconnected")
    } catch {
      googleIntegrationState.lastError = error.localizedDescription
      showError(title: "Failed to disconnect Google", message: error.localizedDescription)
    }
    await refreshIntegrationDiagnostics()
  }

  func setGoogleIntegrationSyncEnabled(_ enabled: Bool) async {
    googleIntegrationState.syncEnabled = enabled
    await refreshIntegrationDiagnostics()
  }

  func addGitHubIntegrationToken(token: String, displayName: String?) async {
    do {
      let tokens = try await githubIntegrationService.addToken(token, displayName: displayName)
      githubIntegrationState.tokens = tokens
      githubIntegrationState.lastError = nil
      showToast("GitHub token added")
      await refreshIntegrationDiagnostics()
    } catch {
      githubIntegrationState.lastError = error.localizedDescription
      showError(title: "Failed to add GitHub token", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func removeGitHubIntegrationToken(id: String) async {
    do {
      githubIntegrationState.tokens = try await githubIntegrationService.removeToken(id: id)
      showToast("GitHub token removed")
      await refreshIntegrationDiagnostics()
    } catch {
      githubIntegrationState.lastError = error.localizedDescription
      showError(title: "Failed to remove GitHub token", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func toggleGitHubIntegrationToken(id: String) async {
    do {
      githubIntegrationState.tokens = try await githubIntegrationService.toggleTokenActive(id: id)
      await refreshIntegrationDiagnostics()
    } catch {
      githubIntegrationState.lastError = error.localizedDescription
      showError(title: "Failed to update GitHub token", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func setGitHubIntegrationSyncEnabled(_ enabled: Bool) async {
    githubIntegrationState.syncEnabled = enabled
    await refreshIntegrationDiagnostics()
  }

  func syncIntegrationsNow() async {
    integrationSyncInProgress = true
    var outcomes: [IntegrationSyncOutcome] = []

    defer {
      integrationSyncInProgress = false
    }

    do {
      if googleIntegrationState.connected && googleIntegrationState.syncEnabled {
        let payload = try await googleIntegrationService.syncCalendarTasks(
          existingTasks: tasks,
          existingProjects: projects
        )
        if let project = payload.project {
          try await saveProject(project)
        }
        for task in payload.tasks {
          try await saveTask(task)
        }
        googleIntegrationState.lastSyncAt = Date()
        outcomes.append(
          IntegrationSyncOutcome(
            provider: .google,
            importedTasks: payload.importedCount,
            detail: "Imported \(payload.importedCount) Google calendar task(s)"
          )
        )
      }

      if githubIntegrationState.syncEnabled && !githubIntegrationState.tokens.isEmpty {
        let payload = try await githubIntegrationService.syncGitHubPullRequests(
          existingTasks: tasks,
          existingProjects: projects
        )
        if let project = payload.project {
          try await saveProject(project)
        }
        for task in payload.tasks {
          try await saveTask(task)
        }
        githubIntegrationState.tokens = (try? await githubIntegrationService.listTokens()) ?? githubIntegrationState.tokens
        githubIntegrationState.lastSyncAt = Date()
        outcomes.append(
          IntegrationSyncOutcome(
            provider: .github,
            importedTasks: payload.importedCount,
            detail: "Imported \(payload.importedCount) GitHub PR task(s)"
          )
        )
      }

      if let slackOutcome = await syncSlackNow() {
        outcomes.append(slackOutcome)
      }

      if outcomes.isEmpty {
        showToast("No integrations were enabled for sync")
      } else {
        let summary = outcomes.map(\.detail).joined(separator: " • ")
        showToast(summary)
      }

      await refreshCoreWorkflowData()
      await refreshIntegrationDiagnostics()
    } catch {
      showError(title: "Integration sync failed", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  // MARK: Slack

  func connectSlackIntegration() async {
    do {
      let session = try await slackIntegrationService.signIn()
      slackIntegrationState.connected = true
      slackIntegrationState.teamName = session.teamName
      slackIntegrationState.userName = session.userName
      slackIntegrationState.expiresAt = session.expiresAt
      slackIntegrationState.syncEnabled = true
      UserDefaults.standard.set(true, forKey: Self.slackSyncEnabledDefaultsKey)
      slackIntegrationState.lastError = nil
      showToast("Connected to \(session.teamName ?? "Slack")")
      restartSlackPolling()
      _ = await syncSlackNow()
      await refreshIntegrationDiagnostics()
    } catch IntegrationServiceError.slackAuthorizationCancelled {
      await refreshIntegrationDiagnostics()
    } catch {
      slackIntegrationState.lastError = error.localizedDescription
      showError(title: "Slack sign-in failed", message: error.localizedDescription)
      await refreshIntegrationDiagnostics()
    }
  }

  func disconnectSlackIntegration() async {
    do {
      try await slackIntegrationService.disconnect()
      slackIntegrationState = .disconnected
      slackMessageReader = nil
      slackProposals = []
      restartSlackPolling()
      showToast("Disconnected from Slack")
    } catch {
      slackIntegrationState.lastError = error.localizedDescription
      showError(title: "Failed to disconnect Slack", message: error.localizedDescription)
    }

    await refreshIntegrationDiagnostics()
  }

  func setSlackIntegrationSyncEnabled(_ enabled: Bool) async {
    slackIntegrationState.syncEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.slackSyncEnabledDefaultsKey)
    restartSlackPolling()
    await refreshIntegrationDiagnostics()
  }

  func setSlackPollIntervalMinutes(_ minutes: Int) {
    slackPollIntervalMinutes = max(1, minutes)
    UserDefaults.standard.set(slackPollIntervalMinutes, forKey: Self.slackPollIntervalDefaultsKey)
    restartSlackPolling()
  }

  /// Polls only while the app is running — a quit Mac app checks nothing, which
  /// is why the Integrations row says so rather than leaving it to be guessed.
  func restartSlackPolling() {
    slackPollTask?.cancel()
    slackPollTask = nil

    guard !Self.isRunningUnderXCTest else { return }
    guard slackIntegrationState.connected, slackIntegrationState.syncEnabled else { return }

    slackPollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let interval = self?.slackPollIntervalMinutes else { return }
        try? await Task.sleep(nanoseconds: UInt64(max(1, interval)) * 60 * 1_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.syncSlackNow()
      }
    }
  }

  func setSlackRelevanceSettings(_ settings: SlackRelevanceSettings) {
    slackRelevanceSettings = settings
  }

  func loadSlackProposals() async {
    guard slackIntegrationState.connected else {
      slackProposals = []
      return
    }

    do {
      let repositories = try await requireSlackRepositories()
      slackProposals = try repositories.proposals.fetchPending()
    } catch {
      slackProposals = []
      slackIntegrationState.lastError = error.localizedDescription
    }
  }

  /// One pass: read what is new, drop what is not aimed at you, ask the model
  /// about the rest, and queue whatever it proposes for review. Nothing here
  /// writes to a task.
  @discardableResult
  func syncSlackNow(now: Date = Date()) async -> IntegrationSyncOutcome? {
    guard slackIntegrationState.connected, slackIntegrationState.syncEnabled else { return nil }

    do {
      let session = try await slackIntegrationService.activeSession()
      slackIntegrationState.expiresAt = session.expiresAt

      let repositories = try await requireSlackRepositories()
      let reader = slackReader()
      let previousCursors = try repositories.cursors.fetchAll()

      let batch = try await reader.fetchNewActivity(
        session: session,
        cursors: previousCursors,
        now: now,
        deadline: now.addingTimeInterval(120)
      )
      slackChannelsWatched = batch.cursors.count

      let filtered = SlackRelevanceFilter.filter(
        messages: batch.messages,
        ownUserID: session.userID,
        ownGroupIDs: await reader.ownGroups(session: session, now: now),
        participatedThreads: Set(batch.cursors.flatMap(\.participatedThreadTS)),
        seenKeys: try repositories.seenMessages.seenKeys(),
        settings: slackRelevanceSettings
      )

      try repositories.seenMessages.record(
        filtered.rejected.map { SlackSeenMessage(channelID: $0.channelID, ts: $0.ts, outcome: .filtered) },
        at: now
      )

      AppLogger.info(
        "Slack sync: \(batch.channelsScanned) channel(s), \(batch.messages.count) new message(s), "
          + "\(filtered.signals.count) aimed at you"
      )

      var proposed = 0
      var failedChannels: Set<String> = []

      if !filtered.signals.isEmpty {
        guard let credential = defaultSlackCredential() else {
          throw AIWorkflowError.noCredentialConfigured
        }

        let names = await reader.userNameMap()
        let outcome = try await aiWorkflowService.proposeSlackDecisions(
          signals: filtered.signals,
          credentialID: credential.id,
          openTasks: tasks,
          projects: quickCaptureProjectContext,
          availableTags: quickCaptureAvailableTags,
          names: names,
          ownName: session.userName ?? "the user",
          now: now
        )

        let failedSignals = Set(outcome.failedSignalIDs)
        let decisions = Dictionary(
          outcome.decisions.map { ($0.signalID, $0) },
          uniquingKeysWith: { first, _ in first }
        )
        var seenEntries: [SlackSeenMessage] = []

        for signal in filtered.signals {
          // A failed signal is recorded nowhere, so the retry below re-reads it
          // rather than losing it to a transient provider error.
          if failedSignals.contains(signal.id) {
            failedChannels.insert(signal.anchor.channelID)
            continue
          }

          let proposal = decisions[signal.id].flatMap {
            SlackProposalMapper.proposal(
              from: $0,
              signal: signal,
              workspaceURL: session.teamURL,
              names: names,
              now: now
            )
          }

          if let proposal {
            try repositories.proposals.save(proposal)
            // A thread that keeps moving would otherwise stack up one pending
            // proposal per sync. The newest reflects where the conversation
            // actually got to.
            try repositories.proposals.supersedePending(
              channelID: proposal.source.channelID,
              threadTS: proposal.source.threadTS,
              excluding: proposal.id,
              at: now
            )
            proposed += 1
          }

          seenEntries.append(
            contentsOf: signal.seenCandidates.map {
              SlackSeenMessage(
                channelID: $0.channelID,
                ts: $0.ts,
                outcome: proposal == nil ? .ignored : .proposed
              )
            }
          )
        }

        try repositories.seenMessages.record(seenEntries, at: now)
        slackIntegrationState.lastError = outcome.lastError
      } else {
        slackIntegrationState.lastError = nil
      }

      // Cursors advance last, and not at all for a channel whose signals failed:
      // the seen table makes a re-read cheap, whereas a skipped window is gone.
      let previousByChannel = Dictionary(
        previousCursors.map { ($0.channelID, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let cursorsToSave = batch.cursors.map { cursor -> SlackChannelCursor in
        guard failedChannels.contains(cursor.channelID) else { return cursor }
        var held = cursor
        held.lastTS = previousByChannel[cursor.channelID]?.lastTS
        return held
      }
      try repositories.cursors.save(cursorsToSave)

      slackIntegrationState.lastSyncAt = now
      slackLastPass = SlackSyncPass(
        at: now,
        channelsScanned: batch.channelsScanned,
        messagesRead: batch.messages.count,
        signals: filtered.signals.count,
        proposalsCreated: proposed,
        stoppedOnDeadline: batch.reachedDeadline
      )
      AppLogger.info("Slack sync: \(proposed) proposal(s) queued for review")

      await loadSlackProposals()
      announceSlackProposals(newlyProposed: proposed)

      return IntegrationSyncOutcome(
        provider: .slack,
        importedTasks: proposed,
        detail: proposed == 0
          ? "Slack: nothing new to review"
          : "Slack: \(proposed) proposal(s) waiting"
      )
    } catch {
      slackIntegrationState.lastError = error.localizedDescription
      AppLogger.error("Slack sync failed: \(error.localizedDescription)")
      await refreshIntegrationDiagnostics()
      return nil
    }
  }

  func acceptSlackProposal(id: String) async {
    guard let proposal = slackProposals.first(where: { $0.id == id }) else { return }

    do {
      let repositories = try await requireSlackRepositories()
      let now = Date()

      switch proposal.kind {
      case .create:
        try await applySlackCreate(proposal, at: now)
      case .update:
        guard let taskID = proposal.targetTaskID, tasks.contains(where: { $0.id == taskID }) else {
          try repositories.proposals.updateStatus(id: id, status: .superseded, decidedAt: now)
          showToast("That task no longer exists, so the proposal was dropped")
          await loadSlackProposals()
          return
        }
        try await applySlackUpdate(proposal, taskID: taskID, at: now)
      }

      try repositories.proposals.updateStatus(id: id, status: .accepted, decidedAt: now)
      try repositories.proposals.supersedePending(
        channelID: proposal.source.channelID,
        threadTS: proposal.source.threadTS,
        excluding: id,
        at: now
      )

      await refreshCoreWorkflowData()
      await loadSlackProposals()
    } catch {
      showError(title: "Could not apply the Slack proposal", message: error.localizedDescription)
    }
  }

  func dismissSlackProposal(id: String) async {
    guard let proposal = slackProposals.first(where: { $0.id == id }) else { return }

    do {
      let repositories = try await requireSlackRepositories()
      let now = Date()
      try repositories.proposals.updateStatus(id: id, status: .dismissed, decidedAt: now)
      try repositories.proposals.supersedePending(
        channelID: proposal.source.channelID,
        threadTS: proposal.source.threadTS,
        excluding: id,
        at: now
      )
      await loadSlackProposals()
    } catch {
      showError(title: "Could not dismiss the Slack proposal", message: error.localizedDescription)
    }
  }

  func dismissAllSlackProposals() async {
    do {
      let repositories = try await requireSlackRepositories()
      let now = Date()
      for proposal in slackProposals {
        try repositories.proposals.updateStatus(id: proposal.id, status: .dismissed, decidedAt: now)
      }
      await loadSlackProposals()
    } catch {
      showError(title: "Could not clear the Slack proposals", message: error.localizedDescription)
    }
  }

  // MARK: - Capture commands

  /// Runs a `/slack` or `/github` line: fetch the source material, draft the
  /// task, and hold it for confirmation. Nothing is written here.
  @discardableResult
  func submitCaptureCommand(_ command: CaptureCommand, typedText: String, now: Date = Date()) async -> Bool {
    pendingCaptureDraft = nil

    do {
      let sources = try await captureSources(for: command)
      guard !sources.isEmpty else {
        captureCommandProgress = nil
        showToast("Nothing to read from that link")
        return false
      }

      let labels = sources.map(CaptureCommandDrafter.label(for:)).joined(separator: ", ")

      // No credential is not a dead end: the material is already in hand, so
      // assemble what can be assembled and say it was done without a model.
      guard let credential = defaultSlackCredential() else {
        captureCommandProgress = nil
        pendingCaptureDraft = CaptureDraftPreview(
          typedText: typedText,
          kind: command.kind,
          drafts: fallbackDrafts(for: sources, context: command.context, now: now),
          draftedByModel: false
        )
        showToast("Drafted from \(labels) without a model — add an AI key in Insights for more detail")
        return true
      }

      captureCommandProgress = .drafting
      let drafts = try await aiWorkflowService.draftCaptureCommand(
        sources: sources,
        context: command.context,
        credentialID: credential.id,
        openTasks: tasks,
        projects: quickCaptureProjectContext,
        availableTags: quickCaptureAvailableTags,
        now: now
      )
      captureCommandProgress = nil

      guard !drafts.isEmpty else {
        showToast("Could not draft a task from \(labels) — try adding what you want in your own words")
        return false
      }

      pendingCaptureDraft = CaptureDraftPreview(
        typedText: typedText,
        kind: command.kind,
        drafts: drafts,
        draftedByModel: true
      )
      return true
    } catch {
      captureCommandProgress = nil
      showError(title: "Could not read that link", message: error.localizedDescription)
      return false
    }
  }

  /// A command is an explicit instruction about one conversation, so it reads
  /// straight past the relevance filter, the seen table and the channel cursors
  /// the background sync relies on. Routing it through any of those would make
  /// it silently do nothing for a message the sync had already handled.
  private func captureSources(for command: CaptureCommand) async throws -> [CaptureSource] {
    var sources: [CaptureSource] = []

    for reference in command.references {
      switch reference {
      case .slack(let slackReference):
        guard slackIntegrationState.connected else {
          throw CaptureCommandError.slackNotConnected
        }
        let session = try await slackIntegrationService.activeSession()
        slackIntegrationState.expiresAt = session.expiresAt

        captureCommandProgress = .reading("#\(slackReference.channelID)")
        let excerpt = try await slackReader().fetchConversation(
          session: session,
          reference: slackReference
        )
        captureCommandProgress = .reading("#\(excerpt.channelName)")
        sources.append(.slack(excerpt))

      case .github(let githubReference):
        guard !githubIntegrationState.tokens.filter(\.isActive).isEmpty else {
          throw CaptureCommandError.githubNotConnected
        }

        captureCommandProgress = .reading(githubReference.slug)
        let snapshot = try await githubIntegrationService.fetchPullRequest(githubReference)
        sources.append(.github(snapshot))
      }
    }

    return sources
  }

  /// What a command produces with no AI credential configured: the title and
  /// the links, a date only if the user's own words carried one, and the origin
  /// tag so a later paste still recognises it.
  private func fallbackDrafts(for sources: [CaptureSource], context: String, now: Date) -> [CaptureDraft] {
    let parsedContext = QuickCaptureDateParser.parse(context)
    let links = sources.compactMap(CaptureCommandDrafter.link(for:))
    let labels = sources.map(CaptureCommandDrafter.label(for:))

    let title: String
    if let first = sources.first, case .github(let snapshot) = first, sources.count == 1 {
      title = snapshot.title
    } else if !parsedContext.title.isEmpty {
      title = parsedContext.title
    } else {
      title = "Follow up on \(labels.joined(separator: ", "))"
    }

    let description = ([context.trimmingCharacters(in: .whitespacesAndNewlines)] + links)
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    let draft = CaptureDraft(
      kind: .create,
      payload: SlackProposalPayload(
        title: title,
        description: description.isEmpty ? nil : description,
        dueDate: parsedContext.dueDate
      ),
      confidence: 0,
      reason: "Assembled without a model — no AI credential is configured.",
      sourceLabel: labels.joined(separator: ", ")
    )

    return CaptureCommandDrafter.redirectingDuplicates(
      [
        CaptureCommandDrafter.tagged(
          draft,
          sources: sources,
          coveringKeys: sources.indices.map(CaptureCommandDrafter.key(for:))
        )
      ],
      sources: sources,
      tasks: tasks
    )
  }

  /// Writes every draft in the held preview. One Save, because the user issued
  /// one command.
  @discardableResult
  func savePendingCaptureDraft(now: Date = Date()) async -> Bool {
    guard let preview = pendingCaptureDraft, !preview.drafts.isEmpty else { return false }

    var created = 0
    var updated = 0

    do {
      for draft in preview.drafts {
        let attribution = captureAttribution(for: draft, at: now)

        switch draft.resolvedKind {
        case .create:
          try await applyDraftCreate(draft.resolvedPayload, attribution: attribution, at: now)
          created += 1
        case .update:
          // The task can have been deleted between the draft and the Save.
          guard let taskID = draft.targetTaskID, tasks.contains(where: { $0.id == taskID }) else {
            var orphaned = draft
            orphaned.chosenKind = .create
            try await applyDraftCreate(orphaned.resolvedPayload, attribution: attribution, at: now)
            created += 1
            continue
          }
          try await applyDraftUpdate(draft.payload, taskID: taskID, attribution: attribution, at: now)
          updated += 1
        }
      }

      pendingCaptureDraft = nil
      showToast(captureSaveSummary(created: created, updated: updated))
      await refreshCoreWorkflowData()
      return true
    } catch {
      showError(title: "Could not save the drafted task", message: error.localizedDescription)
      return false
    }
  }

  /// The user's answer to a match they disagree with: the same drafted work,
  /// written as a new task instead of over the one it was aimed at.
  func chooseCaptureDraftKind(_ kind: CaptureDraftKind, forDraftID id: String) {
    guard let index = pendingCaptureDraft?.drafts.firstIndex(where: { $0.id == id }) else { return }
    pendingCaptureDraft?.drafts[index].chosenKind = kind
  }

  func discardPendingCaptureDraft() {
    pendingCaptureDraft = nil
  }

  private func captureSaveSummary(created: Int, updated: Int) -> String {
    switch (created, updated) {
    case (0, 0):
      return "Nothing to save"
    case (let created, 0):
      return "Created \(created) task\(created == 1 ? "" : "s")"
    case (0, let updated):
      return "Updated \(updated) task\(updated == 1 ? "" : "s")"
    default:
      return "Created \(created), updated \(updated)"
    }
  }

  private func captureAttribution(for draft: CaptureDraft, at now: Date) -> TaskActivityEntry {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM yyyy"

    return TaskActivityEntry(
      id: UUID().uuidString,
      kind: .event,
      text: "Drafted from \(draft.sourceLabel), \(formatter.string(from: now))",
      createdAt: now
    )
  }

  private func applySlackCreate(_ proposal: SlackProposal, at now: Date) async throws {
    try await applyDraftCreate(
      proposal.payload,
      attribution: slackAttribution(for: proposal, at: now),
      at: now
    )
  }

  private func applySlackUpdate(_ proposal: SlackProposal, taskID: String, at now: Date) async throws {
    try await applyDraftUpdate(
      proposal.payload,
      taskID: taskID,
      attribution: slackAttribution(for: proposal, at: now),
      at: now
    )
  }

  /// Writes a drafted task, whoever drafted it. The attribution line is the
  /// only thing that differs between a Slack proposal and a capture command.
  func applyDraftCreate(
    _ payload: SlackProposalPayload,
    attribution: TaskActivityEntry,
    at now: Date
  ) async throws {
    let completed = payload.statusChange == .completed

    let task = TaskEntity(
      id: UUID().uuidString,
      title: payload.title ?? "Untitled",
      description: payload.description,
      completed: completed,
      completedAt: completed ? now : nil,
      priority: payload.priority ?? .medium,
      dueDate: payload.dueDate,
      projectId: validQuickCaptureProjectID(payload.projectId),
      tags: payload.tags,
      createdAt: now,
      updatedAt: now,
      subtasks: payload.subtasks.enumerated().map { offset, title in
        TaskSubtask(id: UUID().uuidString, title: title, completed: false, order: offset)
      },
      recurring: nil,
      userId: nil,
      activity: [attribution]
    )

    try await saveTask(task)
  }

  /// Writes only the fields the draft actually changes. `saveTask` diffs the
  /// result and logs what moved, so this adds just the line saying where it
  /// came from.
  func applyDraftUpdate(
    _ payload: SlackProposalPayload,
    taskID: String,
    attribution: TaskActivityEntry,
    at now: Date
  ) async throws {
    guard var task = tasks.first(where: { $0.id == taskID }) else { return }

    if let title = payload.title { task.title = title }
    if let description = payload.description { task.description = description }
    if let priority = payload.priority { task.priority = priority }
    if let dueDate = payload.dueDate { task.dueDate = dueDate }
    if let projectID = validQuickCaptureProjectID(payload.projectId) { task.projectId = projectID }

    if !payload.tags.isEmpty {
      var tags = task.tags
      for tag in payload.tags where !tags.contains(tag) {
        tags.append(tag)
      }
      task.tags = tags
    }

    if !payload.subtasks.isEmpty {
      let start = task.subtasks.count
      task.subtasks.append(
        contentsOf: payload.subtasks.enumerated().map { offset, title in
          TaskSubtask(id: UUID().uuidString, title: title, completed: false, order: start + offset)
        }
      )
    }

    switch payload.statusChange {
    case .completed:
      task.completed = true
      task.completedAt = now
    case .reopened:
      task.completed = false
      task.completedAt = nil
    case .none:
      break
    }

    task.updatedAt = now
    task.activity.append(attribution)
    try await saveTask(task)
  }

  private func slackAttribution(for proposal: SlackProposal, at now: Date) -> TaskActivityEntry {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM yyyy"

    return TaskActivityEntry(
      id: UUID().uuidString,
      kind: .event,
      text: "From Slack · \(proposal.source.author) in #\(proposal.source.channelName), \(formatter.string(from: proposal.source.sentAt))",
      createdAt: now
    )
  }

  /// One notification for the batch, replacing the previous one. Firing per
  /// proposal would turn a quiet feature into a noisy one.
  private func announceSlackProposals(newlyProposed: Int) {
    guard notificationsEnabled, newlyProposed > 0 else { return }

    let total = slackProposals.count
    let title = total == 1 ? "1 Slack item needs a decision" : "\(total) Slack items need a decision"
    let body = newlyProposed == total ? nil : "\(newlyProposed) new since the last check"

    Task { [notificationCenter] in
      await notificationCenter.postNow(id: "slack-proposals", title: title, body: body)
    }
  }

  private func defaultSlackCredential() -> AICredentialEntity? {
    aiCredentials
      .filter(\.enabled)
      .sorted { lhs, rhs in
        lhs.priority == rhs.priority ? lhs.createdAt < rhs.createdAt : lhs.priority < rhs.priority
      }
      .first
  }

  private func slackReader() -> SlackMessageReader {
    if let slackMessageReader {
      return slackMessageReader
    }

    let reader = SlackMessageReader(client: slackIntegrationService.client)
    slackMessageReader = reader
    return reader
  }

  private func requireSlackRepositories() async throws -> GRDBSlackRepositorySet {
    if let slackRepositories {
      return slackRepositories
    }

    _ = try await requireSQLiteCoreRepositories()
    let repositories = try sqliteBackendAdapter.makeSlackRepositories()
    slackRepositories = repositories
    return repositories
  }

  func refreshIntegrationDiagnostics() async {
    var lines: [String] = []
    lines.append("Google configured: \(googleCalendarConfigured ? "yes" : "no")")
    lines.append("Google connected: \(googleIntegrationState.connected ? "yes" : "no")")
    lines.append("Google sync enabled: \(googleIntegrationState.syncEnabled ? "yes" : "no")")
    if let userEmail = googleIntegrationState.userEmail {
      lines.append("Google account: \(userEmail)")
    }
    if let lastSyncAt = googleIntegrationState.lastSyncAt {
      lines.append("Google last sync: \(Self.backendDiagnosticsDateFormatter.string(from: lastSyncAt))")
    }
    if let error = googleIntegrationState.lastError {
      lines.append("Google error: \(error)")
    }

    lines.append("Slack configured: \(slackConfigured ? "yes" : "no")")
    lines.append("Slack connected: \(slackIntegrationState.connected ? "yes" : "no")")
    lines.append("Slack sync enabled: \(slackIntegrationState.syncEnabled ? "yes" : "no")")
    if let teamName = slackIntegrationState.teamName {
      lines.append("Slack workspace: \(teamName)")
    }
    if let expiresAt = slackIntegrationState.expiresAt {
      lines.append("Slack token expires: \(expiresAt)")
    }
    if let lastSyncAt = slackIntegrationState.lastSyncAt {
      lines.append("Slack last sync: \(lastSyncAt)")
    }
    lines.append("Slack channels watched: \(slackChannelsWatched)")
    if let pass = slackLastPass {
      lines.append("Slack last pass: \(Self.backendDiagnosticsDateFormatter.string(from: pass.at))")
      lines.append("Slack messages read: \(pass.messagesRead) across \(pass.channelsScanned) channel(s)")
      lines.append("Slack aimed at you: \(pass.signals)")
      lines.append("Slack proposals created: \(pass.proposalsCreated)")
      if pass.stoppedOnDeadline {
        lines.append("Slack pass hit its time budget — more will arrive next sync")
      }
    } else {
      lines.append("Slack last pass: never")
    }
    lines.append("Slack pending proposals: \(slackProposals.count)")
    if let error = slackIntegrationState.lastError {
      lines.append("Slack last error: \(error)")
    }
    lines.append("GitHub tokens: \(githubIntegrationState.tokens.count)")
    lines.append("GitHub sync enabled: \(githubIntegrationState.syncEnabled ? "yes" : "no")")
    if let lastSyncAt = githubIntegrationState.lastSyncAt {
      lines.append("GitHub last sync: \(Self.backendDiagnosticsDateFormatter.string(from: lastSyncAt))")
    }
    if let error = githubIntegrationState.lastError {
      lines.append("GitHub error: \(error)")
    }

    integrationDiagnosticsLines = lines
  }

  func bootstrapAIWorkflows() async {
    aiModelCatalog = await aiWorkflowService.modelCatalog()
    await refreshAIWorkflows()
  }

  func refreshAIWorkflows() async {
    do {
      let snapshot = try await aiWorkflowService.fetchSnapshot(limit: 200)
      aiCredentials = snapshot.credentials
      aiSettings = snapshot.settings
      aiInsights = snapshot.insights
      aiRecaps = snapshot.recaps
      aiSummaries = snapshot.summaries
      aiUsageEntries = snapshot.usage
      aiModelRates = snapshot.modelRates
      standups = snapshot.standups

      if aiCredentials.contains(where: { $0.enabled }) {
        aiStatusMessage = "AI is ready."
      } else {
        aiStatusMessage = "AI features require a configured provider key."
      }
    } catch {
      aiStatusMessage = "Failed to load AI state: \(error.localizedDescription)"
    }
  }

  func validateAICredentialKey(
    provider: AICredentialProvider,
    apiKey: String,
    baseURL: String? = nil
  ) async throws -> [String] {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await aiWorkflowService.validateAPIKey(
      provider: provider,
      apiKey: trimmed,
      baseURL: baseURL
    )
  }

  func addAICredential(
    provider: AICredentialProvider,
    name: String,
    apiKey: String,
    modelPreference: String?,
    availableModels: [String]? = nil,
    baseURL: String? = nil
  ) async {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      showToast("API key is required")
      return
    }

    let trimmedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    if provider == .custom, trimmedBaseURL?.isEmpty ?? true {
      showToast("Custom provider needs a domain")
      return
    }

    // Saving without pressing Verify would otherwise store no model list, leaving the credential on
    // the compiled-in catalog. A failure here is not fatal — the key still saves.
    var resolvedModels = availableModels
    if resolvedModels?.isEmpty ?? true {
      resolvedModels = try? await aiWorkflowService.validateAPIKey(
        provider: provider,
        apiKey: trimmedKey,
        baseURL: trimmedBaseURL
      )
    }

    do {
      _ = try await aiWorkflowService.addCredential(
        provider: provider,
        name: name,
        apiKey: trimmedKey,
        modelPreference: modelPreference,
        availableModels: resolvedModels,
        baseURL: trimmedBaseURL
      )
      showToast("\(provider.rawValue.capitalized) credential added")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to add credential", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func updateAICredentialEnabled(id: String, enabled: Bool) async {
    do {
      _ = try await aiWorkflowService.updateCredential(id: id, enabled: enabled)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update credential", message: error.localizedDescription)
    }
  }

  func updateAICredentialModel(id: String, modelPreference: String?) async {
    do {
      _ = try await aiWorkflowService.updateCredential(id: id, modelPreference: modelPreference)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update credential model", message: error.localizedDescription)
    }
  }

  func deleteAICredential(id: String) async {
    do {
      try await aiWorkflowService.deleteCredential(id: id)
      showToast("Credential deleted")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to delete credential", message: error.localizedDescription)
    }
  }

  func saveAIModelRate(
    provider: AIUsageProvider,
    model: String,
    inputUSDPerMillion: Double,
    outputUSDPerMillion: Double
  ) async {
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
      showToast("Model name is required")
      return
    }

    do {
      let rate = AIModelRateEntity(
        provider: provider,
        model: trimmedModel,
        inputUSDPerMillion: max(0, inputUSDPerMillion),
        outputUSDPerMillion: max(0, outputUSDPerMillion),
        source: .user
      )
      try await aiWorkflowService.saveModelRate(rate)
      showToast("Model rate saved")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to save model rate", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func deleteAIModelRate(provider: AIUsageProvider, model: String) async {
    do {
      try await aiWorkflowService.deleteModelRate(provider: provider, model: model)
      showToast("Model rate removed")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to remove model rate", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func resetAIModelRatesToDefaults() async {
    do {
      try await aiWorkflowService.resetModelRatesToDefaults()
      showToast("Default model rates restored")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to reset model rates", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func refreshMissingAIModelRatesFromLiteLLM() async {
    do {
      let count = try await aiWorkflowService.refreshMissingModelRatesFromLiteLLM()
      showToast(count == 1 ? "Fetched 1 model rate" : "Fetched \(count) model rates")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to refresh LiteLLM pricing", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func setAIActiveProvider(_ provider: AICredentialProvider?) async {
    var updated = aiSettings
    updated.activeProvider = provider

    do {
      try await aiWorkflowService.saveSettings(updated)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to save AI settings", message: error.localizedDescription)
    }
  }

  func setAIPreferredModel(provider: AICredentialProvider, model: String?) async {
    var preferred = aiSettings.preferredModels ?? AIPreferredModels(openai: nil, gemini: nil, anthropic: nil)
    switch provider {
    case .openai:
      preferred.openai = model
    case .gemini:
      preferred.gemini = model
    case .anthropic:
      preferred.anthropic = model
    case .nvidia:
      preferred.nvidia = model
    case .custom:
      // Several custom domains share this provider, so the model is set on the credential instead.
      return
    }

    var updated = aiSettings
    updated.preferredModels = preferred

    do {
      try await aiWorkflowService.saveSettings(updated)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update preferred model", message: error.localizedDescription)
    }
  }

  func setAIDataTypes(includeTasks: Bool, includeJournal: Bool, includeProjects: Bool) async {
    var updated = aiSettings
    updated.dataTypes = AISettingsDataTypes(
      includeTasks: includeTasks,
      includeJournal: includeJournal,
      includeProjects: includeProjects
    )

    do {
      try await aiWorkflowService.saveSettings(updated)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to save AI data settings", message: error.localizedDescription)
    }
  }

  func setAIAutoAnalyze(_ enabled: Bool) async {
    var updated = aiSettings
    updated.autoAnalyze = enabled

    do {
      try await aiWorkflowService.saveSettings(updated)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to save auto-analyze setting", message: error.localizedDescription)
    }
  }

  func setAIAnalysisFrequency(_ frequency: AIAnalysisFrequency) async {
    var updated = aiSettings
    updated.analysisFrequency = frequency

    do {
      try await aiWorkflowService.saveSettings(updated)
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to save analysis frequency", message: error.localizedDescription)
    }
  }

  func runAIAnalysis() async {
    do {
      _ = try await aiWorkflowService.generateInsights(
        tasks: aiSettings.dataTypes.includeTasks ? tasks : [],
        journalEntries: aiSettings.dataTypes.includeJournal ? journalEntries : [],
        projects: aiSettings.dataTypes.includeProjects ? projects : [],
        goals: goals
      )
      triggerICloudSync()
      showToast("Insights generated")
      await refreshAIWorkflows()
    } catch {
      aiStatusMessage = error.localizedDescription
      showError(title: "Insight generation failed", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func updateAIInsightFeedback(
    id: String,
    userRating: Int?,
    dismissed: Bool?,
    markedHelpful: Bool?,
    userNotes: String?
  ) async {
    do {
      try await aiWorkflowService.updateInsightFeedback(
        id: id,
        userRating: userRating,
        dismissed: dismissed,
        markedHelpful: markedHelpful,
        userNotes: userNotes
      )
      triggerICloudSync()
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update insight feedback", message: error.localizedDescription)
    }
  }

  // MARK: - Stand-up

  /// The last stand-up is both the window anchor and the source of carry-over,
  /// so a stale copy would silently replay yesterday. Read it fresh rather than
  /// trusting whatever the last refresh left in `standups`.
  private func latestStandup() async -> StandupEntity? {
    do {
      return try await aiWorkflowService.fetchLatestStandup()
    } catch {
      AppLogger.error("Standup: failed to read the last stand-up: \(error.localizedDescription)")
      return standups.max { $0.generatedAt < $1.generatedAt }
    }
  }

  /// What Home's strip reports before anything is opened.
  func standupPendingCount(now: Date = Date()) async -> Int {
    let recall = await latestStandup()?.recall
    return StandupPlanner.build(tasks: tasks, recall: recall, now: now).reportableCount
  }

  func buildStandupBoard(now: Date = Date()) async {
    let previous = await latestStandup()
    standupScript = nil
    standupBoardEdited = false
    standupBoard = StandupPlanner.build(tasks: tasks, recall: previous?.recall, now: now)
  }

  func moveStandupCard(id: String, to column: StandupColumn) {
    guard var board = standupBoard, let index = board.cards.firstIndex(where: { $0.id == id }) else { return }
    guard board.cards[index].column != column else { return }

    let previousID = board.cards[index].id
    var card = board.cards[index]
    card.column = column
    // The id carries the column, so a moved card has to be re-keyed or a second
    // move of the same task collides with where it used to be.
    if let taskID = card.taskID {
      card.id = StandupCard.cardID(taskID: taskID, column: column)
    }

    // Both keys go: the row being moved, and any card already sitting in the
    // destination for this task. A task may hold two columns, never two cards
    // in one.
    board.cards.removeAll { $0.id == previousID || $0.id == card.id }
    board.cards.insert(card, at: min(index, board.cards.count))
    standupBoard = board
    standupBoardEdited = true
  }

  func addStandupCard(title: String, to column: StandupColumn) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var board = standupBoard else { return }

    board.cards.append(
      StandupCard(
        id: "manual:\(UUID().uuidString)",
        taskID: nil,
        column: column,
        title: trimmed,
        fact: "Not tracked in Serenity",
        source: .manual
      )
    )
    standupBoard = board
    standupBoardEdited = true
  }

  func removeStandupCard(id: String) {
    guard var board = standupBoard else { return }
    board.cards.removeAll { $0.id == id }
    standupBoard = board
    standupBoardEdited = true
  }

  func setStandupLength(_ length: StandupLength) async {
    var updated = aiSettings
    updated.standupLength = length

    do {
      try await aiWorkflowService.saveSettings(updated)
      aiSettings = updated
    } catch {
      showError(title: "Failed to save stand-up length", message: error.localizedDescription)
    }
  }

  func setStandupFormat(_ instruction: String) async {
    var updated = aiSettings
    updated.standupFormat = instruction.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    do {
      try await aiWorkflowService.saveSettings(updated)
      aiSettings = updated
      showToast("Stand-up format saved")
    } catch {
      showError(title: "Failed to save stand-up format", message: error.localizedDescription)
    }
  }

  /// `instructionOverride` is the just-for-today escape: the morning someone
  /// asks for it differently, without rewriting the standing rule.
  func writeStandup(instructionOverride: String? = nil, now: Date = Date()) async {
    guard let board = standupBoard else { return }

    standupIsWriting = true
    defer { standupIsWriting = false }

    do {
      let draft = try await aiWorkflowService.writeStandup(
        board: board,
        instruction: instructionOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? aiSettings.resolvedStandupFormat,
        length: aiSettings.resolvedStandupLength,
        now: now
      )
      standupScript = draft.script
      standupWrittenByModel = draft.writtenByModel
      pendingStandupDraft = draft
    } catch {
      showError(title: "Stand-up generation failed", message: error.localizedDescription)
    }
  }

  func updateStandupScript(spoken: String) {
    guard var script = standupScript else { return }
    script.spoken = spoken
    standupScript = script
  }

  @discardableResult
  func saveStandup(now: Date = Date()) async -> Bool {
    guard let board = standupBoard, let script = standupScript, let draft = pendingStandupDraft else {
      return false
    }

    let standup = StandupEntity(
      id: UUID().uuidString,
      generatedAt: now,
      windowStart: board.window.start,
      windowEnd: board.window.end,
      spoken: script.spoken,
      paste: script.paste,
      folded: script.folded,
      items: board.cards.map {
        StandupItem(
          id: $0.id,
          taskID: $0.taskID,
          column: $0.column,
          title: $0.title,
          fact: $0.fact,
          source: $0.source
        )
      },
      formatInstruction: aiSettings.resolvedStandupFormat,
      length: aiSettings.resolvedStandupLength,
      writtenByModel: draft.writtenByModel,
      provider: draft.provider,
      promptTokens: draft.promptTokens,
      completionTokens: draft.completionTokens,
      totalTokens: draft.totalTokens,
      createdAt: now,
      updatedAt: now
    )

    do {
      try await aiWorkflowService.saveStandup(standup)

      if standupSaveToJournal {
        await createJournalEntry(
          title: "Stand-up",
          content: script.paste,
          mood: nil,
          tags: ["standup"]
        )
      }

      triggerICloudSync()
      discardStandup()
      await refreshAIWorkflows()
      // Rebuild rather than leaving the board nil: the window now anchors to
      // the stand-up just saved, and the screen should say that plainly
      // instead of sitting on the "gathering" message forever.
      await buildStandupBoard(now: now)
      showToast(standupSaveToJournal ? "Stand-up saved to your journal" : "Stand-up saved")
      return true
    } catch {
      showError(title: "Failed to save the stand-up", message: error.localizedDescription)
      return false
    }
  }

  func deleteStandup(id: String) async {
    do {
      try await aiWorkflowService.deleteStandup(id: id)
      triggerICloudSync()
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to delete the stand-up", message: error.localizedDescription)
    }
  }

  func discardStandup() {
    standupBoard = nil
    standupBoardEdited = false
    standupScript = nil
    standupWrittenByModel = false
    pendingStandupDraft = nil
  }

  func generateAIRecap(type: AIRecapType) async {
    do {
      _ = try await aiWorkflowService.generateRecap(
        type: type,
        tasks: tasks,
        journalEntries: journalEntries,
        projects: projects
      )
      triggerICloudSync()
      showToast("\(type == .weekly ? "Weekly" : "Monthly") recap generated")
      await refreshAIWorkflows()
    } catch {
      aiStatusMessage = error.localizedDescription
      showError(title: "Recap generation failed", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  func markRecapViewed(id: String) async {
    do {
      try await aiWorkflowService.updateRecapInteraction(id: id, viewed: true, favorited: nil, exported: nil)
      triggerICloudSync()
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update recap", message: error.localizedDescription)
    }
  }

  func toggleRecapFavorite(id: String) async {
    guard let recap = aiRecaps.first(where: { $0.id == id }) else { return }

    do {
      try await aiWorkflowService.updateRecapInteraction(id: id, viewed: nil, favorited: !recap.favorited, exported: nil)
      triggerICloudSync()
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to update recap favorite", message: error.localizedDescription)
    }
  }

  func generateAISummary(type: SummaryType, startDate: Date? = nil, endDate: Date? = nil) async {
    let selectedTasks: [TaskEntity]
    let selectedJournalEntries: [JournalEntryEntity]
    if let startDate, let endDate {
      let calendar = Calendar.current
      let rangeStart = calendar.startOfDay(for: startDate)
      let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
      selectedTasks = tasks.filter { task in
        let taskDate = task.completedAt ?? task.dueDate ?? task.updatedAt
        return taskDate >= rangeStart && taskDate < rangeEnd
      }
      selectedJournalEntries = journalEntries.filter { entry in
        let entryDate = calendar.startOfDay(for: entry.date)
        return entryDate >= rangeStart && entryDate < rangeEnd
      }
    } else {
      selectedTasks = tasks
      selectedJournalEntries = journalEntries
    }

    do {
      _ = try await aiWorkflowService.generateSummary(
        type: type,
        tasks: selectedTasks,
        journalEntries: selectedJournalEntries,
        startDate: startDate,
        endDate: endDate
      )
      triggerICloudSync()
      showToast("\(type.rawValue.capitalized) summary generated")
      await refreshAIWorkflows()
    } catch {
      aiStatusMessage = error.localizedDescription
      showError(title: "Summary generation failed", message: error.localizedDescription)
      await refreshAIWorkflows()
    }
  }

  @discardableResult
  func submitAIQuickCapture(input: String, credentialID: String) async -> Bool {
    let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty else {
      showToast("Quick capture cannot be empty")
      return false
    }

    do {
      let classification = try await aiWorkflowService.classifyQuickCapture(
        input: trimmedInput,
        credentialID: credentialID,
        projects: quickCaptureProjectContext,
        availableTags: quickCaptureAvailableTags,
        now: Date()
      )

      if classification.confidence < Self.aiQuickCapturePreviewThreshold {
        pendingAIQuickCapturePreview = AIQuickCapturePreview(
          originalInput: trimmedInput,
          classification: classification
        )
        showToast("Review AI capture before saving")
        await refreshAIWorkflows()
        return false
      }

      let saved = try await saveAIQuickCaptureClassification(classification)
      await refreshAIWorkflows()
      return saved
    } catch {
      aiStatusMessage = error.localizedDescription
      showError(title: "AI quick capture failed", message: error.localizedDescription)
      await refreshAIWorkflows()
      return false
    }
  }

  @discardableResult
  func savePendingAIQuickCapturePreview() async -> Bool {
    guard let preview = pendingAIQuickCapturePreview else { return false }

    do {
      let saved = try await saveAIQuickCaptureClassification(preview.classification)
      if saved {
        pendingAIQuickCapturePreview = nil
      }
      await refreshAIWorkflows()
      return saved
    } catch {
      showError(title: "Failed to save AI capture", message: error.localizedDescription)
      await refreshAIWorkflows()
      return false
    }
  }

  func discardPendingAIQuickCapturePreview() {
    pendingAIQuickCapturePreview = nil
  }

  private func saveAIQuickCaptureClassification(_ classification: AIQuickCaptureClassification) async throws -> Bool {
    switch classification.kind {
    case .tasks:
      let validTasks = classification.tasks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      guard !validTasks.isEmpty else {
        showToast("AI capture did not include any tasks")
        return false
      }

      let projectLookup = try await ensureQuickCaptureProjects(for: classification.newProjects)

      for draft in validTasks {
        let now = Date()
        let trimmedDescription = draft.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = TaskEntity(
          id: UUID().uuidString,
          title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
          description: trimmedDescription?.isEmpty == true ? nil : trimmedDescription,
          completed: false,
          completedAt: nil,
          priority: draft.priority,
          dueDate: draft.dueDate,
          projectId: resolvedQuickCaptureProjectID(for: draft, projectLookup: projectLookup),
          tags: normalizedQuickCaptureValues(draft.tags),
          createdAt: now,
          updatedAt: now,
          subtasks: normalizedQuickCaptureValues(draft.subtasks).enumerated().map { offset, title in
            TaskSubtask(id: UUID().uuidString, title: title, completed: false, order: offset)
          },
          recurring: nil,
          userId: nil
        )
        try await createTask(task)
      }

      showToast("Created \(validTasks.count) task\(validTasks.count == 1 ? "" : "s")")
      await refreshCoreWorkflowData()
      return true

    case .journal:
      guard let draft = classification.journal else {
        showToast("AI capture did not include a journal entry")
        return false
      }

      let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else {
        showToast("AI capture did not include journal content")
        return false
      }

      let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let now = Date()
      let entry = JournalEntryEntity(
        id: UUID().uuidString,
        title: title?.isEmpty == true ? nil : title,
        content: content,
        date: now,
        tags: normalizedQuickCaptureValues(draft.tags),
        createdAt: now,
        updatedAt: now,
        pinned: false,
        mood: draft.mood,
        attachments: [],
        userId: nil
      )
      try await createJournalEntry(entry)
      showToast("Journal entry created")
      await refreshCoreWorkflowData()
      return true
    }
  }

  private var quickCaptureProjectContext: [AIQuickCaptureProjectContext] {
    projects.map { project in
      AIQuickCaptureProjectContext(
        id: project.id,
        name: project.name,
        description: project.description,
        archived: project.archived
      )
    }
  }

  private var quickCaptureAvailableTags: [String] {
    let allTags = tasks.flatMap(\.tags) + journalEntries.flatMap(\.tags)
    return normalizedQuickCaptureValues(allTags)
  }

  private func validQuickCaptureProjectID(_ projectID: String?) -> String? {
    guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty else {
      return nil
    }
    return projects.contains { $0.id == projectID && !$0.archived } ? projectID : nil
  }

  private func ensureQuickCaptureProjects(for drafts: [AIQuickCaptureProjectDraft]) async throws -> [String: String] {
    var lookup: [String: String] = [:]
    for project in projects where !project.archived {
      let key = normalizedQuickCaptureProjectName(project.name)
      guard !key.isEmpty, lookup[key] == nil else { continue }
      lookup[key] = project.id
    }

    for draft in drafts {
      let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizedQuickCaptureProjectName(name)
      guard !key.isEmpty, lookup[key] == nil else { continue }

      let now = Date()
      let description = draft.description?.trimmingCharacters(in: .whitespacesAndNewlines)
      let project = ProjectEntity(
        id: UUID().uuidString,
        name: name,
        description: description?.isEmpty == true ? nil : description,
        color: "#4A90E2",
        icon: nil,
        createdAt: now,
        updatedAt: now,
        archived: false,
        userId: nil
      )
      try await createProject(project)
      lookup[key] = project.id
    }

    return lookup
  }

  private func resolvedQuickCaptureProjectID(
    for draft: AIQuickCaptureTaskDraft,
    projectLookup: [String: String]
  ) -> String? {
    if let projectID = validQuickCaptureProjectID(draft.projectId) {
      return projectID
    }

    guard let projectName = draft.projectName else { return nil }
    return projectLookup[normalizedQuickCaptureProjectName(projectName)]
  }

  private func normalizedQuickCaptureProjectName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func normalizedQuickCaptureValues(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      normalized.append(trimmed)
    }
    return normalized
  }

  func deleteAISummary(id: String) async {
    do {
      try await aiWorkflowService.deleteSummary(id: id)
      triggerICloudSync()
      showToast("Summary deleted")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to delete summary", message: error.localizedDescription)
    }
  }

  func exportAISummary(id: String) async {
    do {
      lastSummaryExportPath = try await aiWorkflowService.exportSummary(id: id)
      showToast("Summary exported")
      await refreshAIWorkflows()
    } catch {
      showError(title: "Failed to export summary", message: error.localizedDescription)
    }
  }

  func refreshCoreWorkflowData() async {
    coreWorkflowState = .loading

    do {
      let loadedTasks = try await fetchTasks()
      let loadedProjects = try await fetchProjects()
      let loadedJournalEntries = try await fetchJournalEntries()
      let loadedGoals = try await fetchGoals()

      tasks = loadedTasks.sorted { $0.createdAt > $1.createdAt }
      projects = loadedProjects.sorted { lhs, rhs in
        if lhs.archived != rhs.archived {
          return lhs.archived == false
        }

        return lhs.updatedAt > rhs.updatedAt
      }
      journalEntries = loadedJournalEntries.sorted { $0.date > $1.date }
      goals = loadedGoals.sorted { $0.updatedAt > $1.updatedAt }

      selectedTaskIDs = selectedTaskIDs.filter { id in tasks.contains(where: { $0.id == id }) }
      rebuildGlobalSearchIndex()
      setGlobalSearchQuery(globalSearchQuery)
      syncTaskNotifications()

      coreWorkflowState = .ready
      await refreshDatabaseManagement()
      await refreshIntegrationDiagnostics()
    } catch {
      let message = error.localizedDescription
      coreWorkflowState = .failed(message: message)
      showError(title: "Data load failed", message: message)
    }
  }

  // MARK: Notifications

  /// Runs after every data refresh. Because the scheduler diffs desired against
  /// pending, completing, deleting or rescheduling a task cancels its reminder
  /// without any explicit call at those sites.
  func syncTaskNotifications() {
    // When reminders are off there is nothing to keep in sync; tearing down any
    // leftovers is handled once, in `setNotificationsEnabled`.
    guard notificationsEnabled else { return }

    let occurrences = TaskNotificationPlan.occurrences(
      for: tasks,
      leadMinutes: notificationLeadMinutes
    )
    Task { [notificationScheduler] in
      await notificationScheduler.reconcile(occurrences)
    }
  }

  func setNotificationsEnabled(_ enabled: Bool) async {
    guard enabled else {
      notificationsEnabled = false
      UserDefaults.standard.set(false, forKey: Self.notificationsEnabledDefaultsKey)
      // Turning reminders off has to clear what is already queued, which the
      // early-returning sync path deliberately will not do.
      await notificationScheduler.reconcile([])
      return
    }

    let granted = await SystemNotificationCenter().authorizationGranted()
    guard granted else {
      notificationsEnabled = false
      UserDefaults.standard.set(false, forKey: Self.notificationsEnabledDefaultsKey)
      showError(
        title: "Notifications not allowed",
        message: "Enable notifications for Serenity in System Settings › Notifications."
      )
      return
    }

    notificationsEnabled = true
    UserDefaults.standard.set(true, forKey: Self.notificationsEnabledDefaultsKey)
    syncTaskNotifications()
  }

  func setNotificationLeadMinutes(_ minutes: Int) {
    notificationLeadMinutes = minutes
    UserDefaults.standard.set(minutes, forKey: Self.notificationLeadMinutesDefaultsKey)
    syncTaskNotifications()
  }

  /// Takes you to the capture field rather than inventing a task. This used to
  /// save a placeholder titled "Quick task <date>", which was a stub, not a
  /// feature.
  func focusQuickCapture() {
    setSection(.home)
    shouldFocusQuickCapture = true
  }

  /// ⌘F narrows the list you are looking at; ⌘K searches everything.
  func focusSectionSearch() {
    setSection(.actionHub)
    shouldFocusSectionSearch = true
  }

  @discardableResult
  func createTask(
    title: String,
    priority: TaskPriority,
    dueDate: Date?,
    tags: [String],
    subtaskTitles: [String],
    description: String = "",
    projectID: String? = nil
  ) async -> Bool {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      showToast("Task title cannot be empty")
      return false
    }

    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedProjectID: String? = {
      guard let rawProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawProjectID.isEmpty else {
        return nil
      }
      return rawProjectID
    }()
    let now = Date()
    let task = TaskEntity(
      id: UUID().uuidString,
      title: trimmedTitle,
      description: trimmedDescription.isEmpty ? nil : trimmedDescription,
      completed: false,
      completedAt: nil,
      priority: priority,
      dueDate: dueDate,
      projectId: normalizedProjectID,
      tags: tags
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty },
      createdAt: now,
      updatedAt: now,
      subtasks: subtaskTitles.enumerated().map { offset, title in
        TaskSubtask(id: UUID().uuidString, title: title, completed: false, order: offset)
      },
      recurring: nil,
      userId: nil
    )

    do {
      try await createTask(task)
      showToast("Task created")
      await refreshCoreWorkflowData()
      return true
    } catch {
      showError(title: "Failed to create task", message: error.localizedDescription)
      return false
    }
  }

  @discardableResult
  func updateTask(
    id: String,
    title: String,
    description: String,
    priority: TaskPriority,
    dueDate: Date?,
    projectID: String?,
    tags: [String],
    subtasks: [TaskSubtask]? = nil,
    recurring: TaskRecurringPattern? = nil
  ) async -> Bool {
    guard let existing = tasks.first(where: { $0.id == id }) else { return false }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      showToast("Task title cannot be empty")
      return false
    }

    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedProjectID: String? = {
      guard let rawProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawProjectID.isEmpty else {
        return nil
      }
      return rawProjectID
    }()

    var updated = existing
    updated.title = trimmedTitle
    updated.description = trimmedDescription.isEmpty ? nil : trimmedDescription
    updated.priority = priority
    updated.dueDate = dueDate
    updated.projectId = normalizedProjectID
    updated.tags = tags
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    updated.recurring = recurring
    if let subtasks {
      updated.subtasks = subtasks
    }
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      showToast("Task updated")
      await refreshCoreWorkflowData()
      return true
    } catch {
      showError(title: "Failed to update task", message: error.localizedDescription)
      return false
    }
  }

  func toggleTaskCompletion(id: String) async {
    guard let task = tasks.first(where: { $0.id == id }) else { return }

    var updated = task
    updated.completed.toggle()
    updated.completedAt = updated.completed ? Date() : nil
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)

      // Completing a recurring task rolls the series forward. The completed
      // instance stays as history, which is what a streak will be computed from.
      if updated.completed, let successor = RecurrenceEngine.successor(for: updated) {
        try await saveTask(successor)
        showToast("Repeats \(SerenityDateText.due(successor.dueDate ?? Date()).lowercased())")
      }

      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update task", message: error.localizedDescription)
    }
  }

  func deleteTask(id: String) async {
    do {
      try await deleteTask(id: id, in: settings.backendProfile)
      selectedTaskIDs.remove(id)
      showToast("Task deleted")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete task", message: error.localizedDescription)
    }
  }

  func toggleTaskSelection(id: String) {
    if selectedTaskIDs.contains(id) {
      selectedTaskIDs.remove(id)
    } else {
      selectedTaskIDs.insert(id)
    }
  }

  func clearTaskSelection() {
    selectedTaskIDs.removeAll()
  }

  func markSelectedTasksCompleted() async {
    guard !selectedTaskIDs.isEmpty else { return }

    do {
      for id in selectedTaskIDs {
        guard let task = tasks.first(where: { $0.id == id }) else { continue }
        var updated = task
        updated.completed = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        try await saveTask(updated)
      }

      showToast("Updated \(selectedTaskIDs.count) tasks")
      selectedTaskIDs.removeAll()
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update tasks", message: error.localizedDescription)
    }
  }

  func deleteSelectedTasks() async {
    guard !selectedTaskIDs.isEmpty else { return }

    do {
      for id in selectedTaskIDs {
        try await deleteTask(id: id, in: settings.backendProfile)
      }

      showToast("Deleted \(selectedTaskIDs.count) tasks")
      selectedTaskIDs.removeAll()
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete tasks", message: error.localizedDescription)
    }
  }

  func addSubtask(taskID: String, title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let task = tasks.first(where: { $0.id == taskID }) else { return }

    var updated = task
    updated.subtasks.append(
      TaskSubtask(
        id: UUID().uuidString,
        title: trimmed,
        completed: false,
        order: updated.subtasks.count
      )
    )
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to add subtask", message: error.localizedDescription)
    }
  }

  func toggleSubtask(taskID: String, subtaskID: String) async {
    guard let task = tasks.first(where: { $0.id == taskID }) else { return }

    var updated = task
    guard let index = updated.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }

    updated.subtasks[index].completed.toggle()
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update subtask", message: error.localizedDescription)
    }
  }

  func addTaskComment(taskID: String, text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let task = tasks.first(where: { $0.id == taskID }) else { return }

    var updated = task
    updated.activity.append(
      TaskActivityEntry(
        id: UUID().uuidString,
        kind: .comment,
        text: trimmed,
        createdAt: Date()
      )
    )
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to add comment", message: error.localizedDescription)
    }
  }

  func updateTaskComment(taskID: String, commentID: String, text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let task = tasks.first(where: { $0.id == taskID }) else { return }

    var updated = task
    guard let index = updated.activity.firstIndex(where: { $0.id == commentID }) else { return }
    guard updated.activity[index].kind == .comment else { return }
    guard updated.activity[index].text != trimmed else { return }

    updated.activity[index].text = trimmed
    updated.activity[index].editedAt = Date()
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update comment", message: error.localizedDescription)
    }
  }

  func deleteTaskComment(taskID: String, commentID: String) async {
    guard let task = tasks.first(where: { $0.id == taskID }) else { return }

    var updated = task
    guard let index = updated.activity.firstIndex(where: { $0.id == commentID }) else { return }
    guard updated.activity[index].kind == .comment else { return }

    updated.activity.remove(at: index)
    updated.updatedAt = Date()

    do {
      try await saveTask(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete comment", message: error.localizedDescription)
    }
  }

  @discardableResult
  func createProject(name: String, description: String, color: String) async -> ProjectEntity? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      showToast("Project name cannot be empty")
      return nil
    }

    let now = Date()
    let project = ProjectEntity(
      id: UUID().uuidString,
      name: trimmedName,
      description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
      color: color,
      icon: nil,
      createdAt: now,
      updatedAt: now,
      archived: false,
      userId: nil
    )

    do {
      try await createProject(project)
      showToast("Project created")
      await refreshCoreWorkflowData()
      return project
    } catch {
      showError(title: "Failed to create project", message: error.localizedDescription)
      return nil
    }
  }

  func toggleProjectArchive(id: String) async {
    guard let project = projects.first(where: { $0.id == id }) else { return }

    var updated = project
    updated.archived.toggle()
    updated.updatedAt = Date()

    do {
      try await saveProject(updated)
      showToast(updated.archived ? "Project archived" : "Project unarchived")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update project", message: error.localizedDescription)
    }
  }

  func updateProject(
    id: String,
    name: String,
    description: String,
    color: String
  ) async {
    guard let existing = projects.first(where: { $0.id == id }) else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      showToast("Project name cannot be empty")
      return
    }

    var updated = existing
    updated.name = trimmedName
    updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
    updated.color = color
    updated.updatedAt = Date()

    do {
      try await saveProject(updated)
      showToast("Project updated")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update project", message: error.localizedDescription)
    }
  }

  func deleteProject(id: String) async {
    do {
      try await deleteProject(id: id, in: settings.backendProfile)
      showToast("Project deleted")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete project", message: error.localizedDescription)
    }
  }

  func createJournalEntry(
    title: String,
    content: String,
    mood: JournalMood?,
    tags: [String]
  ) async {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      showToast("Journal content cannot be empty")
      return
    }

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let now = Date()
    let entry = JournalEntryEntity(
      id: UUID().uuidString,
      title: trimmedTitle.isEmpty ? nil : trimmedTitle,
      content: trimmedContent,
      date: now,
      tags: tags.filter { !$0.isEmpty },
      createdAt: now,
      updatedAt: now,
      pinned: false,
      mood: mood,
      attachments: [],
      userId: nil
    )

    do {
      try await createJournalEntry(entry)
      showToast("Journal entry created")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to create journal entry", message: error.localizedDescription)
    }
  }

  func toggleJournalPin(id: String) async {
    guard let entry = journalEntries.first(where: { $0.id == id }) else { return }

    var updated = entry
    updated.pinned.toggle()
    updated.updatedAt = Date()

    do {
      try await saveJournalEntry(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update journal entry", message: error.localizedDescription)
    }
  }

  func updateJournalEntry(
    id: String,
    title: String,
    content: String,
    mood: JournalMood?,
    tags: [String]
  ) async {
    guard let existing = journalEntries.first(where: { $0.id == id }) else { return }
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      showToast("Journal content cannot be empty")
      return
    }

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    var updated = existing
    updated.title = trimmedTitle.isEmpty ? nil : trimmedTitle
    updated.content = trimmedContent
    updated.mood = mood
    updated.tags = tags.filter { !$0.isEmpty }
    updated.updatedAt = Date()

    do {
      try await saveJournalEntry(updated)
      showToast("Journal entry updated")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update journal entry", message: error.localizedDescription)
    }
  }

  func deleteJournalEntry(id: String) async {
    do {
      try await deleteJournalEntry(id: id, in: settings.backendProfile)
      showToast("Journal entry deleted")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete journal entry", message: error.localizedDescription)
    }
  }

  func createGoal(title: String, target: Double, type: GoalType, priority: GoalPriority) async {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      showToast("Goal title cannot be empty")
      return
    }

    let normalizedTarget = max(1, target)
    let now = Date()
    let periodStart = Calendar.current.startOfDay(for: now)
    let periodEnd = Calendar.current.date(byAdding: .day, value: 7, to: periodStart) ?? now

    let goal = GoalEntity(
      id: UUID().uuidString,
      title: trimmedTitle,
      description: nil,
      type: type,
      config: GoalConfig(
        targetCount: normalizedTarget,
        projectId: nil,
        priority: nil,
        streakDays: nil,
        targetRate: nil,
        timeframe: .weekly
      ),
      progress: GoalProgress(
        current: 0,
        target: normalizedTarget,
        percentage: 0,
        isCompleted: false,
        periodStart: periodStart,
        periodEnd: periodEnd
      ),
      status: .active,
      priority: priority,
      reminders: [],
      createdAt: now,
      updatedAt: now,
      userId: nil
    )

    do {
      try await createGoal(goal)
      showToast("Goal created")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to create goal", message: error.localizedDescription)
    }
  }

  func incrementGoalProgress(id: String) async {
    guard let goal = goals.first(where: { $0.id == id }) else { return }

    var updated = goal
    let target = max(1, updated.progress.target)
    let current = min(target, updated.progress.current + 1)
    let percentage = min(100, (current / target) * 100)

    updated.progress.current = current
    updated.progress.percentage = percentage
    updated.progress.isCompleted = current >= target
    updated.status = updated.progress.isCompleted ? .completed : .active
    updated.updatedAt = Date()

    do {
      try await saveGoal(updated)
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to update goal", message: error.localizedDescription)
    }
  }

  func deleteGoal(id: String) async {
    do {
      try await deleteGoal(id: id, in: settings.backendProfile)
      showToast("Goal deleted")
      await refreshCoreWorkflowData()
    } catch {
      showError(title: "Failed to delete goal", message: error.localizedDescription)
    }
  }

  func setGlobalSearchQuery(_ query: String) {
    globalSearchQuery = query

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      globalSearchResults = []
      return
    }

    let lowercasedTerms = trimmed.lowercased().split(separator: " ").map(String.init)

    let scored = globalSearchDocuments.compactMap { document -> (GlobalSearchResult, Int)? in
      let combined = "\(document.title) \(document.body)".lowercased()
      let matchCount = lowercasedTerms.reduce(into: 0) { count, term in
        if combined.contains(term) {
          count += 1
        }
      }

      guard matchCount == lowercasedTerms.count else {
        return nil
      }

      let score = (document.title.lowercased().contains(trimmed.lowercased()) ? 10 : 0) + matchCount
      let result = GlobalSearchResult(
        type: document.type,
        entityID: document.entityID,
        title: document.title,
        subtitle: document.body,
        updatedAt: document.updatedAt
      )

      return (result, score)
    }

    globalSearchResults = scored
      .sorted { lhs, rhs in
        if lhs.1 == rhs.1 {
          return lhs.0.updatedAt > rhs.0.updatedAt
        }

        return lhs.1 > rhs.1
      }
      .map(\.0)
  }

  func refreshDatabaseManagement() async {
    var lines: [String] = []
    lines.append("Active backend: \(backendSelectionState.activeProfile.title)")
    lines.append("Tasks: \(tasks.count)")
    lines.append("Projects: \(projects.count)")
    lines.append("Journal entries: \(journalEntries.count)")
    lines.append("Goals: \(goals.count)")

    if let backup = lastDatabaseBackupPath {
      lines.append("Last backup: \(backup)")
    }

    if let export = lastDatabaseExportPath {
      lines.append("Last export: \(export)")
    }

    do {
      lines.append("SQLite path: \(try sqliteBackendAdapter.currentDatabasePath())")
      lines.append("Integrity check: \(databaseIntegrityCheckResult)")
    } catch {
      lines.append("SQLite diagnostics unavailable: \(error.localizedDescription)")
    }

    databaseManagementLines = lines
  }

  func runDatabaseIntegrityCheck() async {
    do {
      databaseIntegrityCheckResult = try sqliteBackendAdapter.runQuickIntegrityCheck()
      showToast("Integrity check: \(databaseIntegrityCheckResult)")
    } catch {
      databaseIntegrityCheckResult = "failed"
      showError(title: "Integrity check failed", message: error.localizedDescription)
    }

    await refreshDatabaseManagement()
  }

  func createDatabaseBackup() async {
    do {
      _ = try await requireSQLiteCoreRepositories()
      let summary = try sqliteBackendAdapter.createBackup()
      lastDatabaseBackupPath = summary.backupPath
      showToast("Backup created")
    } catch {
      showError(title: "Backup failed", message: error.localizedDescription)
    }

    await refreshDatabaseManagement()
  }

  func exportCoreDataSnapshot() async {
    let snapshot = CoreDataExportSnapshot(
      exportedAt: Date(),
      backend: settings.backendProfile.rawValue,
      tasks: tasks.map { task in
        TaskExportItem(
          id: task.id,
          title: task.title,
          description: task.description,
          completed: task.completed,
          completedAt: task.completedAt,
          priority: task.priority.rawValue,
          dueDate: task.dueDate,
          projectId: task.projectId,
          tags: task.tags,
          subtasks: task.subtasks.map { subtask in
            TaskExportSubtask(
              id: subtask.id,
              title: subtask.title,
              completed: subtask.completed,
              order: subtask.order
            )
          },
          createdAt: task.createdAt,
          updatedAt: task.updatedAt
        )
      },
      projects: projects.map { project in
        ProjectExportItem(
          id: project.id,
          name: project.name,
          description: project.description,
          color: project.color,
          icon: project.icon,
          archived: project.archived,
          createdAt: project.createdAt,
          updatedAt: project.updatedAt
        )
      },
      journalEntries: journalEntries.map { entry in
        JournalExportItem(
          id: entry.id,
          title: entry.title,
          content: entry.content,
          date: entry.date,
          tags: entry.tags,
          pinned: entry.pinned,
          mood: entry.mood?.rawValue,
          createdAt: entry.createdAt,
          updatedAt: entry.updatedAt
        )
      },
      goals: goals.map { goal in
        GoalExportItem(
          id: goal.id,
          title: goal.title,
          description: goal.description,
          type: goal.type.rawValue,
          status: goal.status.rawValue,
          priority: goal.priority.rawValue,
          progressCurrent: goal.progress.current,
          progressTarget: goal.progress.target,
          progressPercentage: goal.progress.percentage,
          progressCompleted: goal.progress.isCompleted,
          createdAt: goal.createdAt,
          updatedAt: goal.updatedAt
        )
      }
    )

    do {
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

      let filename = "serenity-export-\(formatter.string(from: Date())).json"
      let destination = exportsDirectory.appendingPathComponent(filename)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601

      let data = try encoder.encode(snapshot)
      try data.write(to: destination, options: .atomic)
      lastDatabaseExportPath = destination.path
      showToast("Data export complete")
    } catch {
      showError(title: "Export failed", message: error.localizedDescription)
    }

    await refreshDatabaseManagement()
  }

  func refreshBackendDiagnostics() async {
    var lines: [String] = []
    let active = backendSelectionState.activeProfile

    lines.append("Active profile: \(active.title)")
    lines.append("Validation: \(validationState(for: active).message)")

    if let lastValidated = backendSelectionState.lastValidatedAt[active] {
      lines.append("Last validation: \(Self.backendDiagnosticsDateFormatter.string(from: lastValidated))")
    } else {
      lines.append("Last validation: never")
    }

    do {
      let sqlite = try sqliteBackendAdapter.diagnostics()
      lines.append("SQLite path: \(sqlite.databasePath)")
      lines.append("SQLite bootstrapped: \(sqlite.isBootstrapped ? "yes" : "no")")
    } catch {
      lines.append("SQLite diagnostics error: \(error.localizedDescription)")
    }

    if let serenityCloudAdapter {
      let cloud = serenityCloudAdapter.diagnostics()
      lines.append("Cloud base URL: \(cloud.baseURL)")
      lines.append("Cloud access token configured: \(cloud.hasAccessToken ? "yes" : "no")")
      if let lastHealthyAt = cloud.lastHealthyAt {
        lines.append("Cloud last healthy: \(Self.backendDiagnosticsDateFormatter.string(from: lastHealthyAt))")
      }
    } else {
      lines.append("Cloud adapter: not configured")
    }

    if let externalPostgresAdapter {
      let postgres = externalPostgresAdapter.diagnostics()
      lines.append("PostgreSQL endpoint: \(postgres.host):\(postgres.port) / \(postgres.database)")
      lines.append("PostgreSQL user: \(postgres.username)")
      lines.append("PostgreSQL SSL mode: \(postgres.sslMode)")
      if let lastHealthyAt = postgres.lastHealthyAt {
        lines.append("PostgreSQL last healthy: \(Self.backendDiagnosticsDateFormatter.string(from: lastHealthyAt))")
      }
    } else {
      lines.append("PostgreSQL adapter: not configured")
    }

    backendDiagnosticsLines = lines
  }

  private func rebuildGlobalSearchIndex() {
    var documents: [GlobalSearchDocument] = []

    documents += tasks.map { task in
      GlobalSearchDocument(
        type: .task,
        entityID: task.id,
        title: task.title,
        body: [task.description ?? "", task.tags.joined(separator: " "), task.subtasks.map(\.title).joined(separator: " ")]
          .joined(separator: " "),
        updatedAt: task.updatedAt
      )
    }

    documents += projects.map { project in
      GlobalSearchDocument(
        type: .project,
        entityID: project.id,
        title: project.name,
        body: [project.description ?? "", project.color].joined(separator: " "),
        updatedAt: project.updatedAt
      )
    }

    documents += journalEntries.map { entry in
      GlobalSearchDocument(
        type: .journal,
        entityID: entry.id,
        title: entry.title ?? "Journal Entry",
        body: [entry.content, entry.tags.joined(separator: " ")].joined(separator: " "),
        updatedAt: entry.updatedAt
      )
    }

    documents += goals.map { goal in
      GlobalSearchDocument(
        type: .goal,
        entityID: goal.id,
        title: goal.title,
        body: [goal.description ?? "", goal.type.rawValue, goal.status.rawValue].joined(separator: " "),
        updatedAt: goal.updatedAt
      )
    }

    globalSearchDocuments = documents
  }

  private func requireSQLiteCoreRepositories() async throws -> GRDBCoreRepositorySet {
    if let sqliteCoreRepositories {
      return sqliteCoreRepositories
    }

    let summary = try await sqliteBackendAdapter.bootstrap()
    let repositories = try sqliteBackendAdapter.makeCoreRepositories()
    sqliteCoreRepositories = repositories
    await installICloudSyncEngine(using: repositories)

    if case .ready = databaseBootstrapState {
      // Already reflected by an explicit bootstrap call.
    } else {
      databaseBootstrapState = .ready(path: summary.databasePath, appliedCount: summary.appliedMigrations.count)
    }

    guard let sqliteCoreRepositories else {
      throw CoreWorkflowError.unavailableBackend("Could not initialize SQLite repositories")
    }

    return sqliteCoreRepositories
  }

  // MARK: - iCloud sync

  /// Builds the iCloud sync engine on first access to a repository set and
  /// kicks off an initial round-trip in the background. Idempotent — calling
  /// it twice with the same set is a no-op.
  ///
  /// Skipped under XCTest because the test binary is unsigned and lacks the
  /// CloudKit entitlement; talking to the CloudKit XPC service from a detached
  /// task would crash the test process at teardown.
  private func installICloudSyncEngine(using repositories: GRDBCoreRepositorySet) async {
    guard iCloudSyncEngine == nil else { return }
    guard !Self.isRunningUnderXCTest else { return }

    await aiWorkflowService.configureCloudSync(pendingStore: repositories.pendingSyncChanges)

    let aiRepositories: GRDBAIRepositorySet
    do {
      aiRepositories = try sqliteBackendAdapter.makeAIRepositories(pendingStore: repositories.pendingSyncChanges)
      try CloudSyncInitialExporter(
        coreRepositories: repositories,
        aiRepositories: aiRepositories
      ).enqueueIfNeeded()
    } catch {
      AppLogger.error("iCloudSync: failed to prepare sync repositories: \(error.localizedDescription)")
      return
    }

    guard
      let insightRepository = aiRepositories.insights as? SyncAwareAIInsightRepository,
      let recapRepository = aiRepositories.recaps as? SyncAwareAIRecapRepository,
      let summaryRepository = aiRepositories.summaries as? SyncAwareSummaryRepository,
      let standupRepository = aiRepositories.standups as? SyncAwareStandupRepository
    else {
      AppLogger.error("iCloudSync: AI repositories were not sync-aware.")
      return
    }

    let engine = ICloudSyncEngine(
      pendingStore: repositories.pendingSyncChanges,
      stateStore: repositories.cloudSyncState,
      recordKinds: [
        TaskSyncRecordKind(repository: repositories.tasks),
        ProjectSyncRecordKind(repository: repositories.projects),
        JournalEntrySyncRecordKind(repository: repositories.journal),
        GoalSyncRecordKind(repository: repositories.goals),
        AIInsightSyncRecordKind(repository: insightRepository),
        AIRecapSyncRecordKind(repository: recapRepository),
        SummarySyncRecordKind(repository: summaryRepository),
        StandupSyncRecordKind(repository: standupRepository),
      ],
      stateUpdate: { [weak self] state in
        Task { @MainActor [weak self] in
          self?.iCloudSyncState = state
        }
      },
      logger: { message in
        AppLogger.info("iCloudSync: \(message)")
      }
    )
    iCloudSyncEngine = engine

    // Initial pass picks up anything queued before the engine existed plus
    // any remote changes that landed while we were offline.
    triggerICloudSync()
  }

  /// Fire-and-forget kick to the engine. Coalesces internally — calling this
  /// from many save/delete sites is fine.
  func triggerICloudSync() {
    guard let engine = iCloudSyncEngine else { return }
    Task.detached(priority: .utility) {
      await engine.sync()
    }
  }

  /// True when the host process has loaded XCTest (SPM `xctest` runner or
  /// Xcode test bundle). Used to gate features that talk to system XPC
  /// services we can't reach from an unsigned test binary.
  private static let isRunningUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

  /// Called from the app delegate when CloudKit delivers a silent push for
  /// the SerenityZone subscription.
  func handleICloudRemoteNotification() {
    triggerICloudSync()
  }

  private func fetchTasks() async throws -> [TaskEntity] {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      return try repositories.tasks.fetchAll()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      return try await serenityCloudAdapter.listTasks()
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      return try await externalPostgresAdapter.listTasks()
    }
  }

  private func createTask(_ task: TaskEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.tasks.save(task)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.createTask(task)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.createTask(task)
    }
  }

  private func saveTask(_ task: TaskEntity) async throws {
    let task = recordingActivity(for: task)

    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.tasks.save(task)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.updateTask(task)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.updateTask(task)
    }
  }

  /// Every task write funnels through `saveTask`, so this is the one place that
  /// has both the old and the new task — and the only place events get logged.
  private func recordingActivity(for task: TaskEntity) -> TaskEntity {
    guard let previous = tasks.first(where: { $0.id == task.id }) else { return task }

    let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let events = TaskActivityRecorder.events(from: previous, to: task, projectNames: names)
    guard !events.isEmpty else { return task }

    var recorded = task
    recorded.activity.append(contentsOf: events)
    return recorded
  }

  private func deleteTask(id: String, in profile: BackendProfile) async throws {
    switch profile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.tasks.delete(id: id)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      try await serenityCloudAdapter.deleteTask(id: id)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      try await externalPostgresAdapter.deleteTask(id: id)
    }
  }

  private func fetchProjects() async throws -> [ProjectEntity] {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      return try repositories.projects.fetchAll(includeArchived: includeArchivedProjects)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      return try await serenityCloudAdapter.listProjects()
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      let projects = try await externalPostgresAdapter.listProjects()
      if includeArchivedProjects {
        return projects
      }
      return projects.filter { !$0.archived }
    }
  }

  private func createProject(_ project: ProjectEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.projects.save(project)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.createProject(project)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.createProject(project)
    }
  }

  private func saveProject(_ project: ProjectEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.projects.save(project)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.updateProject(project)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.updateProject(project)
    }
  }

  private func deleteProject(id: String, in profile: BackendProfile) async throws {
    switch profile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.projects.delete(id: id)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      try await serenityCloudAdapter.deleteProject(id: id)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      try await externalPostgresAdapter.deleteProject(id: id)
    }
  }

  private func fetchJournalEntries() async throws -> [JournalEntryEntity] {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      if journalDateRangeEnabled {
        let range = DateInterval(start: min(journalRangeStartDate, journalRangeEndDate), end: max(journalRangeStartDate, journalRangeEndDate))
        return try repositories.journal.fetch(in: range)
      }

      return try repositories.journal.fetchAll()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      return try await serenityCloudAdapter.listJournalEntries()
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      let entries = try await externalPostgresAdapter.listJournalEntries()
      if journalDateRangeEnabled {
        let start = min(journalRangeStartDate, journalRangeEndDate)
        let end = max(journalRangeStartDate, journalRangeEndDate)
        return entries.filter { $0.date >= start && $0.date <= end }
      }
      return entries
    }
  }

  private func createJournalEntry(_ entry: JournalEntryEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.journal.save(entry)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.createJournalEntry(entry)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.createJournalEntry(entry)
    }
  }

  private func saveJournalEntry(_ entry: JournalEntryEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.journal.save(entry)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.updateJournalEntry(entry)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.updateJournalEntry(entry)
    }
  }

  private func deleteJournalEntry(id: String, in profile: BackendProfile) async throws {
    switch profile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.journal.delete(id: id)
      triggerICloudSync()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      try await serenityCloudAdapter.deleteJournalEntry(id: id)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      try await externalPostgresAdapter.deleteJournalEntry(id: id)
    }
  }

  private func fetchGoals() async throws -> [GoalEntity] {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      return try repositories.goals.fetchAll()
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      return try await serenityCloudAdapter.listGoals()
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      return try await externalPostgresAdapter.listGoals()
    }
  }

  private func createGoal(_ goal: GoalEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.goals.save(goal)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.createGoal(goal)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.createGoal(goal)
    }
  }

  private func saveGoal(_ goal: GoalEntity) async throws {
    switch settings.backendProfile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.goals.save(goal)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      _ = try await serenityCloudAdapter.updateGoal(goal)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      _ = try await externalPostgresAdapter.updateGoal(goal)
    }
  }

  private func deleteGoal(id: String, in profile: BackendProfile) async throws {
    switch profile {
    case .sqliteLocal:
      let repositories = try await requireSQLiteCoreRepositories()
      try repositories.goals.delete(id: id)
    case .serenityCloud:
      guard let serenityCloudAdapter else {
        throw CoreWorkflowError.unavailableBackend("Serenity Cloud adapter is not configured")
      }
      try await serenityCloudAdapter.deleteGoal(id: id)
    case .externalPostgres:
      guard let externalPostgresAdapter else {
        throw CoreWorkflowError.unavailableBackend("External PostgreSQL adapter is not configured")
      }
      try await externalPostgresAdapter.deleteGoal(id: id)
    }
  }

  private static let backendDiagnosticsDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
  }()

  private func assertRateLimit(for operation: SensitiveOperation, operationName: String) async -> Bool {
    let decision = await sensitiveOperationRateGuard.evaluate(operation)
    guard decision.allowed else {
      let retrySeconds = Int(decision.retryAfter.rounded(.up))
      let message = "\(operationName) is temporarily rate-limited. Try again in \(retrySeconds)s."
      showToast(message)
      await securityAuditService.record(
        eventType: .securityPolicy,
        severity: .warning,
        message: "Rate guard blocked operation",
        metadata: [
          "operation": operation.rawValue,
          "retryAfterSeconds": "\(retrySeconds)",
        ]
      )
      return false
    }

    return true
  }
}
