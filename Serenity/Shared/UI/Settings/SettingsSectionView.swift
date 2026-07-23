import SwiftUI

// MARK: - Shared settings helpers

/// Settings panel: section header (icon as a quiet accessory) above a flat card.
/// Signature kept from the legacy tinted-icon panel so panel bodies stay unchanged.
func settingsPanel<Content: View>(
  title: String,
  subtitle: String,
  systemImage: String,
  tint: Color,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
    SerenitySectionHeader(title, subtitle: subtitle) {
      Image(systemName: systemImage)
        .font(.subheadline)
        .foregroundStyle(SerenityPalette.textSecondary)
    }

    SerenityCard {
      content()
    }
  }
}

/// Caption label above a control, with optional help text below.
func settingsField<Content: View>(
  _ label: String,
  help: String? = nil,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
    Text(label)
      .font(SerenityType.caption)
      .foregroundStyle(SerenityPalette.textSecondary)

    content()

    if let help {
      Text(help)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Quiet inline status line: tinted icon plus secondary text, no tinted block.
func statusBanner(_ message: String, systemImage: String, tint: Color) -> some View {
  HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
    Image(systemName: systemImage)
      .font(.footnote)
      .foregroundStyle(tint)

    Text(message)
      .font(.footnote)
      .foregroundStyle(SerenityPalette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

    Spacer(minLength: 0)
  }
}

// MARK: - Settings section

/// Settings window content: native TabView with General/AI/Sync & Backend/Advanced.
struct SettingsSectionView: View {
  @EnvironmentObject private var appState: AppState
  @State private var authorizationCode = ""
  @State private var oauthBaseURL = ""
  @State private var oauthClientID = ""
  @State private var oauthRedirectURI = ""
  @State private var cloudBaseURL = ""
  @State private var cloudAccessToken = ""
  @State private var postgresHost = ""
  @State private var postgresPort = "5432"
  @State private var postgresDatabase = ""
  @State private var postgresUsername = ""
  @State private var postgresPassword = ""
  @State private var postgresSSLMode = "require"
  @State private var localLockPassword = ""
  @State private var localLockConfirmPassword = ""
  @State private var unlockPassword = ""
  @State private var backendConfigProfile: BackendProfile = .serenityCloud
  @State private var localLockFormError: String?
  @State private var oauthConfigurationError: String?
  @State private var loadedStoredSettingsValues = false
  @State private var newCredentialProvider: AICredentialProvider = .openai
  @State private var newCredentialName = ""
  @State private var newCredentialAPIKey = ""
  @State private var newCredentialModel = ""
  @State private var keyVerification: KeyVerificationState = .idle
  @State private var selectedTab: SettingsTab = .general

  private enum KeyVerificationState: Equatable {
    case idle
    case validating
    case valid(models: [String])
    case invalid(message: String)
  }

  private let postgresSSLModes = ["disable", "prefer", "require", "verify-ca", "verify-full"]

  var body: some View {
#if os(macOS)
    TabView(selection: $selectedTab) {
      settingsTabContent { generalPane }
        .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
        .tag(SettingsTab.general)

      settingsTabContent { aiPane }
        .tabItem { Label(SettingsTab.ai.title, systemImage: SettingsTab.ai.systemImage) }
        .tag(SettingsTab.ai)

      settingsTabContent { syncBackendPane }
        .tabItem { Label(SettingsTab.syncBackend.title, systemImage: SettingsTab.syncBackend.systemImage) }
        .tag(SettingsTab.syncBackend)

      settingsTabContent { advancedPane }
        .tabItem { Label(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.systemImage) }
        .tag(SettingsTab.advanced)
    }
    .onAppear {
      loadStoredSettingsValuesIfNeeded()
      consumePendingSettingsTab()
    }
    .onChange(of: appState.pendingSettingsTab) { _, _ in
      consumePendingSettingsTab()
    }
#else
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      generalPane
      aiPane
      syncBackendPane
      advancedPane
    }
    .onAppear {
      loadStoredSettingsValuesIfNeeded()
    }
#endif
  }

  private func settingsTabContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      content()
        .padding(SerenityUI.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private func consumePendingSettingsTab() {
    if let tab = appState.pendingSettingsTab {
      selectedTab = tab
      appState.pendingSettingsTab = nil
    }
  }

  private var generalPane: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      appearancePanel
      appLockPanel
    }
  }

  private var aiPane: some View {
    aiProviderPanel
  }

  private var syncBackendPane: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      IntegrationsSettingsPane()
      DatabaseBackendConfigurationPanel()
      authPanel
    }
  }

  private var advancedPane: some View {
    DatabaseToolsPane()
  }

  private var backendProfileDropdownOptions: [SerenityDropdownOption<BackendProfile>] {
    BackendProfile.allCases.map { profile in
      SerenityDropdownOption(
        value: profile,
        title: profile.title,
        subtitle: backendProfileSubtitle(profile),
        systemImage: backendProfileIcon(profile),
        tint: backendProfileTint(profile)
      )
    }
  }

  private var postgresSSLModeDropdownOptions: [SerenityDropdownOption<String>] {
    postgresSSLModes.map { mode in
      SerenityDropdownOption(
        value: mode,
        title: mode,
        subtitle: sslModeSubtitle(mode),
        systemImage: mode == "disable" ? "lock.open" : "lock.fill",
        tint: mode == "disable" ? .orange : .green
      )
    }
  }

  private var appearancePanel: some View {
    settingsPanel(
      title: "Appearance",
      subtitle: "Workspace presentation",
      systemImage: "paintpalette",
      tint: SerenityPalette.accent
    ) {
      settingsField("Theme", help: "Choose whether Serenity follows the system appearance or forces light/dark mode.") {
        Picker(
          "Theme",
          selection: Binding(
            get: { appState.themePreference },
            set: { appState.setThemePreference($0) }
          )
        ) {
          ForEach(AppThemePreference.allCases) { preference in
            Text(preference.title).tag(preference)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
      }
    }
  }

  private var aiProviderPanel: some View {
    settingsPanel(
      title: "AI Provider",
      subtitle: credentialStatusText,
      systemImage: "key.horizontal.fill",
      tint: hasEnabledCredential ? .green : .orange
    ) {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
        statusBanner(
          hasEnabledCredential
            ? "An enabled provider key is configured."
            : "Add and enable a provider key to use AI features.",
          systemImage: hasEnabledCredential ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tint: hasEnabledCredential ? .green : .orange
        )

        if !appState.aiCredentials.isEmpty {
          configuredKeysSection
        }

        addCredentialSection
      }
    }
  }

  private var configuredKeysSection: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text("Configured keys")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)
        Spacer()
        Text("\(appState.aiCredentials.count) total")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        ForEach(appState.aiCredentials) { credential in
          credentialRow(credential)
        }
      }
    }
  }

  private var addCredentialSection: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      Text(appState.aiCredentials.isEmpty ? "Add a provider key" : "Add another key")
        .font(SerenityType.bodyMedium)
        .foregroundStyle(SerenityPalette.textPrimary)

      settingsField("Provider") {
        providerPickerRow
      }

      settingsField("API key", help: "Stored securely in the system Keychain.") {
        HStack(spacing: SerenityUI.Spacing.xs) {
          SecureField("sk-…", text: $newCredentialAPIKey)
            .textFieldStyle(.plain)
            .serenityInputField()
            .frame(maxWidth: 520)

          Button {
            Task { await runKeyVerification() }
          } label: {
            switch keyVerification {
            case .validating:
              HStack(spacing: SerenityUI.Spacing.xxs) {
                ProgressView().controlSize(.small)
                Text("Verifying…")
              }
            default:
              Label("Verify", systemImage: "checkmark.shield")
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .disabled(
            newCredentialAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || keyVerification == .validating
          )
        }

        keyVerificationStatusView
      }

      HStack(alignment: .top, spacing: SerenityUI.Spacing.md) {
        settingsField("Model (optional)") {
          SerenityDropdownField(
            placeholder: "Default",
            selection: $newCredentialModel,
            options: addFormModelOptions
          )
          .frame(maxWidth: 280, alignment: .leading)
        }

        settingsField("Label (optional)") {
          TextField(providerTitle(newCredentialProvider), text: $newCredentialName)
            .textFieldStyle(.plain)
            .serenityInputField()
            .frame(maxWidth: 260)
        }

        Spacer(minLength: 0)
      }

      HStack {
        Spacer()
        Button {
          Task {
            let trimmed = newCredentialName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmed.isEmpty ? providerTitle(newCredentialProvider) : trimmed
            let verifiedModels: [String]? = {
              if case .valid(let models) = keyVerification, !models.isEmpty {
                return models
              }
              return nil
            }()
            await appState.addAICredential(
              provider: newCredentialProvider,
              name: finalName,
              apiKey: newCredentialAPIKey,
              modelPreference: newCredentialModel.isEmpty ? nil : newCredentialModel,
              availableModels: verifiedModels
            )
            newCredentialName = ""
            newCredentialAPIKey = ""
            newCredentialModel = ""
            keyVerification = .idle
          }
        } label: {
          Label("Save provider key", systemImage: "plus")
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(
          newCredentialAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || keyVerification == .validating
        )
      }
    }
    .padding(SerenityUI.Spacing.md)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
    .onChange(of: newCredentialProvider) { _, _ in keyVerification = .idle }
    .onChange(of: newCredentialAPIKey) { _, _ in
      if keyVerification != .validating { keyVerification = .idle }
    }
  }

  @ViewBuilder
  private var keyVerificationStatusView: some View {
    switch keyVerification {
    case .idle:
      EmptyView()
    case .validating:
      HStack(spacing: SerenityUI.Spacing.xxs) {
        ProgressView().controlSize(.small)
        Text("Validating key…")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    case .valid(let models):
      HStack(spacing: SerenityUI.Spacing.xxs) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Key valid · \(models.count) model\(models.count == 1 ? "" : "s") available")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    case .invalid(let message):
      HStack(spacing: SerenityUI.Spacing.xxs) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
        Text(message)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var addFormModelOptions: [SerenityDropdownOption<String>] {
    if case .valid(let models) = keyVerification, !models.isEmpty {
      return [
        SerenityDropdownOption(
          value: "",
          title: "Default",
          subtitle: "Use Serenity's recommended model",
          systemImage: "sparkles",
          tint: SerenityPalette.accent
        )
      ] + models.map { model in
        SerenityDropdownOption(
          value: model,
          title: model,
          systemImage: "cpu",
          tint: providerTint(newCredentialProvider)
        )
      }
    }
    return modelDropdownOptions(for: newCredentialProvider)
  }

  private func runKeyVerification() async {
    let trimmed = newCredentialAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    keyVerification = .validating
    do {
      let models = try await appState.validateAICredentialKey(
        provider: newCredentialProvider,
        apiKey: trimmed
      )
      keyVerification = .valid(models: models)
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      keyVerification = .invalid(message: message)
    }
  }

  private var providerPickerRow: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      ForEach(providerOptions, id: \.self) { provider in
        providerPickerCard(provider)
      }
    }
  }

  private func providerPickerCard(_ provider: AICredentialProvider) -> some View {
    let isSelected = newCredentialProvider == provider
    let tint = providerTint(provider)
    return Button {
      newCredentialProvider = provider
    } label: {
      VStack(spacing: SerenityUI.Spacing.xs) {
        providerLogo(provider, size: 23)
          .frame(width: 42, height: 42)
        Text(providerTitle(provider))
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)
      }
      .padding(.vertical, SerenityUI.Spacing.sm)
      .padding(.horizontal, SerenityUI.Spacing.sm)
      .frame(maxWidth: .infinity)
      .contentShape(RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
      .background(
        SerenityPalette.panelBackground,
        in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
          .stroke(isSelected ? tint : SerenityPalette.thinBorder, lineWidth: isSelected ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
  }

  private func credentialRow(_ credential: AICredentialEntity) -> some View {
    HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
      providerLogo(credential.provider, size: 20)
        .frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: SerenityUI.Spacing.xs) {
          Text(credential.name)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
          statusDot(isActive: credential.enabled)
        }
        Text("\(providerTitle(credential.provider)) · \(credential.totalRequests) requests · \(credential.totalTokens) tokens")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
      }

      Spacer(minLength: SerenityUI.Spacing.sm)

      SerenityDropdownField(
        placeholder: "Default",
        selection: Binding(
          get: { credential.modelPreference ?? "" },
          set: { model in
            Task {
              await appState.updateAICredentialModel(id: credential.id, modelPreference: model.isEmpty ? nil : model)
            }
          }
        ),
        options: credentialModelOptions(for: credential)
      )
      .frame(width: 220)

      Toggle("Enabled", isOn: Binding(
        get: { credential.enabled },
        set: { enabled in
          Task { await appState.updateAICredentialEnabled(id: credential.id, enabled: enabled) }
        }
      ))
      .toggleStyle(.switch)
      .labelsHidden()

      Button {
        Task { await appState.deleteAICredential(id: credential.id) }
      } label: {
        Image(systemName: "trash")
          .font(.subheadline)
          .foregroundStyle(.red.opacity(0.85))
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .help("Delete credential")
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }

  private var credentialStatusText: String {
    if appState.aiCredentials.isEmpty {
      return "No keys"
    }
    let enabledCount = appState.aiCredentials.filter(\.enabled).count
    return "\(enabledCount) enabled of \(appState.aiCredentials.count)"
  }

  private var hasEnabledCredential: Bool {
    appState.aiCredentials.contains { $0.enabled }
  }

  private var providerDropdownOptions: [SerenityDropdownOption<AICredentialProvider>] {
    providerOptions.map { provider in
      SerenityDropdownOption(
        value: provider,
        title: providerTitle(provider),
        systemImage: providerIcon(provider),
        tint: providerTint(provider)
      )
    }
  }

  private func modelDropdownOptions(for provider: AICredentialProvider) -> [SerenityDropdownOption<String>] {
    [SerenityDropdownOption(value: "", title: "Default", subtitle: "Use Serenity's recommended model", systemImage: "sparkles", tint: SerenityPalette.accent)]
      + (appState.aiModelCatalog[provider] ?? []).map { model in
        SerenityDropdownOption(value: model, title: model, systemImage: "cpu", tint: providerTint(provider))
      }
  }

  private func credentialModelOptions(for credential: AICredentialEntity) -> [SerenityDropdownOption<String>] {
    var models = decodeAvailableModels(from: credential.metadataJSON)
    if let pref = credential.modelPreference, !pref.isEmpty, !models.contains(pref) {
      models.append(pref)
    }
    guard !models.isEmpty else {
      return modelDropdownOptions(for: credential.provider)
    }
    return [
      SerenityDropdownOption(
        value: "",
        title: "Default",
        subtitle: "Use Serenity's recommended model",
        systemImage: "sparkles",
        tint: SerenityPalette.accent
      )
    ] + models.map { model in
      SerenityDropdownOption(
        value: model,
        title: model,
        systemImage: "cpu",
        tint: providerTint(credential.provider)
      )
    }
  }

  private func decodeAvailableModels(from json: String) -> [String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = object["availableModels"] as? [String]
    else {
      return []
    }
    return models
  }

  private var providerOptions: [AICredentialProvider] {
    [.openai, .gemini, .anthropic]
  }

  private func providerTitle(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "OpenAI"
    case .gemini:
      return "Gemini"
    case .anthropic:
      return "Anthropic"
    }
  }

  private func providerLogo(_ provider: AICredentialProvider, size: CGFloat) -> some View {
    Image(providerLogoAsset(provider))
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .foregroundStyle(providerTint(provider))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  private func providerLogoAsset(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "ProviderOpenAI"
    case .gemini:
      return "ProviderGemini"
    case .anthropic:
      return "ProviderAnthropic"
    }
  }

  private func providerIcon(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "sparkles"
    case .gemini:
      return "diamond.fill"
    case .anthropic:
      return "brain.head.profile"
    }
  }

  private func providerTint(_ provider: AICredentialProvider) -> Color {
    switch provider {
    case .openai:
      return SerenityPalette.accent
    case .gemini:
      return .purple
    case .anthropic:
      return .orange
    }
  }

  private func statusDot(isActive: Bool) -> some View {
    Circle()
      .fill(isActive ? Color.green : Color.orange)
      .frame(width: 8, height: 8)
  }

  private var authPanel: some View {
    settingsPanel(
      title: "Auth Session",
      subtitle: "Sign-in and OAuth setup",
      systemImage: "person.badge.key",
      tint: authOverviewTint
    ) {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        authSessionStatus

        Divider()

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          Text("OAuth Configuration")
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)

          settingsField("Base URL") {
            TextField("https://...", text: $oauthBaseURL)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          settingsField("Client ID") {
            TextField("Client ID", text: $oauthClientID)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          settingsField("Redirect URI") {
            TextField("Redirect URI", text: $oauthRedirectURI)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          if let oauthConfigurationError {
            statusBanner(oauthConfigurationError, systemImage: "xmark.octagon.fill", tint: .red)
          }

          if !isOAuthConfigured {
            statusBanner(
              "Save OAuth configuration to enable sign in on this Mac.",
              systemImage: "exclamationmark.triangle.fill",
              tint: .orange
            )
          }

          HStack(spacing: SerenityUI.Spacing.xs) {
            Button {
              let submittedBaseURL = oauthBaseURL
              let submittedClientID = oauthClientID
              let submittedRedirectURI = oauthRedirectURI
              Task {
                do {
                  try await appState.saveOAuthConfiguration(
                    baseURL: submittedBaseURL,
                    clientID: submittedClientID,
                    redirectURI: submittedRedirectURI
                  )
                  oauthConfigurationError = nil
                  syncOAuthConfigurationFields()
                } catch {
                  oauthConfigurationError = error.localizedDescription
                }
              }
            } label: {
              Label("Save OAuth config", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SerenityPrimaryButtonStyle())

            Button {
              Task {
                await appState.clearOAuthConfiguration()
                oauthConfigurationError = nil
                syncOAuthConfigurationFields()
              }
            } label: {
              Label("Clear", systemImage: "xmark")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          Text("Authorization")
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)

          settingsField("Authorization code") {
            TextField("Paste OAuth authorization code", text: $authorizationCode)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          HStack(spacing: SerenityUI.Spacing.xs) {
            Button {
              let submittedCode = authorizationCode
              Task {
                await appState.loginWithAuthorizationCode(submittedCode)
                if case .authenticated = appState.authSessionState {
                  authorizationCode = ""
                }
              }
            } label: {
              Label("Sign in", systemImage: "arrow.right.circle")
            }
            .buttonStyle(SerenityPrimaryButtonStyle())
            .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isOAuthConfigured)

            Button {
              Task {
                await appState.logout()
              }
            } label: {
              Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
          }
        }
      }
    }
  }

  private var appLockPanel: some View {
    settingsPanel(
      title: "App Lock",
      subtitle: "Local device protection",
      systemImage: "lock.shield",
      tint: appState.settings.localLockEnabled ? .green : SerenityPalette.textSecondary
    ) {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        Toggle(
          "Enable local app lock",
          isOn: Binding(
            get: { appState.settings.localLockEnabled },
            set: { newValue in
              if newValue {
                appState.settings.localLockEnabled = true
              } else {
                Task {
                  await appState.handleLocalLockToggle(false)
                  localLockPassword = ""
                  localLockConfirmPassword = ""
                  unlockPassword = ""
                  localLockFormError = nil
                }
              }
            }
          )
        )
        .toggleStyle(.switch)

        statusBanner(
          appState.statusMessage(for: appState.localLockStatus),
          systemImage: appState.settings.localLockEnabled ? "checkmark.shield.fill" : "shield",
          tint: appState.settings.localLockEnabled ? .green : SerenityPalette.textSecondary
        )

        if appState.settings.localLockEnabled, case .disabled = appState.localLockStatus {
          Divider()

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            Text("Set Local Lock Password")
              .font(SerenityType.bodyMedium)
              .foregroundStyle(SerenityPalette.textPrimary)

            SecureField("New password", text: $localLockPassword)
              .textFieldStyle(.plain)
              .serenityInputField()

            SecureField("Confirm password", text: $localLockConfirmPassword)
              .textFieldStyle(.plain)
              .serenityInputField()

            if let localLockFormError {
              statusBanner(localLockFormError, systemImage: "xmark.octagon.fill", tint: .red)
            }

            Button {
              let password = localLockPassword.trimmingCharacters(in: .whitespacesAndNewlines)
              let confirmation = localLockConfirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !password.isEmpty else {
                localLockFormError = "Password cannot be empty."
                return
              }
              guard password == confirmation else {
                localLockFormError = "Passwords do not match."
                return
              }

              localLockFormError = nil
              Task {
                await appState.handleLocalLockToggle(true, password: password)
                if case .unlocked = appState.localLockStatus {
                  localLockPassword = ""
                  localLockConfirmPassword = ""
                }
              }
            } label: {
              Label("Set password and enable lock", systemImage: "key.fill")
            }
            .buttonStyle(SerenityPrimaryButtonStyle())
          }
        }

        if appState.settings.localLockEnabled {
          Divider()

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            Text("Unlock Controls")
              .font(SerenityType.bodyMedium)
              .foregroundStyle(SerenityPalette.textPrimary)

            SecureField("Enter local lock password", text: $unlockPassword)
              .textFieldStyle(.plain)
              .serenityInputField()

            HStack(spacing: SerenityUI.Spacing.xs) {
              Button {
                let submittedPassword = unlockPassword
                Task {
                  await appState.unlockAppWithPassword(submittedPassword)
                  if case .unlocked = appState.localLockStatus {
                    unlockPassword = ""
                  }
                }
              } label: {
                Label("Unlock", systemImage: "lock.open")
              }
              .buttonStyle(SerenitySecondaryButtonStyle())

              Button {
                Task {
                  await appState.lockAppNow()
                }
              } label: {
                Label("Lock now", systemImage: "lock")
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
            }
          }
        }

        biometricStatus
      }
    }
  }

  private var backendValidation: BackendProfileValidationState {
    appState.validationState(for: appState.settings.backendProfile)
  }

  private func backendProfileSubtitle(_ profile: BackendProfile) -> String {
    switch profile {
    case .sqliteLocal:
      return "Private storage on this Mac"
    case .serenityCloud:
      return "Sync through Serenity Cloud"
    case .externalPostgres:
      return "Use a custom PostgreSQL database"
    }
  }

  private func backendProfileIcon(_ profile: BackendProfile) -> String {
    switch profile {
    case .sqliteLocal:
      return "internaldrive"
    case .serenityCloud:
      return "cloud.fill"
    case .externalPostgres:
      return "server.rack"
    }
  }

  private func backendProfileTint(_ profile: BackendProfile) -> Color {
    switch profile {
    case .sqliteLocal:
      return SerenityPalette.accent
    case .serenityCloud:
      return .purple
    case .externalPostgres:
      return .orange
    }
  }

  private func sslModeSubtitle(_ mode: String) -> String {
    switch mode {
    case "disable":
      return "No encrypted transport"
    case "prefer":
      return "Use TLS when available"
    case "require":
      return "Require encrypted transport"
    case "verify-ca":
      return "Validate the certificate authority"
    case "verify-full":
      return "Validate CA and hostname"
    default:
      return "PostgreSQL SSL setting"
    }
  }

  private var authOverviewTint: Color {
    switch appState.authSessionState {
    case .authenticated:
      return .green
    case .failed:
      return .red
    case .authenticating, .refreshing:
      return SerenityPalette.accent
    case .unauthenticated:
      return isOAuthConfigured ? SerenityPalette.textSecondary : .orange
    }
  }

  private var databaseOverviewTint: Color {
    switch appState.databaseBootstrapState {
    case .ready:
      return .green
    case .bootstrapping:
      return SerenityPalette.accent
    case .failed:
      return .red
    case .idle:
      return SerenityPalette.textSecondary
    }
  }

  @ViewBuilder
  private var backendConfigurationEditor: some View {
    switch backendConfigProfile {
    case .sqliteLocal:
      statusBanner(
        "SQLite local backend is ready with no additional setup.",
        systemImage: "checkmark.circle.fill",
        tint: .green
      )

    case .serenityCloud:
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        Text("Serenity Cloud")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)

        Text("Sign in under Auth Session, then use your signed-in session to configure cloud access automatically.")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

        settingsField("Base URL") {
          TextField("https://...", text: $cloudBaseURL)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        if hasAuthenticatedSession {
          statusBanner(
            "Signed-in session available for one-click cloud setup.",
            systemImage: "checkmark.circle.fill",
            tint: .green
          )
        } else {
          statusBanner(
            "Not signed in yet. Use Auth Session below, or provide an access token manually.",
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
          )
        }

        settingsField("Access token") {
          SecureField("Access token", text: $cloudAccessToken)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: SerenityUI.Spacing.xs) {
            serenityCloudActions
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            serenityCloudActions
          }
        }
      }

    case .externalPostgres:
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        Text("External PostgreSQL")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)

        settingsField("Host") {
          TextField("Host", text: $postgresHost)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
          settingsField("Port") {
            TextField("Port", text: $postgresPort)
              .textFieldStyle(.plain)
              .serenityInputField()
          }
          .frame(maxWidth: 140)

          settingsField("SSL mode") {
            SerenityDropdownField(
              placeholder: "SSL mode",
              selection: $postgresSSLMode,
              options: postgresSSLModeDropdownOptions
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        settingsField("Database") {
          TextField("Database", text: $postgresDatabase)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        settingsField("Username") {
          TextField("Username", text: $postgresUsername)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        settingsField("Password") {
          SecureField("Password", text: $postgresPassword)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        HStack(spacing: SerenityUI.Spacing.xs) {
          Button {
            Task {
              await appState.configureExternalPostgres(
                host: postgresHost,
                port: postgresPort,
                database: postgresDatabase,
                username: postgresUsername,
                password: postgresPassword,
                sslMode: postgresSSLMode
              )
            }
          } label: {
            Label("Save PostgreSQL config", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(SerenityPrimaryButtonStyle())

          Button {
            Task {
              await appState.clearExternalPostgresConfiguration()
              postgresPassword = ""
            }
          } label: {
            Label("Clear", systemImage: "xmark")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        }
      }
    }
  }

  @ViewBuilder
  private var serenityCloudActions: some View {
    Button {
      Task {
        await appState.configureSerenityCloudFromSignedInSession(baseURLOverride: cloudBaseURL)
        cloudAccessToken = ""
      }
    } label: {
      Label("Use signed-in session", systemImage: "person.crop.circle.badge.checkmark")
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .disabled(!hasAuthenticatedSession)

    Button {
      Task {
        await appState.configureSerenityCloud(baseURL: cloudBaseURL, accessToken: cloudAccessToken)
      }
    } label: {
      Label("Save cloud config", systemImage: "square.and.arrow.down")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())

    Button {
      Task {
        await appState.clearSerenityCloudConfiguration()
        cloudAccessToken = ""
      }
    } label: {
      Label("Clear", systemImage: "xmark")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
  }

  @ViewBuilder
  private var backendSwitchStatus: some View {
    switch appState.backendSwitchState {
    case .idle:
      EmptyView()
    case .switching(let target):
      Label("Switching to \(target.title)...", systemImage: "arrow.triangle.2.circlepath")
        .font(SerenityType.caption)
    case .succeeded(let message):
      Text(message)
        .font(SerenityType.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Text(message)
        .font(SerenityType.caption)
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private var authSessionStatus: some View {
    switch appState.authSessionState {
    case .unauthenticated:
      Text("Not signed in")
        .foregroundStyle(SerenityPalette.textSecondary)
    case .authenticating:
      Text("Authenticating...")
        .foregroundStyle(SerenityPalette.textSecondary)
    case .authenticated(let session):
      Text("Signed in as \(session.userEmail)")
      Text("User ID: \(session.userID)")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
    case .refreshing:
      Text("Refreshing session...")
        .foregroundStyle(SerenityPalette.textSecondary)
    case .failed(let message):
      Text("Auth error: \(message)")
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private var biometricStatus: some View {
    switch appState.biometricAvailability {
    case .available:
      Button("Unlock with biometrics or passcode") {
        Task {
          await appState.unlockAppWithBiometrics()
        }
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
    case .unavailable(let reason):
      Text("Biometric authentication unavailable: \(reason)")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
  }

  @ViewBuilder
  private var databaseStatusContent: some View {
    switch appState.databaseBootstrapState {
    case .idle:
      Text("Local database bootstrap has not started yet.")
        .foregroundStyle(SerenityPalette.textSecondary)
    case .bootstrapping:
      Label("Applying migrations...", systemImage: "arrow.triangle.2.circlepath")
    case .ready(let path, let appliedCount):
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        Text("Database ready")
        Text(path)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .textSelection(.enabled)
        Text("Migrations applied this run: \(appliedCount)")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    case .failed(let message):
      Text("Bootstrap failed: \(message)")
        .foregroundStyle(.red)
    }
  }

  private var isOAuthConfigured: Bool {
    appState.oauthConfigurationForSettings() != nil
  }

  private var hasAuthenticatedSession: Bool {
    if case .authenticated = appState.authSessionState {
      return true
    }

    return false
  }

  private func loadStoredSettingsValuesIfNeeded() {
    guard !loadedStoredSettingsValues else { return }
    loadedStoredSettingsValues = true

    syncOAuthConfigurationFields()

    let existingCloudBaseURL = appState.cloudBaseURLForSettings()
    if !existingCloudBaseURL.isEmpty {
      cloudBaseURL = existingCloudBaseURL
    } else if let oauthConfiguration = appState.oauthConfigurationForSettings() {
      cloudBaseURL = oauthConfiguration.baseURL.absoluteString
    }

    backendConfigProfile = appState.settings.backendProfile

    if let diagnostics = appState.externalPostgresDiagnosticsForSettings() {
      postgresHost = diagnostics.host
      postgresPort = String(diagnostics.port)
      postgresDatabase = diagnostics.database
      postgresUsername = diagnostics.username
      postgresSSLMode = diagnostics.sslMode
    }
  }

  private func syncOAuthConfigurationFields() {
    guard let configuration = appState.oauthConfigurationForSettings() else {
      oauthBaseURL = ""
      oauthClientID = ""
      oauthRedirectURI = ""
      return
    }

    oauthBaseURL = configuration.baseURL.absoluteString
    oauthClientID = configuration.clientID
    oauthRedirectURI = configuration.redirectURI
  }
}
