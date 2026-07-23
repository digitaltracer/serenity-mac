import SwiftUI

/// Sync & integrations pane: manual sync, Google Calendar, GitHub tokens, iCloud.
struct IntegrationsSettingsPane: View {
  @EnvironmentObject private var appState: AppState

  @State private var githubToken = ""
  @State private var githubDisplayName = ""
  @State private var isConnectingGoogle = false

  private var isGoogleConfigured: Bool {
    appState.googleCalendarConfigured
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      syncStatusCard
      connectedServicesCard
      githubTokensCard
      iCloudSyncStatusCard
    }
  }

  private var syncStatusCard: some View {
    SerenityCard {
      HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.body.weight(.semibold))
          .foregroundStyle(SerenityPalette.accent)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(appState.integrationSyncInProgress ? "Syncing..." : "All integrations ready")
            .font(SerenityType.bodyMedium)
          Text(lastSyncSummary)
            .font(.subheadline)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer()

        Button("Sync Now") {
          Task { await appState.syncIntegrationsNow() }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(appState.integrationSyncInProgress)
      }
    }
  }

  private var lastSyncSummary: String {
    let recents = [
      appState.googleIntegrationState.lastSyncAt,
      appState.githubIntegrationState.lastSyncAt
    ].compactMap { $0 }

    if appState.integrationSyncInProgress {
      return "Syncing now..."
    }
    if let mostRecent = recents.max() {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .abbreviated
      return "Last synced \(formatter.localizedString(for: mostRecent, relativeTo: Date()))"
    }
    return "Manual sync available"
  }

  private var connectedServicesCard: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("Connected Services")

      SerenityCard(padding: 0) {
        VStack(alignment: .leading, spacing: 0) {
          googleServiceRow

          Divider()
            .padding(.leading, SerenityUI.Spacing.md)

          githubServiceRow
        }
      }
    }
  }

  private var googleServiceRow: some View {
    let connected = appState.googleIntegrationState.connected
    return HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
      serviceIcon(systemName: "calendar", accent: Color(red: 0.26, green: 0.52, blue: 0.96))

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: SerenityUI.Spacing.xs) {
          Text("Google Calendar")
            .font(SerenityType.bodyMedium)
          statusBadge(connected: connected)
        }
        Text(googleStatusDetail)
          .font(.subheadline)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()

      if connected {
        Toggle("", isOn: Binding(
          get: { appState.googleIntegrationState.syncEnabled },
          set: { enabled in
            Task { await appState.setGoogleIntegrationSyncEnabled(enabled) }
          }
        ))
        .toggleStyle(.switch)
        .labelsHidden()

        Button("Disconnect") {
          Task { await appState.disconnectGoogleIntegration() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      } else {
        Button {
          Task { await connectGoogle() }
        } label: {
          HStack(spacing: SerenityUI.Spacing.xxs) {
            if isConnectingGoogle {
              ProgressView().controlSize(.small)
            }
            Text(isConnectingGoogle ? "Connecting..." : "Connect")
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(!isGoogleConfigured || isConnectingGoogle)
      }
    }
    .padding(SerenityUI.Spacing.md)
  }

  private var githubServiceRow: some View {
    let tokenCount = appState.githubIntegrationState.tokens.count
    let connected = tokenCount > 0
    return HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
      serviceIcon(systemName: "chevron.left.forwardslash.chevron.right", accent: SerenityPalette.textSecondary)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: SerenityUI.Spacing.xs) {
          Text("GitHub")
            .font(SerenityType.bodyMedium)
          statusBadge(connected: connected)
        }
        Text(connected
          ? "\(tokenCount) token\(tokenCount == 1 ? "" : "s") configured"
          : "Add a personal access token below to connect")
          .font(.subheadline)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()

      if connected {
        Toggle("", isOn: Binding(
          get: { appState.githubIntegrationState.syncEnabled },
          set: { enabled in
            Task { await appState.setGitHubIntegrationSyncEnabled(enabled) }
          }
        ))
        .toggleStyle(.switch)
        .labelsHidden()
      }
    }
    .padding(SerenityUI.Spacing.md)
  }

  private var googleStatusDetail: String {
    if appState.googleIntegrationState.connected {
      return appState.googleIntegrationState.userEmail.map { "Connected as \($0)" } ?? "Connected"
    }
    if !isGoogleConfigured {
      return "Google Sign-In is not configured for this build."
    }
    return "Sync your calendar events as tasks"
  }

  private func serviceIcon(systemName: String, accent: Color) -> some View {
    Image(systemName: systemName)
      .font(.body.weight(.semibold))
      .foregroundStyle(accent)
      .frame(width: 24)
  }

  private func statusBadge(connected: Bool) -> some View {
    SerenityBadge(
      connected ? "Connected" : "Not connected",
      tint: connected ? .green : SerenityPalette.textSecondary
    )
  }

  private var githubTokensCard: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader(
        "GitHub Access Tokens",
        subtitle: "Generate a personal access token with the repo scope at github.com/settings/tokens, then paste it below."
      )

      SerenityCard {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SecureField("Personal access token", text: $githubToken)
              .textFieldStyle(.plain)
              .serenityInputField()

            TextField("Display name (optional)", text: $githubDisplayName)
              .textFieldStyle(.plain)
              .serenityInputField()

            HStack {
              Spacer()
              Button("Add Token") {
                Task {
                  await appState.addGitHubIntegrationToken(
                    token: githubToken,
                    displayName: githubDisplayName.isEmpty ? nil : githubDisplayName
                  )
                  githubToken = ""
                  githubDisplayName = ""
                }
              }
              .buttonStyle(SerenityPrimaryButtonStyle())
              .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }

          if !appState.githubIntegrationState.tokens.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
              ForEach(appState.githubIntegrationState.tokens) { token in
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(token.displayName)
                      .font(SerenityType.bodyMedium)
                    Text("@\(token.username) • \(token.maskedToken)")
                      .font(SerenityType.caption)
                      .foregroundStyle(SerenityPalette.textSecondary)
                  }

                  Spacer()

                  Toggle("Active", isOn: Binding(
                    get: { token.isActive },
                    set: { _ in
                      Task {
                        await appState.toggleGitHubIntegrationToken(id: token.id)
                      }
                    }
                  ))
                  .toggleStyle(.switch)
                  .labelsHidden()

                  Button("Remove", role: .destructive) {
                    Task {
                      await appState.removeGitHubIntegrationToken(id: token.id)
                    }
                  }
                  .buttonStyle(.borderless)
                  .foregroundStyle(Color.red.opacity(0.85))
                }
                .padding(SerenityUI.Spacing.sm)
                .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
              }
            }
          }
        }
      }
    }
  }

  @MainActor
  private func connectGoogle() async {
    AppLogger.info("connectGoogle tapped: isGoogleConfigured=\(isGoogleConfigured)")
    guard isGoogleConfigured else {
      AppLogger.error("connectGoogle: not configured — showing error")
      appState.showError(
        title: "Google is not configured",
        message: "Set GOOGLE_CLIENT_ID, GOOGLE_REVERSED_CLIENT_ID, and the matching URL scheme in the app build settings."
      )
      return
    }

    isConnectingGoogle = true
    defer {
      AppLogger.info("connectGoogle: clearing isConnectingGoogle (defer)")
      isConnectingGoogle = false
    }

    await appState.connectGoogleIntegration()
    AppLogger.info("connectGoogle: connectGoogleIntegration returned")
  }

  private var iCloudSyncStatusCard: some View {
    SerenityCard {
      HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
        serviceIcon(systemName: iCloudSyncIcon, accent: iCloudSyncTint)

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
          HStack(spacing: SerenityUI.Spacing.xs) {
            Text("iCloud Sync")
              .font(SerenityType.bodyMedium)
            SerenityBadge(iCloudSyncBadge, tint: iCloudSyncTint)
          }

          Text(iCloudSyncDetail)
            .font(.subheadline)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: SerenityUI.Spacing.sm)

        Button {
          appState.triggerICloudSync()
        } label: {
          if case .syncing = appState.iCloudSyncState {
            HStack(spacing: SerenityUI.Spacing.xxs) {
              ProgressView().controlSize(.small)
              Text("Syncing")
            }
          } else {
            Label(iCloudSyncButtonTitle, systemImage: iCloudSyncButtonIcon)
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(isICloudSyncing)
      }
    }
  }

  private var iCloudSyncBadge: String {
    switch appState.iCloudSyncState {
    case .idle:
      return "Idle"
    case .syncing:
      return "Syncing"
    case .succeeded:
      return "Synced"
    case .unavailable:
      return "Unavailable"
    case .failed:
      return "Needs attention"
    }
  }

  private var iCloudSyncDetail: String {
    switch appState.iCloudSyncState {
    case .idle:
      return "Ready to sync tasks, projects, journal entries, goals, insights, recaps, and summaries."
    case .syncing:
      return "Uploading local changes and checking for updates from iCloud."
    case .succeeded(let syncedAt, let pending):
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .abbreviated
      let syncedText = formatter.localizedString(for: syncedAt, relativeTo: Date())
      return "Last synced \(syncedText). Pending changes: \(pending)."
    case .unavailable(let reason):
      return reason
    case .failed(let message):
      return message
    }
  }

  private var iCloudSyncTint: Color {
    switch appState.iCloudSyncState {
    case .succeeded:
      return .green
    case .failed:
      return .red
    case .unavailable:
      return .orange
    case .syncing:
      return SerenityPalette.accent
    case .idle:
      return SerenityPalette.textSecondary
    }
  }

  private var iCloudSyncIcon: String {
    switch appState.iCloudSyncState {
    case .succeeded:
      return "checkmark.icloud.fill"
    case .failed:
      return "exclamationmark.icloud.fill"
    case .unavailable:
      return "icloud.slash"
    case .syncing:
      return "icloud.and.arrow.up"
    case .idle:
      return "icloud"
    }
  }

  private var iCloudSyncButtonTitle: String {
    switch appState.iCloudSyncState {
    case .failed, .unavailable:
      return "Retry Sync"
    default:
      return "Sync Now"
    }
  }

  private var iCloudSyncButtonIcon: String {
    switch appState.iCloudSyncState {
    case .failed, .unavailable:
      return "arrow.clockwise"
    default:
      return "arrow.triangle.2.circlepath"
    }
  }

  private var isICloudSyncing: Bool {
    if case .syncing = appState.iCloudSyncState {
      return true
    }
    return false
  }
}
