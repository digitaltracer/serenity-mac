import SwiftUI
import Charts
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SerenityAppScene: View {
  @ObservedObject var appState: AppState
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      if appState.isLockOverlayVisible {
        LocalLockOverlayView()
      } else {
        appContent
      }
    }
    .environmentObject(appState)
    .groupBoxStyle(SerenityPanelGroupBoxStyle())
    .tint(SerenityPalette.accent)
    .preferredColorScheme(appState.themePreference.colorScheme)
    .onOpenURL { url in
      GoogleCalendarConfiguration.handleSignInURL(url)
    }
    .overlay(alignment: .top) {
      if let toast = appState.activeToast {
        ToastBanner(message: toast.message)
          .padding(.top, 12)
      }
    }
    .alert(item: $appState.activeAlert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
    }
    .sheet(isPresented: $appState.isGlobalSearchPresented, onDismiss: {
      appState.closeGlobalSearch()
    }) {
      GlobalSearchSheet()
        .environmentObject(appState)
    }
    .sheet(isPresented: $appState.isHelpCenterPresented, onDismiss: {
      appState.closeHelpCenter()
    }) {
      HelpCenterSheet()
        .environmentObject(appState)
    }
    .task {
      await bootstrap()
    }
    .onAppear {
      activateApplicationIfNeeded()
      AppLogger.info("Native shell loaded")
    }
  }

  @MainActor
  private func bootstrap() async {
    await appState.bootstrapAuthSession()
    await appState.bootstrapLocalLockState()
    await appState.loadBackendSelectionState()
    await appState.refreshActiveBackendValidation()
    await appState.bootstrapLocalDatabaseIfNeeded()
    await appState.refreshCoreWorkflowData()
    await appState.bootstrapIntegrations()
    await appState.bootstrapAIWorkflows()
    await appState.refreshDatabaseManagement()
  }

  private func activateApplicationIfNeeded() {
#if os(macOS)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
#endif
  }

  private var appContent: some View {
    NavigationSplitView(columnVisibility: $splitViewVisibility) {
      SerenitySidebar(
        selectedSection: Binding(
          get: { appState.selectedSection },
          set: { appState.setSection($0) }
        )
      )
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
#if os(macOS)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          openWindow(id: "quick-capture")
        } label: {
          Label("Quick Capture", systemImage: "square.and.pencil")
        }
        .help("Quick Capture (⇧⌘N)")
        .disabled(appState.isLockOverlayVisible)

        Button {
          appState.openGlobalSearch()
        } label: {
          Label("Search", systemImage: "magnifyingglass")
        }
        .help("Search (⌘K)")

        Button {
          appState.openHelpCenter()
        } label: {
          Label("Help", systemImage: "questionmark.circle")
        }
        .help("Help (⌘/)")
      }
    }
#endif
  }

  @ViewBuilder
  private var detailContent: some View {
#if os(macOS)
    detailNavigationStack
#else
    VStack(spacing: 0) {
      SerenityTopBar()
      detailNavigationStack
    }
#endif
  }

  private var detailNavigationStack: some View {
    NavigationStack {
      if let selectedSection = appState.selectedSection {
        SectionView(section: selectedSection)
          .environmentObject(appState)
          .navigationTitle(selectedSection.title)
      } else {
        ContentUnavailableView("Select a section", systemImage: "sidebar.left")
      }
    }
  }
}

private extension AppThemePreference {
  var topBarSymbol: String {
    switch self {
    case .system:
      return "desktopcomputer"
    case .light:
      return "sun.max"
    case .dark:
      return "moon"
    }
  }
}

private enum SerenityCursor {
  case arrow
  case iBeam
  case pointingHand
}

private struct HoverCursorModifier: ViewModifier {
  let cursor: SerenityCursor

  func body(content: Content) -> some View {
#if os(macOS)
    if #available(macOS 13.0, *) {
      content
        .onContinuousHover { phase in
          switch phase {
          case .active:
            cursor.nativeCursor.set()
          case .ended:
            NSCursor.arrow.set()
          }
        }
    } else {
      content
        .onHover { hovering in
          if hovering {
            cursor.nativeCursor.set()
          } else {
            NSCursor.arrow.set()
          }
        }
    }
#else
    content
#endif
  }
}

private extension View {
  func hoverCursor(_ cursor: SerenityCursor) -> some View {
    modifier(HoverCursorModifier(cursor: cursor))
  }
}

#if os(macOS)
private extension SerenityCursor {
  var nativeCursor: NSCursor {
    switch self {
    case .arrow:
      return .arrow
    case .iBeam:
      return .iBeam
    case .pointingHand:
      return .pointingHand
    }
  }
}
#endif

private struct SerenityPanelGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      configuration.label
        .font(SerenityType.bodyLarge.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)

      Divider()
        .overlay(SerenityPalette.thinBorder)

      configuration.content
        .padding(16)
    }
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }
}

private enum SerenityChromeMetrics {
  static let rowHeight: CGFloat = 32
  static let horizontalPadding: CGFloat = 18
  static let controlSpacing: CGFloat = 8
  static let buttonSize: CGFloat = 32
  static let buttonIconSize: CGFloat = 14
  static let sidebarHeaderIconSize: CGFloat = 30
  static let sidebarHeaderTopPadding: CGFloat = 4
  static let sidebarHeaderBottomPadding: CGFloat = 12
}

#if os(iOS)
private struct SerenityTopBar: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    HStack(spacing: SerenityChromeMetrics.controlSpacing) {
      Spacer()

      TopBarButton(symbol: "magnifyingglass", accessibilityLabel: "Search") {
        appState.openGlobalSearch()
      }
      TopBarButton(symbol: "questionmark.circle", accessibilityLabel: "Help") {
        appState.openHelpCenter()
      }
      TopBarButton(symbol: appState.themePreference.topBarSymbol, accessibilityLabel: "Theme") {
        cycleThemePreference()
      }
    }
    .padding(.horizontal, SerenityChromeMetrics.horizontalPadding)
    .frame(height: SerenityChromeMetrics.rowHeight)
    .background(
      LinearGradient(
        colors: [SerenityPalette.sidebarHeaderBackground.opacity(0.95), SerenityPalette.sidebarBackground.opacity(0.9)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(SerenityPalette.thinBorder)
        .frame(height: 1)
    }
  }

  private func cycleThemePreference() {
    let all = AppThemePreference.allCases
    guard let currentIndex = all.firstIndex(of: appState.themePreference) else {
      appState.setThemePreference(.system)
      return
    }

    let next = all[(currentIndex + 1) % all.count]
    appState.setThemePreference(next)
  }
}
#endif

