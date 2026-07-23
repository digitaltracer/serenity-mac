import SwiftUI

/// Advanced tab: database statistics, quick actions, and diagnostics.
struct DatabaseToolsPane: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "checkmark.circle.fill")
          .font(.subheadline)
          .foregroundStyle(.green)
        Text("Connected to \(appState.backendSelectionState.activeProfile.title)")
          .font(.subheadline)
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer()

        Button("Refresh") {
          Task {
            await appState.refreshCoreWorkflowData()
            await appState.refreshDatabaseManagement()
            await appState.refreshActiveBackendValidation()
            await appState.refreshBackendDiagnostics()
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        statMetricCard(title: "Size", value: sqlitePath == nil ? "N/A" : "Local")
        statMetricCard(title: "Records", value: "\(recordCount)")
        statMetricCard(title: "Tasks", value: "\(appState.tasks.count)")
        statMetricCard(title: "Error Rate", value: databaseHealthErrorRate)
      }

      HStack(alignment: .top, spacing: SerenityUI.Spacing.md) {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          SerenitySectionHeader("Database Statistics")

          SerenityCard {
            VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
                Text("Record Breakdown")
                  .font(SerenityType.bodyMedium)

                breakdownRow("Tasks", value: "\(appState.tasks.count)")
                breakdownRow("Projects", value: "\(appState.projects.count)")
                breakdownRow("Journal Entries", value: "\(appState.journalEntries.count)")
                breakdownRow("Goals", value: "\(appState.goals.count)")
              }

              Divider()

              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
                Text("Performance Metrics")
                  .font(SerenityType.bodyMedium)

                breakdownRow("Integrity Check", value: appState.databaseIntegrityCheckResult)
                breakdownRow("Last Backup", value: appState.lastDatabaseBackupPath == nil ? "Not created" : "Available")
                breakdownRow("Last Export", value: appState.lastDatabaseExportPath == nil ? "Not exported" : "Available")
              }
            }
          }
        }
        .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
            SerenitySectionHeader("Quick Actions")

            SerenityCard {
              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
                Button("Create Backup") {
                  Task { await appState.createDatabaseBackup() }
                }
                .buttonStyle(SerenityPrimaryButtonStyle())

                Button("Integrity Check") {
                  Task { await appState.runDatabaseIntegrityCheck() }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Export Snapshot") {
                  Task { await appState.exportCoreDataSnapshot() }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Run Bootstrap") {
                  Task { await appState.bootstrapLocalDatabase() }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())
              }
            }
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
            SerenitySectionHeader("Current Configuration")

            SerenityCard {
              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
                breakdownRow("Database Type", value: appState.backendSelectionState.activeProfile.title)
                breakdownRow("SQLite Path", value: sqlitePath ?? "Unavailable")
              }
            }
          }
        }
        .frame(width: 320)
      }

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        SerenitySectionHeader("Diagnostics")

        SerenityCard {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
            if appState.databaseManagementLines.isEmpty {
              Text("No diagnostics available yet.")
                .foregroundStyle(SerenityPalette.textSecondary)
            } else {
              ForEach(appState.databaseManagementLines, id: \.self) { line in
                Text(line)
                  .font(SerenityType.caption)
                  .textSelection(.enabled)
              }
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        SerenitySectionHeader("Backend Diagnostics")

        SerenityCard {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            if appState.backendDiagnosticsLines.isEmpty {
              Text("No backend diagnostics available yet.")
                .foregroundStyle(SerenityPalette.textSecondary)
            } else {
              ForEach(appState.backendDiagnosticsLines, id: \.self) { line in
                Text(line)
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
                  .textSelection(.enabled)
              }
            }

            Button {
              Task {
                await appState.refreshActiveBackendValidation()
                await appState.refreshBackendDiagnostics()
              }
            } label: {
              Label("Refresh backend diagnostics", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
          }
        }
      }
    }
    .task {
      await appState.refreshActiveBackendValidation()
      await appState.refreshBackendDiagnostics()
    }
  }

  private var recordCount: Int {
    appState.tasks.count + appState.projects.count + appState.journalEntries.count + appState.goals.count
  }

  private var sqlitePath: String? {
    appState.databaseManagementLines
      .first(where: { $0.hasPrefix("SQLite path: ") })?
      .replacingOccurrences(of: "SQLite path: ", with: "")
  }

  private var databaseHealthErrorRate: String {
    appState.databaseIntegrityCheckResult.lowercased().contains("ok") ? "0%" : "N/A"
  }

  private func breakdownRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer()
      Text(value)
        .lineLimit(1)
    }
    .font(SerenityType.body)
  }

  private func statMetricCard(title: String, value: String) -> some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        Text(title)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }
}

