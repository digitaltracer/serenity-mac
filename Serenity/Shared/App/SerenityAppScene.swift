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
