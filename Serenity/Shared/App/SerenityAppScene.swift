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

private enum SerenityChromeMetrics {
  static let rowHeight: CGFloat = 32
  static let horizontalPadding: CGFloat = 18
  static let controlSpacing: CGFloat = 8
  static let buttonSize: CGFloat = 32
  static let buttonIconSize: CGFloat = 14
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