private struct TopBarButton: View {
  @State private var hovered = false
  let symbol: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(SerenityType.scaledSystem(size: SerenityChromeMetrics.buttonIconSize, weight: .semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
        .frame(width: SerenityChromeMetrics.buttonSize, height: SerenityChromeMetrics.buttonSize)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovered ? SerenityPalette.panelBackgroundRaised : .clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(hovered ? SerenityPalette.thinBorder : .clear, lineWidth: 1)
        )
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
          hovered = hovering
        }
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)
  }
}

private enum SerenityContentDensity {
  case regular
  case compact
  case tight

  static func from(width: CGFloat) -> SerenityContentDensity {
    if width < 980 {
      return .tight
    }

    if width < 1280 {
      return .compact
    }

    return .regular
  }

  var sectionSpacing: CGFloat {
    switch self {
    case .regular: return 18
    case .compact: return 14
    case .tight: return 12
    }
  }

  var contentPadding: CGFloat {
    switch self {
    case .regular: return 22
    case .compact: return 18
    case .tight: return 14
    }
  }

  var contentBottomPadding: CGFloat {
    switch self {
    case .regular: return 12
    case .compact: return 10
    case .tight: return 8
    }
  }

  var sectionIconContainer: CGFloat {
    switch self {
    case .regular: return 50
    case .compact: return 44
    case .tight: return 40
    }
  }

  var sectionIconSize: CGFloat {
    switch self {
    case .regular: return 19
    case .compact: return 17
    case .tight: return 15
    }
  }

  var sectionTitleFont: Font {
    switch self {
    case .regular: return SerenityType.scaledSystem(size: 28, weight: .semibold)
    case .compact: return SerenityType.scaledSystem(size: 24, weight: .semibold)
    case .tight: return SerenityType.scaledSystem(size: 21, weight: .medium)
    }
  }

  var sectionSubtitleFont: Font {
    switch self {
    case .regular: return SerenityType.scaledSystem(size: 17, weight: .regular)
    case .compact: return SerenityType.scaledSystem(size: 15, weight: .regular)
    case .tight: return SerenityType.scaledSystem(size: 14, weight: .regular)
    }
  }

  var heroAvatarSize: CGFloat {
    switch self {
    case .regular: return 88
    case .compact: return 76
    case .tight: return 64
    }
  }

  var heroLetterSize: CGFloat {
    switch self {
    case .regular: return 36
    case .compact: return 32
    case .tight: return 27
    }
  }

  var heroTitleSize: CGFloat {
    switch self {
    case .regular: return 48
    case .compact: return 40
    case .tight: return 34
    }
  }

  var heroSubtitleMaxWidth: CGFloat {
    switch self {
    case .regular: return 700
    case .compact: return 560
    case .tight: return 460
    }
  }

  var heroBottomPadding: CGFloat {
    switch self {
    case .regular: return 28
    case .compact: return 24
    case .tight: return 20
    }
  }

  var quickCapturePromptHorizontalPadding: CGFloat {
    switch self {
    case .regular: return 24
    case .compact: return 18
    case .tight: return 14
    }
  }

  var quickCapturePromptVerticalPadding: CGFloat {
    switch self {
    case .regular: return 22
    case .compact: return 18
    case .tight: return 14
    }
  }

  var quickCaptureEditorFontSize: CGFloat {
    switch self {
    case .regular: return 18
    case .compact: return 17
    case .tight: return 16
    }
  }

  var quickCaptureEditorPadding: CGFloat {
    switch self {
    case .regular: return 16
    case .compact: return 14
    case .tight: return 12
    }
  }

  var quickCaptureEditorHeight: CGFloat {
    switch self {
    case .regular: return 156
    case .compact: return 132
    case .tight: return 116
    }
  }

  var quickCaptureFooterPaddingVertical: CGFloat {
    switch self {
    case .regular: return 12
    case .compact: return 10
    case .tight: return 8
    }
  }

  var featureGridSpacing: CGFloat {
    switch self {
    case .regular: return 16
    case .compact: return 14
    case .tight: return 12
    }
  }

  var featureCardPadding: CGFloat {
    switch self {
    case .regular: return 20
    case .compact: return 16
    case .tight: return 14
    }
  }

  var featureCardMinHeight: CGFloat {
    switch self {
    case .regular: return 168
    case .compact: return 150
    case .tight: return 136
    }
  }

  var featureIconContainer: CGFloat {
    switch self {
    case .regular: return 54
    case .compact: return 46
    case .tight: return 42
    }
  }

  var featureIconSize: CGFloat {
    switch self {
    case .regular: return 24
    case .compact: return 20
    case .tight: return 18
    }
  }

  var heroTitleWeight: Font.Weight {
    switch self {
    case .regular, .compact: return .semibold
    case .tight: return .medium
    }
  }

  var featureColumns: [GridItem] {
    switch self {
    case .tight:
      return [GridItem(.flexible(), spacing: featureGridSpacing)]
    case .regular, .compact:
      return [
        GridItem(.flexible(), spacing: featureGridSpacing),
        GridItem(.flexible(), spacing: featureGridSpacing),
      ]
    }
  }
}

private struct SectionView: View {
  @EnvironmentObject private var appState: AppState
  let section: AppSection

  var body: some View {
    GeometryReader { proxy in
      let density = SerenityContentDensity.from(width: proxy.size.width)

      ScrollView {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
          switch section {
          case .today:
            TodaySectionView()
          case .tasks:
            TasksSectionView()
          case .projects:
            ProjectsSectionView()
          case .journal:
            JournalSectionView()
          case .goals:
            GoalsSectionView()
          case .insights:
            InsightsSectionView()
          case .settings:
            SettingsSectionView()
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, density.contentPadding)
        .padding(.leading, density.contentPadding)
        .padding(.trailing, density.contentPadding + 14)
        .padding(.bottom, density.contentBottomPadding)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: section)
    .onAppear {
      AppLogger.info("Rendered section: \(section.rawValue)")
      if section == .insights {
        Task {
          await appState.refreshAIWorkflows()
        }
      }

      if [.today, .tasks, .projects, .journal, .goals, .insights].contains(section) {
        Task {
          await appState.refreshCoreWorkflowData()
        }
      }
    }
  }

}

struct IntegrationsSettingsPane: View {
  @EnvironmentObject private var appState: AppState

  @State private var githubToken = ""
  @State private var githubDisplayName = ""
  @State private var isConnectingGoogle = false

  private var isGoogleConfigured: Bool {
    appState.googleCalendarConfigured
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      syncStatusCard
      connectedServicesCard
      githubTokensCard
      iCloudSyncStatusCard
    }
  }