/// Backend selection and per-profile connection configuration.
struct DatabaseBackendConfigurationPanel: View {
  @EnvironmentObject private var appState: AppState
  @State private var cloudBaseURL = ""
  @State private var cloudAccessToken = ""
  @State private var postgresHost = ""
  @State private var postgresPort = "5432"
  @State private var postgresDatabase = ""
  @State private var postgresUsername = ""
  @State private var postgresPassword = ""
  @State private var postgresSSLMode = "require"
  @State private var backendConfigProfile: BackendProfile = .serenityCloud
  @State private var loadedStoredValues = false

  private let postgresSSLModes = ["disable", "prefer", "require", "verify-ca", "verify-full"]

  var body: some View {
    settingsPanel(
      title: "Backend Configuration",
      subtitle: "Data residency and connectivity",
      systemImage: "server.rack",
      tint: backendValidation.isAvailable ? .green : .orange
    ) {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        settingsField("Primary backend", help: "Controls the active storage adapter used by the app.") {
          SerenityDropdownField(
            placeholder: "Primary backend",
            selection: $appState.settings.backendProfile,
            options: backendProfileDropdownOptions
          )
          .frame(maxWidth: 300, alignment: .leading)
        }

        statusBanner(
          backendValidation.message,
          systemImage: backendValidation.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tint: backendValidation.isAvailable ? .green : .orange
        )

        Divider()

        settingsField("Edit configuration", help: "Select a backend profile, then update its connection details.") {
          SerenityDropdownField(
            placeholder: "Edit configuration",
            selection: $backendConfigProfile,
            options: backendProfileDropdownOptions
          )
          .frame(maxWidth: 300, alignment: .leading)
        }

        backendConfigurationEditor

        HStack(spacing: SerenityUI.Spacing.xs) {
          Button {
            Task {
              await appState.refreshActiveBackendValidation()
              await appState.refreshBackendDiagnostics()
            }
          } label: {
            Label("Validate active backend", systemImage: "checkmark.seal")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())

          backendSwitchStatus
        }
      }
    }
    .onAppear {
      loadStoredValuesIfNeeded()
    }
    .onChange(of: appState.settings.backendProfile) { _, newValue in
      Task {
        await appState.handleBackendProfileSelection(newValue)
        await appState.refreshBackendDiagnostics()
      }
    }
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

  private var backendValidation: BackendProfileValidationState {
    appState.validationState(for: appState.settings.backendProfile)
  }

  private func backendProfileSubtitle(_ profile: BackendProfile) -> String {
    switch profile {
    case .sqliteLocal:
      return "Private storage on this device"
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

        Text("Sign in under Settings > Auth, then use your signed-in session to configure cloud access automatically.")
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
            "Not signed in yet. Use Settings > Auth, or provide an access token manually.",
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
              await appState.refreshBackendDiagnostics()
            }
          } label: {
            Label("Save PostgreSQL config", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(SerenityPrimaryButtonStyle())

          Button {
            Task {
              await appState.clearExternalPostgresConfiguration()
              postgresPassword = ""
              await appState.refreshBackendDiagnostics()
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
        await appState.refreshBackendDiagnostics()
      }
    } label: {
      Label("Use signed-in session", systemImage: "person.crop.circle.badge.checkmark")
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .disabled(!hasAuthenticatedSession)

    Button {
      Task {
        await appState.configureSerenityCloud(baseURL: cloudBaseURL, accessToken: cloudAccessToken)
        await appState.refreshBackendDiagnostics()
      }
    } label: {
      Label("Save cloud config", systemImage: "square.and.arrow.down")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())

    Button {
      Task {
        await appState.clearSerenityCloudConfiguration()
        cloudAccessToken = ""
        await appState.refreshBackendDiagnostics()
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

  private var hasAuthenticatedSession: Bool {
    if case .authenticated = appState.authSessionState {
      return true
    }

    return false
  }

  private func loadStoredValuesIfNeeded() {
    guard !loadedStoredValues else { return }
    loadedStoredValues = true

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
}