  private var syncStatusCard: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: 40, height: 40)
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(SerenityType.scaledSystem(size: 17, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(appState.integrationSyncInProgress ? "Syncing..." : "All integrations ready")
          .font(SerenityType.sectionTitle)
        Text(lastSyncSummary)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()

      Button("Sync Now") {
        Task { await appState.syncIntegrationsNow() }
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
      .hoverCursor(.pointingHand)
      .disabled(appState.integrationSyncInProgress)
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
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
    VStack(alignment: .leading, spacing: 0) {
      Text("Connected Services")
        .font(SerenityType.sectionTitle)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)

      Divider().overlay(SerenityPalette.thinBorder)

      googleServiceRow

      Divider().overlay(SerenityPalette.thinBorder).padding(.leading, 16)

      githubServiceRow
    }
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var googleServiceRow: some View {
    let connected = appState.googleIntegrationState.connected
    return HStack(alignment: .center, spacing: 14) {
      serviceIcon(systemName: "calendar", accent: Color(red: 0.26, green: 0.52, blue: 0.96))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text("Google Calendar")
            .font(SerenityType.bodyLarge.weight(.semibold))
          statusPill(connected: connected)
        }
        Text(googleStatusDetail)
          .font(SerenityType.body)
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
        .hoverCursor(.pointingHand)
      } else {
        Button {
          Task { await connectGoogle() }
        } label: {
          HStack(spacing: 6) {
            if isConnectingGoogle {
              ProgressView().controlSize(.small)
            }
            Text(isConnectingGoogle ? "Connecting..." : "Connect")
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
        .disabled(!isGoogleConfigured || isConnectingGoogle)
      }
    }
    .padding(16)
  }

  private var githubServiceRow: some View {
    let tokenCount = appState.githubIntegrationState.tokens.count
    let connected = tokenCount > 0
    return HStack(alignment: .center, spacing: 14) {
      serviceIcon(systemName: "chevron.left.forwardslash.chevron.right", accent: Color(red: 0.55, green: 0.55, blue: 0.60))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text("GitHub")
            .font(SerenityType.bodyLarge.weight(.semibold))
          statusPill(connected: connected)
        }
        Text(connected
          ? "\(tokenCount) token\(tokenCount == 1 ? "" : "s") configured"
          : "Add a personal access token below to connect")
          .font(SerenityType.body)
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
    .padding(16)
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
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(accent.opacity(0.18))
        .frame(width: 36, height: 36)
      Image(systemName: systemName)
        .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
        .foregroundStyle(accent)
    }
  }

  private func statusPill(connected: Bool) -> some View {
    Text(connected ? "Connected" : "Not connected")
      .font(SerenityType.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(connected ? Color.green : SerenityPalette.textSecondary)
      .background((connected ? Color.green : SerenityPalette.textSecondary).opacity(0.15), in: Capsule())
  }

  private var githubTokensCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("GitHub Access Tokens")
        .font(SerenityType.sectionTitle)

      Text("Generate a personal access token with the repo scope at github.com/settings/tokens, then paste it below.")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)

      VStack(alignment: .leading, spacing: 8) {
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
          .hoverCursor(.pointingHand)
          .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }

      if !appState.githubIntegrationState.tokens.isEmpty {
        Divider().overlay(SerenityPalette.thinBorder)

        VStack(alignment: .leading, spacing: 8) {
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
              .hoverCursor(.pointingHand)
            }
            .padding(12)
            .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
        }
      }
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
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
    HStack(alignment: .center, spacing: 14) {
      serviceIcon(systemName: iCloudSyncIcon, accent: iCloudSyncTint)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("iCloud Sync")
            .font(SerenityType.bodyLarge.weight(.semibold))
          Text(iCloudSyncBadge)
            .font(SerenityType.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(iCloudSyncTint)
            .background(iCloudSyncTint.opacity(0.15), in: Capsule())
        }

        Text(iCloudSyncDetail)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button {
        appState.triggerICloudSync()
      } label: {
        if case .syncing = appState.iCloudSyncState {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Syncing")
          }
        } else {
          Label(iCloudSyncButtonTitle, systemImage: iCloudSyncButtonIcon)
        }
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
      .hoverCursor(.pointingHand)
      .disabled(isICloudSyncing)
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
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

private struct DatabaseToolsPane: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
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
        .hoverCursor(.pointingHand)
        .controlSize(.large)
      }

      HStack(spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Connected to \(appState.backendSelectionState.activeProfile.title.uppercased())")
          .font(SerenityType.sectionTitle)
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.green.opacity(0.45), lineWidth: 1)
      )

      HStack(alignment: .top, spacing: 16) {
        GroupBox("Database Statistics") {
          VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
              statMetricCard(title: "Size", value: sqlitePath == nil ? "N/A" : "Local")
              statMetricCard(title: "Records", value: "\(recordCount)")
              statMetricCard(title: "Tasks", value: "\(appState.tasks.count)")
              statMetricCard(title: "Error Rate", value: databaseHealthErrorRate)
            }

            VStack(alignment: .leading, spacing: 8) {
              Text("Record Breakdown")
                .font(SerenityType.sectionTitle)

              breakdownRow("Tasks", value: "\(appState.tasks.count)")
              breakdownRow("Projects", value: "\(appState.projects.count)")
              breakdownRow("Journal Entries", value: "\(appState.journalEntries.count)")
              breakdownRow("Goals", value: "\(appState.goals.count)")
            }

            Divider()
              .overlay(SerenityPalette.thinBorder)

            VStack(alignment: .leading, spacing: 8) {
              Text("Performance Metrics")
                .font(SerenityType.sectionTitle)

              breakdownRow("Integrity Check", value: appState.databaseIntegrityCheckResult)
              breakdownRow("Last Backup", value: appState.lastDatabaseBackupPath == nil ? "Not created" : "Available")
              breakdownRow("Last Export", value: appState.lastDatabaseExportPath == nil ? "Not exported" : "Available")
            }
          }
          .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)

        VStack(spacing: 16) {
          GroupBox("Quick Actions") {
            VStack(alignment: .leading, spacing: 10) {
              Button("Create Backup") {
                Task { await appState.createDatabaseBackup() }
              }
              .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)

              Button("Integrity Check") {
                Task { await appState.runDatabaseIntegrityCheck() }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

              Button("Export Snapshot") {
                Task { await appState.exportCoreDataSnapshot() }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

              Button("Run Bootstrap") {
                Task { await appState.bootstrapLocalDatabase() }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
            }
            .padding(.top, 4)
          }

          GroupBox("Current Configuration") {
            VStack(alignment: .leading, spacing: 6) {
              breakdownRow("Database Type", value: appState.backendSelectionState.activeProfile.title)
              breakdownRow("SQLite Path", value: sqlitePath ?? "Unavailable")
            }
            .padding(.top, 4)
          }
        }
        .frame(width: 320)
      }

      GroupBox("Diagnostics") {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.top, 8)
      }

      GroupBox("Backend Diagnostics") {
        VStack(alignment: .leading, spacing: 8) {
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
          .hoverCursor(.pointingHand)
        }
        .padding(.top, 8)
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
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(SerenityType.scaledSystem(size: 10, weight: .regular))
        .foregroundStyle(SerenityPalette.textSecondary)
      Text(value)
        .font(SerenityType.pageTitle)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private struct DatabaseBackendConfigurationPanel: View {
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
      VStack(alignment: .leading, spacing: 14) {
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
          .overlay(SerenityPalette.thinBorder)

        settingsField("Edit configuration", help: "Select a backend profile, then update its connection details.") {
          SerenityDropdownField(
            placeholder: "Edit configuration",
            selection: $backendConfigProfile,
            options: backendProfileDropdownOptions
          )
          .frame(maxWidth: 300, alignment: .leading)
        }

        backendConfigurationEditor

        HStack(spacing: 10) {
          Button {
            Task {
              await appState.refreshActiveBackendValidation()
              await appState.refreshBackendDiagnostics()
            }
          } label: {
            Label("Validate active backend", systemImage: "checkmark.seal")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

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
      VStack(alignment: .leading, spacing: 12) {
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
          HStack(spacing: 10) {
            serenityCloudActions
          }

          VStack(alignment: .leading, spacing: 10) {
            serenityCloudActions
          }
        }
      }

    case .externalPostgres:
      VStack(alignment: .leading, spacing: 12) {
        Text("External PostgreSQL")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)

        settingsField("Host") {
          TextField("Host", text: $postgresHost)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        HStack(alignment: .top, spacing: 10) {
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

        HStack(spacing: 10) {
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
          .hoverCursor(.pointingHand)

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
          .hoverCursor(.pointingHand)
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
    .hoverCursor(.pointingHand)

    Button {
      Task {
        await appState.configureSerenityCloud(baseURL: cloudBaseURL, accessToken: cloudAccessToken)
        await appState.refreshBackendDiagnostics()
      }
    } label: {
      Label("Save cloud config", systemImage: "square.and.arrow.down")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)

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
    .hoverCursor(.pointingHand)
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

  private func settingsPanel<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: systemImage)
          .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 34, height: 34)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(tint.opacity(0.16), lineWidth: 1)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(SerenityType.sectionTitle)
            .foregroundStyle(SerenityPalette.textPrimary)
          Text(subtitle)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 0)
      }

      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func settingsField<Content: View>(
    _ label: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
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

  private func statusBanner(_ message: String, systemImage: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: systemImage)
        .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 16)

      Text(message)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tint.opacity(0.24), lineWidth: 1)
    )
  }
}

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
    VStack(alignment: .leading, spacing: 18) {
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
        .padding(20)
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
    VStack(alignment: .leading, spacing: 18) {
      appearancePanel
      appLockPanel
    }
  }

  private var aiPane: some View {
    aiProviderPanel
  }

  private var syncBackendPane: some View {
    VStack(alignment: .leading, spacing: 18) {
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
      VStack(alignment: .leading, spacing: 20) {
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
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Configured keys")
          .font(SerenityType.sectionTitle)
          .foregroundStyle(SerenityPalette.textPrimary)
        Spacer()
        Text("\(appState.aiCredentials.count) total")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        ForEach(appState.aiCredentials) { credential in
          credentialRow(credential)
        }
      }
    }
  }

  private var addCredentialSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(appState.aiCredentials.isEmpty ? "Add a provider key" : "Add another key")
        .font(SerenityType.sectionTitle)
        .foregroundStyle(SerenityPalette.textPrimary)

      settingsField("Provider") {
        providerPickerRow
      }

      settingsField("API key", help: "Stored securely in the system Keychain.") {
        HStack(spacing: 10) {
          SecureField("sk-…", text: $newCredentialAPIKey)
            .textFieldStyle(.plain)
            .serenityInputField()
            .frame(maxWidth: 520)

          Button {
            Task { await runKeyVerification() }
          } label: {
            switch keyVerification {
            case .validating:
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…")
              }
            default:
              Label("Verify", systemImage: "checkmark.shield")
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(
            newCredentialAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || keyVerification == .validating
          )
        }

        keyVerificationStatusView
      }

      HStack(alignment: .top, spacing: 18) {
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
        .hoverCursor(.pointingHand)
        .disabled(
          newCredentialAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || keyVerification == .validating
        )
      }
    }
    .padding(18)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
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
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Validating key…")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    case .valid(let models):
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Key valid · \(models.count) model\(models.count == 1 ? "" : "s") available")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    case .invalid(let message):
      HStack(spacing: 6) {
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
    HStack(spacing: 10) {
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
      VStack(spacing: 8) {
        providerLogo(provider, size: 23)
          .frame(width: 42, height: 42)
          .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        Text(providerTitle(provider))
          .font(SerenityType.bodyMedium.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity)
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .background(
        isSelected ? tint.opacity(0.10) : SerenityPalette.panelBackground,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? tint : SerenityPalette.thinBorder, lineWidth: isSelected ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func credentialRow(_ credential: AICredentialEntity) -> some View {
    HStack(alignment: .center, spacing: 14) {
      providerLogo(credential.provider, size: 20)
        .frame(width: 38, height: 38)
        .background(providerTint(credential.provider).opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(credential.name)
            .font(SerenityType.bodyMedium.weight(.semibold))
            .foregroundStyle(SerenityPalette.textPrimary)
          statusDot(isActive: credential.enabled)
        }
        Text("\(providerTitle(credential.provider)) · \(credential.totalRequests) requests · \(credential.totalTokens) tokens")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

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
          .font(SerenityType.scaledSystem(size: 14, weight: .semibold))
          .foregroundStyle(.red.opacity(0.85))
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)
      .help("Delete credential")
    }
    .padding(14)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
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
      VStack(alignment: .leading, spacing: 14) {
        authSessionStatus

        Divider()
          .overlay(SerenityPalette.thinBorder)

        VStack(alignment: .leading, spacing: 10) {
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

          HStack(spacing: 10) {
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
            .hoverCursor(.pointingHand)

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
            .hoverCursor(.pointingHand)
          }
        }

        Divider()
          .overlay(SerenityPalette.thinBorder)

        VStack(alignment: .leading, spacing: 10) {
          Text("Authorization")
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)

          settingsField("Authorization code") {
            TextField("Paste OAuth authorization code", text: $authorizationCode)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          HStack(spacing: 10) {
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
            .hoverCursor(.pointingHand)

            Button {
              Task {
                await appState.logout()
              }
            } label: {
              Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)
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
      VStack(alignment: .leading, spacing: 14) {
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
            .overlay(SerenityPalette.thinBorder)

          VStack(alignment: .leading, spacing: 10) {
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
            .hoverCursor(.pointingHand)
          }
        }

        if appState.settings.localLockEnabled {
          Divider()
            .overlay(SerenityPalette.thinBorder)

          VStack(alignment: .leading, spacing: 10) {
            Text("Unlock Controls")
              .font(SerenityType.bodyMedium)
              .foregroundStyle(SerenityPalette.textPrimary)

            SecureField("Enter local lock password", text: $unlockPassword)
              .textFieldStyle(.plain)
              .serenityInputField()

            HStack(spacing: 10) {
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
              .hoverCursor(.pointingHand)

              Button {
                Task {
                  await appState.lockAppNow()
                }
              } label: {
                Label("Lock now", systemImage: "lock")
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
          }
        }

        biometricStatus
      }
    }
  }

  private func settingsPanel<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: systemImage)
          .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 34, height: 34)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(tint.opacity(0.16), lineWidth: 1)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(SerenityType.sectionTitle)
            .foregroundStyle(SerenityPalette.textPrimary)
          Text(subtitle)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 0)
      }

      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func settingsField<Content: View>(
    _ label: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
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

  private func statusBanner(_ message: String, systemImage: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: systemImage)
        .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 16)

      Text(message)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tint.opacity(0.24), lineWidth: 1)
    )
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
      VStack(alignment: .leading, spacing: 12) {
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
          HStack(spacing: 10) {
            serenityCloudActions
          }

          VStack(alignment: .leading, spacing: 10) {
            serenityCloudActions
          }
        }
      }

    case .externalPostgres:
      VStack(alignment: .leading, spacing: 12) {
        Text("External PostgreSQL")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)

        settingsField("Host") {
          TextField("Host", text: $postgresHost)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        HStack(alignment: .top, spacing: 10) {
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

        HStack(spacing: 10) {
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
          .hoverCursor(.pointingHand)

          Button {
            Task {
              await appState.clearExternalPostgresConfiguration()
              postgresPassword = ""
            }
          } label: {
            Label("Clear", systemImage: "xmark")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
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
    .hoverCursor(.pointingHand)

    Button {
      Task {
        await appState.configureSerenityCloud(baseURL: cloudBaseURL, accessToken: cloudAccessToken)
      }
    } label: {
      Label("Save cloud config", systemImage: "square.and.arrow.down")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)

    Button {
      Task {
        await appState.clearSerenityCloudConfiguration()
        cloudAccessToken = ""
      }
    } label: {
      Label("Clear", systemImage: "xmark")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
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
      .hoverCursor(.pointingHand)
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
      VStack(alignment: .leading, spacing: 4) {
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

private struct LocalLockOverlayView: View {
  @EnvironmentObject private var appState: AppState
  @State private var password = ""
  @State private var revealPassword = false
  @State private var isUnlockingWithPassword = false
  @State private var isUnlockingWithBiometrics = false
  @FocusState private var passwordFieldFocused: Bool

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.06, green: 0.12, blue: 0.24),
          Color(red: 0.04, green: 0.10, blue: 0.20),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      Circle()
        .fill(Color(red: 0.30, green: 0.45, blue: 0.82).opacity(0.34))
        .frame(width: 680, height: 680)
        .blur(radius: 120)
        .offset(x: -220, y: -300)

      Circle()
        .fill(Color(red: 0.18, green: 0.32, blue: 0.62).opacity(0.30))
        .frame(width: 780, height: 780)
        .blur(radius: 140)
        .offset(x: 260, y: -260)

      Rectangle()
        .fill(
          LinearGradient(
            colors: [
              Color.black.opacity(0.10),
              Color.black.opacity(0.26),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .ignoresSafeArea()

      VStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 18) {
          VStack(spacing: 8) {
            ZStack {
              Circle()
                .fill(
                  LinearGradient(
                    colors: [
                      Color(red: 0.37, green: 0.52, blue: 0.98),
                      Color(red: 0.59, green: 0.29, blue: 0.96),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
                .frame(width: 62, height: 62)
                .shadow(color: Color(red: 0.38, green: 0.47, blue: 0.97).opacity(0.28), radius: 14, y: 8)

              Image(systemName: "lock")
                .font(SerenityType.scaledSystem(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
            }

            Text("Serenity Notes")
              .font(SerenityType.scaledSystem(size: 32, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.97))

            Text("Enter your master password to unlock")
              .font(SerenityType.scaledSystem(size: 15, weight: .regular, design: .rounded))
              .foregroundStyle(Color(red: 0.66, green: 0.72, blue: 0.82))
          }
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 8) {
            Text("Master Password")
              .font(SerenityType.scaledSystem(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color(red: 0.74, green: 0.79, blue: 0.88))

            HStack(spacing: 10) {
              Image(systemName: "key")
                .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.61, green: 0.67, blue: 0.78))

              Group {
                if revealPassword {
                  TextField("", text: $password, prompt: Text("Enter master password").foregroundStyle(Color(red: 0.55, green: 0.62, blue: 0.73)))
                    .textFieldStyle(.plain)
                } else {
                  SecureField("", text: $password, prompt: Text("Enter master password").foregroundStyle(Color(red: 0.55, green: 0.62, blue: 0.73)))
                    .textFieldStyle(.plain)
                }
              }
              .font(SerenityType.scaledSystem(size: 15, weight: .medium, design: .rounded))
              .foregroundStyle(Color(red: 0.84, green: 0.89, blue: 0.97))
              .focused($passwordFieldFocused)
              .submitLabel(.go)
              .onSubmit {
                unlockWithPassword()
              }
              .disabled(isLockedOut || isUnlockingWithPassword)

              Button {
                revealPassword.toggle()
              } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
                  .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
                  .foregroundStyle(Color(red: 0.56, green: 0.63, blue: 0.75))
              }
              .buttonStyle(.plain)
              .hoverCursor(.pointingHand)
              .disabled(isLockedOut || isUnlockingWithPassword)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.03, green: 0.07, blue: 0.16).opacity(0.96))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 0.18, green: 0.35, blue: 0.60).opacity(0.82), lineWidth: 1.2)
            )
          }

          if let lockoutMessage {
            statusMessageBox(
              text: lockoutMessage,
              tint: Color(red: 0.98, green: 0.74, blue: 0.47),
              border: Color(red: 0.64, green: 0.42, blue: 0.23),
              background: Color(red: 0.23, green: 0.15, blue: 0.08)
            )
          } else if let attemptsWarning {
            statusMessageBox(
              text: attemptsWarning,
              tint: Color(red: 0.95, green: 0.81, blue: 0.44),
              border: Color(red: 0.54, green: 0.46, blue: 0.20),
              background: Color(red: 0.22, green: 0.19, blue: 0.09)
            )
          }

          Button {
            unlockWithPassword()
          } label: {
            HStack(spacing: 10) {
              if isUnlockingWithPassword {
                ProgressView()
                  .controlSize(.small)
                  .tint(Color(red: 0.10, green: 0.13, blue: 0.22))
                Text("Validating...")
              } else {
                Text(isLockedOut ? "Locked" : "Unlock")
              }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
          }
          .font(SerenityType.scaledSystem(size: 16, weight: .semibold, design: .rounded))
          .foregroundStyle(unlockDisabled ? Color.white.opacity(0.62) : Color(red: 0.08, green: 0.11, blue: 0.20))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 11)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(unlockButtonFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(Color.white.opacity(unlockDisabled ? 0.05 : 0.14), lineWidth: 1)
          )
          .hoverCursor(.pointingHand)
          .buttonStyle(.plain)
          .disabled(unlockDisabled)

          if isBiometricAvailable {
            Button {
              unlockWithBiometrics()
            } label: {
              HStack(spacing: 10) {
                if isUnlockingWithBiometrics {
                  ProgressView()
                    .controlSize(.small)
                  Text("Authenticating...")
                } else {
                  Label("Use Touch ID", systemImage: "touchid")
                }
              }
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
            }
            .font(SerenityType.scaledSystem(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.82, green: 0.88, blue: 0.97))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.11, green: 0.18, blue: 0.29))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(red: 0.26, green: 0.40, blue: 0.63).opacity(0.62), lineWidth: 1)
            )
            .hoverCursor(.pointingHand)
            .buttonStyle(.plain)
            .disabled(isUnlockingWithBiometrics || isUnlockingWithPassword || isLockedOut)
          }

          if isBiometricAvailable {
            HStack(spacing: 10) {
              Rectangle()
                .fill(Color(red: 0.30, green: 0.37, blue: 0.49))
                .frame(height: 1)
              Text("or")
                .font(SerenityType.scaledSystem(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(Color(red: 0.56, green: 0.62, blue: 0.73))
              Rectangle()
                .fill(Color(red: 0.30, green: 0.37, blue: 0.49))
                .frame(height: 1)
            }
          }

          Button("Forgot your password?") {
            appState.requestSettings(tab: .general)
            appState.showToast("After unlocking, open Settings to reset your local lock password.")
          }
          .buttonStyle(.plain)
          .font(SerenityType.scaledSystem(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color(red: 0.43, green: 0.67, blue: 0.98))
          .frame(maxWidth: .infinity, alignment: .center)
          .hoverCursor(.pointingHand)

          VStack(alignment: .leading, spacing: 6) {
            Label("Your data is protected", systemImage: "shield")
              .font(SerenityType.scaledSystem(size: 14, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.71, green: 0.83, blue: 1.0))
            Text("All sensitive information is encrypted with your master password.")
              .font(SerenityType.scaledSystem(size: 13, weight: .regular, design: .rounded))
              .foregroundStyle(Color(red: 0.74, green: 0.82, blue: 0.95))
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(Color(red: 0.10, green: 0.16, blue: 0.30).opacity(0.9))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(Color(red: 0.20, green: 0.42, blue: 0.84).opacity(0.78), lineWidth: 1)
          )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: 480, minHeight: 620)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color(red: 0.06, green: 0.12, blue: 0.24).opacity(0.96),
                  Color(red: 0.05, green: 0.10, blue: 0.21).opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(red: 0.17, green: 0.31, blue: 0.50).opacity(0.7), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 16, x: 0, y: 10)

        Text("Serenity Notes v2.0 • Privacy-First Productivity")
          .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .rounded))
          .foregroundStyle(Color(red: 0.53, green: 0.59, blue: 0.69))
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
    .onAppear {
      passwordFieldFocused = true
    }
  }

  private var unlockDisabled: Bool {
    password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLockedOut || isUnlockingWithPassword || isUnlockingWithBiometrics
  }

  private var isLockedOut: Bool {
    if case .lockedOut = appState.localLockStatus {
      return true
    }
    return false
  }

  private var isBiometricAvailable: Bool {
    if case .available = appState.biometricAvailability {
      return true
    }
    return false
  }

  private var unlockButtonFill: LinearGradient {
    if unlockDisabled {
      return LinearGradient(
        colors: [
          Color(red: 0.49, green: 0.53, blue: 0.60),
          Color(red: 0.43, green: 0.48, blue: 0.56),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
    }

    return LinearGradient(
      colors: [
        Color(red: 0.74, green: 0.77, blue: 0.82),
        Color(red: 0.66, green: 0.70, blue: 0.77),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var attemptsWarning: String? {
    guard case .locked(let attemptsRemaining) = appState.localLockStatus else { return nil }
    guard attemptsRemaining < 5 else { return nil }
    if attemptsRemaining == 1 {
      return "Last attempt before temporary lockout"
    }
    return "\(attemptsRemaining) attempts remaining"
  }

  private var lockoutMessage: String? {
    guard case .lockedOut(let until) = appState.localLockStatus else { return nil }
    let remainingSeconds = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
    if remainingSeconds <= 0 {
      return "Too many failed attempts. Try again shortly."
    }
    return "Too many failed attempts. Try again in \(formattedDuration(seconds: remainingSeconds))."
  }

  private func formattedDuration(seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    if minutes > 0 {
      return "\(minutes)m \(remainder)s"
    }
    return "\(remainder)s"
  }

  @ViewBuilder
  private func statusMessageBox(text: String, tint: Color, border: Color, background: Color) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.top, 2)
      Text(text)
        .font(SerenityType.scaledSystem(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(tint.opacity(0.95))
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .background(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .fill(background.opacity(0.72))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(border.opacity(0.70), lineWidth: 1)
    )
  }

  private func unlockWithPassword() {
    guard !unlockDisabled else { return }

    let submitted = password.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty else { return }

    isUnlockingWithPassword = true
    Task {
      await appState.unlockAppWithPassword(submitted)
      if case .unlocked = appState.localLockStatus {
        password = ""
      }
      isUnlockingWithPassword = false
    }
  }

  private func unlockWithBiometrics() {
    guard isBiometricAvailable else { return }
    guard !isUnlockingWithBiometrics else { return }

    isUnlockingWithBiometrics = true
    Task {
      await appState.unlockAppWithBiometrics()
      isUnlockingWithBiometrics = false
    }
  }
}

private struct GlobalSearchSheet: View {
  @EnvironmentObject private var appState: AppState
  @FocusState private var queryFocused: Bool
  @State private var highlightedResultID: String?
  @State private var keyMonitor: Any?

  private var queryBinding: Binding<String> {
    Binding(
      get: { appState.globalSearchQuery },
      set: { appState.setGlobalSearchQuery($0) }
    )
  }

  private var hasSearchQuery: Bool {
    !appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var displayedResults: [GlobalSearchResult] {
    Array(appState.globalSearchResults.prefix(40))
  }

  private var groupedResults: [(GlobalSearchResultType, [GlobalSearchResult])] {
    GlobalSearchResultType.allCases.compactMap { type in
      let matches = displayedResults.filter { $0.type == type }
      guard !matches.isEmpty else { return nil }
      return (type, matches)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Global Search", systemImage: "magnifyingglass")
          .font(SerenityType.sectionTitle)
        Spacer()
        Text("Cmd+K")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(SerenityPalette.innerCardBackground, in: Capsule())
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(SerenityPalette.textSecondary)
        TextField("Search tasks, projects, journal, or goals", text: queryBinding)
          .textFieldStyle(.plain)
          .font(SerenityType.scaledSystem(size: 16, weight: .regular))
          .focused($queryFocused)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )

      if !hasSearchQuery {
        ContentUnavailableView(
          "Start typing to search",
          systemImage: "text.magnifyingglass",
          description: Text("Use keywords, tags, project names, or journal terms.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appState.globalSearchResults.isEmpty {
        ContentUnavailableView(
          "No matches found",
          systemImage: "magnifyingglass",
          description: Text("Try fewer keywords or a broader term.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(groupedResults, id: \.0.id) { type, results in
              VStack(alignment: .leading, spacing: 8) {
                Text(type.title.uppercased())
                  .font(SerenityType.caption.weight(.semibold))
                  .foregroundStyle(SerenityPalette.textSecondary)
                ForEach(results) { result in
                  Button {
                    appState.selectGlobalSearchResult(result)
                  } label: {
                    GlobalSearchResultRow(
                      result: result,
                      isHighlighted: highlightedResultID == result.id
                    )
                  }
                  .buttonStyle(.plain)
                  .hoverCursor(.pointingHand)
                  .onHover { isHovering in
                    guard isHovering else { return }
                    highlightedResultID = result.id
                  }
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 560)
    .background(SerenityPalette.windowBackground)
    .onAppear {
      queryFocused = true
      syncHighlightedResult()
      installKeyMonitor()
    }
    .onDisappear {
      removeKeyMonitor()
    }
    .onChange(of: appState.globalSearchResults) { _, _ in
      syncHighlightedResult()
    }
    .onChange(of: appState.globalSearchQuery) { _, _ in
      syncHighlightedResult()
    }
    .onSubmit(of: .text) {
      openHighlightedResult()
    }
  }

  private func syncHighlightedResult() {
    guard hasSearchQuery else {
      highlightedResultID = nil
      return
    }

    guard !displayedResults.isEmpty else {
      highlightedResultID = nil
      return
    }

    if let highlightedResultID,
       displayedResults.contains(where: { $0.id == highlightedResultID }) {
      return
    }

    highlightedResultID = displayedResults.first?.id
  }

  private func moveHighlightedResult(step: Int) {
    guard !displayedResults.isEmpty else {
      highlightedResultID = nil
      return
    }

    guard let selectedResultID = highlightedResultID,
          let currentIndex = displayedResults.firstIndex(where: { $0.id == selectedResultID }) else {
      highlightedResultID = step >= 0 ? displayedResults.first?.id : displayedResults.last?.id
      return
    }

    let nextIndex = (currentIndex + step + displayedResults.count) % displayedResults.count
    highlightedResultID = displayedResults[nextIndex].id
  }

  private func openHighlightedResult() {
    guard let result =
      displayedResults.first(where: { $0.id == highlightedResultID }) ?? displayedResults.first else {
      return
    }

    appState.selectGlobalSearchResult(result)
  }

  private func installKeyMonitor() {
#if os(macOS)
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleKeyDown(event)
    }
#endif
  }

  private func removeKeyMonitor() {
#if os(macOS)
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
#endif
  }

#if os(macOS)
  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard appState.isGlobalSearchPresented else { return event }
    guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else {
      return event
    }

    switch event.keyCode {
    case 125: // Down arrow
      moveHighlightedResult(step: 1)
      return nil
    case 126: // Up arrow
      moveHighlightedResult(step: -1)
      return nil
    case 36: // Return
      openHighlightedResult()
      return nil
    case 53: // Escape
      appState.closeGlobalSearch()
      return nil
    default:
      return event
    }
  }
#endif
}

private struct GlobalSearchResultRow: View {
  let result: GlobalSearchResult
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: result.type.systemImage)
        .foregroundStyle(SerenityPalette.accent)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        Text(result.title)
          .font(SerenityType.bodyLarge.weight(.medium))
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineLimit(1)
        Text(result.subtitle.isEmpty ? "No additional details" : result.subtitle)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text(result.type.title)
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(result.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      (isHighlighted ? SerenityPalette.activeItemBackground.opacity(0.18) : SerenityPalette.panelBackground),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isHighlighted ? SerenityPalette.accent.opacity(0.45) : SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private struct HelpCenterArticle: Identifiable {
  let title: String
  let summary: String
  let keywords: [String]
  let shortcut: String?
  let section: AppSection?

  var id: String { title }
}

private struct HelpCenterFAQ: Identifiable {
  let question: String
  let answer: String
  let keywords: [String]

  var id: String { question }
}

private struct HelpCenterSheet: View {
  @EnvironmentObject private var appState: AppState
  @State private var query = ""
#if os(macOS)
  @Environment(\.openSettings) private var openSettings
#endif

  private let articles: [HelpCenterArticle] = [
    HelpCenterArticle(
      title: "Search across everything",
      summary: "Find tasks, projects, journal entries, and goals from one place.",
      keywords: ["search", "global", "find", "lookup"],
      shortcut: "Cmd+K",
      section: nil
    ),
    HelpCenterArticle(
      title: "Manage your tasks",
      summary: "Create, edit, complete, or bulk-update tasks and subtasks.",
      keywords: ["tasks", "subtasks", "bulk", "calendar"],
      shortcut: nil,
      section: .tasks
    ),
    HelpCenterArticle(
      title: "Plan your day",
      summary: "Review due and overdue work in Today view.",
      keywords: ["today", "due", "overdue"],
      shortcut: nil,
      section: .today
    ),
    HelpCenterArticle(
      title: "Capture journal entries",
      summary: "Track reflections, moods, and tags in the Journal.",
      keywords: ["journal", "mood", "entry", "notes"],
      shortcut: nil,
      section: .journal
    ),
    HelpCenterArticle(
      title: "Track goal progress",
      summary: "Use Goals to monitor weekly and project targets.",
      keywords: ["goals", "progress", "target"],
      shortcut: nil,
      section: .goals
    ),
    HelpCenterArticle(
      title: "Configure integrations",
      summary: "Connect Google and GitHub in Settings › Sync & Backend and inspect sync health.",
      keywords: ["integrations", "google", "github", "sync"],
      shortcut: nil,
      section: nil
    ),
    HelpCenterArticle(
      title: "Review AI insights, summaries, and costs",
      summary: "Explore generated insights, recaps, summary exports, and AI usage spend.",
      keywords: ["insights", "ai", "summary", "usage", "cost", "tokens", "billing", "pricing"],
      shortcut: nil,
      section: .insights
    ),
    HelpCenterArticle(
      title: "Security and backend settings",
      summary: "Manage auth, local lock, database tools, and backend selection in Settings.",
      keywords: ["settings", "security", "database", "backend"],
      shortcut: nil,
      section: .settings
    ),
  ]

  private let faqs: [HelpCenterFAQ] = [
    HelpCenterFAQ(
      question: "How do I jump to results without using the mouse?",
      answer: "Open Global Search with Cmd+K, use Up/Down to move selection, Return to open, and Escape to close.",
      keywords: ["keyboard", "search", "navigation", "shortcuts"]
    ),
    HelpCenterFAQ(
      question: "Why is a search result not showing up?",
      answer: "Search indexes current tasks, projects, journal entries, and goals after data refreshes. Run Refresh Data if you recently changed records.",
      keywords: ["search", "index", "missing", "refresh"]
    ),
    HelpCenterFAQ(
      question: "How can I verify local database health?",
      answer: "Use Run Integrity Check in Troubleshooting Actions. The result appears in the Database section diagnostics.",
      keywords: ["database", "integrity", "health", "troubleshoot"]
    ),
    HelpCenterFAQ(
      question: "How do I recover from stale integration status?",
      answer: "Run Refresh Integrations, then open Integrations to review OAuth state and sync diagnostics.",
      keywords: ["integration", "google", "github", "diagnostics"]
    ),
  ]

  private var filteredArticles: [HelpCenterArticle] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return articles }

    return articles.filter { article in
      let haystack = [
        article.title,
        article.summary,
        article.shortcut ?? "",
        article.section?.title ?? "",
        article.keywords.joined(separator: " "),
      ]
        .joined(separator: " ")
        .lowercased()
      return haystack.contains(trimmed)
    }
  }

  private var filteredFAQs: [HelpCenterFAQ] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return faqs }

    return faqs.filter { faq in
      let haystack = [
        faq.question,
        faq.answer,
        faq.keywords.joined(separator: " "),
      ]
        .joined(separator: " ")
        .lowercased()
      return haystack.contains(trimmed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Help Center", systemImage: "questionmark.circle")
          .font(SerenityType.sectionTitle)
        Spacer()
        Text("Cmd+/")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(SerenityPalette.innerCardBackground, in: Capsule())
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(SerenityPalette.textSecondary)
        TextField("Search help topics", text: $query)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          GroupBox("Quick Actions") {
            HStack(spacing: 8) {
              Button("Open Search") {
                appState.closeHelpCenter()
                appState.openGlobalSearch()
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Go to Tasks") {
                appState.setSection(.tasks)
                appState.closeHelpCenter()
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Open Settings") {
                appState.closeHelpCenter()
                appState.requestSettings(tab: .general)
#if os(macOS)
                openSettings()
#endif
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
            .padding(.top, 8)
          }

          GroupBox("Troubleshooting Actions") {
            HStack(spacing: 8) {
              Button("Refresh Data") {
                Task {
                  await appState.refreshCoreWorkflowData()
                  appState.showToast("Core data refreshed")
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Refresh Integrations") {
                Task {
                  await appState.refreshIntegrationDiagnostics()
                  appState.showToast("Integration diagnostics refreshed")
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Refresh AI Workflows") {
                Task {
                  await appState.refreshAIWorkflows()
                  appState.showToast("AI workflows refreshed")
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Run Integrity Check") {
                Task {
                  await appState.runDatabaseIntegrityCheck()
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
            .padding(.top, 8)
          }

          GroupBox("Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
              HelpShortcutRow(action: "Global Search", shortcut: "Cmd+K")
              HelpShortcutRow(action: "Help Center", shortcut: "Cmd+/")
              HelpShortcutRow(action: "Quick Capture", shortcut: "Cmd+Shift+N")
            }
            .padding(.top, 8)
          }

          GroupBox("Frequently Asked Questions") {
            VStack(alignment: .leading, spacing: 10) {
              if filteredFAQs.isEmpty {
                Text("No FAQ entries matched your search.")
                  .foregroundStyle(SerenityPalette.textSecondary)
              } else {
                ForEach(filteredFAQs) { faq in
                  HelpFAQRow(faq: faq)
                }
              }
            }
            .padding(.top, 8)
          }

          GroupBox("Guides") {
            VStack(alignment: .leading, spacing: 10) {
              if filteredArticles.isEmpty {
                Text("No help topics matched your search.")
                  .foregroundStyle(SerenityPalette.textSecondary)
              } else {
                ForEach(filteredArticles) { article in
                  HelpArticleRow(article: article) {
                    guard let section = article.section else { return }
                    appState.closeHelpCenter()
#if os(macOS)
                    if section == .settings {
                      appState.requestSettings(tab: .general)
                      openSettings()
                      return
                    }
#endif
                    appState.setSection(section)
                  }
                }
              }
            }
            .padding(.top, 8)
          }
        }
      }
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 560)
    .background(SerenityPalette.windowBackground)
  }
}

private struct HelpFAQRow: View {
  let faq: HelpCenterFAQ

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(faq.question)
        .font(SerenityType.bodyLarge.weight(.semibold))
      Text(faq.answer)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private struct HelpShortcutRow: View {
  let action: String
  let shortcut: String

  var body: some View {
    HStack {
      Text(action)
      Spacer()
      Text(shortcut)
        .font(SerenityType.caption.weight(.semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SerenityPalette.innerCardBackground, in: Capsule())
    }
  }
}

private struct HelpArticleRow: View {
  let article: HelpCenterArticle
  let openAction: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: article.section?.systemImage ?? "info.circle")
        .frame(width: 18)
        .foregroundStyle(SerenityPalette.accent)

      VStack(alignment: .leading, spacing: 3) {
        Text(article.title)
          .font(SerenityType.bodyLarge.weight(.medium))
        Text(article.summary)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()

      if let shortcut = article.shortcut {
        Text(shortcut)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      if article.section != nil {
        Button("Open", action: openAction)
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private struct ToastBanner: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(SerenityPalette.accent)
      Text(message)
        .font(SerenityType.bodyMedium.weight(.medium))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(
      Capsule()
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
