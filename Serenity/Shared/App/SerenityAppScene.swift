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
#if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

  var body: some View {
    Group {
      if appState.isLockOverlayVisible {
        LocalLockOverlayView()
      } else {
        appContent
      }
    }
    .environmentObject(appState)
    .environment(\.serenityCompactLayout, isCompactLayout)
    .groupBoxStyle(SerenityPanelGroupBoxStyle())
    .tint(SerenityPalette.accent)
    .foregroundStyle(SerenityPalette.textPrimary)
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
        .environment(\.serenityCompactLayout, isCompactLayout)
    }
    .sheet(isPresented: $appState.isHelpCenterPresented, onDismiss: {
      appState.closeHelpCenter()
    }) {
      HelpCenterSheet()
        .environmentObject(appState)
        .environment(\.serenityCompactLayout, isCompactLayout)
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

  /// Only an iPhone-sized surface is compact. Regular-width iPad keeps the
  /// split view, so this is a size-class question rather than a platform one.
  private var isCompactLayout: Bool {
#if os(iOS)
    horizontalSizeClass == .compact
#else
    false
#endif
  }

  @ViewBuilder
  private var appContent: some View {
#if os(iOS)
    if isCompactLayout {
      SerenityPhoneTabShell()
    } else {
      splitViewContent
    }
#else
    splitViewContent
#endif
  }

  private var splitViewContent: some View {
    NavigationSplitView(columnVisibility: $splitViewVisibility) {
      SerenitySidebar(
        selectedSection: Binding(
          get: { appState.selectedSection },
          set: { appState.setSection($0) }
        )
      )
      .navigationSplitViewColumnWidth(min: 214, ideal: 228, max: 246)
    } detail: {
      ZStack {
        SerenityDetailBackground()
        detailContent
      }
    }
    .navigationSplitViewStyle(.balanced)
#if os(macOS)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        // The window toolbar fills from the leading edge, so this flexible
        // space is what parks the controls opposite the page header.
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
    }
    .toolbarBackground(.hidden, for: .windowToolbar)
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
      } else {
        ContentUnavailableView("Select a section", systemImage: "sidebar.left")
      }
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

private extension AppThemePreference {
  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

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

  var moreRowDetail: String {
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

private struct SerenityDetailBackground: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          SerenityPalette.windowBackground,
          SerenityPalette.windowBackgroundDepth,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      Circle()
        .fill(SerenityPalette.detailAccentGlow)
        .frame(width: 520, height: 520)
        .blur(radius: 80)
        .offset(x: 220, y: -250)

      Circle()
        .fill(SerenityPalette.ambientGlow)
        .frame(width: 560, height: 560)
        .blur(radius: 100)
        .offset(x: 0, y: 260)
    }
    .allowsHitTesting(false)
  }
}

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

#if os(iOS)
/// The phone shell. Tabs cover the daily surfaces and everything else is pushed
/// from More. `AppState.selectedSection` stays the source of truth, so global
/// search, Help Center destinations and the last-section restore keep working.
enum SerenityPhoneTab: String, CaseIterable, Identifiable {
  case home
  case actionHub
  case journal
  case goals
  case more

  var id: String { rawValue }

  /// The section the tab lands on. More has a list of its own instead.
  var rootSection: AppSection? {
    switch self {
    case .home:
      return .home
    case .actionHub:
      return .actionHub
    case .journal:
      return .journal
    case .goals:
      return .goals
    case .more:
      return nil
    }
  }

  var title: String {
    switch self {
    case .home:
      return "Home"
    case .actionHub:
      return "Hub"
    case .journal:
      return "Journal"
    case .goals:
      return "Goals"
    case .more:
      return "More"
    }
  }

  var systemImage: String {
    rootSection?.systemImage ?? "ellipsis"
  }

  /// Projects has no tab of its own but belongs under ActionHub, which is where
  /// projects are managed. Every other tabless section belongs to More.
  static func containing(_ section: AppSection?) -> SerenityPhoneTab {
    switch section {
    case .home:
      return .home
    case .actionHub, .projects:
      return .actionHub
    case .journal:
      return .journal
    case .goals:
      return .goals
    default:
      return .more
    }
  }
}

private struct SerenityPhoneTabShell: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    TabView(selection: tabSelection) {
      ForEach(SerenityPhoneTab.allCases) { tab in
        tabStack(tab)
          .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
          }
          .tag(tab)
      }
    }
  }

  private var tabSelection: Binding<SerenityPhoneTab> {
    Binding(
      get: { SerenityPhoneTab.containing(appState.selectedSection) },
      // Re-selecting the active tab clears its push, which is the standard
      // tap-the-tab-again-to-go-back behaviour.
      set: { appState.setSection($0.rootSection) }
    )
  }

  private func tabStack(_ tab: SerenityPhoneTab) -> some View {
    NavigationStack {
      Group {
        if let root = tab.rootSection {
          SectionView(section: root)
        } else {
          MorePhoneList()
        }
      }
      // A background rather than a ZStack sibling: the backdrop's blur circles
      // are wider than a phone, and as a sibling they size the stack.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { SerenityDetailBackground() }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(isPresented: pushBinding(tab)) {
        Group {
          if let pushed = pushedSection(tab) {
            SectionView(section: pushed)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SerenityDetailBackground() }
        .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  /// A tab pushes when the selected section is one it owns but is not its own
  /// root: Projects under ActionHub, and everything under More.
  private func pushedSection(_ tab: SerenityPhoneTab) -> AppSection? {
    guard let selected = appState.selectedSection else { return nil }
    guard SerenityPhoneTab.containing(selected) == tab else { return nil }
    guard selected != tab.rootSection else { return nil }
    return selected
  }

  private func pushBinding(_ tab: SerenityPhoneTab) -> Binding<Bool> {
    Binding(
      get: { pushedSection(tab) != nil },
      set: { presented in
        guard !presented else { return }
        appState.setSection(tab.rootSection)
      }
    )
  }
}

private struct MorePhoneList: View {
  @EnvironmentObject private var appState: AppState

  private let sections: [AppSection] = [.standup, .insights, .aiSummaries, .integrations, .settings]

  var body: some View {
    SerenityThemedScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("More")
          .font(SerenityType.scaledSystem(size: 24, weight: .semibold))
          .padding(.top, 4)

        VStack(spacing: 8) {
          ForEach(sections) { section in
            row(section.title, systemImage: section.systemImage) {
              appState.setSection(section)
            }
          }
        }

        VStack(spacing: 8) {
          row("Search", systemImage: "magnifyingglass") {
            appState.openGlobalSearch()
          }
          row("Help Center", systemImage: "questionmark.circle") {
            appState.openHelpCenter()
          }
          row(
            "Appearance",
            systemImage: appState.themePreference.topBarSymbol,
            detail: appState.themePreference.moreRowDetail
          ) {
            cycleThemePreference()
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private func row(
    _ title: String,
    systemImage: String,
    detail: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(SerenityType.scaledSystem(size: 14, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
          .frame(width: 28, height: 28)
          .background(SerenityPalette.headerIconBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        Text(title)
          .font(SerenityType.bodyLarge)

        Spacer(minLength: 8)

        if let detail {
          Text(detail)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        } else {
          Image(systemName: "chevron.right")
            .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }
      .padding(.horizontal, 14)
      .frame(minHeight: SerenityTouchMetrics.minimumTarget + 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func cycleThemePreference() {
    let all = AppThemePreference.allCases
    guard let currentIndex = all.firstIndex(of: appState.themePreference) else {
      appState.setThemePreference(.system)
      return
    }

    appState.setThemePreference(all[(currentIndex + 1) % all.count])
  }
}
#endif

private struct TopBarButton: View {
  @Environment(\.serenityCompactLayout) private var compactLayout
  @State private var hovered = false
  let symbol: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(SerenityType.scaledSystem(size: compactLayout ? 17 : SerenityChromeMetrics.buttonIconSize, weight: .semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
        .frame(width: buttonSize, height: buttonSize)
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

  private var buttonSize: CGFloat {
    compactLayout ? SerenityTouchMetrics.minimumTarget : SerenityChromeMetrics.buttonSize
  }
}

private struct SerenitySidebar: View {
  @Binding var selectedSection: AppSection?
  @State private var hoveredSection: AppSection?

  private let primarySections: [AppSection] = [.home, .actionHub, .standup, .journal, .goals, .insights, .aiSummaries]
  private let systemSections: [AppSection] = [.integrations, .settings]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarHeader

      VStack(alignment: .leading, spacing: 0) {
        Text("NAVIGATION")
          .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
          .tracking(1.1)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 18)
          .padding(.top, 16)

        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(primarySections) { section in
              navRow(section)
            }
          }
          .padding(.horizontal, 14)
          .padding(.top, 10)
        }

        Spacer(minLength: 0)

        Divider()
          .overlay(SerenityPalette.thinBorder)
          .padding(.top, 8)

        VStack(alignment: .leading, spacing: 4) {
          ForEach(systemSections) { section in
            navRow(section)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
    .background(SerenityPalette.sidebarBackground)
  }

  private var sidebarHeader: some View {
    HStack(spacing: 10) {
      Image("SerenityAppMark")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: SerenityChromeMetrics.sidebarHeaderIconSize, height: SerenityChromeMetrics.sidebarHeaderIconSize)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text("Serenity Notes")
          .font(SerenityType.bodyLarge.weight(.semibold))
      }
      Spacer()
    }
    .padding(.horizontal, 18)
    .padding(.top, SerenityChromeMetrics.sidebarHeaderTopPadding)
    .padding(.bottom, SerenityChromeMetrics.sidebarHeaderBottomPadding)
    .background(SerenityPalette.sidebarHeaderBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(SerenityPalette.thinBorder)
        .frame(height: 1)
    }
  }

  private func navRow(_ section: AppSection) -> some View {
    let selected = isSelected(section)
    let hovered = hoveredSection == section

    return Button {
      selectedSection = section
    } label: {
      HStack(spacing: 10) {
        Image(systemName: section.systemImage)
          .frame(width: 18)
          .font(SerenityType.scaledSystem(size: 14, weight: .semibold))

        Text(section.title)
          .font(SerenityType.bodyLarge.weight(.medium))

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .foregroundStyle(selected ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textSecondary)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(selected ? SerenityPalette.activeItemBackground : (hovered ? SerenityPalette.panelBackgroundRaised : .clear))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(hovered && !selected ? SerenityPalette.thinBorder : .clear, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .onHover { hovering in
      hoveredSection = hovering ? section : nil
    }
  }

  private func isSelected(_ section: AppSection) -> Bool {
    selectedSection == section
  }
}

private extension AppSection {
  var subtitle: String {
    switch self {
    case .home:
      return "Boost productivity and mindfulness from one workspace"
    case .actionHub:
      return "Task and project control center"
    case .journal:
      return "Capture notes, mood, and reflections"
    case .goals:
      return "Track progress against measurable targets"
    case .projects:
      return "Organize work across active initiatives"
    case .integrations:
      return "Manage external providers and sync health"
    case .insights:
      return "AI analysis, recaps, and usage intelligence"
    case .standup:
      return "Build today's stand-up from what actually happened, then say it"
    case .aiSummaries:
      return "Generate and view AI-powered summaries of your tasks and journal entries"
    case .settings:
      return "Appearance, AI provider, spend, app lock, and database controls"
    }
  }
}

private enum SerenityContentDensity {
  case regular
  case compact
  case tight
  case phone

  static func from(width: CGFloat) -> SerenityContentDensity {
    // `.tight` was tuned for a narrow Mac window, not a 390pt screen, so the
    // phone gets its own tier rather than the bottom of the desktop ramp.
    if width < 480 {
      return .phone
    }

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
    case .phone: return 14
    }
  }

  var contentPadding: CGFloat {
    switch self {
    case .regular: return 22
    case .compact: return 18
    case .tight: return 14
    case .phone: return 16
    }
  }

  var contentBottomPadding: CGFloat {
    switch self {
    case .regular: return 12
    case .compact: return 10
    case .tight: return 8
    case .phone: return 12
    }
  }

  /// Deliberately wider than `sectionSpacing`: the title needs to read as the
  /// screen's header, not as the first row of the content.
  var pageHeaderSpacing: CGFloat {
    switch self {
    case .regular: return 38
    case .compact: return 34
    case .tight: return 32
    case .phone: return 20
    }
  }

  var sectionIconContainer: CGFloat {
    switch self {
    case .regular: return 50
    case .compact: return 44
    case .tight: return 40
    case .phone: return 40
    }
  }

  var sectionIconSize: CGFloat {
    switch self {
    case .regular: return 19
    case .compact: return 17
    case .tight: return 15
    case .phone: return 19
    }
  }

  var sectionTitleFont: Font {
    switch self {
    case .regular: return SerenityType.scaledSystem(size: 28, weight: .semibold)
    case .compact: return SerenityType.scaledSystem(size: 24, weight: .semibold)
    case .tight: return SerenityType.scaledSystem(size: 21, weight: .medium)
    case .phone: return SerenityType.scaledSystem(size: 24, weight: .semibold)
    }
  }

  var sectionSubtitleFont: Font {
    switch self {
    case .regular: return SerenityType.scaledSystem(size: 17, weight: .regular)
    case .compact: return SerenityType.scaledSystem(size: 15, weight: .regular)
    case .tight: return SerenityType.scaledSystem(size: 14, weight: .regular)
    case .phone: return SerenityType.scaledSystem(size: 14, weight: .regular)
    }
  }

  var quickCapturePromptHorizontalPadding: CGFloat {
    switch self {
    case .regular: return 24
    case .compact: return 18
    case .tight: return 14
    case .phone: return 14
    }
  }

  var quickCapturePromptVerticalPadding: CGFloat {
    switch self {
    case .regular: return 22
    case .compact: return 18
    case .tight: return 14
    case .phone: return 14
    }
  }

  var quickCaptureEditorFontSize: CGFloat {
    switch self {
    case .regular: return 18
    case .compact: return 17
    case .tight: return 16
    case .phone: return 16
    }
  }

  var quickCaptureEditorPadding: CGFloat {
    switch self {
    case .regular: return 16
    case .compact: return 14
    case .tight: return 12
    case .phone: return 12
    }
  }

  var quickCaptureEditorHeight: CGFloat {
    switch self {
    case .regular: return 156
    case .compact: return 132
    case .tight: return 116
    case .phone: return 92
    }
  }

  var quickCaptureFooterPaddingVertical: CGFloat {
    switch self {
    case .regular: return 12
    case .compact: return 10
    case .tight: return 8
    case .phone: return 8
    }
  }

}

private struct SectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
#if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

  private enum PendingEditorAction {
    case close
    case open(TaskEntity)
  }

  let section: AppSection

  @State private var editorDraft: TaskEditorDraft?
  @State private var pendingEditorAction: PendingEditorAction?
  @State private var showUnsavedChangesConfirmation = false

  var body: some View {
    presentedSectionContent
      .confirmationDialog(
        "Save changes before continuing?",
        isPresented: $showUnsavedChangesConfirmation,
        titleVisibility: .visible
      ) {
        Button("Save") {
          let action = pendingEditorAction ?? .close
          Task {
            _ = await saveEditor(then: action)
          }
        }
        Button("Discard Changes", role: .destructive) {
          applyPendingEditorAction()
        }
        Button("Cancel", role: .cancel) {
          pendingEditorAction = nil
        }
      } message: {
        Text("This task has unsaved edits.")
      }
      .animation(.easeInOut(duration: 0.2), value: section)
      .onAppear {
        AppLogger.info("Rendered section: \(section.rawValue)")
        if section == .insights || section == .aiSummaries || section == .standup || section == .settings {
          Task {
            await appState.refreshAIWorkflows()
          }
        }

        if [.home, .actionHub, .standup, .journal, .goals, .projects, .integrations, .settings].contains(section) {
          Task {
            await appState.refreshCoreWorkflowData()
          }
        }
      }
  }

  /// The page title sits outside the scroll view so it reads as the screen's
  /// title rather than as the first thing on it — on the Mac it rises into the
  /// transparent toolbar row, level with the controls parked on the right.
  private var sectionContent: some View {
    GeometryReader { proxy in
      let density = SerenityContentDensity.from(width: proxy.size.width)

      VStack(alignment: .leading, spacing: 0) {
        pageHeader(density: density)
          .padding(.top, Self.headerTopPadding(density))
          .padding(.leading, density.contentPadding)
          .padding(.trailing, density.contentPadding + trailingScrollbarGutter)
          .padding(.bottom, Self.headerScrollGap)

        sectionScrollView(density: density) {
          VStack(alignment: .leading, spacing: density.sectionSpacing) {
            switch section {
            case .home:
              HomeSectionView(density: density, onEditTask: openTaskEditor)
            case .actionHub:
              ActionHubSectionView(onEditTask: openTaskEditor)
            case .journal:
              JournalSectionView()
            case .goals:
              GoalsSectionView()
            case .projects:
              ProjectsSectionView()
            case .integrations:
              IntegrationsSectionView()
            case .insights:
              InsightsSectionView()
            case .standup:
              StandupSectionView()
            case .aiSummaries:
              AISummariesSectionView()
            case .settings:
              SettingsSectionView()
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.top, density.pageHeaderSpacing + density.contentPadding - Self.headerScrollGap)
          .padding(.leading, density.contentPadding)
          .padding(.trailing, density.contentPadding + trailingScrollbarGutter)
          .padding(.bottom, density.contentBottomPadding)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
#if os(macOS)
    .ignoresSafeArea(.container, edges: .top)
#endif
  }

  /// Pull to refresh is a phone gesture; the Mac refreshes on section entry.
  @ViewBuilder
  private func sectionScrollView<Content: View>(
    density: SerenityContentDensity,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if compactLayout {
      SerenityThemedScrollView(content: content)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
          await refreshSection()
        }
    } else {
      SerenityThemedScrollView(content: content)
    }
  }

  @MainActor
  private func refreshSection() async {
    if section == .insights || section == .aiSummaries || section == .standup || section == .settings {
      await appState.refreshAIWorkflows()
    }

    if [.home, .actionHub, .standup, .journal, .goals, .projects, .integrations, .settings].contains(section) {
      await appState.refreshCoreWorkflowData()
    }
  }

  @ViewBuilder
  private func pageHeader(density: SerenityContentDensity) -> some View {
    if compactLayout {
      // The phone has no top bar, so search rides with the page title. Help and
      // the theme toggle live in More.
      HStack(alignment: .center, spacing: 8) {
        headerTitle(density: density)

        TopBarButton(symbol: "magnifyingglass", accessibilityLabel: "Search") {
          appState.openGlobalSearch()
        }
      }
    } else {
      headerTitle(density: density)
    }
  }

  @ViewBuilder
  private func headerTitle(density: SerenityContentDensity) -> some View {
    if section == .home {
      HomeSectionHeader()
    } else {
      sectionHeader(density: density)
    }
  }

  /// Reserves room for the hover scrollbar, which a phone does not draw, so on
  /// compact the content sits evenly between both edges.
  private var trailingScrollbarGutter: CGFloat {
    compactLayout ? 0 : 14
  }

  /// Most of the gap under the title belongs *inside* the scroll view. The
  /// capture card's halo bleeds well past its bounds and the scroll view clips,
  /// so a boundary sitting close to the card sliced that halo into a hard line.
  private static let headerScrollGap: CGFloat = 10

  private static func headerTopPadding(_ density: SerenityContentDensity) -> CGFloat {
#if os(macOS)
    // Sits the title row on the band the toolbar controls occupy, a hair lower
    // so the glyphs are not flush against the window edge.
    return 16
#else
    return density.contentPadding
#endif
  }

#if os(iOS)
  @ViewBuilder
  private var presentedSectionContent: some View {
    if horizontalSizeClass == .regular {
      sectionContent
        .inspector(isPresented: editorIsPresented) {
          taskEditorContent
            .inspectorColumnWidth(min: 340, ideal: 400, max: 480)
        }
    } else {
      // A sheet rather than a push: the list stays behind the editor, a drag
      // dismisses it, and the tab's own navigationDestination stays free.
      sectionContent
        .sheet(isPresented: editorIsPresented) {
          NavigationStack {
            taskEditorContent
          }
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
        }
    }
  }
#else
  private var presentedSectionContent: some View {
    sectionContent
      .inspector(isPresented: editorIsPresented) {
        taskEditorContent
          .inspectorColumnWidth(min: 340, ideal: 400, max: 480)
      }
  }
#endif

  private var editorIsPresented: Binding<Bool> {
    Binding(
      get: { editorDraft != nil },
      set: { presented in
        if !presented {
          requestCloseEditor()
        }
      }
    )
  }

  @ViewBuilder
  private var taskEditorContent: some View {
    if let openDraft = editorDraft {
      TaskEditorView(
        // The inspector lays its content out once more after the draft is
        // cleared, so this binding has to survive the nil rather than trap.
        draft: Binding(
          get: { editorDraft ?? openDraft },
          set: { updated in
            guard editorDraft != nil else { return }
            editorDraft = updated
          }
        ),
        availableProjects: appState.projects.filter { !$0.archived },
        onCancel: requestCloseEditor,
        onSave: {
          await saveEditor(then: .close)
        }
      )
    }
  }

  private func openTaskEditor(_ task: TaskEntity) {
    guard editorDraft?.id != task.id else { return }
    guard editorDraft?.isDirty == true else {
      editorDraft = TaskEditorDraft(task: task)
      return
    }

    pendingEditorAction = .open(task)
    showUnsavedChangesConfirmation = true
  }

  private func requestCloseEditor() {
    guard editorDraft?.isDirty == true else {
      editorDraft = nil
      return
    }

    pendingEditorAction = .close
    showUnsavedChangesConfirmation = true
  }

  @MainActor
  private func saveEditor(then action: PendingEditorAction) async -> Bool {
    guard let draft = editorDraft else { return false }
    let saved = await appState.updateTask(
      id: draft.id,
      title: draft.title,
      description: draft.description,
      priority: draft.priority,
      dueDate: draft.hasDueDate ? draft.dueDate : nil,
      projectID: draft.selectedProjectID,
      tags: draft.savedTags,
      subtasks: draft.savedSubtasks,
      recurring: draft.savedRecurrence
    )

    if saved {
      applyPendingEditorAction(action)
    }
    return saved
  }

  private func applyPendingEditorAction(_ action: PendingEditorAction? = nil) {
    let action = action ?? pendingEditorAction
    pendingEditorAction = nil

    switch action {
    case .close:
      editorDraft = nil
    case .open(let task):
      editorDraft = TaskEditorDraft(task: task)
    case nil:
      break
    }
  }

  private func sectionHeader(density: SerenityContentDensity) -> some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: density.sectionIconContainer, height: density.sectionIconContainer)
        Image(systemName: section.systemImage)
          .font(SerenityType.scaledSystem(size: density.sectionIconSize, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
      }

      // One line: the sidebar already names the section, so the subtitle only
      // restated it. `AppSection.subtitle` still backs Help Center and search.
      Text(section.title)
        .font(density.sectionTitleFont)

      Spacer()
    }
    .padding(.vertical, 4)
  }
}

/// The keys the command menu takes over while it is open. The editor asks
/// before acting on them, so nothing is intercepted when no menu is showing.
enum CaptureCommandMenuKey: Equatable, Sendable {
  case up
  case down
  case complete
  case dismiss
}

#if os(macOS)
private final class QuickCaptureTextView: NSTextView {
  var focusChanged: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      focusChanged?(true)
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      focusChanged?(false)
    }
    return accepted
  }
}

private final class QuickCaptureContainerScrollView: NSScrollView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .iBeam)
  }

  override func mouseDown(with event: NSEvent) {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)

    if let textView = documentView as? NSTextView {
      window?.makeFirstResponder(textView)
    }
    super.mouseDown(with: event)
  }
}

private struct QuickCaptureEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let fontSize: CGFloat
  var commandKey: (CaptureCommandMenuKey) -> Bool = { _ in false }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = QuickCaptureContainerScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.backgroundColor = .clear

    let textView = QuickCaptureTextView()
    textView.delegate = context.coordinator
    textView.focusChanged = { focused in
      if context.coordinator.isFocused != focused {
        context.coordinator.isFocused = focused
      }
    }
    textView.string = text
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFindBar = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.isContinuousSpellCheckingEnabled = true
    textView.textContainerInset = NSSize(width: 0, height: 0)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
    textView.font = .systemFont(ofSize: SerenityType.scaledSize(fontSize), weight: .regular)
    textView.textColor = NSColor(SerenityPalette.textPrimary)
    textView.insertionPointColor = NSColor(SerenityPalette.textPrimary)
    textView.typingAttributes[.foregroundColor] = NSColor(SerenityPalette.textPrimary)

    scrollView.documentView = textView
    context.coordinator.textView = textView

    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? QuickCaptureTextView else { return }

    context.coordinator.commandKey = commandKey

    let contentSize = nsView.contentView.bounds.size
    let targetHeight = max(contentSize.height, textView.frame.height)
    if textView.frame.width != contentSize.width || textView.frame.height < contentSize.height {
      textView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: targetHeight)
    }
    textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

    if textView.string != text {
      textView.string = text
    }

    textView.font = .systemFont(ofSize: SerenityType.scaledSize(fontSize), weight: .regular)
    textView.textColor = NSColor(SerenityPalette.textPrimary)
    textView.insertionPointColor = NSColor(SerenityPalette.textPrimary)
    textView.typingAttributes[.foregroundColor] = NSColor(SerenityPalette.textPrimary)

    if isFocused {
      if nsView.window?.firstResponder !== textView {
        nsView.window?.makeFirstResponder(textView)
      }
    } else if nsView.window?.firstResponder === textView {
      nsView.window?.makeFirstResponder(nil)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var isFocused: Bool
    var commandKey: (CaptureCommandMenuKey) -> Bool = { _ in false }
    weak var textView: QuickCaptureTextView?

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    /// Return completes a highlighted command rather than breaking the line,
    /// which is why the menu closes on Escape the moment it is unwanted.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      let key: CaptureCommandMenuKey?
      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        key = .up
      case #selector(NSResponder.moveDown(_:)):
        key = .down
      case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
        key = .complete
      case #selector(NSResponder.cancelOperation(_:)):
        key = .dismiss
      default:
        key = nil
      }
      guard let key else { return false }
      return commandKey(key)
    }

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      text = textView.string
    }

    func textDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      isFocused = false
    }
  }
}
#else
private struct QuickCaptureEditor: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  let fontSize: CGFloat
  /// Unread here: the command menu is tapped on iPhone, never keyed.
  var commandKey: (CaptureCommandMenuKey) -> Bool = { _ in false }

  @FocusState private var editorFocused: Bool

  var body: some View {
    TextEditor(text: $text)
      .font(SerenityType.scaledSystem(size: fontSize, weight: .regular))
      .foregroundStyle(SerenityPalette.textPrimary)
      .scrollContentBackground(.hidden)
      .focused($editorFocused)
      .onAppear {
        editorFocused = isFocused
      }
      .onChange(of: editorFocused) { _, newValue in
        isFocused = newValue
      }
      .onChange(of: isFocused) { _, newValue in
        editorFocused = newValue
      }
      .toolbar {
        // Without this the software keyboard has no dismiss affordance: the
        // editor accepts newlines, so Return cannot close it.
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()

          Button("Done") {
            editorFocused = false
          }
        }
      }
  }
}
#endif

private struct HomeSectionHeader: View {
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter
  }()

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: "house")
        .font(SerenityType.scaledSystem(size: 22, weight: .semibold))
        .foregroundStyle(SerenityPalette.accent)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Home")
          .font(SerenityType.pageTitle)
        Text("Focus on what matters most right now")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(Self.dateFormatter.string(from: Date()))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary.opacity(0.8))
      }

      Spacer()
    }
  }
}

private struct HomeSectionView: View {
  let density: SerenityContentDensity
  let onEditTask: (TaskEntity) -> Void

  @EnvironmentObject private var appState: AppState

  @State private var quickCapture = ""
  @State private var submitting = false
  @State private var quickCaptureFocused = false
  @State private var selectedQuickCaptureCredentialID = ""
  @State private var commandInput: CaptureCommandInput = .none
  @State private var commandMenuSelection = 0
  @State private var commandMenuDismissed = false
  @State private var standupPending = 0

  private let nativeQuickCaptureProviderID = "native"
  private static let quickCapturePreviewDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: density.sectionSpacing) {
      quickCaptureCard
      if let preview = appState.pendingCaptureDraft {
        captureDraftPreview(preview)
      }
      if let preview = appState.pendingAIQuickCapturePreview {
        aiQuickCapturePreview(preview)
      }
      if standupPending > 0 {
        standupStrip
      }
      TodayOverviewView(onEditTask: onEditTask)
    }
    .task(id: appState.tasks.count) {
      standupPending = await appState.standupPendingCount()
    }
    .onChange(of: appState.shouldFocusQuickCapture) { _, requested in
      guard requested else { return }
      quickCaptureFocused = true
      appState.shouldFocusQuickCapture = false
    }
    .onChange(of: quickCapture) { _, text in
      commandInput = CaptureCommandParser.inspect(text)
      commandMenuSelection = 0
      commandMenuDismissed = false
    }
  }

  /// Only appears when there is something to report, so it is not dead
  /// furniture on a quiet morning.
  private var standupStrip: some View {
    Button {
      appState.setSection(.standup)
    } label: {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SerenityPalette.headerIconBackground)
            .frame(width: 38, height: 38)
          Image(systemName: "mic")
            .font(SerenityType.scaledSystem(size: 17, weight: .semibold))
            .foregroundStyle(SerenityPalette.accent)
        }

        VStack(alignment: .leading, spacing: 3) {
          Text("Ready for stand-up?")
            .font(SerenityType.bodyLarge.weight(.semibold))
            .foregroundStyle(SerenityPalette.textPrimary)
          Text("\(standupPending) thing\(standupPending == 1 ? "" : "s") to go through.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 8)

        Text("Build it")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textOnInteractiveSurface)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(SerenityPalette.primaryActionBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.accent.opacity(0.3), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .accessibilityLabel("Build today's stand-up from \(standupPending) items")
  }

  private var commandPreview: CaptureCommandPreview? {
    guard case .command(let preview) = commandInput else { return nil }
    return preview
  }

  /// The menu is only ever offered for a slash still being spelled, and only
  /// while the field has focus — it is an aid to typing, not a panel.
  private var commandMenuMatches: [CaptureCommandKind] {
    guard case .menu(let query) = commandInput, quickCaptureFocused, !commandMenuDismissed else {
      return []
    }
    return CaptureCommandKind.matching(query)
  }

  private var quickCaptureCard: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 0)
          .fill(
            LinearGradient(
              colors: [
                SerenityPalette.panelBackgroundRaised.opacity(0.9),
                SerenityPalette.quickCaptureTint,
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )

        if quickCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !quickCaptureFocused {
          Text("Speak naturally. Example: \"Remind me to call mom tomorrow afternoon.\"")
            .font(SerenityType.bodyLarge)
            .foregroundStyle(SerenityPalette.textSecondary.opacity(0.72))
            .padding(.horizontal, density.quickCapturePromptHorizontalPadding)
            .padding(.vertical, density.quickCapturePromptVerticalPadding)
            .allowsHitTesting(false)
        }

        QuickCaptureEditor(
          text: $quickCapture,
          isFocused: $quickCaptureFocused,
          fontSize: density.quickCaptureEditorFontSize,
          commandKey: handleCommandMenuKey
        )
          .padding(density.quickCaptureEditorPadding)
          .frame(height: density.quickCaptureEditorHeight)
      }

      if let preview = commandPreview {
        captureChipStrip(preview)
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          Text(quickCaptureHelperText)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)

          Spacer()

          quickCaptureProviderDropdown
          submitButton
        }

        VStack(alignment: .leading, spacing: 10) {
          Text(quickCaptureHelperText)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)

          HStack {
            Spacer()
            quickCaptureProviderDropdown
            submitButton
          }
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, density.quickCaptureFooterPaddingVertical)
      .background(
        LinearGradient(
          colors: [
            SerenityPalette.panelBackgroundRaised.opacity(0.92),
            SerenityPalette.quickCaptureTint.opacity(0.72),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(quickCaptureFocused ? SerenityPalette.accent.opacity(0.7) : SerenityPalette.border.opacity(0.95), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(color: quickCaptureFocused ? SerenityPalette.accent.opacity(0.42) : SerenityPalette.accent.opacity(0.28), radius: quickCaptureFocused ? 30 : 24)
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.highlightStroke, lineWidth: 1)
        .blur(radius: 4)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      let matches = commandMenuMatches
      if !matches.isEmpty {
        commandMenu(matches)
          .offset(x: 18, y: 58)
      }
    }
    // The menu hangs past the card, so the card has to outrank the rows below.
    .zIndex(commandMenuMatches.isEmpty ? 0 : 1)
    .animation(.easeInOut(duration: 0.18), value: quickCaptureFocused)
  }

  private func commandMenu(_ matches: [CaptureCommandKind]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(matches.enumerated()), id: \.element) { index, kind in
        Button {
          completeCommand(kind)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: kind.symbolName)
              .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
              .foregroundStyle(SerenityPalette.accent)
              .frame(width: 26, height: 26)
              .background(SerenityPalette.headerIconBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
              Text(kind.token)
                .font(SerenityType.body.weight(.semibold))
                .foregroundStyle(SerenityPalette.textPrimary)
              Text(kind.summary)
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
            }

            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            index == commandMenuSelection ? SerenityPalette.activeItemBackground : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
      }

#if os(macOS)
      Text("↑↓ choose · Tab complete · Esc dismiss")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(SerenityPalette.thinBorder)
            .frame(height: 1)
        }
#endif
    }
    .padding(6)
    .frame(width: 340, alignment: .leading)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
  }

  /// Returns true when the menu took the key, which is what stops it reaching
  /// the text. With no menu open every key falls through untouched.
  private func handleCommandMenuKey(_ key: CaptureCommandMenuKey) -> Bool {
    let matches = commandMenuMatches
    guard !matches.isEmpty else { return false }

    switch key {
    case .up:
      commandMenuSelection = (commandMenuSelection - 1 + matches.count) % matches.count
    case .down:
      commandMenuSelection = (commandMenuSelection + 1) % matches.count
    case .complete:
      completeCommand(matches[min(commandMenuSelection, matches.count - 1)])
    case .dismiss:
      commandMenuDismissed = true
    }
    return true
  }

  /// The trailing space matters: it closes the menu and leaves the caret where
  /// a link is about to be pasted.
  private func completeCommand(_ kind: CaptureCommandKind) {
    quickCapture = "\(kind.token) "
    quickCaptureFocused = true
  }

  private enum CaptureChipTone {
    case command
    case resolved
    case refused
    case waiting
  }

  private struct CaptureChip: Identifiable {
    var id: Int
    var text: String
    var tone: CaptureChipTone
    var symbol: String?
  }

  private func captureChips(_ preview: CaptureCommandPreview) -> [CaptureChip] {
    var entries: [(String, CaptureChipTone, String?)] = [
      (preview.kind.token, .command, preview.kind.symbolName)
    ]

    // Past the limit the links stop being worth naming one by one — how many
    // there are is the whole problem.
    if preview.exceedsLimit {
      entries.append(("\(preview.references.count) links", .refused, nil))
    } else {
      entries.append(contentsOf: preview.references.map { ($0.label, .resolved, nil) })
    }
    entries.append(contentsOf: preview.rejections.map { ($0.reason.chipLabel, .refused, nil) })

    if preview.references.isEmpty, preview.rejections.isEmpty, !preview.exceedsLimit {
      if let settled = preview.settledError {
        entries.append((settled.chipLabel, .refused, nil))
      } else {
        entries.append(
          (preview.kind == .slack ? "paste a message link" : "paste a pull request link", .waiting, nil)
        )
      }
    }

    return entries.enumerated().map {
      CaptureChip(id: $0.offset, text: $0.element.0, tone: $0.element.1, symbol: $0.element.2)
    }
  }

  /// What the command was understood to mean, shown while it is still editable.
  /// Every refusal here is one the parser already knew how to make — this is
  /// only the difference between hearing it now and hearing it after a submit.
  private func captureChipStrip(_ preview: CaptureCommandPreview) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      SerenityFlowLayout(spacing: 8) {
        ForEach(captureChips(preview)) { chip in
          captureChipView(chip)
        }

        if preview.contextWordCount > 0 {
          Text("plus \(preview.contextWordCount) word\(preview.contextWordCount == 1 ? "" : "s") of context")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.vertical, 4)
        }
      }

      if let message = preview.settledError?.errorDescription {
        Text(message)
          .font(SerenityType.caption)
          .foregroundStyle(Color.red.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackgroundRaised.opacity(0.55))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(SerenityPalette.thinBorder)
        .frame(height: 1)
    }
  }

  private func captureChipView(_ chip: CaptureChip) -> some View {
    HStack(spacing: 5) {
      if let symbol = chip.symbol {
        Image(systemName: symbol)
          .font(SerenityType.scaledSystem(size: 10, weight: .semibold))
      }
      Text(chip.text)
        .font(SerenityType.caption)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .foregroundStyle(chipForeground(chip.tone))
    .background(chipBackground(chip.tone), in: Capsule())
    .overlay(Capsule().stroke(chipBorder(chip.tone), lineWidth: 1))
  }

  private func chipForeground(_ tone: CaptureChipTone) -> Color {
    switch tone {
    case .command:
      return SerenityPalette.accent
    case .resolved:
      return SerenityPalette.textPrimary
    case .refused:
      return Color.red.opacity(0.9)
    case .waiting:
      return SerenityPalette.textSecondary
    }
  }

  private func chipBackground(_ tone: CaptureChipTone) -> Color {
    switch tone {
    case .command:
      return SerenityPalette.headerIconBackground
    case .resolved:
      return SerenityPalette.panelBackgroundRaised
    case .refused:
      return Color.red.opacity(0.14)
    case .waiting:
      return Color.clear
    }
  }

  private func chipBorder(_ tone: CaptureChipTone) -> Color {
    switch tone {
    case .command:
      return SerenityPalette.accent.opacity(0.35)
    case .resolved:
      return SerenityPalette.thinBorder
    case .refused:
      return Color.red.opacity(0.38)
    case .waiting:
      return SerenityPalette.thinBorder
    }
  }

  private var quickCaptureProviderDropdown: some View {
    SerenityDropdownField(
      placeholder: "Provider",
      selection: Binding(
        get: { quickCaptureSelectedCredentialID },
        set: { credentialID in
          selectedQuickCaptureCredentialID = credentialID
          guard credentialID != nativeQuickCaptureProviderID else {
            Task {
              await appState.setAIActiveProvider(nil)
            }
            return
          }
          guard let credential = enabledQuickCaptureCredentials.first(where: { $0.id == credentialID }) else { return }
          Task {
            await appState.setAIActiveProvider(credential.provider)
          }
        }
      ),
      options: quickCaptureCredentialOptions,
      style: .inline
    ) {
      Button {
        appState.setSection(.settings, settingsTab: .aiProvider)
      } label: {
        Label("Manage providers", systemImage: "key")
          .font(SerenityType.caption)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
      }
      .buttonStyle(.plain)
      .foregroundStyle(SerenityPalette.accent)
      .hoverCursor(.pointingHand)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var canSubmitQuickCapture: Bool {
    guard !submitting, !quickCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    guard let preview = commandPreview else { return true }
    return preview.settledError == nil && !preview.references.isEmpty
  }

  private var submitButton: some View {
    Button {
      Task {
        await submitQuickCapture()
      }
    } label: {
      ZStack {
        Circle()
          .fill(canSubmitQuickCapture ? SerenityPalette.primaryActionBackground : SerenityPalette.panelBackgroundRaised)
          .overlay(
            Circle()
              .stroke(canSubmitQuickCapture ? Color.clear : SerenityPalette.thinBorder, lineWidth: 1)
          )

        if submitting {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.55)
        } else {
          Image(systemName: "arrow.up")
            .font(SerenityType.scaledSystem(size: 12, weight: .bold))
            .foregroundStyle(canSubmitQuickCapture ? Color.white : SerenityPalette.textSecondary)
        }
      }
      .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .disabled(!canSubmitQuickCapture)
    .keyboardShortcut(.return, modifiers: .command)
    .help("Capture (Cmd-Return)")
    .accessibilityLabel(submitting ? "Submitting capture" : "Submit capture")
    .hoverCursor(.pointingHand)
    .animation(.easeOut(duration: 0.16), value: canSubmitQuickCapture)
  }

  private func submitQuickCapture() async {
    let text = quickCapture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    submitting = true
    defer { submitting = false }

    do {
      if let command = try CaptureCommandParser.parse(text) {
        appState.discardPendingAIQuickCapturePreview()
        if await appState.submitCaptureCommand(command, typedText: text) {
          quickCapture = ""
        }
        return
      }
    } catch {
      appState.showError(title: "That command could not run", message: error.localizedDescription)
      return
    }

    if let credential = selectedQuickCaptureCredential {
      let saved = await appState.submitAIQuickCapture(input: text, credentialID: credential.id)
      if saved {
        quickCapture = ""
      }
      return
    }

    appState.discardPendingAIQuickCapturePreview()

    if text.lowercased().hasPrefix("journal:") {
      let content = text.replacingOccurrences(of: "journal:", with: "", options: [.caseInsensitive])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      await appState.createJournalEntry(
        title: "",
        content: content.isEmpty ? text : content,
        mood: nil,
        tags: []
      )
    } else {
      let parsed = QuickCaptureDateParser.parse(text)
      await appState.createTask(
        title: parsed.title,
        priority: .medium,
        dueDate: parsed.dueDate,
        tags: [],
        subtaskTitles: []
      )
    }

    quickCapture = ""
    await appState.refreshCoreWorkflowData()
  }

  /// The confirmation surface for a command. Always shown, whatever the
  /// confidence: a drafted task is six lines long and cost a round trip, so
  /// reading it before it is written is the point.
  private func captureDraftPreview(_ preview: CaptureDraftPreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(
          preview.drafts.count == 1 ? "Drafted task" : "\(preview.drafts.count) drafted tasks",
          systemImage: preview.kind == .slack ? "number" : "chevron.left.forwardslash.chevron.right"
        )
        .font(SerenityType.sectionTitle)
        .foregroundStyle(SerenityPalette.textPrimary)

        Spacer()

        if !preview.draftedByModel {
          Text("No AI key")
            .font(SerenityType.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      ForEach(preview.drafts) { draft in
        captureDraftRow(draft)
      }

      HStack(spacing: 8) {
        Spacer()

        Button("Discard") {
          appState.discardPendingCaptureDraft()
          // The typed line comes back so a near miss can be re-run with one word
          // changed rather than pasted again.
          quickCapture = preview.typedText
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button(saveButtonTitle(for: preview)) {
          Task { await appState.savePendingCaptureDraft() }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  /// The badge states which task the draft would write to, so it is also where
  /// that decision is made: a match the user disagrees with becomes its own
  /// task without losing the draft. A draft that matched nothing has no second
  /// shape to offer, so it stays a plain label.
  @ViewBuilder
  private func draftKindControl(_ draft: CaptureDraft) -> some View {
    if draft.matchesExistingTask {
      HStack(spacing: 2) {
        draftKindSegment(.create, in: draft)
        draftKindSegment(.update, in: draft)
      }
      .padding(2)
      .background(SerenityPalette.panelBackground, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Save this draft as")
    } else {
      Text("New task")
        .font(SerenityType.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SerenityPalette.headerIconBackground, in: Capsule())
        .foregroundStyle(SerenityPalette.accent)
    }
  }

  private func draftKindSegment(_ kind: CaptureDraftKind, in draft: CaptureDraft) -> some View {
    let selected = draft.resolvedKind == kind

    return Button {
      appState.chooseCaptureDraftKind(kind, forDraftID: draft.id)
    } label: {
      Text(kind == .create ? "New task" : "Update")
        .font(SerenityType.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(selected ? SerenityPalette.accent : SerenityPalette.textSecondary)
        .background(selected ? SerenityPalette.headerIconBackground : Color.clear, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func saveButtonTitle(for preview: CaptureDraftPreview) -> String {
    guard preview.drafts.count > 1 else {
      return preview.drafts.first?.resolvedKind == .update ? "Apply update" : "Save task"
    }
    return "Save \(preview.drafts.count) tasks"
  }

  private func captureDraftRow(_ draft: CaptureDraft) -> some View {
    let isUpdate = draft.resolvedKind == .update
    let payload = draft.resolvedPayload
    // A draft saved as new work is not about the task it matched, so nothing
    // below reads from that task any more.
    let target = isUpdate ? draft.targetTaskID.flatMap({ id in appState.tasks.first { $0.id == id } }) : nil

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        // One paste can be part-new and part-already-tracked, so the badge sits
        // on every row rather than on the card.
        draftKindControl(draft)

        Text(payload.title ?? target?.title ?? "Untitled")
          .font(SerenityType.bodyLarge.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 8)

        if draft.confidence > 0 {
          Text("\(Int(draft.confidence * 100))%")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      let changes = DraftChanges.rows(
        payload: payload,
        isUpdate: isUpdate,
        target: target
      )
      if !changes.isEmpty {
        DraftChangeRowsView(rows: changes)
      }

      if let reason = draft.reason {
        Text(reason)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !draft.sourceLabel.isEmpty {
        HStack(spacing: 6) {
          Text("from \(draft.sourceLabel)")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)

          ForEach(Array(draft.sourceLinks.enumerated()), id: \.offset) { index, link in
            if let url = URL(string: link) {
              Link(destination: url) {
                Text("open\(draft.sourceLinks.count > 1 ? " \(index + 1)" : "")")
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.accent)
              }
              .hoverCursor(.pointingHand)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  private func aiQuickCapturePreview(_ preview: AIQuickCapturePreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(previewTitle(for: preview.classification), systemImage: "sparkles")
          .font(SerenityType.sectionTitle)
          .foregroundStyle(SerenityPalette.textPrimary)

        Spacer()

        Text("\(Int(preview.classification.confidence * 100))%")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      switch preview.classification.kind {
      case .tasks:
        VStack(alignment: .leading, spacing: 8) {
          ForEach(preview.classification.tasks) { task in
            aiQuickCaptureTaskPreviewRow(task)
          }
        }
      case .journal:
        if let journal = preview.classification.journal {
          aiQuickCaptureJournalPreview(journal)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          appState.discardPendingAIQuickCapturePreview()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(SerenityPalette.textSecondary)
        .hoverCursor(.pointingHand)

        Button("Save") {
          Task {
            let saved = await appState.savePendingAIQuickCapturePreview()
            if saved {
              quickCapture = ""
            }
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func aiQuickCaptureTaskPreviewRow(_ task: AIQuickCaptureTaskDraft) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(SerenityPalette.accent)
        Text(task.title)
          .font(SerenityType.bodyLarge)
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineLimit(2)
        Spacer()
        Text(task.priority.rawValue.capitalized)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      let metadata = taskPreviewMetadata(task)
      if !metadata.isEmpty {
        Text(metadata.joined(separator: " · "))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
      }
    }
    .padding(10)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func aiQuickCaptureJournalPreview(_ journal: AIQuickCaptureJournalDraft) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = journal.title, !title.isEmpty {
        Text(title)
          .font(SerenityType.bodyLarge)
          .foregroundStyle(SerenityPalette.textPrimary)
      }

      Text(journal.content)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(5)

      let metadata = journalPreviewMetadata(journal)
      if !metadata.isEmpty {
        Text(metadata.joined(separator: " · "))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .padding(10)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func previewTitle(for classification: AIQuickCaptureClassification) -> String {
    switch classification.kind {
    case .tasks:
      return "Review \(classification.tasks.count) Task\(classification.tasks.count == 1 ? "" : "s")"
    case .journal:
      return "Review Journal Entry"
    }
  }

  private func taskPreviewMetadata(_ task: AIQuickCaptureTaskDraft) -> [String] {
    var metadata: [String] = []
    if let dueDate = task.dueDate {
      metadata.append(Self.quickCapturePreviewDateFormatter.string(from: dueDate))
    }
    if let projectName = projectName(for: task.projectId) {
      metadata.append(projectName)
    }
    if !task.tags.isEmpty {
      metadata.append(task.tags.map { "#\($0)" }.joined(separator: " "))
    }
    if !task.subtasks.isEmpty {
      metadata.append("\(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s")")
    }
    return metadata
  }

  private func journalPreviewMetadata(_ journal: AIQuickCaptureJournalDraft) -> [String] {
    var metadata: [String] = []
    if let mood = journal.mood {
      metadata.append(mood.rawValue.capitalized)
    }
    if !journal.tags.isEmpty {
      metadata.append(journal.tags.map { "#\($0)" }.joined(separator: " "))
    }
    return metadata
  }

  private func projectName(for projectID: String?) -> String? {
    guard let projectID else { return nil }
    return appState.projects.first { $0.id == projectID }?.name
  }

  private var quickCaptureHelperText: String {
    if let progress = appState.captureCommandProgress {
      return progress.message
    }
    if let preview = commandPreview {
      return commandHelperText(preview)
    }
    if selectedQuickCaptureCredential != nil {
      return "Write naturally, or paste a link after /slack or /github — Cmd-Return to capture."
    }

    return "Prefix with journal:, or paste a link after /slack or /github — Cmd-Return to capture."
  }

  /// The chips name each link; this line only has to say what pressing send
  /// would set going.
  private func commandHelperText(_ preview: CaptureCommandPreview) -> String {
    guard preview.settledError == nil else { return "Fix the link to capture." }

    let count = preview.references.count
    guard count > 0 else {
      return preview.kind == .slack
        ? "Paste a Slack message link."
        : "Paste a pull request link."
    }

    let noun = preview.kind == .slack ? "Slack thread" : "pull request"
    return "Reads \(count) \(noun)\(count == 1 ? "" : "s") — Cmd-Return to capture."
  }

  private var selectedQuickCaptureCredential: AICredentialEntity? {
    enabledQuickCaptureCredentials.first { $0.id == quickCaptureSelectedCredentialID }
  }

  private var enabledQuickCaptureCredentials: [AICredentialEntity] {
    appState.aiCredentials
      .filter(\.enabled)
      .sorted { lhs, rhs in
        if lhs.priority == rhs.priority {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.priority < rhs.priority
      }
  }

  private var quickCaptureSelectedCredentialID: String {
    if selectedQuickCaptureCredentialID == nativeQuickCaptureProviderID {
      return nativeQuickCaptureProviderID
    }

    if enabledQuickCaptureCredentials.contains(where: { $0.id == selectedQuickCaptureCredentialID }) {
      return selectedQuickCaptureCredentialID
    }

    if let activeProvider = appState.aiSettings.activeProvider,
       let activeCredential = enabledQuickCaptureCredentials.first(where: { $0.provider == activeProvider }) {
      return activeCredential.id
    }

    return enabledQuickCaptureCredentials.first?.id ?? nativeQuickCaptureProviderID
  }

  private var quickCaptureCredentialOptions: [SerenityDropdownOption<String>] {
    [
      SerenityDropdownOption(
        value: nativeQuickCaptureProviderID,
        title: "Native",
        subtitle: "Create tasks and journal entries locally",
        systemImage: "macwindow",
        tint: SerenityPalette.accent
      )
    ] + enabledQuickCaptureCredentials.map { credential in
      SerenityDropdownOption(
        value: credential.id,
        title: providerTitle(credential.provider),
        subtitle: "\(credential.name) · \(effectiveModel(for: credential))",
        systemImage: providerIcon(credential.provider),
        tint: providerTint(credential.provider)
      )
    }
  }

  private func effectiveModel(for credential: AICredentialEntity) -> String {
    if let modelPreference = credential.modelPreference?.trimmingCharacters(in: .whitespacesAndNewlines), !modelPreference.isEmpty {
      return modelPreference
    }

    switch credential.provider {
    case .openai:
      if let preferred = appState.aiSettings.preferredModels?.openai, !preferred.isEmpty {
        return preferred
      }
    case .gemini:
      if let preferred = appState.aiSettings.preferredModels?.gemini, !preferred.isEmpty {
        return preferred
      }
    case .anthropic:
      if let preferred = appState.aiSettings.preferredModels?.anthropic, !preferred.isEmpty {
        return preferred
      }
    case .nvidia:
      if let preferred = appState.aiSettings.preferredModels?.nvidia, !preferred.isEmpty {
        return preferred
      }
    case .custom:
      break
    }

    return appState.aiModelCatalog[credential.provider]?.first ?? "Default model"
  }

  private func providerTitle(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "OpenAI"
    case .gemini:
      return "Gemini"
    case .anthropic:
      return "Anthropic"
    case .nvidia:
      return "NVIDIA NIM"
    case .custom:
      return "Custom"
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
    case .nvidia:
      return "cpu.fill"
    case .custom:
      return "globe"
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
    case .nvidia:
      return .green
    case .custom:
      return .teal
    }
  }
}

/// The integrations page is a registry: one table, one row per service, and a
/// service's settings open in place rather than in a card of their own further
/// down the page.
struct IntegrationsSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout

  private enum Service: String, CaseIterable, Identifiable {
    case google
    case github
    case slack
    case iCloud

    var id: String { rawValue }
  }

  @State private var githubToken = ""
  @State private var githubDisplayName = ""
  @State private var isConnectingGoogle = false
  /// One panel at a time — two open rows stop reading as a table.
  @State private var expandedService: Service?
  @State private var showDiagnostics = false

  private static let accountColumn: CGFloat = 170
  private static let lastSyncColumn: CGFloat = 104
  private static let controlColumn: CGFloat = 116
  private static let rowIcon: CGFloat = 32
  private static let settingsLabelColumn: CGFloat = 118
  /// Settings line up under the service name, not under its icon.
  private static let panelIndent: CGFloat = 16 + rowIcon + 12

  private var isGoogleConfigured: Bool {
    appState.googleCalendarConfigured
  }

  private var rowDetailFont: Font {
    SerenityType.scaledSystem(size: 13)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      summaryBar
      registryCard
      diagnosticsCard
    }
    .task {
      await appState.refreshIntegrationDiagnostics()
    }
  }

  // MARK: - Summary

  @ViewBuilder
  private var summaryBar: some View {
    if compactLayout {
      VStack(alignment: .leading, spacing: 10) {
        summaryLine
        syncAllButton
      }
    } else {
      HStack(spacing: 12) {
        summaryLine
        Spacer(minLength: 12)
        syncAllButton
      }
    }
  }

  private var summaryLine: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(overallTint)
        .frame(width: 7, height: 7)

      Text("\(activeServiceCount) of \(Service.allCases.count) services active")
        .font(SerenityType.body.weight(.medium))
        .foregroundStyle(SerenityPalette.textPrimary)

      Text("·")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary.opacity(0.5))

      Text(lastSyncSummary)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(1)
    }
  }

  private var syncAllButton: some View {
    Button {
      Task { await appState.syncIntegrationsNow() }
    } label: {
      HStack(spacing: 6) {
        if appState.integrationSyncInProgress {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        Text(appState.integrationSyncInProgress ? "Syncing" : "Sync all")
      }
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(appState.integrationSyncInProgress)
  }

  private var activeServiceCount: Int {
    var count = 0
    if appState.googleIntegrationState.connected, appState.googleIntegrationState.syncEnabled {
      count += 1
    }
    if !appState.githubIntegrationState.tokens.isEmpty, appState.githubIntegrationState.syncEnabled {
      count += 1
    }
    if appState.slackIntegrationState.connected, appState.slackIntegrationState.syncEnabled {
      count += 1
    }
    if iCloudIsAvailable {
      count += 1
    }
    return count
  }

  private var iCloudIsAvailable: Bool {
    switch appState.iCloudSyncState {
    case .unavailable, .failed:
      return false
    default:
      return true
    }
  }

  private var needsAttention: Bool {
    if appState.googleIntegrationState.lastError != nil { return true }
    if appState.githubIntegrationState.lastError != nil { return true }
    if appState.slackIntegrationState.lastError != nil { return true }
    return !iCloudIsAvailable
  }

  private var overallTint: Color {
    if needsAttention {
      return .orange
    }
    return activeServiceCount > 0 ? .green : SerenityPalette.textSecondary
  }

  private var lastSyncSummary: String {
    let recents = [
      appState.googleIntegrationState.lastSyncAt,
      appState.githubIntegrationState.lastSyncAt,
      appState.slackIntegrationState.lastSyncAt
    ].compactMap { $0 }

    if appState.integrationSyncInProgress {
      return "Syncing now..."
    }
    if let mostRecent = recents.max() {
      if abs(mostRecent.timeIntervalSinceNow) < 60 {
        return "Last synced just now"
      }
      return "Last synced \(relativeSync(mostRecent))"
    }
    return "Never synced"
  }

  /// A sync that finished seconds ago formats as "in 0s", which reads as a
  /// scheduled future pass rather than one that just landed.
  private func relativeSync(_ date: Date?) -> String {
    guard let date else { return "Never" }
    let now = Date()
    guard abs(date.timeIntervalSince(now)) >= 60 else { return "Just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: now)
  }

  // MARK: - Registry

  private var registryCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !compactLayout {
        columnHeader
        Divider().overlay(SerenityPalette.thinBorder)
      }

      googleRow
      rowDivider
      githubRow
      rowDivider
      slackRow
      rowDivider
      iCloudRow
    }
    .background(SerenityPalette.panelBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var columnHeader: some View {
    HStack(spacing: 12) {
      Text("Service")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Account")
        .frame(width: Self.accountColumn, alignment: .leading)
      Text("Last sync")
        .frame(width: Self.lastSyncColumn, alignment: .leading)
      Color.clear
        .frame(width: Self.controlColumn, height: 1)
    }
    .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
    .tracking(0.6)
    .textCase(.uppercase)
    .foregroundStyle(SerenityPalette.textSecondary)
    .padding(.horizontal, 16)
    .frame(height: 36)
  }

  private var rowDivider: some View {
    Divider()
      .overlay(SerenityPalette.thinBorder)
      .padding(.leading, 16)
  }

  private func serviceRow<Trailing: View>(
    service: Service,
    name: String,
    icon: String,
    tint: Color,
    detail: String,
    detailIsProblem: Bool = false,
    account: String,
    lastSync: String,
    canExpand: Bool,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 12) {
      serviceIcon(systemName: icon, accent: tint)

      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(SerenityType.bodyLarge.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)

        Text(detail)
          .font(rowDetailFont)
          .foregroundStyle(detailIsProblem ? Color.red.opacity(0.85) : SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

        if compactLayout {
          Text("\(account) · \(lastSync)")
            .font(rowDetailFont)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      Spacer(minLength: 12)

      if !compactLayout {
        Text(account)
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(width: Self.accountColumn, alignment: .leading)

        Text(lastSync)
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
          .frame(width: Self.lastSyncColumn, alignment: .leading)
      }

      HStack(spacing: 10) {
        trailing()
        disclosureButton(for: service, name: name, enabled: canExpand)
      }
      .frame(width: compactLayout ? nil : Self.controlColumn, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
  }

  @ViewBuilder
  private func disclosureButton(for service: Service, name: String, enabled: Bool) -> some View {
    if enabled {
      let isOpen = expandedService == service
      Button {
        withAnimation(.easeOut(duration: 0.16)) {
          expandedService = isOpen ? nil : service
        }
      } label: {
        Image(systemName: "chevron.right")
          .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          .frame(width: 26, height: 26)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(isOpen ? SerenityPalette.inputBackgroundHover : Color.clear)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)
      .accessibilityLabel(Text(isOpen ? "Hide \(name) settings" : "Show \(name) settings"))
    }
  }

  private func serviceIcon(systemName: String, accent: Color) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(accent.opacity(0.18))
        .frame(width: Self.rowIcon, height: Self.rowIcon)
      Image(systemName: systemName)
        .font(SerenityType.scaledSystem(size: 14, weight: .semibold))
        .foregroundStyle(accent)
    }
  }

  private func syncToggle(_ label: String, isOn: Binding<Bool>) -> some View {
    Toggle(label, isOn: isOn)
      .toggleStyle(.switch)
      .labelsHidden()
  }

  // MARK: - Settings panels

  private func settingsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider().overlay(SerenityPalette.thinBorder)

      VStack(alignment: .leading, spacing: 14) {
        content()
      }
      .padding(.vertical, 16)
      .padding(.trailing, 16)
      .padding(.leading, compactLayout ? 16 : Self.panelIndent)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(SerenityPalette.innerCardBackground)
    }
  }

  @ViewBuilder
  private func settingsRow<Content: View>(
    _ label: String,
    alignment: VerticalAlignment = .center,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if compactLayout {
      VStack(alignment: .leading, spacing: 6) {
        Text(label)
          .font(rowDetailFont)
          .foregroundStyle(SerenityPalette.textSecondary)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      HStack(alignment: alignment, spacing: 16) {
        Text(label)
          .font(rowDetailFont)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(width: Self.settingsLabelColumn, alignment: .trailing)
        content()
        Spacer(minLength: 0)
      }
    }
  }

  /// A disconnect is the one action here that loses data, so it sits below a
  /// rule at the end of the panel rather than beside the row's switch.
  private func panelFooter(title: String, action: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().overlay(SerenityPalette.thinBorder)

      HStack {
        Spacer(minLength: 0)
        Button(role: .destructive, action: action) {
          Text(title)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: compactLayout ? SerenityTouchMetrics.minimumTarget : 0)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
      }
    }
    .padding(.top, 2)
  }

  // MARK: - Google Calendar

  private var googleRow: some View {
    let state = appState.googleIntegrationState

    return VStack(alignment: .leading, spacing: 0) {
      serviceRow(
        service: .google,
        name: "Google Calendar",
        icon: "calendar",
        tint: Color(red: 0.26, green: 0.52, blue: 0.96),
        detail: googleDetail,
        detailIsProblem: state.lastError != nil || !isGoogleConfigured,
        account: state.connected ? (state.userEmail ?? "Connected") : "Not connected",
        lastSync: relativeSync(state.lastSyncAt),
        canExpand: state.connected
      ) {
        if state.connected {
          syncToggle("Google Calendar sync", isOn: Binding(
            get: { appState.googleIntegrationState.syncEnabled },
            set: { enabled in
              Task { await appState.setGoogleIntegrationSyncEnabled(enabled) }
            }
          ))
        } else {
          Button {
            Task { await connectGoogle() }
          } label: {
            HStack(spacing: 6) {
              if isConnectingGoogle {
                ProgressView().controlSize(.small)
              }
              Text(isConnectingGoogle ? "Connecting" : "Connect")
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(!isGoogleConfigured || isConnectingGoogle)
        }
      }

      if expandedService == .google {
        settingsPanel {
          settingsRow("Account") {
            Text(state.userEmail ?? "Connected")
              .font(SerenityType.bodyMedium)
              .foregroundStyle(SerenityPalette.textPrimary)
          }

          settingsRow("Imports", alignment: .top) {
            Text("Events on your primary calendar become tasks on the day they happen.")
              .font(rowDetailFont)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: 460, alignment: .leading)
          }

          panelFooter(title: "Disconnect Google Calendar") {
            Task { await appState.disconnectGoogleIntegration() }
          }
        }
      }
    }
  }

  private var googleDetail: String {
    if let error = appState.googleIntegrationState.lastError {
      return error
    }
    if !isGoogleConfigured {
      return "Google Sign-In is not configured for this build"
    }
    return "Calendar events become tasks"
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

  // MARK: - GitHub

  private var githubRow: some View {
    let state = appState.githubIntegrationState

    return VStack(alignment: .leading, spacing: 0) {
      serviceRow(
        service: .github,
        name: "GitHub",
        icon: "chevron.left.forwardslash.chevron.right",
        tint: Color(red: 0.55, green: 0.55, blue: 0.60),
        detail: githubDetail,
        detailIsProblem: state.lastError != nil,
        account: githubAccount,
        lastSync: relativeSync(state.lastSyncAt),
        canExpand: true
      ) {
        if !state.tokens.isEmpty {
          syncToggle("GitHub sync", isOn: Binding(
            get: { appState.githubIntegrationState.syncEnabled },
            set: { enabled in
              Task { await appState.setGitHubIntegrationSyncEnabled(enabled) }
            }
          ))
        }
      }

      if expandedService == .github {
        settingsPanel { githubSettings }
      }
    }
  }

  private var githubDetail: String {
    if let error = appState.githubIntegrationState.lastError {
      return error
    }
    let count = appState.githubIntegrationState.tokens.count
    guard count > 0 else {
      return "Add a personal access token to connect"
    }
    return "Pull requests and issues become tasks"
  }

  private var githubAccount: String {
    let tokens = appState.githubIntegrationState.tokens
    guard let leading = tokens.first(where: { $0.isActive }) ?? tokens.first else {
      return "No token"
    }
    if tokens.count > 1 {
      return "@\(leading.username) +\(tokens.count - 1)"
    }
    return "@\(leading.username)"
  }

  @ViewBuilder
  private var githubSettings: some View {
    settingsRow("New token", alignment: .top) {
      VStack(alignment: .leading, spacing: 8) {
        SecureField("Personal access token", text: $githubToken)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Display name (optional)", text: $githubDisplayName)
          .textFieldStyle(.plain)
          .serenityInputField()

        Text("Needs the repo scope, generated at github.com/settings/tokens.")
          .font(rowDetailFont)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

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
      .frame(maxWidth: 420, alignment: .leading)
    }

    if !appState.githubIntegrationState.tokens.isEmpty {
      settingsRow("Tokens", alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(appState.githubIntegrationState.tokens) { token in
            githubTokenRow(token)
          }
        }
        .frame(maxWidth: 420, alignment: .leading)
      }
    }
  }

  private func githubTokenRow(_ token: GitHubTokenRecord) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(token.displayName)
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)
        Text("@\(token.username) • \(token.maskedToken)")
          .font(rowDetailFont)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer(minLength: 12)

      syncToggle("\(token.displayName) active", isOn: Binding(
        get: { token.isActive },
        set: { _ in
          Task { await appState.toggleGitHubIntegrationToken(id: token.id) }
        }
      ))

      Button("Remove", role: .destructive) {
        Task { await appState.removeGitHubIntegrationToken(id: token.id) }
      }
      .buttonStyle(.borderless)
      .foregroundStyle(Color.red.opacity(0.85))
      .hoverCursor(.pointingHand)
    }
    .padding(12)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  // MARK: - Slack

  private var slackRow: some View {
    let state = appState.slackIntegrationState

    return VStack(alignment: .leading, spacing: 0) {
      serviceRow(
        service: .slack,
        name: "Slack",
        icon: "number",
        tint: Color(red: 0.36, green: 0.19, blue: 0.56),
        detail: slackDetail,
        detailIsProblem: state.lastError != nil || !appState.slackConfigured,
        account: state.teamName ?? (state.connected ? "Connected" : "Not connected"),
        lastSync: relativeSync(state.lastSyncAt),
        canExpand: state.connected
      ) {
        if state.connected {
          syncToggle("Slack sync", isOn: Binding(
            get: { appState.slackIntegrationState.syncEnabled },
            set: { enabled in
              Task { await appState.setSlackIntegrationSyncEnabled(enabled) }
            }
          ))
        } else {
          Button("Connect") {
            Task { await appState.connectSlackIntegration() }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(!appState.slackConfigured)
        }
      }

      if expandedService == .slack {
        settingsPanel { slackSettings }
      }
    }
  }

  private var slackDetail: String {
    if !appState.slackConfigured {
      return "Add SLACK_CLIENT_ID to the app configuration to enable Slack"
    }
    if let error = appState.slackIntegrationState.lastError {
      return error
    }
    guard appState.slackIntegrationState.connected else {
      return "Channel messages become task proposals"
    }
    let pending = appState.slackProposals.count
    if pending > 0 {
      return "\(pending) proposal\(pending == 1 ? "" : "s") waiting to review"
    }
    let watched = appState.slackChannelsWatched
    if watched > 0 {
      return "Watching \(watched) channel\(watched == 1 ? "" : "s")"
    }
    return "Channel messages become task proposals"
  }

  @ViewBuilder
  private var slackSettings: some View {
    settingsRow("Include", alignment: .top) {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Messages sent with @here or @channel", isOn: Binding(
          get: { appState.slackRelevanceSettings.includeBroadcastMentions },
          set: { value in
            var settings = appState.slackRelevanceSettings
            settings.includeBroadcastMentions = value
            appState.setSlackRelevanceSettings(settings)
          }
        ))

        Toggle("Messages from bots and apps", isOn: Binding(
          get: { appState.slackRelevanceSettings.includeBotMessages },
          set: { value in
            var settings = appState.slackRelevanceSettings
            settings.includeBotMessages = value
            appState.setSlackRelevanceSettings(settings)
          }
        ))
      }
      .font(SerenityType.bodyMedium)
    }

    settingsRow("Check every") {
      Picker("", selection: Binding(
        get: { appState.slackPollIntervalMinutes },
        set: { appState.setSlackPollIntervalMinutes($0) }
      )) {
        Text("5 minutes").tag(5)
        Text("15 minutes").tag(15)
        Text("30 minutes").tag(30)
        Text("1 hour").tag(60)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 140)
    }

    settingsRow("Privacy", alignment: .top) {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "lock.fill")
          .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
        Text("Serenity reads the channels you belong to, and only while the app is open. It never requests access to your direct messages.")
          .font(rowDetailFont)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 460, alignment: .leading)
    }

    panelFooter(title: "Disconnect Slack") {
      Task { await appState.disconnectSlackIntegration() }
    }
  }

  // MARK: - iCloud

  private var iCloudRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      serviceRow(
        service: .iCloud,
        name: "iCloud Sync",
        icon: iCloudSyncIcon,
        tint: iCloudSyncTint,
        detail: iCloudRowDetail,
        detailIsProblem: !iCloudIsAvailable,
        account: "iCloud",
        lastSync: iCloudLastSync,
        canExpand: true
      ) {
        EmptyView()
      }

      if expandedService == .iCloud {
        settingsPanel {
          settingsRow("Status", alignment: .top) {
            Text(iCloudSyncDetail)
              .font(rowDetailFont)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: 460, alignment: .leading)
          }

          settingsRow("Sync") {
            Button {
              appState.triggerICloudSync()
            } label: {
              if isICloudSyncing {
                HStack(spacing: 6) {
                  ProgressView().controlSize(.small)
                  Text("Syncing")
                }
              } else {
                Label(iCloudSyncButtonTitle, systemImage: iCloudSyncButtonIcon)
              }
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)
            .disabled(isICloudSyncing)
          }
        }
      }
    }
  }

  private var iCloudRowDetail: String {
    switch appState.iCloudSyncState {
    case .idle, .succeeded:
      return "Tasks, projects, journal entries, goals and recaps across devices"
    case .syncing:
      return "Uploading local changes and checking for updates"
    case .unavailable(let reason):
      return reason
    case .failed(let message):
      return message
    }
  }

  private var iCloudLastSync: String {
    switch appState.iCloudSyncState {
    case .succeeded(let syncedAt, _):
      return relativeSync(syncedAt)
    case .syncing:
      return "Syncing"
    default:
      return "—"
    }
  }

  private var iCloudSyncDetail: String {
    switch appState.iCloudSyncState {
    case .idle:
      return "Ready to sync tasks, projects, journal entries, goals, insights, recaps, and summaries."
    case .syncing:
      return "Uploading local changes and checking for updates from iCloud."
    case .succeeded(let syncedAt, let pending):
      return "Last synced \(relativeSync(syncedAt)). Pending changes: \(pending)."
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

  // MARK: - Diagnostics

  /// These lines were being computed on every sync and shown nowhere. When an
  /// integration quietly does nothing, they are the difference between a bug
  /// and a workspace that simply had nothing to say.
  private var diagnosticsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        showDiagnostics.toggle()
        if showDiagnostics {
          Task { await appState.refreshIntegrationDiagnostics() }
        }
      } label: {
        HStack(spacing: 10) {
          Text("Diagnostics")
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
          Text("Last pass, per service")
            .font(rowDetailFont)
            .foregroundStyle(SerenityPalette.textSecondary)
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
            .foregroundStyle(SerenityPalette.textSecondary)
            .rotationEffect(.degrees(showDiagnostics ? 90 : 0))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)

      if showDiagnostics {
        Divider().overlay(SerenityPalette.thinBorder)

        VStack(alignment: .leading, spacing: 4) {
          ForEach(appState.integrationDiagnosticsLines, id: \.self) { line in
            Text(line)
              .font(SerenityType.body.monospaced())
              .foregroundStyle(SerenityPalette.textSecondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(16)
      }
    }
    .background(SerenityPalette.panelBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }
}


private func tagsIncludingPendingInput(_ tags: [String], input: String) -> [String] {
  let pendingTag = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !pendingTag.isEmpty, !tags.contains(pendingTag) else { return tags }
  return tags + [pendingTag]
}

/// One field a draft would change, rendered as before → after so a mis-targeted
/// update is visible before it is applied rather than after.
struct DraftChangeRow: Identifiable {
  let id = UUID()
  let label: String
  let before: String?
  let after: String
}

/// Shared by the Slack review inbox and the Home draft card. A second, subtly
/// different diff renderer is how two surfaces start disagreeing about what a
/// change looks like.
enum DraftChanges {
  static func rows(
    payload: SlackProposalPayload,
    isUpdate: Bool,
    target: TaskEntity?
  ) -> [DraftChangeRow] {
    var rows: [DraftChangeRow] = []

    if isUpdate, let title = payload.title, title != target?.title {
      rows.append(DraftChangeRow(label: "Title", before: target?.title, after: title))
    }

    if let dueDate = payload.dueDate {
      rows.append(
        DraftChangeRow(label: "Due", before: target?.dueDate.map(stamp), after: stamp(dueDate))
      )
    }

    if let priority = payload.priority, priority != target?.priority {
      rows.append(
        DraftChangeRow(
          label: "Priority",
          before: target?.priority.rawValue.capitalized,
          after: priority.rawValue.capitalized
        )
      )
    }

    switch payload.statusChange {
    case .completed:
      rows.append(DraftChangeRow(label: "Status", before: target == nil ? nil : "Open", after: "Done"))
    case .reopened:
      rows.append(DraftChangeRow(label: "Status", before: target == nil ? nil : "Done", after: "Open"))
    case .none:
      break
    }

    if !payload.subtasks.isEmpty {
      rows.append(
        DraftChangeRow(
          label: "Subtasks",
          before: nil,
          after: payload.subtasks.joined(separator: ", ")
        )
      )
    }

    if let description = payload.description, !isUpdate {
      rows.append(DraftChangeRow(label: "Notes", before: nil, after: description))
    }

    return rows
  }

  static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE d MMM yyyy"
    return formatter.string(from: date)
  }
}

struct DraftChangeRowsView: View {
  let rows: [DraftChangeRow]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(row.label)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .frame(width: 66, alignment: .leading)

          if let before = row.before {
            Text(before)
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
              .strikethrough()
            Image(systemName: "arrow.right")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          Text(row.after)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// The review queue. Nothing Slack proposes reaches a task until a card here
/// is accepted.
struct SlackProposalInboxView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      if appState.slackProposals.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(appState.slackProposals) { proposal in
              card(for: proposal)
            }
          }
          .padding(.bottom, 8)
        }
      }
    }
    .padding(compactLayout ? 16 : 24)
    .frame(minWidth: compactLayout ? nil : 520, minHeight: compactLayout ? nil : 420)
    .background(SerenityPalette.windowBackground)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label("From Slack", systemImage: "number")
        .font(SerenityType.sectionTitle)
        .foregroundStyle(SerenityPalette.textPrimary)

      Spacer()

      if !appState.slackProposals.isEmpty {
        Button("Dismiss all") {
          Task { await appState.dismissAllSlackProposals() }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(SerenityPalette.textSecondary)
        .hoverCursor(.pointingHand)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Nothing waiting")
        .font(SerenityType.bodyLarge)
        .foregroundStyle(SerenityPalette.textPrimary)
      Text(lastLookedSummary)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  /// A quiet workspace is the normal state, so say when Serenity last looked
  /// rather than leaving a blank panel that reads as broken.
  private var lastLookedSummary: String {
    guard appState.slackIntegrationState.connected else {
      return "Connect Slack in Integrations to start seeing proposals here."
    }
    guard let lastSyncAt = appState.slackIntegrationState.lastSyncAt else {
      return "Serenity has not checked Slack yet."
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Serenity last checked \(formatter.localizedString(for: lastSyncAt, relativeTo: Date()))."
  }

  private func card(for proposal: SlackProposal) -> some View {
    let target = proposal.targetTaskID.flatMap { id in appState.tasks.first(where: { $0.id == id }) }

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(proposal.kind == .create ? "New task" : "Update")
          .font(SerenityType.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(SerenityPalette.headerIconBackground, in: Capsule())
          .foregroundStyle(SerenityPalette.accent)

        Text(proposal.payload.title ?? target?.title ?? "Untitled")
          .font(SerenityType.bodyLarge.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)

        Spacer(minLength: 8)

        Text("\(Int(proposal.confidence * 100))%")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      let changes = DraftChanges.rows(
        payload: proposal.payload,
        isUpdate: proposal.kind == .update,
        target: target
      )
      if !changes.isEmpty {
        DraftChangeRowsView(rows: changes)
      }

      if let reason = proposal.reason {
        Text(reason)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      sourceLine(for: proposal)

      HStack(spacing: 8) {
        Spacer()

        Button("Dismiss") {
          Task { await appState.dismissSlackProposal(id: proposal.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Accept") {
          Task { await appState.acceptSlackProposal(id: proposal.id) }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(16)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  /// The excerpt is what earns trust, and the permalink is the one tap that
  /// settles any doubt about it.
  private func sourceLine(for proposal: SlackProposal) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\u{201C}\(proposal.source.excerpt)\u{201D}")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        Text("#\(proposal.source.channelName) · \(proposal.source.author) · \(DraftChanges.stamp(proposal.source.sentAt))")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        if let permalink = proposal.source.permalink, let url = URL(string: permalink) {
          Link("Open in Slack", destination: url)
            .font(SerenityType.caption)
            .hoverCursor(.pointingHand)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

}

private struct ActionHubSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
  let onEditTask: (TaskEntity) -> Void

  private enum HubTab: String, CaseIterable, Identifiable {
    case tasks
    case projects
    case calendar

    var id: String { rawValue }

    var title: String {
      switch self {
      case .tasks:
        return "Tasks"
      case .projects:
        return "Projects"
      case .calendar:
        return "Calendar"
      }
    }
  }

  private enum TaskListFilter: String, CaseIterable, Identifiable {
    case active
    case inbox
    case all
    case completed

    var id: String { rawValue }

    var title: String {
      switch self {
      case .active:
        return "Active"
      case .inbox:
        return "Inbox"
      case .all:
        return "All"
      case .completed:
        return "Completed"
      }
    }
  }

  /// Tasks read best grouped by how soon they matter rather than as one flat
  /// due-date sort.
  private enum DueBucket: String, CaseIterable, Identifiable {
    case overdue
    case today
    case thisWeek
    case later
    case someday

    var id: String { rawValue }

    var title: String {
      switch self {
      case .overdue:
        return "Overdue"
      case .today:
        return "Today"
      case .thisWeek:
        return "This week"
      case .later:
        return "Later"
      case .someday:
        return "Someday"
      }
    }

    static func containing(_ task: TaskEntity, calendar: Calendar = .current) -> DueBucket {
      guard let dueDate = task.dueDate else { return .someday }

      let today = calendar.startOfDay(for: Date())
      let dueDay = calendar.startOfDay(for: dueDate)

      if dueDay < today {
        return task.completed ? .today : .overdue
      }
      if dueDay == today {
        return .today
      }

      let daysOut = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
      return daysOut <= 7 ? .thisWeek : .later
    }
  }

  @State private var activeTab: HubTab = .tasks
  @State private var taskFilter: TaskListFilter = .active
  @State private var searchQuery = ""
  @State private var showQuickAddForm = false

  @State private var newTaskTitle = ""
  @State private var newTaskDescription = ""
  @State private var newTaskTags: [String] = []
  @State private var newTaskTagInput = ""
  @State private var newTaskProjectID = ""
  @State private var newTaskPriority: TaskPriority = .medium
  @State private var includeDueDate = false
  @State private var dueDate = Date()
  @State private var calendarVisibleMonth = Calendar.current.startOfMonth(for: Date())
  @State private var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
  @State private var expandedTaskID: String?
  @State private var showQuickProjectCreator = false
  @FocusState private var searchFocused: Bool
  @State private var quickProjectName = ""
  @State private var quickProjectDescription = ""
  @State private var quickProjectColor: Color = ProjectColorCodec.fallbackColor
  @State private var showProjectCreator = false
  @State private var newProjectName = ""
  @State private var newProjectDescription = ""
  @State private var newProjectColor: Color = ProjectColorCodec.fallbackColor
  @State private var editingProject: ProjectEntity?
  @State private var projectPendingDeletion: ProjectEntity?
  @State private var openSwipeTaskID: String?
  @State private var taskPendingDeletion: TaskEntity?
  @State private var showSlackInbox = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      tabSelector

      if !appState.slackProposals.isEmpty {
        slackProposalBanner
      }

      switch activeTab {
      case .tasks:
        tasksView
      case .projects:
        projectsView
      case .calendar:
        calendarView
      }
    }
    .sheet(isPresented: $showSlackInbox) {
      SlackProposalInboxView()
        .environmentObject(appState)
    }
    .onChange(of: appState.shouldFocusSectionSearch) { _, requested in
      guard requested else { return }
      activeTab = .tasks
      searchFocused = true
      appState.shouldFocusSectionSearch = false
    }
  }

  private var slackProposalBanner: some View {
    let count = appState.slackProposals.count

    return Button {
      showSlackInbox = true
    } label: {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(SerenityPalette.headerIconBackground)
            .frame(width: 32, height: 32)
          Image(systemName: "number")
            .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
            .foregroundStyle(SerenityPalette.accent)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(count == 1 ? "1 Slack item needs a decision" : "\(count) Slack items need a decision")
            .font(SerenityType.bodyLarge.weight(.semibold))
            .foregroundStyle(SerenityPalette.textPrimary)
          Text("Nothing reaches your tasks until you accept it")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 8)

        Text("Review")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.accent)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private var tabSelector: some View {
    HStack(spacing: 8) {
      ForEach(HubTab.allCases) { tab in
        Button(tab.title) {
          activeTab = tab
        }
        .buttonStyle(SerenityPillButtonStyle(selected: activeTab == tab))
          .hoverCursor(.pointingHand)
      }
    }
    .padding(6)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
    .frame(maxWidth: 420, alignment: .leading)
  }

  private var tasksView: some View {
    let tasks = displayedTasks

    return VStack(alignment: .leading, spacing: 16) {
      quickAddPanel

      if compactLayout {
        // Side by side these squeeze the field to a few characters and wrap the
        // pill labels onto two lines, so the phone gets a row each.
        taskSearchField

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            taskFilterPills
          }
          .padding(.horizontal, 1)
        }
      } else {
        HStack(spacing: 12) {
          taskSearchField

          Spacer(minLength: 8)

          taskFilterPills
        }
      }

      if !appState.selectedTaskIDs.isEmpty {
        selectionBar
      }

      if tasks.isEmpty {
        emptyListState
      } else {
        LazyVStack(spacing: 0) {
          ForEach(groupedTasks, id: \.bucket.id) { group in
            bucketHeader(group.bucket, count: group.tasks.count)

            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
              swipeableTaskRow(task)
                .overlay(alignment: .bottom) {
                  if index < group.tasks.count - 1 {
                    Rectangle()
                      .fill(SerenityPalette.thinBorder)
                      .frame(height: 1)
                  }
                }
            }
          }
        }
        .background(SerenityPalette.panelBackground, in: taskListShape)
        .overlay(taskListShape.stroke(SerenityPalette.border, lineWidth: 1))
        .clipShape(taskListShape)
        .simultaneousGesture(closeSwipeOnScrollGesture)
      }
    }
    .confirmationDialog(
      "Delete \(taskPendingDeletion?.title ?? "this task")?",
      isPresented: Binding(
        get: { taskPendingDeletion != nil },
        set: { if !$0 { taskPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let task = taskPendingDeletion else { return }
        taskPendingDeletion = nil
        Task { await appState.deleteTask(id: task.id) }
      }
      Button("Cancel", role: .cancel) {
        taskPendingDeletion = nil
      }
    } message: {
      Text("This cannot be undone.")
    }
  }

  /// Swipe is a phone gesture; the Mac row keeps its hover affordances.
  @ViewBuilder
  private func swipeableTaskRow(_ task: TaskEntity) -> some View {
#if os(iOS)
    if compactLayout {
      taskRow(task)
        .serenitySwipeActions(
          rowID: task.id,
          openRowID: $openSwipeTaskID,
          actions: [
            SerenitySwipeAction(
              id: "complete",
              title: task.completed ? "Undo" : "Done",
              systemImage: task.completed ? "arrow.uturn.backward" : "checkmark",
              tint: .green
            ) {
              Task { await appState.toggleTaskCompletion(id: task.id) }
            },
            SerenitySwipeAction(
              id: "delete",
              title: "Delete",
              systemImage: "trash",
              tint: .red
            ) {
              taskPendingDeletion = task
            },
          ]
        )
    } else {
      taskRow(task)
    }
#else
    taskRow(task)
#endif
  }

  /// A vertical drag is a scroll, and a scroll closes whatever is open.
  private var closeSwipeOnScrollGesture: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard openSwipeTaskID != nil else { return }
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          openSwipeTaskID = nil
        }
      }
  }


  private var taskSearchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(SerenityPalette.textSecondary)
      TextField("Search tasks, projects, or tags...", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(SerenityType.scaledSystem(size: 17, weight: .regular))
        .focused($searchFocused)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var taskFilterPills: some View {
    ForEach(TaskListFilter.allCases) { filter in
      Button(filter.title) {
        taskFilter = filter
      }
      .buttonStyle(SerenityPillButtonStyle(selected: taskFilter == filter))
      .hoverCursor(.pointingHand)
      .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func bucketHeader(_ bucket: DueBucket, count: Int) -> some View {
    HStack(spacing: 8) {
      Text(bucket.title)
        .font(SerenityType.caption.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(bucket == .overdue ? Color.red.opacity(0.9) : SerenityPalette.textSecondary)
      Text("\(count)")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary.opacity(0.8))
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 6)
    .background(SerenityPalette.panelBackgroundRaised.opacity(0.45))
  }

  /// Only mounted while a selection exists, so the list is not permanently
  /// topped with two disabled buttons.
  private var selectionBar: some View {
    HStack(spacing: 8) {
      Text("\(appState.selectedTaskIDs.count) selected")
        .font(SerenityType.bodyMedium)
        .foregroundStyle(SerenityPalette.textSecondary)

      Spacer()

      Button("Complete") {
        Task { await appState.markSelectedTasksCompleted() }
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Button("Delete", role: .destructive) {
        Task { await appState.deleteSelectedTasks() }
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Button("Clear") {
        appState.clearTaskSelection()
      }
      .buttonStyle(.plain)
      .font(SerenityType.bodyMedium)
      .foregroundStyle(SerenityPalette.accent)
      .hoverCursor(.pointingHand)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  @ViewBuilder
  private var emptyListState: some View {
    let completed = appState.tasks.filter(\.completed).count

    switch taskFilter {
    case .active where completed > 0:
      SerenityEmptyState(
        icon: "checkmark.circle",
        title: "Nothing active",
        message: "Every task is done."
      ) {
        Button("Show \(completed) completed") {
          taskFilter = .completed
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    case .inbox:
      SerenityEmptyState(
        icon: "tray",
        title: "Inbox is clear",
        message: "Captured tasks land here until they get a due date."
      )
    default:
      SerenityEmptyState(
        icon: "magnifyingglass",
        title: "No matches",
        message: "No tasks match the current filter or search."
      )
    }
  }

  private var taskListShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
  }

  private var isSelecting: Bool {
    !appState.selectedTaskIDs.isEmpty
  }

  private var quickAddPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showQuickAddForm {
        TextField("Task title", text: $newTaskTitle)
          .textFieldStyle(.plain)
          .serenityInputField()

        TaskMarkdownDescriptionField(text: $newTaskDescription)

        SerenityTagInputField(tags: $newTaskTags, inputText: $newTaskTagInput)

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Project")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            SerenityDropdownField(
              placeholder: "No project",
              selection: $newTaskProjectID,
              options: projectDropdownOptions
            ) {
              Divider()
                .overlay(SerenityPalette.thinBorder)
              Button {
                showQuickProjectCreator = true
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "plus.circle.fill")
                    .foregroundStyle(SerenityPalette.accent)
                  Text("Create new project")
                    .font(SerenityType.bodyMedium)
                    .foregroundStyle(SerenityPalette.textPrimary)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
              }
              .buttonStyle(.plain)
              .hoverCursor(.pointingHand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Priority")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            SerenityDropdownField(
              placeholder: "Priority",
              selection: $newTaskPriority,
              options: priorityDropdownOptions
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity)

        if showQuickProjectCreator {
          quickProjectCreator
        }

        HStack(spacing: 12) {
          Toggle("Due date", isOn: $includeDueDate)
            .toggleStyle(.switch)
            .frame(maxWidth: 120, alignment: .leading)

          if includeDueDate {
            DueDateSelectionField(selection: $dueDate)
              .frame(maxWidth: 280, alignment: .leading)
          }

          Spacer(minLength: 0)
        }

        HStack {
          Button("Create Task") {
            let title = newTaskTitle
            let description = newTaskDescription
            let tags = tagsIncludingPendingInput(newTaskTags, input: newTaskTagInput)
            let projectID = newTaskProjectID.isEmpty ? nil : newTaskProjectID
            let priority = newTaskPriority
            let taskDueDate = includeDueDate ? dueDate : nil

            Task {
              let created = await appState.createTask(
                title: title,
                priority: priority,
                dueDate: taskDueDate,
                tags: tags,
                subtaskTitles: [],
                description: description,
                projectID: projectID
              )

              guard created else { return }
              newTaskTitle = ""
              newTaskDescription = ""
              newTaskTags = []
              newTaskTagInput = ""
              newTaskProjectID = ""
              searchQuery = ""
              taskFilter = .active
              includeDueDate = false
              resetQuickProjectForm()
              showQuickProjectCreator = false
              showQuickAddForm = false
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("Cancel") {
            newTaskTags = []
            newTaskTagInput = ""
            resetQuickProjectForm()
            showQuickProjectCreator = false
            showQuickAddForm = false
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      } else {
        Button {
          showQuickAddForm = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "plus")
              .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
            Text("Add a task")
              .font(SerenityType.bodyMedium)
            Spacer()
          }
          .foregroundStyle(SerenityPalette.textSecondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
      }
    }
    .padding(showQuickAddForm ? 16 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var quickProjectCreator: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(assignableProjects.isEmpty ? "Create a project to organize this task" : "New project", systemImage: "folder.badge.plus")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)
      }

      TextField("Project name", text: $quickProjectName)
        .textFieldStyle(.plain)
        .serenityInputField()

      TextField("Description (optional)", text: $quickProjectDescription)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack(spacing: 10) {
        ColorPicker("Project color", selection: $quickProjectColor, supportsOpacity: false)
          .labelsHidden()
        Text(ProjectColorCodec.hex(from: quickProjectColor))
          .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer()

        Button("Cancel") {
          resetQuickProjectForm()
          showQuickProjectCreator = false
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Create Project") {
          let name = quickProjectName
          let description = quickProjectDescription
          let colorHex = ProjectColorCodec.hex(from: quickProjectColor)

          Task {
            guard let project = await appState.createProject(
              name: name,
              description: description,
              color: colorHex
            ) else {
              return
            }

            newTaskProjectID = project.id
            resetQuickProjectForm()
            showQuickProjectCreator = false
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
        .disabled(quickProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(12)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func taskRow(_ task: TaskEntity) -> some View {
    let isExpanded = expandedTaskID == task.id
    let projectName = projectName(for: task.projectId)
    let completedSubtasks = task.subtasks.filter(\.completed).count
    let commentCount = task.activity.filter { $0.kind == .comment }.count
    let hasSummary = task.dueDate != nil || projectName != nil || !task.subtasks.isEmpty || commentCount > 0

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        // Shown only once a selection exists (started with Cmd-click). Rendering
        // it always put an unchecked circle next to a checked completion box on
        // every finished row, which read as done and not-done at once.
        if isSelecting {
          Button {
            appState.toggleTaskSelection(id: task.id)
          } label: {
            Image(systemName: appState.selectedTaskIDs.contains(task.id) ? "checkmark.square.fill" : "square")
              .foregroundStyle(appState.selectedTaskIDs.contains(task.id) ? SerenityPalette.accent : SerenityPalette.textSecondary)
          }
          .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
          .accessibilityLabel(appState.selectedTaskIDs.contains(task.id) ? "Deselect \(task.title)" : "Select \(task.title)")
        }

        Button {
          Task { await appState.toggleTaskCompletion(id: task.id) }
        } label: {
          Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(task.completed ? .green : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
          .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")

        taskEditorButton(task, accessibilityLabel: "Edit task \(task.title)") {
          Text(task.title)
            .font(SerenityType.scaledSystem(size: 16, weight: .medium))
            .foregroundStyle(task.completed ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
            .strikethrough(task.completed)
            .lineLimit(1)
        }

        Text(task.priority.rawValue.capitalized)
          .font(SerenityType.caption)
          .padding(.horizontal, 9)
          .padding(.vertical, 3)
          .background(priorityColor(task.priority).opacity(0.18), in: Capsule())

        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            expandedTaskID = isExpanded ? nil : task.id
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
            .foregroundStyle(SerenityPalette.textSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityLabel(isExpanded ? "Collapse task details" : "Expand task details")
        .accessibilityValue(task.title)
      }

      if hasSummary {
        taskEditorButton(task, accessibilityLabel: "Edit task \(task.title) details") {
          HStack(spacing: 14) {
            if let dueDate = task.dueDate {
              Label(SerenityDateText.dueWithTime(dueDate), systemImage: "calendar")
                .foregroundStyle(isOverdue(task) ? Color.red : SerenityPalette.textSecondary)
            }
            if let projectName {
              Label(projectName, systemImage: "folder")
            }
            if !task.subtasks.isEmpty {
              Label("\(completedSubtasks)/\(task.subtasks.count) subtasks", systemImage: "checklist")
            }
            if commentCount > 0 {
              Label("\(commentCount) comment\(commentCount == 1 ? "" : "s")", systemImage: "bubble.left")
            }
          }
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
        }
      }

      if isExpanded {
        TaskDetailPanel(task: task, onEditTask: onEditTask)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 18)
    .background(
      appState.selectedTaskIDs.contains(task.id)
        ? SerenityPalette.accent.opacity(0.10)
        : (isOverdue(task) ? Color.red.opacity(0.06) : Color.clear)
    )
    .contentShape(Rectangle())
    // Starts a selection without giving every row a permanent selection
    // control. `TapGesture.modifiers` is macOS-only, so touch gets the
    // idiomatic long-press instead.
#if os(macOS)
    .simultaneousGesture(
      TapGesture()
        .modifiers(.command)
        .onEnded { _ in
          appState.toggleTaskSelection(id: task.id)
        }
    )
#else
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.4)
        .onEnded { _ in
          appState.toggleTaskSelection(id: task.id)
        }
    )
#endif
  }

  private func taskEditorButton<Content: View>(
    _ task: TaskEntity,
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      onEditTask(task)
    } label: {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
  }

  private var projectsView: some View {
    VStack(alignment: .leading, spacing: 16) {
      projectAddPanel

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          if appState.projects.isEmpty {
            Text("No projects yet. Add one above to group your tasks.")
              .foregroundStyle(SerenityPalette.textSecondary)
          } else {
            ForEach(appState.projects) { project in
              projectRow(project)
            }
          }
        }
        .padding(.top, 4)
      } label: {
        HStack {
          Text("Projects")
          Spacer()
          Toggle("Include archived", isOn: $appState.includeArchivedProjects)
            .toggleStyle(.switch)
            .font(SerenityType.caption)
            .onChange(of: appState.includeArchivedProjects) { _, _ in
              Task {
                await appState.refreshCoreWorkflowData()
              }
            }
        }
      }
    }
    .sheet(item: $editingProject) { project in
      ProjectEditorView(project: project) { name, description, color in
        Task {
          await appState.updateProject(id: project.id, name: name, description: description, color: color)
        }
      }
      .serenityDesktopSheetSize(minWidth: 420, minHeight: 260)
    }
    .confirmationDialog(
      "Delete \(projectPendingDeletion?.name ?? "this project")?",
      isPresented: Binding(
        get: { projectPendingDeletion != nil },
        set: { if !$0 { projectPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Project", role: .destructive) {
        guard let project = projectPendingDeletion else { return }
        projectPendingDeletion = nil
        Task {
          await appState.deleteProject(id: project.id)
        }
      }
      Button("Cancel", role: .cancel) {
        projectPendingDeletion = nil
      }
    } message: {
      Text("Tasks assigned to it stay, but lose their project.")
    }
  }

  private func projectRow(_ project: ProjectEntity) -> some View {
    let taskCount = appState.tasks.filter { $0.projectId == project.id }.count

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Circle()
          .fill(ProjectColorCodec.color(from: project.color) ?? SerenityPalette.accent)
          .frame(width: 10, height: 10)

        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
            .font(SerenityType.bodyLarge.weight(.semibold))
          if let description = project.description, !description.isEmpty {
            Text(description)
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
        }

        Spacer()

        Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Text(project.archived ? "Archived" : "Active")
          .font(SerenityType.caption)
          .foregroundStyle(project.archived ? SerenityPalette.textSecondary : .green)
      }

      HStack(spacing: 8) {
        Button("Edit") {
          editingProject = project
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button(project.archived ? "Unarchive" : "Archive") {
          Task {
            await appState.toggleProjectArchive(id: project.id)
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Spacer()

        Button("Delete", role: .destructive) {
          projectPendingDeletion = project
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(10)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var projectAddPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showProjectCreator {
        TextField("Project name", text: $newProjectName)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Description (optional)", text: $newProjectDescription)
          .textFieldStyle(.plain)
          .serenityInputField()

        HStack(spacing: 10) {
          ColorPicker("Project color", selection: $newProjectColor, supportsOpacity: false)
            .labelsHidden()
          Text(ProjectColorCodec.hex(from: newProjectColor))
            .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(SerenityPalette.textSecondary)

          Spacer(minLength: 0)
        }

        HStack(spacing: 12) {
          Button("Create Project") {
            let name = newProjectName
            let description = newProjectDescription
            let colorHex = ProjectColorCodec.hex(from: newProjectColor)

            Task {
              guard await appState.createProject(
                name: name,
                description: description,
                color: colorHex
              ) != nil else { return }

              resetProjectForm()
              showProjectCreator = false
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("Cancel") {
            resetProjectForm()
            showProjectCreator = false
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      } else {
        Button {
          showProjectCreator = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "plus")
              .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
            Text("Add a project")
              .font(SerenityType.bodyMedium)
            Spacer()
          }
          .foregroundStyle(SerenityPalette.textSecondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
      }
    }
    .padding(showProjectCreator ? 16 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var calendarView: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Schedule Calendar")
            .font(SerenityType.sectionTitle)
          Text("\(dueTasksSorted.count) task\(dueTasksSorted.count == 1 ? "" : "s") with due dates")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 16)

        serenityChip("Today \(appState.todayTasks.count)", tint: SerenityPalette.accent)
        serenityChip("Overdue \(appState.overdueTasks.count)", tint: appState.overdueTasks.isEmpty ? SerenityPalette.textSecondary : .red)

        HStack(spacing: 6) {
          Button {
            shiftCalendarMonth(by: -1)
          } label: {
            Image(systemName: "chevron.left")
              .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
              .frame(width: 26, height: 26)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)

          Text(calendarVisibleMonth.formatted(.dateTime.month(.wide).year()))
            .font(SerenityType.bodyMedium)
            .frame(minWidth: 170, alignment: .center)

          Button {
            shiftCalendarMonth(by: 1)
          } label: {
            Image(systemName: "chevron.right")
              .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
              .frame(width: 26, height: 26)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)
        }

        Button("Today") {
          jumpCalendarToToday()
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 14) {
          calendarMonthPanel
          calendarAgendaPanel
            .frame(width: 340)
        }

        VStack(alignment: .leading, spacing: 14) {
          calendarMonthPanel
          calendarAgendaPanel
        }
      }
    }
  }

  private var displayedTasks: [TaskEntity] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return appState.tasks
      .filter { task in
        switch taskFilter {
        case .all:
          break
        case .active:
          if task.completed { return false }
        case .inbox:
          if task.completed || task.dueDate != nil { return false }
        case .completed:
          if !task.completed { return false }
        }

        guard !query.isEmpty else { return true }
        let haystack = [
          task.title,
          task.description ?? "",
          task.tags.joined(separator: " "),
          task.subtasks.map(\.title).joined(separator: " "),
        ]
          .joined(separator: " ")
          .lowercased()
        return haystack.contains(query)
      }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  /// Grouped in bucket order, each group keeping the due-date sort above.
  private var groupedTasks: [(bucket: DueBucket, tasks: [TaskEntity])] {
    let grouped = Dictionary(grouping: displayedTasks) { DueBucket.containing($0) }
    return DueBucket.allCases.compactMap { bucket in
      guard let tasks = grouped[bucket], !tasks.isEmpty else { return nil }
      return (bucket, tasks)
    }
  }

  private var dueTasksSorted: [TaskEntity] {
    appState.tasks
      .filter { $0.dueDate != nil }
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  private var dueTasksByDay: [Date: [TaskEntity]] {
    Dictionary(grouping: dueTasksSorted) { task in
      Calendar.current.startOfDay(for: task.dueDate ?? task.createdAt)
    }
  }

  private var selectedDayStart: Date {
    Calendar.current.startOfDay(for: selectedCalendarDate)
  }

  private var selectedDayTasks: [TaskEntity] {
    (dueTasksByDay[selectedDayStart] ?? [])
      .sorted { lhs, rhs in
        (lhs.dueDate ?? lhs.createdAt) < (rhs.dueDate ?? rhs.createdAt)
      }
  }

  private var calendarWeekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var calendarGridDates: [Date] {
    Calendar.current.monthGridDates(for: calendarVisibleMonth)
  }

  private var calendarMonthPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ForEach(Array(calendarWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, 4)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
        ForEach(calendarGridDates, id: \.self) { date in
          calendarDayCell(date)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var calendarAgendaPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(selectedDayStart.formatted(date: .complete, time: .omitted))
          .font(SerenityType.sectionTitle)
          .lineLimit(1)
        Spacer(minLength: 8)
        serenityChip("\(selectedDayTasks.count) due", tint: SerenityPalette.accent)
      }

      HStack(spacing: 8) {
        serenityChip("\(selectedDayTasks.filter { !$0.completed }.count) open", tint: .orange)
        serenityChip("\(selectedDayTasks.filter(\.completed).count) done", tint: .green)
      }

      if selectedDayTasks.isEmpty {
        Text("No tasks due on this date.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.top, 2)
      } else {
        VStack(spacing: 8) {
          ForEach(Array(selectedDayTasks.prefix(8))) { task in
            calendarAgendaTaskRow(task)
          }
        }

        if selectedDayTasks.count > 8 {
          Text("+\(selectedDayTasks.count - 8) more due task\(selectedDayTasks.count - 8 == 1 ? "" : "s")")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.top, 2)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func calendarDayCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)
    let isSelected = calendar.isDate(dayStart, inSameDayAs: selectedDayStart)
    let isInVisibleMonth = calendar.isDate(dayStart, equalTo: calendarVisibleMonth, toGranularity: .month)
    let isToday = calendar.isDateInToday(dayStart)
    let dueItems = dueTasksByDay[dayStart] ?? []
    let openDueCount = dueItems.filter { !$0.completed }.count

    return Button {
      selectedCalendarDate = dayStart
      calendarVisibleMonth = calendar.startOfMonth(for: dayStart)
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text("\(calendar.component(.day, from: dayStart))")
            .font(SerenityType.bodyMedium.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textPrimary)

          Spacer(minLength: 0)

          if isToday {
            Circle()
              .fill(isSelected ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.accent)
              .frame(width: 6, height: 6)
          }
        }

        Spacer(minLength: 0)

        if !dueItems.isEmpty {
          HStack(spacing: 4) {
            Circle()
              .fill(openDueCount == 0 ? .green : SerenityPalette.accent)
              .frame(width: 6, height: 6)

            Text("\(dueItems.count)")
              .font(SerenityType.caption)
              .foregroundStyle(isSelected ? SerenityPalette.textOnInteractiveSurface.opacity(0.9) : SerenityPalette.textSecondary)
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
      .background(
        (isSelected ? SerenityPalette.activeItemBackground : SerenityPalette.innerCardBackground.opacity(isInVisibleMonth ? 0.58 : 0.3)),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(isSelected ? SerenityPalette.border : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .opacity(isInVisibleMonth ? 1 : 0.44)
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func calendarAgendaTaskRow(_ task: TaskEntity) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(task.completed ? .green : priorityColor(task.priority))
        .frame(width: 8, height: 8)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .font(SerenityType.bodyMedium)
          .strikethrough(task.completed)
          .lineLimit(2)

        HStack(spacing: 6) {
          if let dueDate = task.dueDate {
            Text(dueDate.formatted(date: .omitted, time: .shortened))
          }
          if let projectName = projectName(for: task.projectId) {
            Text(projectName)
          }
        }
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  private func jumpCalendarToToday() {
    let today = Calendar.current.startOfDay(for: Date())
    selectedCalendarDate = today
    calendarVisibleMonth = Calendar.current.startOfMonth(for: today)
  }

  private func shiftCalendarMonth(by value: Int) {
    let calendar = Calendar.current
    guard let shifted = calendar.date(byAdding: .month, value: value, to: calendarVisibleMonth) else { return }
    let monthStart = calendar.startOfMonth(for: shifted)
    let preferredDay = calendar.component(.day, from: selectedCalendarDate)
    let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
    let clampedDay = min(preferredDay, dayCount)
    let nextSelected = calendar.date(byAdding: .day, value: clampedDay - 1, to: monthStart) ?? monthStart
    calendarVisibleMonth = monthStart
    selectedCalendarDate = calendar.startOfDay(for: nextSelected)
  }

  private func isOverdue(_ task: TaskEntity) -> Bool {
    guard let dueDate = task.dueDate else { return false }
    return !task.completed && dueDate < Calendar.current.startOfDay(for: Date())
  }

  private func priorityColor(_ priority: TaskPriority) -> Color {
    switch priority {
    case .low:
      return .mint
    case .medium:
      return .orange
    case .high:
      return .red
    }
  }

  private func priorityIcon(_ priority: TaskPriority) -> String {
    switch priority {
    case .low:
      return "arrow.down.circle"
    case .medium:
      return "equal.circle"
    case .high:
      return "exclamationmark.circle"
    }
  }

  private var assignableProjects: [ProjectEntity] {
    appState.projects.filter { !$0.archived }
  }

  private var projectDropdownOptions: [SerenityDropdownOption<String>] {
    [SerenityDropdownOption(value: "", title: "No project", systemImage: "minus.circle")] +
      assignableProjects.map { project in
        SerenityDropdownOption(
          value: project.id,
          title: project.name,
          subtitle: project.description,
          tint: ProjectColorCodec.color(from: project.color) ?? SerenityPalette.accent
        )
      }
  }

  private var priorityDropdownOptions: [SerenityDropdownOption<TaskPriority>] {
    TaskPriority.allCases.map { priority in
      SerenityDropdownOption(
        value: priority,
        title: priority.rawValue.capitalized,
        systemImage: priorityIcon(priority),
        tint: priorityColor(priority)
      )
    }
  }

  private func projectName(for projectID: String?) -> String? {
    guard let projectID else { return nil }
    return appState.projects.first(where: { $0.id == projectID })?.name
  }

  private func resetQuickProjectForm() {
    quickProjectName = ""
    quickProjectDescription = ""
    quickProjectColor = ProjectColorCodec.fallbackColor
  }

  private func resetProjectForm() {
    newProjectName = ""
    newProjectDescription = ""
    newProjectColor = ProjectColorCodec.fallbackColor
  }

}

/// Home's daily surface. Three bands — what slipped, what is due, what has not
/// been scheduled — so nothing captured can fall out of view. Empty bands are
/// omitted entirely rather than reporting zero.
private struct TodayOverviewView: View {
  let onEditTask: (TaskEntity) -> Void

  @EnvironmentObject private var appState: AppState

  @State private var expandedTaskID: String?

  private var bands: [Band] {
    [
      Band(kind: .overdue, tasks: appState.overdueTasks),
      Band(kind: .today, tasks: appState.todayTasks),
      Band(kind: .upcoming, tasks: appState.upcomingTasks),
      Band(kind: .inbox, tasks: appState.inboxTasks),
    ]
    .filter { !$0.tasks.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if bands.isEmpty {
        SerenityEmptyState(
          icon: "checkmark.circle",
          title: "Nothing waiting",
          message: "Capture something above, or open ActionHub to plan ahead."
        ) {
          Button("Open ActionHub") {
            appState.setSection(.actionHub)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      } else {
        ForEach(bands) { band in
          bandPanel(band)
        }
      }
    }
  }

  private func bandPanel(_ band: Band) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: band.kind.systemImage)
          .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
          .foregroundStyle(band.kind.tint)
        Text(band.kind.title)
          .font(SerenityType.sectionTitle)
        Text("\(band.tasks.count)")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
        Spacer()
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(band.tasks) { task in
          taskRow(task, in: band.kind)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func taskRow(_ task: TaskEntity, in kind: Band.Kind) -> some View {
    let isExpanded = expandedTaskID == task.id

    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Button {
          Task { await appState.toggleTaskCompletion(id: task.id) }
        } label: {
          Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
            .font(SerenityType.scaledSystem(size: 18, weight: .regular))
            .foregroundStyle(task.completed ? Color.green : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")

        Text(task.title)
          .strikethrough(task.completed, color: SerenityPalette.textSecondary)
          .foregroundStyle(task.completed ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 8)

        if let dueDate = task.dueDate {
          Text(SerenityDateText.dueWithTime(dueDate))
            .font(SerenityType.caption)
            .foregroundStyle(kind == .overdue ? Color.red.opacity(0.9) : SerenityPalette.textSecondary)
        }

        Button {
          toggleExpansion(of: task)
        } label: {
          Image(systemName: "chevron.right")
            .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
            .foregroundStyle(SerenityPalette.textSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityLabel(isExpanded ? "Collapse task details" : "Expand task details")
        .accessibilityValue(task.title)
      }
      // The whole row opens the task, not just the chevron: the band rows are
      // what you reach for on Home.
      .contentShape(Rectangle())
      .hoverCursor(.pointingHand)
      .onTapGesture {
        toggleExpansion(of: task)
      }

      if isExpanded {
        TaskDetailPanel(task: task, onEditTask: onEditTask)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func toggleExpansion(of task: TaskEntity) {
    withAnimation(.easeInOut(duration: 0.18)) {
      expandedTaskID = expandedTaskID == task.id ? nil : task.id
    }
  }

  struct Band: Identifiable {
    enum Kind {
      case overdue
      case today
      case upcoming
      case inbox

      var title: String {
        switch self {
        case .overdue:
          return "Overdue"
        case .today:
          return "Today"
        case .upcoming:
          return "Next 7 days"
        case .inbox:
          return "Inbox"
        }
      }

      var systemImage: String {
        switch self {
        case .overdue:
          return "exclamationmark.triangle.fill"
        case .today:
          return "sun.max.fill"
        case .upcoming:
          return "calendar"
        case .inbox:
          return "tray"
        }
      }

      var tint: Color {
        switch self {
        case .overdue:
          return .red
        case .today:
          return SerenityPalette.accent
        case .upcoming, .inbox:
          return SerenityPalette.textSecondary
        }
      }
    }

    let kind: Kind
    let tasks: [TaskEntity]

    var id: String { kind.title }
  }
}

private struct SerenityDateRangePicker: View {
  @Environment(\.serenityCompactLayout) private var compactLayout
  @Binding var isEnabled: Bool
  @Binding var startDate: Date
  @Binding var endDate: Date
  let title: String
  let showsEnableToggle: Bool
  let onApply: () -> Void
  let onClose: () -> Void

  @State private var visibleMonth: Date
  @State private var nextPick: NextPick = .start

  private enum NextPick { case start, end }

  init(
    isEnabled: Binding<Bool>,
    startDate: Binding<Date>,
    endDate: Binding<Date>,
    title: String = "Filter by date range",
    showsEnableToggle: Bool = true,
    onApply: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    _isEnabled = isEnabled
    _startDate = startDate
    _endDate = endDate
    self.title = title
    self.showsEnableToggle = showsEnableToggle
    self.onApply = onApply
    self.onClose = onClose
    let anchor = isEnabled.wrappedValue ? startDate.wrappedValue : Date()
    _visibleMonth = State(initialValue: Calendar.current.startOfMonth(for: anchor))
  }

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

  private var weekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var gridDates: [Date] {
    Calendar.current.monthGridDates(for: visibleMonth)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if showsEnableToggle {
        Toggle(isOn: $isEnabled) {
          Text(title)
            .font(SerenityType.bodyMedium)
        }
        .toggleStyle(.switch)
        .tint(SerenityPalette.accent)
        .onChange(of: isEnabled) { _, _ in onApply() }
      } else {
        Text(title)
          .font(SerenityType.bodyMedium.weight(.semibold))
      }

      if isEnabled || !showsEnableToggle {
        calendarBody
      }
    }
    .padding(16)
    .frame(width: 320)
  }

  private var calendarBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      monthHeader
      weekdayRow
      grid
      Divider().overlay(SerenityPalette.thinBorder)
      rangeSummary
      footerButtons
    }
  }

  private var monthHeader: some View {
    HStack(spacing: 8) {
      Button { shiftMonth(by: -1) } label: {
        Image(systemName: "chevron.left")
          .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
        .font(SerenityType.bodyLarge.weight(.semibold))
        .frame(maxWidth: .infinity)

      Button { shiftMonth(by: 1) } label: {
        Image(systemName: "chevron.right")
          .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)
    }
  }

  private var weekdayRow: some View {
    HStack(spacing: 4) {
      ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 2)
  }

  private var grid: some View {
    LazyVGrid(columns: columns, spacing: 4) {
      ForEach(gridDates, id: \.self) { date in
        dayCell(date)
      }
    }
  }

  private func dayCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.startOfDay(for: endDate)
    let isStart = day == start
    let isEnd = day == end
    let isEndpoint = isStart || isEnd
    let isInRange = day > start && day < end
    let isToday = calendar.isDateInToday(day)
    let isInVisibleMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)

    return Button { handleTap(day) } label: {
      Text("\(calendar.component(.day, from: day))")
        .font(SerenityType.bodyMedium.weight(isEndpoint ? .semibold : .regular))
        .foregroundStyle(
          isEndpoint
            ? SerenityPalette.textOnInteractiveSurface
            : SerenityPalette.textPrimary
        )
        .frame(maxWidth: .infinity, minHeight: compactLayout ? SerenityTouchMetrics.minimumTarget : 30)
        .background(
          dayBackground(isEndpoint: isEndpoint, isInRange: isInRange),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
              dayBorderColor(isEndpoint: isEndpoint, isInRange: isInRange, isToday: isToday),
              lineWidth: 1
            )
        )
        .opacity(isInVisibleMonth ? 1 : 0.32)
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func dayBackground(isEndpoint: Bool, isInRange: Bool) -> Color {
    if isEndpoint { return SerenityPalette.primaryActionBackground }
    if isInRange { return SerenityPalette.accent.opacity(0.18) }
    return Color.clear
  }

  private func dayBorderColor(isEndpoint: Bool, isInRange: Bool, isToday: Bool) -> Color {
    if isEndpoint { return SerenityPalette.primaryActionBackground }
    if isToday { return SerenityPalette.accent.opacity(0.6) }
    if isInRange { return SerenityPalette.accent.opacity(0.25) }
    return SerenityPalette.thinBorder
  }

  private var rangeSummary: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("FROM")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(startDate.formatted(.dateTime.month(.abbreviated).day().year()))
          .font(SerenityType.bodyMedium)
      }
      Spacer()
      Image(systemName: "arrow.right")
        .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("TO")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(endDate.formatted(.dateTime.month(.abbreviated).day().year()))
          .font(SerenityType.bodyMedium)
      }
    }
  }

  private var footerButtons: some View {
    HStack {
      Button("Today") {
        let today = Date()
        startDate = today
        endDate = today
        nextPick = .end
        visibleMonth = Calendar.current.startOfMonth(for: today)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Spacer()

      Button("Apply") {
        onApply()
        onClose()
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
      .hoverCursor(.pointingHand)
    }
  }

  private func handleTap(_ day: Date) {
    let calendar = Calendar.current
    if !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
      visibleMonth = calendar.startOfMonth(for: day)
    }
    switch nextPick {
    case .start:
      startDate = day
      endDate = day
      nextPick = .end
    case .end:
      if calendar.compare(day, to: startDate, toGranularity: .day) == .orderedAscending {
        endDate = startDate
        startDate = day
      } else {
        endDate = day
      }
      nextPick = .start
    }
  }

  private func shiftMonth(by value: Int) {
    guard let shifted = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) else { return }
    visibleMonth = Calendar.current.startOfMonth(for: shifted)
  }
}

private struct JournalSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newEntryTitle = ""
  @State private var newEntryContent = ""
  @State private var newEntryMood: JournalMood?
  @State private var newEntryTagList: [String] = []
  @State private var tagInputText = ""

  @State private var editingEntry: JournalEntryEntity?
  @State private var datePopoverOpen = false
  @State private var hoveredEntryId: String?
  @FocusState private var newEntryContentFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      composer
      entriesSection
    }
    .sheet(item: $editingEntry) { entry in
      JournalEntryEditorView(entry: entry) { updatedTitle, updatedContent, updatedMood, updatedTags in
        Task {
          await appState.updateJournalEntry(
            id: entry.id,
            title: updatedTitle,
            content: updatedContent,
            mood: updatedMood,
            tags: updatedTags
          )
        }
      }
      .serenityDesktopSheetSize(minWidth: 460, minHeight: 380)
    }
  }

  // MARK: Composer

  /// Expanded once you engage with it. Title, mood, tags and Save used to sit
  /// open permanently above an empty list, spending ~370pt before you had
  /// decided to write anything.
  private var isComposing: Bool {
    newEntryContentFocused
      || !newEntryContent.isEmpty
      || !newEntryTitle.isEmpty
      || newEntryMood != nil
      || !newEntryTagList.isEmpty
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 14) {
      if isComposing {
        TextField("Title (optional)", text: $newEntryTitle)
          .textFieldStyle(.plain)
          .serenityInputField()
      }

      ZStack(alignment: .topLeading) {
        TextEditor(text: $newEntryContent)
          .focused($newEntryContentFocused)
          .serenityTextArea(minHeight: isComposing ? 140 : 62)

        if newEntryContent.isEmpty && !newEntryContentFocused {
          Text("What's on your mind?")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .allowsHitTesting(false)
        }
      }

      if isComposing {
        VStack(alignment: .leading, spacing: 8) {
          Text("How are you feeling?")
            .font(SerenityType.caption.weight(.medium))
            .foregroundStyle(SerenityPalette.textSecondary)
          HStack(spacing: 8) {
            ForEach(journalMoods, id: \.rawValue) { mood in
              Button {
                newEntryMood = (newEntryMood == mood) ? nil : mood
              } label: {
                Text("\(Self.emoji(for: mood))  \(mood.rawValue.capitalized)")
              }
              .buttonStyle(SerenityPillButtonStyle(selected: newEntryMood == mood))
              .hoverCursor(.pointingHand)
            }
          }
        }

        tagsField

        HStack {
          Spacer()
          Button("Save Entry") {
            submitNewEntry()
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .disabled(saveDisabled)
          .hoverCursor(.pointingHand)
        }
      }
    }
    .padding(16)
    .serenityPanel(cornerRadius: 14)
    .animation(.easeOut(duration: 0.16), value: isComposing)
  }

  private var tagsField: some View {
    SerenityTagInputField(tags: $newEntryTagList, inputText: $tagInputText)
  }

  private func submitNewEntry() {
    let title = newEntryTitle
    let content = newEntryContent
    let mood = newEntryMood
    let tags = tagsIncludingPendingInput(newEntryTagList, input: tagInputText)

    Task {
      await appState.createJournalEntry(
        title: title,
        content: content,
        mood: mood,
        tags: tags
      )
    }

    newEntryTitle = ""
    newEntryContent = ""
    newEntryMood = nil
    newEntryTagList = []
    tagInputText = ""
  }

  private var saveDisabled: Bool {
    newEntryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: Entries

  private var entriesSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      entriesHeader
      Divider().overlay(SerenityPalette.thinBorder)
      entriesContent
    }
  }

  private var entriesHeader: some View {
    HStack(spacing: 10) {
      Text("Entries")
        .font(SerenityType.bodyLarge.weight(.semibold))
      Text(entryCountLabel)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer()
      dateRangeChip
    }
    .padding(.bottom, 10)
  }

  private var entryCountLabel: String {
    let count = appState.filteredJournalEntries.count
    return "\(count) \(count == 1 ? "entry" : "entries")"
  }

  private var dateRangeChip: some View {
    Button {
      datePopoverOpen.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "calendar")
          .font(SerenityType.scaledSystem(size: 11, weight: .medium))
        Text("Date range")
        Image(systemName: "chevron.down")
          .font(SerenityType.scaledSystem(size: 9, weight: .semibold))
      }
    }
    .buttonStyle(SerenityPillButtonStyle(selected: appState.journalDateRangeEnabled))
    .hoverCursor(.pointingHand)
    .popover(isPresented: $datePopoverOpen, arrowEdge: .top) {
      SerenityDateRangePicker(
        isEnabled: $appState.journalDateRangeEnabled,
        startDate: $appState.journalRangeStartDate,
        endDate: $appState.journalRangeEndDate,
        onApply: {
          Task { await appState.refreshCoreWorkflowData() }
        },
        onClose: {
          datePopoverOpen = false
        }
      )
    }
  }

  @ViewBuilder
  private var entriesContent: some View {
    if appState.filteredJournalEntries.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "book.closed")
          .font(SerenityType.scaledSystem(size: 32, weight: .regular))
          .foregroundStyle(SerenityPalette.textSecondary)
        Text("No entries yet")
          .font(SerenityType.bodyLarge.weight(.semibold))
        Text("Your reflections will appear here.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 36)
    } else {
      VStack(spacing: 8) {
        ForEach(appState.filteredJournalEntries) { entry in
          entryRow(entry)
        }
      }
      .padding(.top, 12)
    }
  }

  private func entryRow(_ entry: JournalEntryEntity) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if let mood = entry.mood {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(SerenityPalette.headerIconBackground)
          Text(Self.emoji(for: mood))
            .font(SerenityType.scaledSystem(size: 16))
        }
        .frame(width: 28, height: 28)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(displayTitle(for: entry))
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
          if entry.pinned {
            Image(systemName: "pin.fill")
              .font(SerenityType.scaledSystem(size: 11))
              .foregroundStyle(.orange)
          }
          Spacer()
          Text(entry.date, style: .date)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Text(entry.content)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        if !entry.tags.isEmpty {
          Text(entry.tags.joined(separator: " · "))
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      HStack(spacing: 4) {
        rowAction(systemName: entry.pinned ? "pin.slash" : "pin") {
          Task { await appState.toggleJournalPin(id: entry.id) }
        }
        rowAction(systemName: "pencil") {
          editingEntry = entry
        }
        rowAction(systemName: "trash") {
          Task { await appState.deleteJournalEntry(id: entry.id) }
        }
      }
      .opacity(hoveredEntryId == entry.id ? 1 : 0)
      .animation(.easeOut(duration: 0.12), value: hoveredEntryId)
    }
    .padding(12)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
    .onHover { isHovering in
      hoveredEntryId = isHovering ? entry.id : nil
    }
  }

  private func rowAction(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(SerenityType.scaledSystem(size: 12, weight: .medium))
        .frame(width: 24, height: 24)
        .foregroundStyle(SerenityPalette.textSecondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func displayTitle(for entry: JournalEntryEntity) -> String {
    if let title = entry.title, !title.isEmpty { return title }
    return "Untitled entry"
  }

  private var journalMoods: [JournalMood] {
    [.happy, .neutral, .sad, .excited, .stressed]
  }

  private static func emoji(for mood: JournalMood) -> String {
    switch mood {
    case .happy: return "😊"
    case .neutral: return "😐"
    case .sad: return "😢"
    case .excited: return "✨"
    case .stressed: return "😣"
    }
  }
}

private struct GoalsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newGoalTitle = ""
  @State private var newGoalTarget = "5"
  @State private var newGoalType: GoalType = .weeklyTasks
  @State private var newGoalPriority: GoalPriority = .medium
  @State private var showNewGoalForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if showNewGoalForm {
        newGoalPanel
      } else {
        newGoalButton
      }
      goalsPanel
    }
  }

  /// The form used to sit open permanently above an empty list. It opens on
  /// demand now, and the Active/Completed/Average tiles are gone — they read
  /// 0 / 0 / 0% until the day you have goals, and add nothing after that.
  private var newGoalButton: some View {
    Button {
      showNewGoalForm = true
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "plus")
          .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
        Text("New goal")
          .font(SerenityType.bodyMedium)
        Spacer()
      }
      .foregroundStyle(SerenityPalette.textSecondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var newGoalPanel: some View {
    goalPanel(title: "New Goal", subtitle: "Define a target and track it over time", systemImage: "plus.circle.fill", tint: SerenityPalette.accent) {
      VStack(alignment: .leading, spacing: 14) {
        labeledControl("Goal title") {
          TextField("Goal title", text: $newGoalTitle)
            .textFieldStyle(.plain)
            .serenityInputField()
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 12) {
            targetField
            goalTypeField
            priorityField
          }

          VStack(alignment: .leading, spacing: 12) {
            targetField
            goalTypeField
            priorityField
          }
        }

        HStack(spacing: 10) {
          Button {
            createGoal()
          } label: {
            Label("Create Goal", systemImage: "plus")
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)

          Button("Cancel") {
            showNewGoalForm = false
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      }
    }
  }

  private var targetField: some View {
    labeledControl("Target") {
      TextField("5", text: $newGoalTarget)
        .textFieldStyle(.plain)
        .serenityInputField()
    }
    .frame(maxWidth: 140, alignment: .leading)
  }

  private var goalTypeField: some View {
    labeledControl("Type") {
      SerenityDropdownField(
        placeholder: "Type",
        selection: $newGoalType,
        options: goalTypeOptions
      )
    }
    .frame(maxWidth: 260, alignment: .leading)
  }

  private var priorityField: some View {
    labeledControl("Priority") {
      SerenityDropdownField(
        placeholder: "Priority",
        selection: $newGoalPriority,
        options: goalPriorityOptions
      )
    }
    .frame(maxWidth: 200, alignment: .leading)
  }

  private var goalsPanel: some View {
    goalPanel(title: "Goals", subtitle: "\(appState.goals.count) total", systemImage: "flag.checkered", tint: .green) {
      VStack(alignment: .leading, spacing: 10) {
        if appState.goals.isEmpty {
          VStack(alignment: .center, spacing: 8) {
            Image(systemName: "target")
              .font(SerenityType.scaledSystem(size: 28, weight: .regular))
              .foregroundStyle(SerenityPalette.textSecondary.opacity(0.65))
            Text("No goals yet")
              .font(SerenityType.bodyLarge.weight(.medium))
            Text("Create a goal above to start tracking progress.")
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 26)
        } else {
          ForEach(appState.goals) { goal in
            goalRow(goal)
          }
        }
      }
    }
  }

  private func goalRow(_ goal: GoalEntity) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon(for: goal.type))
          .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
          .foregroundStyle(tint(for: goal.priority))
          .frame(width: 32, height: 32)
          .background(tint(for: goal.priority).opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        VStack(alignment: .leading, spacing: 4) {
          Text(goal.title)
            .font(SerenityType.bodyLarge.weight(.semibold))
            .foregroundStyle(SerenityPalette.textPrimary)
            .lineLimit(2)

          Text("\(goal.progress.current, specifier: "%.0f") / \(goal.progress.target, specifier: "%.0f") - \(goal.progress.percentage, specifier: "%.0f")%")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 8)

        Text(goal.status.rawValue.capitalized)
          .font(SerenityType.caption)
          .foregroundStyle(statusTint(for: goal.status))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(statusTint(for: goal.status).opacity(0.14), in: Capsule())
      }

      ProgressView(value: min(goal.progress.percentage, 100), total: 100)
        .tint(statusTint(for: goal.status))

      HStack(spacing: 10) {
        Text(goalTypeTitle(goal.type))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Text(goal.priority.rawValue.capitalized)
          .font(SerenityType.caption)
          .foregroundStyle(tint(for: goal.priority))

        Spacer(minLength: 8)

        Button {
          Task {
            await appState.incrementGoalProgress(id: goal.id)
          }
        } label: {
          Label("Increment", systemImage: "plus")
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button(role: .destructive) {
          Task {
            await appState.deleteGoal(id: goal.id)
          }
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .hoverCursor(.pointingHand)
      }
    }
    .padding(12)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  private func goalPanel<Content: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: systemImage)
          .font(SerenityType.scaledSystem(size: 14, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 32, height: 32)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

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

  private func labeledControl<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      content()
    }
  }

  private func createGoal() {
    let target = Double(newGoalTarget) ?? 1
    Task {
      await appState.createGoal(
        title: newGoalTitle,
        target: target,
        type: newGoalType,
        priority: newGoalPriority
      )
    }

    newGoalTitle = ""
    newGoalTarget = "5"
    showNewGoalForm = false
  }

  private var goalTypeOptions: [SerenityDropdownOption<GoalType>] {
    goalTypes.map { type in
      SerenityDropdownOption(
        value: type,
        title: goalTypeTitle(type),
        subtitle: goalTypeSubtitle(type),
        systemImage: icon(for: type),
        tint: SerenityPalette.accent
      )
    }
  }

  private var goalPriorityOptions: [SerenityDropdownOption<GoalPriority>] {
    goalPriorities.map { priority in
      SerenityDropdownOption(
        value: priority,
        title: priority.rawValue.capitalized,
        systemImage: priority == .high ? "exclamationmark.triangle.fill" : "circle.fill",
        tint: tint(for: priority)
      )
    }
  }

  private func goalTypeTitle(_ type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "Weekly Tasks"
    case .projectTasks:
      return "Project Tasks"
    case .priorityTasks:
      return "Priority Tasks"
    case .dailyStreak:
      return "Daily Streak"
    case .journalWeekly:
      return "Weekly Journal"
    case .completionRate:
      return "Completion Rate"
    }
  }

  private func goalTypeSubtitle(_ type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "Finish a set number of tasks"
    case .projectTasks:
      return "Move project work forward"
    case .priorityTasks:
      return "Stay focused on high-value tasks"
    case .dailyStreak:
      return "Build a daily habit"
    case .journalWeekly:
      return "Keep reflection consistent"
    case .completionRate:
      return "Improve overall follow-through"
    }
  }

  private func icon(for type: GoalType) -> String {
    switch type {
    case .weeklyTasks:
      return "checklist"
    case .projectTasks:
      return "folder"
    case .priorityTasks:
      return "flag.fill"
    case .dailyStreak:
      return "flame.fill"
    case .journalWeekly:
      return "book.closed.fill"
    case .completionRate:
      return "chart.pie.fill"
    }
  }

  private func tint(for priority: GoalPriority) -> Color {
    switch priority {
    case .low:
      return .green
    case .medium:
      return SerenityPalette.accent
    case .high:
      return .orange
    }
  }

  private func statusTint(for status: GoalStatus) -> Color {
    switch status {
    case .active:
      return SerenityPalette.accent
    case .completed:
      return .green
    case .paused:
      return .orange
    case .failed:
      return .red
    }
  }

  private var goalTypes: [GoalType] {
    [.weeklyTasks, .projectTasks, .priorityTasks, .dailyStreak, .journalWeekly, .completionRate]
  }

  private var goalPriorities: [GoalPriority] {
    [.low, .medium, .high]
  }
}

private struct ProjectsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newProjectName = ""
  @State private var newProjectDescription = ""
  @State private var newProjectColor: Color = ProjectColorCodec.fallbackColor
  @State private var editingProject: ProjectEntity?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("New Project") {
        VStack(alignment: .leading, spacing: 10) {
          TextField("Project name", text: $newProjectName)
            .textFieldStyle(.plain)
            .serenityInputField()
          TextField("Description", text: $newProjectDescription)
            .textFieldStyle(.plain)
            .serenityInputField()
          HStack(spacing: 10) {
            ColorPicker("Project color", selection: $newProjectColor, supportsOpacity: false)
            Text(ProjectColorCodec.hex(from: newProjectColor))
              .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          HStack {
            Button("Create Project") {
              let name = newProjectName
              let description = newProjectDescription
              let colorHex = ProjectColorCodec.hex(from: newProjectColor)

              Task {
                await appState.createProject(
                  name: name,
                  description: description,
                  color: colorHex
                )
              }

              newProjectName = ""
              newProjectDescription = ""
              newProjectColor = ProjectColorCodec.fallbackColor
            }
            .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)

            Toggle("Include archived", isOn: $appState.includeArchivedProjects)
              .onChange(of: appState.includeArchivedProjects) { _, _ in
                Task {
                  await appState.refreshCoreWorkflowData()
                }
              }
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Projects") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.projects.isEmpty {
            Text("No projects available")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.projects) { project in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                      .font(SerenityType.bodyLarge.weight(.semibold))
                    Text(project.description ?? "No description")
                      .font(SerenityType.caption)
                      .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                      Circle()
                        .fill(ProjectColorCodec.color(from: project.color) ?? Color.secondary)
                        .frame(width: 10, height: 10)
                      Text("Color: \(project.color)")
                        .font(SerenityType.scaledSystem(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                    }
                  }

                  Spacer()

                  if project.archived {
                    Text("Archived")
                      .font(SerenityType.caption)
                      .padding(.horizontal, 8)
                      .padding(.vertical, 2)
                      .background(Color.secondary.opacity(0.2), in: Capsule())
                  }
                }

                HStack {
                  Button(project.archived ? "Unarchive" : "Archive") {
                    Task {
                      await appState.toggleProjectArchive(id: project.id)
                    }
                  }
                  .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)

                  Button("Edit") {
                    editingProject = project
                  }
                  .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)

                  Spacer()

                  Button("Delete", role: .destructive) {
                    Task {
                      await appState.deleteProject(id: project.id)
                    }
                  }
                  .buttonStyle(.borderless)
          .hoverCursor(.pointingHand)
                }
              }
              .padding(10)
              .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
        .padding(.top, 8)
      }
    }
    .sheet(item: $editingProject) { project in
      ProjectEditorView(project: project) { name, description, color in
        Task {
          await appState.updateProject(id: project.id, name: name, description: description, color: color)
        }
      }
      .serenityDesktopSheetSize(minWidth: 420, minHeight: 260)
    }
  }
}

struct AIProviderDropdownAvailability {
  static func enabledProviders(from credentials: [AICredentialEntity]) -> [AICredentialProvider] {
    var providers: [AICredentialProvider] = []

    for credential in credentials where credential.enabled && !providers.contains(credential.provider) {
      providers.append(credential.provider)
    }

    return providers
  }
}

struct InsightsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var insightNoteDrafts: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      commandCenter

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          contentColumn
            .frame(maxWidth: .infinity, alignment: .topLeading)

          sideColumn
            .frame(width: 340, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: 18) {
          contentColumn
          sideColumn
        }
      }
    }
  }

  private var commandCenter: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Image(systemName: hasEnabledCredential ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
              .foregroundStyle(hasEnabledCredential ? .green : .orange)
            Text(hasEnabledCredential ? "Ready to analyze" : "Provider setup required")
              .font(SerenityType.bodyLarge.weight(.semibold))
          }

          Text(appState.aiStatusMessage)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      if !hasEnabledCredential {
        setupBanner
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          generateInsightButton
          recapButton(title: "Weekly Recap", type: .weekly)
          recapButton(title: "Monthly Recap", type: .monthly)
          Divider().frame(height: 28)
          summaryButton(title: "Task Summary", type: .tasks)
          summaryButton(title: "Journal Summary", type: .journal)
          summaryButton(title: "Combined Summary", type: .combined)
        }

        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            generateInsightButton
            recapButton(title: "Weekly Recap", type: .weekly)
            recapButton(title: "Monthly Recap", type: .monthly)
          }
          HStack(spacing: 10) {
            summaryButton(title: "Task Summary", type: .tasks)
            summaryButton(title: "Journal Summary", type: .journal)
            summaryButton(title: "Combined Summary", type: .combined)
          }
        }
      }
    }
    .padding(18)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var setupBanner: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("AI Provider not configured")
          .font(SerenityType.bodyMedium)
        HStack(spacing: 4) {
          Text("You need to configure an AI provider to use this feature.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
          Button("Go to Settings") {
            appState.setSection(.settings, settingsTab: .aiProvider)
          }
          .buttonStyle(.plain)
          .foregroundStyle(SerenityPalette.accent)
          .hoverCursor(.pointingHand)
        }
      }
      Spacer()
    }
    .padding(12)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
    )
  }

  private var contentColumn: some View {
    VStack(alignment: .leading, spacing: 18) {
      insightsPanel
      recapsPanel
      summariesPanel
    }
  }

  private var sideColumn: some View {
    VStack(alignment: .leading, spacing: 18) {
      analysisSettingsPanel
      usagePanel
    }
  }

  private var insightsPanel: some View {
    sectionPanel(title: "Latest Insights", subtitle: "\(appState.aiInsights.count) generated") {
      if appState.aiInsights.isEmpty {
        SerenityEmptyState(
          icon: "chart.bar.xaxis",
          title: "No insights yet",
          message: "Generate insights to surface recommendations from your tasks, journal, goals, and projects."
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(appState.aiInsights.prefix(12)) { insight in
            insightCard(insight)
          }
        }
      }
    }
  }

  private var recapsPanel: some View {
    sectionPanel(title: "Recaps", subtitle: "\(appState.aiRecaps.count) saved") {
      if appState.aiRecaps.isEmpty {
        SerenityEmptyState(
          icon: "calendar.badge.clock",
          title: "No recaps yet",
          message: "Weekly and monthly recaps will appear here after generation."
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(appState.aiRecaps.prefix(8)) { recap in
            recapCard(recap)
          }
        }
      }
    }
  }

  private var summariesPanel: some View {
    sectionPanel(title: "Summaries", subtitle: "\(appState.aiSummaries.count) generated") {
      if appState.aiSummaries.isEmpty {
        SerenityEmptyState(
          icon: "sparkles",
          title: "No summaries yet",
          message: "Task, journal, and combined summaries will be listed here."
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(appState.aiSummaries.prefix(10)) { summary in
            summaryCard(summary)
          }
        }
      }

      if let path = appState.lastSummaryExportPath {
        Text("Last export: \(path)")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
    }
  }

  private var analysisSettingsPanel: some View {
    sectionPanel(title: "Analysis Settings", subtitle: "Scope and cadence") {
      VStack(alignment: .leading, spacing: 14) {
        labeledPicker("Active Provider") {
          SerenityDropdownField(
            placeholder: activeProviderDropdownPlaceholder,
            selection: Binding(
              get: { selectedActiveProviderValue },
              set: { value in
                guard let provider = AICredentialProvider(rawValue: value) else { return }
                Task {
                  await appState.setAIActiveProvider(provider)
                }
              }
            ),
            options: activeProviderDropdownOptions
          )
          .frame(maxWidth: 260, alignment: .leading)
        }

        labeledPicker("Frequency") {
          SerenityDropdownField(
            placeholder: "Frequency",
            selection: Binding(
              get: { appState.aiSettings.analysisFrequency },
              set: { frequency in
                Task { await appState.setAIAnalysisFrequency(frequency) }
              }
            ),
            options: frequencyDropdownOptions
          )
          .frame(maxWidth: 220, alignment: .leading)
        }

        Toggle("Auto analyze", isOn: Binding(
          get: { appState.aiSettings.autoAnalyze },
          set: { enabled in
            Task { await appState.setAIAutoAnalyze(enabled) }
          }
        ))
        .toggleStyle(.switch)

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          Text("Included Data")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          dataScopeToggle(title: "Tasks", isOn: appState.aiSettings.dataTypes.includeTasks) { enabled in
            await appState.setAIDataTypes(
              includeTasks: enabled,
              includeJournal: appState.aiSettings.dataTypes.includeJournal,
              includeProjects: appState.aiSettings.dataTypes.includeProjects
            )
          }
          dataScopeToggle(title: "Journal", isOn: appState.aiSettings.dataTypes.includeJournal) { enabled in
            await appState.setAIDataTypes(
              includeTasks: appState.aiSettings.dataTypes.includeTasks,
              includeJournal: enabled,
              includeProjects: appState.aiSettings.dataTypes.includeProjects
            )
          }
          dataScopeToggle(title: "Projects", isOn: appState.aiSettings.dataTypes.includeProjects) { enabled in
            await appState.setAIDataTypes(
              includeTasks: appState.aiSettings.dataTypes.includeTasks,
              includeJournal: appState.aiSettings.dataTypes.includeJournal,
              includeProjects: enabled
            )
          }
        }
      }
    }
  }

  private var usagePanel: some View {
    sectionPanel(title: "Recent Usage", subtitle: "\(appState.aiUsageEntries.count) records") {
      if appState.aiUsageEntries.isEmpty {
        SerenityEmptyState(icon: "bolt.horizontal", title: "No usage records", message: "Token usage will appear after AI actions run.")
          .padding(.vertical, 2)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(appState.aiUsageEntries.prefix(8)) { usage in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(usage.operation.rawValue.capitalized)
                  .font(SerenityType.bodyMedium)
                Text(usage.provider.rawValue.capitalized)
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
              Spacer()
              Text("\(usage.totalTokens) tokens")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
            }
          }
        }
      }
    }
  }

  private var generateInsightButton: some View {
    Button {
      Task { await appState.runAIAnalysis() }
    } label: {
      Label("Generate Insights", systemImage: "chart.bar.xaxis")
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(!hasEnabledCredential)
  }

  private func recapButton(title: String, type: AIRecapType) -> some View {
    Button {
      Task { await appState.generateAIRecap(type: type) }
    } label: {
      Label(title, systemImage: "calendar")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(!hasEnabledCredential)
  }

  private func summaryButton(title: String, type: SummaryType) -> some View {
    Button {
      Task { await appState.generateAISummary(type: type) }
    } label: {
      Label(title, systemImage: "doc.text")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(!hasEnabledCredential)
  }

  private func sectionPanel<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(SerenityType.sectionTitle)
        Spacer()
        if let subtitle {
          Text(subtitle)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
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

  private func insightCard(_ insight: AIInsightEntity) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: insightIcon(for: insight.type))
          .foregroundStyle(SerenityPalette.accent)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(insight.title)
              .font(SerenityType.bodyLarge.weight(.semibold))
            Spacer()
            Text("\(Int(insight.confidence * 100))%")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          Text(insight.description)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: 6) {
            pill(insight.category.rawValue.capitalized)
            pill(insight.type.rawValue.capitalized)
            if insight.actionable {
              pill("Actionable")
            }
          }
        }
      }

      TextField("Notes", text: Binding(
        get: { insightNoteDrafts[insight.id] ?? insight.userNotes ?? "" },
        set: { insightNoteDrafts[insight.id] = $0 }
      ))
      .textFieldStyle(.plain)
      .serenityInputField()

      HStack(spacing: 8) {
        Button("Helpful") {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: insight.userRating,
              dismissed: nil,
              markedHelpful: true,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Dismiss") {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: insight.userRating,
              dismissed: true,
              markedHelpful: nil,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Spacer()

        ratingButtons(for: insight)
      }
    }
    .padding(14)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func ratingButtons(for insight: AIInsightEntity) -> some View {
    HStack(spacing: 4) {
      ForEach(1...5, id: \.self) { rating in
        Button {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: rating,
              dismissed: nil,
              markedHelpful: nil,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        } label: {
          Text("\(rating)")
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(insight.userRating == rating ? SerenityPalette.accent.opacity(0.22) : SerenityPalette.panelBackgroundRaised)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(insight.userRating == rating ? SerenityPalette.accent.opacity(0.6) : SerenityPalette.thinBorder, lineWidth: 1)
        )
        .hoverCursor(.pointingHand)
      }
    }
  }

  private func recapCard(_ recap: AIRecapEntity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(recap.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        pill(recap.type.rawValue.capitalized)
      }

      Text(recap.summary)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button(recap.viewed ? "Viewed" : "Mark viewed") {
          Task { await appState.markRecapViewed(id: recap.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button(recap.favorited ? "Unfavorite" : "Favorite") {
          Task { await appState.toggleRecapFavorite(id: recap.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(14)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func summaryCard(_ summary: SummaryEntity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(summary.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        Text("\(summary.wordCount) words")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Text(summary.content)
        .lineLimit(3)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)

      HStack(spacing: 8) {
        pill(summary.summaryType.rawValue.capitalized)
        Spacer()
        Button("Export") {
          Task { await appState.exportAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Delete", role: .destructive) {
          Task { await appState.deleteAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(14)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func dataScopeToggle(title: String, isOn: Bool, action: @escaping (Bool) async -> Void) -> some View {
    HStack {
      Text(title)
        .font(SerenityType.bodyMedium)
      Spacer()
      Toggle(title, isOn: Binding(
        get: { isOn },
        set: { enabled in
          Task { await action(enabled) }
        }
      ))
      .toggleStyle(.switch)
      .labelsHidden()
    }
  }

  private func labeledPicker<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      content()
    }
  }

  private func pill(_ text: String) -> some View {
    Text(text)
      .font(SerenityType.caption)
      .foregroundStyle(SerenityPalette.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
  }

  private func statusDot(isActive: Bool) -> some View {
    Circle()
      .fill(isActive ? Color.green : Color.orange)
      .frame(width: 8, height: 8)
  }

  private func insightIcon(for type: AIInsightType) -> String {
    switch type {
    case .productivity: return "chart.line.uptrend.xyaxis"
    case .behavior: return "waveform.path.ecg"
    case .recommendation: return "lightbulb"
    case .warning: return "exclamationmark.triangle"
    }
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

  private var enabledProviderOptions: [AICredentialProvider] {
    AIProviderDropdownAvailability.enabledProviders(from: appState.aiCredentials)
  }

  private var selectedActiveProviderValue: String {
    if let activeProvider = appState.aiSettings.activeProvider,
       enabledProviderOptions.contains(activeProvider) {
      return activeProvider.rawValue
    }

    return enabledProviderOptions.first?.rawValue ?? ""
  }

  private var activeProviderDropdownPlaceholder: String {
    enabledProviderOptions.isEmpty ? "No enabled provider keys" : "Active Provider"
  }

  private var activeProviderDropdownOptions: [SerenityDropdownOption<String>] {
    enabledProviderOptions.map { provider in
      SerenityDropdownOption(
        value: provider.rawValue,
        title: providerTitle(provider),
        systemImage: providerIcon(provider),
        tint: providerTint(provider)
      )
    }
  }

  private var frequencyDropdownOptions: [SerenityDropdownOption<AIAnalysisFrequency>] {
    AIAnalysisFrequency.allCases.map { frequency in
      SerenityDropdownOption(
        value: frequency,
        title: frequency.rawValue.capitalized,
        systemImage: frequency == .manual ? "hand.raised.fill" : "clock.arrow.circlepath",
        tint: frequency == .manual ? .orange : SerenityPalette.accent
      )
    }
  }

  private var providerOptions: [AICredentialProvider] {
    [.openai, .gemini, .anthropic, .nvidia, .custom]
  }

  private func providerTitle(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "OpenAI"
    case .gemini:
      return "Gemini"
    case .anthropic:
      return "Anthropic"
    case .nvidia:
      return "NVIDIA NIM"
    case .custom:
      return "Custom"
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
    case .nvidia:
      return "cpu.fill"
    case .custom:
      return "globe"
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
    case .nvidia:
      return .green
    case .custom:
      return .teal
    }
  }
}

private struct CostCenterSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout

  @State private var selectedWindow: CostWindow = .thirtyDays
  @State private var rateProvider: AIUsageProvider = .openai
  @State private var rateModel = ""
  @State private var inputRate = 0.0
  @State private var outputRate = 0.0
  @State private var refreshingLiteLLM = false

  private enum CostWindow: String, CaseIterable, Identifiable {
    case sevenDays = "Last 7 days"
    case fourteenDays = "Last 14 days"
    case thirtyDays = "Last 30 days"
    case all = "All time"

    var id: String { rawValue }

    var cutoffDate: Date? {
      switch self {
      case .sevenDays:
        Calendar.current.date(byAdding: .day, value: -7, to: Date())
      case .fourteenDays:
        Calendar.current.date(byAdding: .day, value: -14, to: Date())
      case .thirtyDays:
        Calendar.current.date(byAdding: .day, value: -30, to: Date())
      case .all:
        nil
      }
    }
  }

  private struct BreakdownRow: Identifiable {
    let id: String
    let label: String
    let calls: Int
    let tokens: Int
    let cost: Double
  }

  private var filteredUsage: [AIUsageEntity] {
    guard let cutoff = selectedWindow.cutoffDate else {
      return appState.aiUsageEntries
    }
    return appState.aiUsageEntries.filter { $0.timestamp >= cutoff }
  }

  private var sortedRates: [AIModelRateEntity] {
    appState.aiModelRates.sorted {
      if $0.provider == $1.provider {
        return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
      }
      return $0.provider.rawValue < $1.provider.rawValue
    }
  }

  private var totalTokens: Int {
    filteredUsage.reduce(0) { $0 + $1.totalTokens }
  }

  private var totalCost: Double {
    filteredUsage.reduce(0) { $0 + ($1.totalCostUSD ?? 0) }
  }

  private var missingRateRows: [AIUsageEntity] {
    filteredUsage.filter { $0.totalTokens > 0 && $0.totalCostUSD == nil }
  }

  private var providerBreakdown: [BreakdownRow] {
    groupedBreakdown { providerTitle($0.provider) }
  }

  private var operationBreakdown: [BreakdownRow] {
    groupedBreakdown { $0.operation.rawValue.capitalized }
  }

  private var modelBreakdown: [BreakdownRow] {
    groupedBreakdown { normalizedModel($0.model) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      controlsRow
      summaryCards
      spendPanels
      modelBreakdownPanel
      recentUsagePanel
      missingRatesPanel
      rateEditorPanel
    }
    .task {
      await appState.refreshAIWorkflows()
    }
  }

  private var controlsRow: some View {
    HStack(alignment: .center, spacing: 12) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(CostWindow.allCases) { window in
            Button {
              selectedWindow = window
            } label: {
              Text(window.rawValue)
                .font(SerenityType.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(selectedWindow == window ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textSecondary)
                .background(
                  Capsule()
                    .fill(selectedWindow == window ? SerenityPalette.activeItemBackground : SerenityPalette.panelBackgroundRaised)
                )
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)
          }
        }
      }

      Spacer()

      Button {
        Task { await appState.refreshAIWorkflows() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)
    }
  }

  private var summaryCards: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        metricCard(title: "Total Tokens", value: formatTokens(totalTokens), icon: "number", tint: .blue)
        metricCard(title: "Estimated Cost", value: formatUSD(totalCost), icon: "dollarsign.circle.fill", tint: .green)
        metricCard(title: "API Calls", value: "\(filteredUsage.count)", icon: "waveform.path.ecg", tint: .orange)
        metricCard(title: "Missing Rates", value: "\(missingRateKeys.count)", icon: "exclamationmark.triangle.fill", tint: missingRateKeys.isEmpty ? SerenityPalette.textSecondary : .orange)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        metricCard(title: "Total Tokens", value: formatTokens(totalTokens), icon: "number", tint: .blue)
        metricCard(title: "Estimated Cost", value: formatUSD(totalCost), icon: "dollarsign.circle.fill", tint: .green)
        metricCard(title: "API Calls", value: "\(filteredUsage.count)", icon: "waveform.path.ecg", tint: .orange)
        metricCard(title: "Missing Rates", value: "\(missingRateKeys.count)", icon: "exclamationmark.triangle.fill", tint: missingRateKeys.isEmpty ? SerenityPalette.textSecondary : .orange)
      }
    }
  }

  private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: icon)
        .font(SerenityType.scaledSystem(size: 18, weight: .semibold))
        .foregroundStyle(tint)
      Text(value)
        .font(SerenityType.scaledSystem(size: 20, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var spendPanels: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        chartPanel(title: "Spend by Provider", rows: providerBreakdown, chart: .bar)
        chartPanel(title: "Spend by Operation", rows: operationBreakdown, chart: .sector)
      }
      VStack(spacing: 12) {
        chartPanel(title: "Spend by Provider", rows: providerBreakdown, chart: .bar)
        chartPanel(title: "Spend by Operation", rows: operationBreakdown, chart: .sector)
      }
    }
  }

  private enum ChartKind {
    case bar
    case sector
  }

  private func chartPanel(title: String, rows: [BreakdownRow], chart: ChartKind) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(SerenityType.sectionTitle)

      if rows.isEmpty {
        emptyPanelText("No usage in \(selectedWindow.rawValue.lowercased()).")
          .frame(maxWidth: .infinity, minHeight: 180)
      } else if chart == .bar {
        Chart(rows) { row in
          BarMark(
            x: .value("Category", row.label),
            y: .value("Cost", row.cost)
          )
          .cornerRadius(5)
          .foregroundStyle(by: .value("Category", row.label))
        }
        .chartForegroundStyleScale(domain: rows.map(\.label), range: chartPalette(count: rows.count))
        .chartYAxis {
          AxisMarks(position: .leading)
        }
        .frame(height: 180)
      } else {
        let palette = chartPalette(count: rows.count)

        Chart(rows) { row in
          SectorMark(
            angle: .value("Cost", row.cost),
            innerRadius: .ratio(0.55),
            angularInset: 2
          )
          .foregroundStyle(by: .value("Operation", row.label))
        }
        .chartForegroundStyleScale(domain: rows.map(\.label), range: palette)
        .chartLegend(position: .bottom, alignment: .center, spacing: 8)
        .chartLegend(compactLayout ? .hidden : .visible)
        .frame(height: 180)

        // The built-in legend names the slices but not their size, which is the
        // one thing worth reading on a phone-width donut.
        if compactLayout {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                  .fill(palette[index % max(palette.count, 1)])
                  .frame(width: 10, height: 10)

                Text(row.label)
                  .font(SerenityType.body)

                Spacer(minLength: 8)

                Text(formatUSD(row.cost))
                  .font(SerenityType.bodyMedium)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
            }
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var modelBreakdownPanel: some View {
    tablePanel(title: "Breakdown by Model") {
      VStack(alignment: .leading, spacing: 8) {
        modelHeader
        Divider().overlay(SerenityPalette.thinBorder)
        if modelBreakdown.isEmpty {
          emptyPanelText("No model usage in \(selectedWindow.rawValue.lowercased()).")
            .padding(.vertical, 12)
        } else {
          ForEach(modelBreakdown.prefix(12)) { row in
            HStack(spacing: 10) {
              Text(row.label)
                .font(SerenityType.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("\(row.calls)")
                .font(SerenityType.caption)
                .frame(width: 64, alignment: .trailing)
              Text(formatTokens(row.tokens))
                .font(SerenityType.caption)
                .frame(width: 96, alignment: .trailing)
              Text(formatUSD(row.cost))
                .font(SerenityType.caption)
                .frame(width: 108, alignment: .trailing)
            }
            Divider().overlay(SerenityPalette.thinBorder)
          }
        }
      }
    }
  }

  private var modelHeader: some View {
    HStack(spacing: 10) {
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Calls").frame(width: 64, alignment: .trailing)
      Text("Tokens").frame(width: 96, alignment: .trailing)
      Text("Cost").frame(width: 108, alignment: .trailing)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  private var recentUsagePanel: some View {
    tablePanel(title: "Recent Usage Log") {
      VStack(alignment: .leading, spacing: 8) {
        recentUsageHeader
        Divider().overlay(SerenityPalette.thinBorder)
        if filteredUsage.isEmpty {
          emptyPanelText("AI calls will appear here after usage is recorded.")
            .padding(.vertical, 12)
        } else {
          ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(filteredUsage.prefix(24))) { row in
                HStack(spacing: 10) {
                  Text(formatDate(row.timestamp))
                    .font(SerenityType.caption)
                    .frame(width: 124, alignment: .leading)
                  Text(providerTitle(row.provider))
                    .font(SerenityType.caption)
                    .frame(width: 82, alignment: .leading)
                  Text(normalizedModel(row.model))
                    .font(SerenityType.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  Text(row.operation.rawValue.capitalized)
                    .font(SerenityType.caption)
                    .frame(width: 84, alignment: .leading)
                  Text(formatTokens(row.totalTokens))
                    .font(SerenityType.caption)
                    .frame(width: 90, alignment: .trailing)
                  Text(row.totalCostUSD.map(formatUSD) ?? "N/A")
                    .font(SerenityType.caption)
                    .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 7)
                Divider().overlay(SerenityPalette.thinBorder)
              }
            }
          }
          .frame(maxHeight: 360)
        }
      }
    }
  }

  private var recentUsageHeader: some View {
    HStack(spacing: 10) {
      Text("Time").frame(width: 124, alignment: .leading)
      Text("Provider").frame(width: 82, alignment: .leading)
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Operation").frame(width: 84, alignment: .leading)
      Text("Tokens").frame(width: 90, alignment: .trailing)
      Text("Cost").frame(width: 84, alignment: .trailing)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  @ViewBuilder
  private var missingRatesPanel: some View {
    if !missingRateKeys.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 10) {
          Label("Missing pricing for \(missingRateKeys.count) model\(missingRateKeys.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
            .font(SerenityType.sectionTitle)
            .foregroundStyle(.orange)
          Spacer()
          Button {
            Task { await refreshLiteLLM() }
          } label: {
            Label(refreshingLiteLLM ? "Refreshing" : "Fetch LiteLLM Prices", systemImage: "arrow.down.circle")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(refreshingLiteLLM)
        }

        Text("These rows keep their token counts, but cost is unavailable until a matching provider/model rate exists.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)

        SerenityFlowLayout(spacing: 8) {
          ForEach(missingRateKeys, id: \.self) { key in
            pill(key)
          }
        }
      }
      .padding(16)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.orange.opacity(0.35), lineWidth: 1)
      )
    }
  }

  private var rateEditorPanel: some View {
    tablePanel(title: "Provider Cost Table (USD per 1M tokens)") {
      VStack(alignment: .leading, spacing: 12) {
        rateForm

        HStack {
          Spacer()
          Button {
            Task { await appState.resetAIModelRatesToDefaults() }
          } label: {
            Label("Reset Defaults", systemImage: "arrow.counterclockwise")
              .frame(height: rateFormButtonLabelHeight)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }

        rateHeader
        Divider().overlay(SerenityPalette.thinBorder)

        if sortedRates.isEmpty {
          emptyPanelText("No model rates available yet.")
            .padding(.vertical, 12)
        } else {
          ForEach(sortedRates) { rate in
            HStack(spacing: 10) {
              Text(providerTitle(rate.provider))
                .font(SerenityType.caption)
                .frame(width: 92, alignment: .leading)
              Text(rate.model)
                .font(SerenityType.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(formatRate(rate.inputUSDPerMillion))
                .font(SerenityType.caption)
                .frame(width: 86, alignment: .trailing)
              Text(formatRate(rate.outputUSDPerMillion))
                .font(SerenityType.caption)
                .frame(width: 86, alignment: .trailing)
              pill(rate.source.rawValue.capitalized)
                .frame(width: 82, alignment: .leading)
              if rate.source == .seeded {
                Image(systemName: "lock")
                  .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
                  .foregroundStyle(SerenityPalette.textSecondary)
                  .help("Seeded rates can be overridden or reset, but not deleted.")
                  .frame(width: 28, alignment: .trailing)
              } else {
                Button {
                  Task { await appState.deleteAIModelRate(provider: rate.provider, model: rate.model) }
                } label: {
                  Image(systemName: "trash")
                    .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .hoverCursor(.pointingHand)
                .help("Remove this provider/model rate")
                .frame(width: 28, alignment: .trailing)
              }
            }
            .padding(.vertical, 5)
            Divider().overlay(SerenityPalette.thinBorder)
          }
        }
      }
    }
  }

  private var rateForm: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .bottom, spacing: 10) {
        providerPicker.frame(width: 190)
        rateTextField("Model", text: $rateModel).frame(minWidth: 300)
        rateNumberField("Input", value: $inputRate)
        rateNumberField("Output", value: $outputRate)
        saveRateButton
      }
      VStack(alignment: .leading, spacing: 10) {
        providerPicker.frame(maxWidth: 260)
        rateTextField("Model", text: $rateModel)
        HStack(spacing: 10) {
          rateNumberField("Input", value: $inputRate)
          rateNumberField("Output", value: $outputRate)
        }
        saveRateButton
      }
    }
  }

  private var rateFormControlHeight: CGFloat { 44 }

  private var rateFormButtonLabelHeight: CGFloat { rateFormControlHeight - 14 }

  private var providerPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Provider")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)

      SerenityDropdownField(
        placeholder: "Provider",
        selection: $rateProvider,
        options: rateProviderDropdownOptions,
        maxMenuHeight: 180
      )
      .frame(maxWidth: .infinity, minHeight: rateFormControlHeight, maxHeight: rateFormControlHeight)
    }
  }

  private var rateProviderDropdownOptions: [SerenityDropdownOption<AIUsageProvider>] {
    AIUsageProvider.allCases.map { provider in
      SerenityDropdownOption(
        value: provider,
        title: providerTitle(provider),
        subtitle: rateProviderSubtitle(provider),
        systemImage: providerIcon(provider),
        tint: providerTint(provider)
      )
    }
  }

  private func rateTextField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      TextField(title, text: text)
        .textFieldStyle(.plain)
        .serenityInputField()
        .frame(height: rateFormControlHeight)
    }
  }

  private func rateNumberField(_ title: String, value: Binding<Double>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      TextField(title, value: value, format: .number.precision(.fractionLength(4)))
        .textFieldStyle(.plain)
        .serenityInputField()
        .frame(height: rateFormControlHeight)
        .frame(width: 104)
    }
  }

  private var saveRateButton: some View {
    Button {
      let model = rateModel.trimmingCharacters(in: .whitespacesAndNewlines)
      Task {
        await appState.saveAIModelRate(
          provider: rateProvider,
          model: model,
          inputUSDPerMillion: inputRate,
          outputUSDPerMillion: outputRate
        )
        rateModel = ""
        inputRate = 0
        outputRate = 0
      }
    } label: {
      Label("Add / Update", systemImage: "plus.circle.fill")
        .frame(height: rateFormButtonLabelHeight)
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(rateModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var rateHeader: some View {
    HStack(spacing: 10) {
      Text("Provider").frame(width: 92, alignment: .leading)
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Input").frame(width: 86, alignment: .trailing)
      Text("Output").frame(width: 86, alignment: .trailing)
      Text("Source").frame(width: 82, alignment: .leading)
      Text("").frame(width: 28)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  private func tablePanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(SerenityType.sectionTitle)
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

  private func groupedBreakdown(label: (AIUsageEntity) -> String) -> [BreakdownRow] {
    var grouped: [String: (calls: Int, tokens: Int, cost: Double)] = [:]
    for row in filteredUsage {
      let key = label(row)
      var entry = grouped[key, default: (calls: 0, tokens: 0, cost: 0)]
      entry.calls += 1
      entry.tokens += row.totalTokens
      entry.cost += row.totalCostUSD ?? 0
      grouped[key] = entry
    }

    return grouped.map { key, value in
      BreakdownRow(id: key, label: key, calls: value.calls, tokens: value.tokens, cost: value.cost)
    }
    .sorted {
      if $0.cost == $1.cost { return $0.tokens > $1.tokens }
      return $0.cost > $1.cost
    }
  }

  private var missingRateKeys: [String] {
    Array(Set(missingRateRows.map { "\(providerTitle($0.provider))/\(normalizedModel($0.model))" })).sorted()
  }

  private func refreshLiteLLM() async {
    refreshingLiteLLM = true
    defer { refreshingLiteLLM = false }
    await appState.refreshMissingAIModelRatesFromLiteLLM()
  }

  private func providerTitle(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "OpenAI"
    case .gemini: return "Gemini"
    case .anthropic: return "Anthropic"
    case .nvidia: return "NVIDIA NIM"
    case .custom: return "Custom"
    }
  }

  private func rateProviderSubtitle(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "OpenAI usage rates"
    case .gemini: return "Google Gemini usage rates"
    case .anthropic: return "Anthropic usage rates"
    case .nvidia: return "NVIDIA NIM usage rates"
    case .custom: return "Custom domain usage rates"
    }
  }

  private func providerIcon(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "sparkles"
    case .gemini: return "diamond.fill"
    case .anthropic: return "brain.head.profile"
    case .nvidia: return "cpu.fill"
    case .custom: return "globe"
    }
  }

  private func providerTint(_ provider: AIUsageProvider) -> Color {
    switch provider {
    case .openai: return SerenityPalette.accent
    case .gemini: return .purple
    case .anthropic: return .orange
    case .nvidia: return .green
    case .custom: return .teal
    }
  }

  private func normalizedModel(_ model: String?) -> String {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Unknown" : trimmed
  }

  private func chartPalette(count: Int) -> [Color] {
    let base: [Color] = [.blue, .green, .orange, .teal, .indigo, .mint, .pink]
    guard count > base.count else { return Array(base.prefix(max(count, 1))) }
    return Array(repeating: base, count: count / base.count + 1).flatMap { $0 }.prefix(count).map { $0 }
  }

  private func formatUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = value < 1 ? 4 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
  }

  private func formatRate(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 4
    return formatter.string(from: NSNumber(value: value)) ?? "0"
  }

  private func formatTokens(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "0"
  }

  private func formatDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private func emptyPanelText(_ text: String) -> some View {
    Text(text)
      .font(SerenityType.body)
      .foregroundStyle(SerenityPalette.textSecondary)
      .frame(maxWidth: .infinity, alignment: .center)
  }

  private func pill(_ text: String) -> some View {
    Text(text)
      .font(SerenityType.caption)
      .foregroundStyle(SerenityPalette.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
  }
}

private struct AISummariesSectionView: View {
  @EnvironmentObject private var appState: AppState

  private enum SummaryFilter: String, CaseIterable, Identifiable {
    case all
    case tasks
    case journal
    case combined

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: return "All"
      case .tasks: return "Tasks"
      case .journal: return "Journal"
      case .combined: return "Combined"
      }
    }
  }

  @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
  @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
  @State private var dateRangeEnabled = true
  @State private var datePopoverOpen = false
  @State private var includeTasks = true
  @State private var includeJournal = true
  @State private var filter: SummaryFilter = .all

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      generateCard

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          summariesPanel
            .frame(maxWidth: .infinity, alignment: .topLeading)
          sidePanel
            .frame(width: 320, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: 18) {
          summariesPanel
          sidePanel
        }
      }
    }
  }

  private var generateCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Generate Summary")
            .font(SerenityType.sectionTitle)
          Text("Create a focused recap for the selected period and sources.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer()

        dateRangeButton
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          presetButton(title: "Last 7 Days", days: 7)
          presetButton(title: "Last 30 Days", days: 30)
          presetButton(title: "Last 3 Months", days: 90)
        }

        VStack(alignment: .leading, spacing: 10) {
          presetButton(title: "Last 7 Days", days: 7)
          presetButton(title: "Last 30 Days", days: 30)
          presetButton(title: "Last 3 Months", days: 90)
        }
      }

      HStack(alignment: .top, spacing: 16) {
        summaryScopeCard(
          title: "Period",
          value: dateRangeLabel,
          icon: "calendar",
          detail: "\(dayCount) day\(dayCount == 1 ? "" : "s") selected"
        )

        summaryScopeCard(
          title: "Sources",
          value: selectedSourceTitle,
          icon: "tray.full",
          detail: "\(selectedTaskCount) task\(selectedTaskCount == 1 ? "" : "s") and \(selectedJournalCount) journal entr\(selectedJournalCount == 1 ? "y" : "ies")"
        )
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Include")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        HStack(spacing: 8) {
          includeToggle(title: "Tasks", systemImage: "checklist", isOn: $includeTasks)
          includeToggle(title: "Journal", systemImage: "book", isOn: $includeJournal)
        }
      }

      if !isAIConfigured {
        aiProviderBanner
      }

      Button {
        Task { await generate() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "sparkles")
          Text("Generate Summary")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
      .hoverCursor(.pointingHand)
      .disabled(!isAIConfigured || resolvedSummaryType == nil)
    }
    .padding(20)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
      )
  }

  private var dateRangeButton: some View {
    Button {
      datePopoverOpen.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
        VStack(alignment: .leading, spacing: 2) {
          Text("Summary Period")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          Text(dateRangeLabel)
            .font(SerenityType.bodyMedium)
        }
        Image(systemName: "chevron.down")
          .font(SerenityType.scaledSystem(size: 9, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
    .popover(isPresented: $datePopoverOpen, arrowEdge: .top) {
      SerenityDateRangePicker(
        isEnabled: $dateRangeEnabled,
        startDate: $startDate,
        endDate: $endDate,
        title: "Summary period",
        showsEnableToggle: false,
        onApply: normalizeDateRange,
        onClose: {
          normalizeDateRange()
          datePopoverOpen = false
        }
      )
    }
  }

  private var aiProviderBanner: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("AI Provider not configured")
          .font(SerenityType.bodyMedium)
        HStack(spacing: 4) {
          Text("You need to configure an AI provider to use this feature.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
          Button("Go to Settings") {
            appState.setSection(.settings, settingsTab: .aiProvider)
          }
          .buttonStyle(.plain)
          .foregroundStyle(SerenityPalette.accent)
          .hoverCursor(.pointingHand)
        }
      }
      Spacer()
    }
    .padding(12)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
    )
  }

  private var summariesPanel: some View {
    sectionPanel(title: "Your Summaries", subtitle: "\(filteredSummaries.count) shown") {
      ViewThatFits(in: .horizontal) {
        HStack {
          summaryLibraryContext
          Spacer()
          filterPills
        }

        VStack(alignment: .leading, spacing: 12) {
          summaryLibraryContext
          filterPills
        }
      }

      summariesList
    }
  }

  private var summaryLibraryContext: some View {
    Text("Browse generated summaries by type and export the ones you want to keep.")
      .font(SerenityType.body)
      .foregroundStyle(SerenityPalette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var sidePanel: some View {
    VStack(alignment: .leading, spacing: 18) {
      sectionPanel(title: "Current Scope", subtitle: resolvedSummaryType?.rawValue.capitalized ?? "Incomplete") {
        VStack(alignment: .leading, spacing: 12) {
          summaryMetricRow(title: "Period", value: dateRangeLabel)
          summaryMetricRow(title: "Tasks", value: "\(selectedTaskCount)")
          summaryMetricRow(title: "Journal entries", value: "\(selectedJournalCount)")
          summaryMetricRow(title: "Saved summaries", value: "\(appState.aiSummaries.count)")
        }
      }

      sectionPanel(title: "Provider", subtitle: isAIConfigured ? "Ready" : "Required") {
        HStack(alignment: .top, spacing: 10) {
          Circle()
            .fill(isAIConfigured ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .padding(.top, 5)

          VStack(alignment: .leading, spacing: 4) {
            Text(isAIConfigured ? "AI provider configured" : "AI provider not configured")
              .font(SerenityType.bodyMedium)
            Text(isAIConfigured ? "Summaries can be generated for the selected scope." : "Configure a provider key before generating summaries.")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if let path = appState.lastSummaryExportPath {
        sectionPanel(title: "Last Export") {
          Text(path)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var filterPills: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        ForEach(SummaryFilter.allCases) { option in
          Button(option.title) {
            filter = option
          }
          .buttonStyle(SerenityPillButtonStyle(selected: filter == option))
          .hoverCursor(.pointingHand)
        }
      }

      HStack(spacing: 6) {
        ForEach(SummaryFilter.allCases.prefix(2)) { option in
          Button(option.title) {
            filter = option
          }
          .buttonStyle(SerenityPillButtonStyle(selected: filter == option))
          .hoverCursor(.pointingHand)
        }
      }
    }
  }

  @ViewBuilder
  private var summariesList: some View {
    if filteredSummaries.isEmpty {
      emptyState
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(filteredSummaries) { summary in
          summaryRow(summary)
        }
      }
    }
  }

  private var emptyState: some View {
    SerenityEmptyState(
      icon: "sparkles",
      title: "No summaries yet",
      message: "Generate your first summary using the controls above."
    )
  }

  private func summaryRow(_ summary: SummaryEntity) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(summary.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        pill(summary.summaryType.rawValue.capitalized)
        Text("\(summary.wordCount) words")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Text(summary.content)
        .lineLimit(3)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)

      HStack(spacing: 8) {
        Label(summaryDateLabel(summary), systemImage: "calendar")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer()

        Button("Export") {
          Task { await appState.exportAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Delete", role: .destructive) {
          Task { await appState.deleteAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(14)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func presetButton(title: String, days: Int) -> some View {
    Button {
      let end = Calendar.current.startOfDay(for: Date())
      let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
      startDate = start
      endDate = end
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "calendar")
        Text(title)
      }
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .hoverCursor(.pointingHand)
  }

  private func includeToggle(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
    Button {
      isOn.wrappedValue.toggle()
    } label: {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(SerenityPillButtonStyle(selected: isOn.wrappedValue))
    .hoverCursor(.pointingHand)
  }

  private func summaryScopeCard(title: String, value: String, icon: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(SerenityPalette.accent)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(value)
          .font(SerenityType.bodyMedium)
        Text(detail)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
      }
      Spacer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func sectionPanel<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(SerenityType.sectionTitle)
        Spacer()
        if let subtitle {
          Text(subtitle)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
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

  private func summaryMetricRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(SerenityType.bodyMedium)
      Spacer()
      Text(value)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .multilineTextAlignment(.trailing)
    }
  }

  private func pill(_ text: String) -> some View {
    Text(text)
      .font(SerenityType.caption)
      .foregroundStyle(SerenityPalette.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
  }

  private var filteredSummaries: [SummaryEntity] {
    switch filter {
    case .all: return appState.aiSummaries
    case .tasks: return appState.aiSummaries.filter { $0.summaryType == .tasks }
    case .journal: return appState.aiSummaries.filter { $0.summaryType == .journal }
    case .combined: return appState.aiSummaries.filter { $0.summaryType == .combined }
    }
  }

  private var selectedTaskCount: Int {
    tasksInRange.count
  }

  private var selectedJournalCount: Int {
    journalEntriesInRange.count
  }

  private var tasksInRange: [TaskEntity] {
    let calendar = Calendar.current
    let rangeStart = calendar.startOfDay(for: startDate)
    let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
    return appState.tasks.filter { task in
      let taskDate = task.completedAt ?? task.dueDate ?? task.updatedAt
      return taskDate >= rangeStart && taskDate < rangeEnd
    }
  }

  private var journalEntriesInRange: [JournalEntryEntity] {
    let calendar = Calendar.current
    let rangeStart = calendar.startOfDay(for: startDate)
    let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
    return appState.journalEntries.filter { entry in
      let entryDate = calendar.startOfDay(for: entry.date)
      return entryDate >= rangeStart && entryDate < rangeEnd
    }
  }

  private var isAIConfigured: Bool {
    appState.aiCredentials.contains { $0.enabled }
  }

  private var resolvedSummaryType: SummaryType? {
    switch (includeTasks, includeJournal) {
    case (true, true): return .combined
    case (true, false): return .tasks
    case (false, true): return .journal
    case (false, false): return nil
    }
  }

  private var selectedSourceTitle: String {
    switch resolvedSummaryType {
    case .tasks: return "Tasks"
    case .journal: return "Journal"
    case .combined: return "Tasks and journal"
    case nil: return "Choose a source"
    }
  }

  private var dateRangeLabel: String {
    "\(startDate.formatted(.dateTime.month(.abbreviated).day())) - \(endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
  }

  private var dayCount: Int {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.startOfDay(for: endDate)
    return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
  }

  private func summaryDateLabel(_ summary: SummaryEntity) -> String {
    "\(summary.startDate.formatted(.dateTime.month(.abbreviated).day())) - \(summary.endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
  }

  private func normalizeDateRange() {
    let calendar = Calendar.current
    let normalizedStart = calendar.startOfDay(for: startDate)
    let normalizedEnd = calendar.startOfDay(for: endDate)
    if normalizedEnd < normalizedStart {
      startDate = normalizedEnd
      endDate = normalizedStart
    } else {
      startDate = normalizedStart
      endDate = normalizedEnd
    }
  }

  private func generate() async {
    guard let type = resolvedSummaryType else { return }
    normalizeDateRange()
    await appState.generateAISummary(type: type, startDate: startDate, endDate: endDate)
  }
}

/// The stand-up board and everything downstream of it. Three columns you drag
/// between, because moving a card is how you say "that one's a blocker" and how
/// you carry yesterday's item into today — the two things this screen exists to
/// let you do.
struct StandupSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout

  @State private var addingTo: StandupColumn?
  @State private var newCardTitle = ""
  @State private var isFormatSheetPresented = false
  @State private var showPasteRendering = false
  @State private var isEditingScript = false
  @State private var editedScript = ""
  @State private var isFoldedExpanded = false
  @State private var openSwipeRowID: String?
  @FocusState private var addFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let script = appState.standupScript {
        outputPanel(script)
      } else if let board = appState.standupBoard, board.hasAnythingToSay {
        boardPanel(board)
      } else {
        quietPanel
      }

      if !appState.standups.isEmpty {
        historyPanel
      }
    }
    // Keyed on the task list rather than on appearing: entering the section
    // straight after launch would otherwise gather from tasks that have not
    // loaded and report an honest-looking "nothing to report" for ever.
    // Reading the database again here instead would race the section's own
    // load and trip SQLite's lock.
    .task(id: appState.tasks.count) {
      guard appState.standupScript == nil, !appState.standupBoardEdited else { return }
      await appState.buildStandupBoard()
    }
    .sheet(isPresented: $isFormatSheetPresented) {
      StandupFormatSheet()
        .environmentObject(appState)
    }
  }

  // MARK: - Nothing to say

  private var quietPanel: some View {
    SerenityEmptyState(
      icon: "mic.slash",
      title: "Nothing to report yet",
      message: appState.standupBoard == nil
        ? "Gathering what has happened since your last stand-up."
        : "Nothing has moved since your last stand-up, and nothing is due. Add something by hand if you spent the day off the board."
    ) {
      HStack(spacing: 8) {
        Button("Start over") {
          Task { await appState.buildStandupBoard() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Format") {
          isFormatSheetPresented = true
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
  }

  // MARK: - The board

  private func boardPanel(_ board: StandupBoard) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      boardHeader(board)

      if compactLayout {
        phoneColumns(board)
      } else {
        deskColumns(board)
      }

      leavingOutTray(board)
      boardFooter
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .serenityPanel()
  }

  private func boardHeader(_ board: StandupBoard) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Stand-up for \(Date().formatted(.dateTime.weekday(.wide)))")
            .font(SerenityType.sectionTitle)
            .foregroundStyle(SerenityPalette.textPrimary)
          Text(windowSubtitle(board.window))
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        if !compactLayout {
          headerButtons
        }
      }

      if compactLayout {
        headerButtons
      }
    }
  }

  private var headerButtons: some View {
    HStack(spacing: 8) {
      Button {
        isFormatSheetPresented = true
      } label: {
        Label("Format", systemImage: "text.alignleft")
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Button("Start over") {
        Task { await appState.buildStandupBoard() }
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)
    }
  }

  /// Says how the window was arrived at, because a suspiciously thin or fat
  /// stand-up should explain itself rather than look broken.
  private func windowSubtitle(_ window: StandupWindow) -> String {
    let span = StandupDateText.windowLabel(window).lowercased()
    switch window.anchor {
    case .lastStandup:
      return "\(span.prefix(1).uppercased() + span.dropFirst()) — your last stand-up. Drag a card to move it between columns."
    case .sameDay:
      return "Since this morning's stand-up. This one will be thin."
    case .previousWorkingDay:
      return "Since your previous working day. Serenity has no earlier stand-up to measure from."
    case .capped:
      return "Capped at \(StandupPlanner.windowCapDays) days — your last stand-up was longer ago than that."
    }
  }

  /// The columns read as one board rather than three cards of random height.
  /// A Grid row is what makes that work: inside a scroll view an HStack
  /// proposes an unbounded height, so `maxHeight: .infinity` on a column would
  /// stretch nothing. A grid cell gets the row's real height instead.
  private func deskColumns(_ board: StandupBoard) -> some View {
    Grid(horizontalSpacing: 14, verticalSpacing: 0) {
      GridRow {
        ForEach(StandupColumn.spoken) { column in
          columnPanel(column, cards: board.cards(in: column), stretch: true)
        }
      }
    }
  }

  private func phoneColumns(_ board: StandupBoard) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(StandupColumn.spoken) { column in
        columnPanel(column, cards: board.cards(in: column), stretch: false)
      }
    }
  }

  private func columnPanel(_ column: StandupColumn, cards: [StandupCard], stretch: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: column.systemImage)
          .font(SerenityType.scaledSystem(size: 13, weight: .semibold))
          .foregroundStyle(tint(for: column))
        Text(columnTitle(column))
          .font(SerenityType.bodyLarge.weight(.semibold))
          .foregroundStyle(SerenityPalette.textPrimary)
        Text("\(cards.count)")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
        Spacer(minLength: 0)
      }

      ForEach(cards) { card in
        cardRow(card)
      }

      if cards.isEmpty {
        Text(column == .blocked ? "Drop a card here to raise it as a blocker" : "Nothing here")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 18)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
              .foregroundStyle(SerenityPalette.border)
          )
      }

      addControl(for: column)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      appState.moveStandupCard(id: id, to: column)
      return true
    }
  }

  private func columnTitle(_ column: StandupColumn) -> String {
    guard column == .since, let window = appState.standupBoard?.window else { return column.title }
    return StandupDateText.windowLabel(window)
  }

  private func tint(for column: StandupColumn) -> Color {
    switch column {
    case .since:
      return .green
    case .today:
      return SerenityPalette.accent
    case .blocked:
      return .red
    case .leftOut:
      return SerenityPalette.textSecondary
    }
  }

  @ViewBuilder
  private func cardRow(_ card: StandupCard) -> some View {
    let content = VStack(alignment: .leading, spacing: 5) {
      Text(card.title)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Text(card.fact)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if card.source.isGuess {
        provenanceChip(card.source.label, tint: .red)
      } else if card.source == .manual {
        provenanceChip(card.source.label, tint: SerenityPalette.accent)
      }

      if let saidLast = card.saidLast {
        // Neutral on purpose: something you mentioned last time is usually
        // still today's work, so this is information, not a nudge to drop it.
        Label("Said last time: \(saidLast)", systemImage: "arrow.counterclockwise")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(SerenityPalette.panelBackground, in: Capsule())
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(card.saidLast == nil ? Color.clear : SerenityPalette.accent.opacity(0.3), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .draggable(card.id)
    // Drag has no keyboard or VoiceOver path, so every move is also a menu
    // item. The phone uses the same list.
    .contextMenu {
      ForEach(moveTargets(from: card.column)) { target in
        Button("Move to \(target.title)") {
          appState.moveStandupCard(id: card.id, to: target)
        }
      }
      Divider()
      Button("Remove", role: .destructive) {
        appState.removeStandupCard(id: card.id)
      }
    }

#if os(iOS)
    content
      .serenitySwipeActions(
        rowID: card.id,
        openRowID: $openSwipeRowID,
        actions: swipeActions(for: card)
      )
#else
    content
#endif
  }

#if os(iOS)
  /// Swiping moves a card to its neighbouring column, which is the phone's
  /// stand-in for dragging across the board.
  private func swipeActions(for card: StandupCard) -> [SerenitySwipeAction] {
    moveTargets(from: card.column).prefix(2).map { target in
      SerenitySwipeAction(
        id: "\(card.id):\(target.rawValue)",
        title: target.title,
        systemImage: target == .leftOut ? "tray" : "arrow.right",
        tint: target == .leftOut ? SerenityPalette.textSecondary : SerenityPalette.accent
      ) {
        appState.moveStandupCard(id: card.id, to: target)
      }
    }
  }
#endif

  private func moveTargets(from column: StandupColumn) -> [StandupColumn] {
    ([.since, .today, .blocked, .leftOut] as [StandupColumn]).filter { $0 != column }
  }

  private func provenanceChip(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(SerenityType.caption)
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(tint.opacity(0.14), in: Capsule())
  }

  @ViewBuilder
  private func addControl(for column: StandupColumn) -> some View {
    if addingTo == column {
      HStack(spacing: 8) {
        TextField("What happened?", text: $newCardTitle)
          .textFieldStyle(.plain)
          .serenityInputField()
          .focused($addFieldFocused)
          .onSubmit { commitNewCard(to: column) }

        Button("Add") {
          commitNewCard(to: column)
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
        .disabled(newCardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    } else {
      Button {
        addingTo = column
        newCardTitle = ""
        addFieldFocused = true
      } label: {
        Label(column == .blocked ? "Add a blocker" : "Add", systemImage: "plus")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
              .foregroundStyle(SerenityPalette.border)
          )
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)
    }
  }

  private func commitNewCard(to column: StandupColumn) {
    appState.addStandupCard(title: newCardTitle, to: column)
    newCardTitle = ""
    addingTo = nil
    addFieldFocused = false
  }

  /// Dropping a card needs a destination and a way back, or excluding
  /// something is a one-way door you cannot audit before you speak.
  private func leavingOutTray(_ board: StandupBoard) -> some View {
    let cards = board.cards(in: .leftOut)

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "tray")
          .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
        Text("Leaving out")
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(cards.isEmpty ? "Drag anything here to keep it out of the script" : "Drag back to include")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary.opacity(0.8))
        Spacer(minLength: 0)
      }

      if !cards.isEmpty {
        SerenityFlowLayout(spacing: 8) {
          ForEach(cards) { card in
            HStack(spacing: 6) {
              Text(card.title)
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
              Button {
                appState.moveStandupCard(id: card.id, to: .today)
              } label: {
                Image(systemName: "arrow.uturn.backward")
                  .font(SerenityType.scaledSystem(size: 10, weight: .semibold))
              }
              .buttonStyle(.plain)
              .hoverCursor(.pointingHand)
              .accessibilityLabel("Put \(card.title) back in Today")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
            .draggable(card.id)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .foregroundStyle(SerenityPalette.thinBorder)
    )
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      appState.moveStandupCard(id: id, to: .leftOut)
      return true
    }
  }

  private var boardFooter: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Picker("Length", selection: lengthBinding) {
          ForEach(StandupLength.allCases, id: \.self) { length in
            Text(length.title).tag(length)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: compactLayout ? .infinity : 260)

        if !compactLayout {
          Spacer(minLength: 8)
          writeButton
        }
      }

      if compactLayout {
        writeButton
          .frame(maxWidth: .infinity)
      }

      Text("Your format instruction wins wherever it disagrees with this.")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .padding(.top, 4)
  }

  private var lengthBinding: Binding<StandupLength> {
    Binding(
      get: { appState.aiSettings.resolvedStandupLength },
      set: { length in Task { await appState.setStandupLength(length) } }
    )
  }

  private var writeButton: some View {
    Button {
      Task { await appState.writeStandup() }
    } label: {
      if appState.standupIsWriting {
        Label("Writing\u{2026}", systemImage: "hourglass")
      } else {
        Text("Write my stand-up")
      }
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .hoverCursor(.pointingHand)
    .disabled(appState.standupIsWriting)
  }

  // MARK: - The finished stand-up

  private func outputPanel(_ script: StandupScript) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(SerenityType.sectionTitle)
            .foregroundStyle(SerenityPalette.textPrimary)
          Text("\(script.wordCount) words \u{00B7} about \(script.spokenSeconds) seconds out loud")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Spacer(minLength: 8)

        if !appState.standupWrittenByModel {
          Text("No AI key")
            .font(SerenityType.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SerenityPalette.panelBackgroundRaised, in: Capsule())
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      Picker("Rendering", selection: $showPasteRendering) {
        Text("Out loud").tag(false)
        Text("To paste").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: compactLayout ? .infinity : 260)

      if isEditingScript {
        TextEditor(text: $editedScript)
          .serenityTextArea(minHeight: 160)
      } else if showPasteRendering, !script.sections.isEmpty {
        sectionBlocks(script.sections)
      } else {
        Text(showPasteRendering ? script.paste : script.spoken)
          .font(SerenityType.scaledSystem(size: showPasteRendering ? 14 : 19, weight: .regular))
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineSpacing(showPasteRendering ? 3 : 7)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(18)
          .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }

      if !script.folded.isEmpty {
        foldedStrip(script.folded)
      }

      outputFooter(script)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .serenityPanel()
  }

  /// The stand-up drawn as the parts the model reported. The alternative is a
  /// slab of markdown with its own asterisks showing, which is what a plain
  /// text view makes of it.
  private func sectionBlocks(_ sections: [StandupSection]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
        VStack(alignment: .leading, spacing: 9) {
          if !section.label.isEmpty || !section.title.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              if !section.label.isEmpty {
                Text(section.label.uppercased())
                  .font(SerenityType.scaledSystem(size: 11, weight: .bold))
                  .kerning(0.6)
                  .foregroundStyle(SerenityPalette.accent)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(
                    SerenityPalette.activeItemBackground,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                  )
              }

              if !section.title.isEmpty {
                Text(section.title)
                  .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
                  .foregroundStyle(SerenityPalette.textPrimary)
                  .fixedSize(horizontal: false, vertical: true)
              }

              Spacer(minLength: 0)
            }
          }

          if !section.body.isEmpty {
            sectionBody(section.body)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if index < sections.count - 1 {
          Rectangle()
            .fill(SerenityPalette.border)
            .frame(height: 1)
            .padding(.vertical, 15)
        }
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// A body is prose, except when the model (or the no-key fallback) wrote it
  /// as a list. A dash at the start of a line is the one piece of markdown
  /// worth drawing rather than showing.
  private func sectionBody(_ body: String) -> some View {
    let lines = body
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    return VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        if line.hasPrefix("- ") || line.hasPrefix("\u{2022} ") {
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\u{2022}")
              .foregroundStyle(SerenityPalette.textSecondary)
            Text(String(line.dropFirst(2)))
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
        } else {
          Text(line)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .font(SerenityType.scaledSystem(size: 14, weight: .regular))
    .foregroundStyle(SerenityPalette.textPrimary.opacity(0.86))
    .lineSpacing(3)
  }

  /// Where "concise" and "nothing left out" both hold: the script stays short,
  /// and the specifics it compressed stay one glance away for the follow-up.
  private func foldedStrip(_ folded: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { isFoldedExpanded.toggle() }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: isFoldedExpanded ? "chevron.down" : "chevron.right")
            .font(SerenityType.scaledSystem(size: 10, weight: .semibold))
          Text("Detail it folded away — \(folded.count)")
            .font(SerenityType.caption)
          Spacer(minLength: 0)
        }
        .foregroundStyle(SerenityPalette.textSecondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverCursor(.pointingHand)

      if isFoldedExpanded {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(folded.enumerated()), id: \.offset) { _, line in
            Text("\u{00B7} \(line)")
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
  }

  private func outputFooter(_ script: StandupScript) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: $appState.standupSaveToJournal) {
        Text("Save as today's journal entry")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .toggleStyle(.switch)

      HStack(spacing: 8) {
        Button(isEditingScript ? "Done editing" : "Edit wording") {
          if isEditingScript {
            appState.updateStandupScript(spoken: editedScript)
            isEditingScript = false
          } else {
            editedScript = script.spoken
            showPasteRendering = false
            isEditingScript = true
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Back to the list") {
          appState.standupScript = nil
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Spacer(minLength: 8)

        Button("Copy") {
          StandupClipboard.copy(showPasteRendering ? script.paste : script.spoken)
          appState.showToast("Copied")
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Save") {
          Task { await appState.saveStandup() }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
  }

  // MARK: - What you said before

  private var historyPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Earlier stand-ups")
        .font(SerenityType.sectionTitle)
        .foregroundStyle(SerenityPalette.textPrimary)

      ForEach(appState.standups.prefix(10)) { standup in
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(standup.generatedAt.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
              .font(SerenityType.bodyMedium)
              .foregroundStyle(SerenityPalette.textPrimary)
            Spacer(minLength: 8)
            Text("\(standup.items.filter { $0.column != .leftOut }.count) items")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          Text(standup.spoken)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
          Button("Copy") {
            StandupClipboard.copy(standup.spoken)
            appState.showToast("Copied")
          }
          Button("Delete", role: .destructive) {
            Task { await appState.deleteStandup(id: standup.id) }
          }
        }
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .serenityPanel()
  }
}

/// The standing instruction that shapes the words. Reachable from the board's
/// header as well as Settings, because the moment you learn the format is wrong
/// is the moment you walk out of the stand-up.
private struct StandupFormatSheet: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.dismiss) private var dismiss

  @State private var instruction = ""
  @State private var justForToday = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("How your team runs stand-up")
          .font(SerenityType.sectionTitle)
          .foregroundStyle(SerenityPalette.textPrimary)
        Text("Plain English. This shapes the words, not what gets gathered.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Start from one of these, then edit it")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        SerenityFlowLayout(spacing: 8) {
          ForEach(StandupWriter.presets) { preset in
            Button(preset.title) {
              instruction = preset.instruction
            }
            .buttonStyle(SerenityPillButtonStyle(selected: instruction == preset.instruction))
            .hoverCursor(.pointingHand)
          }
        }
      }

      TextEditor(text: $instruction)
        .serenityTextArea(minHeight: 150)

      Text("Easier than writing rules: paste a stand-up that went down well and say \u{201C}like this one\u{201D}.")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle(isOn: $justForToday) {
        Text("Just for today, don't save it")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .toggleStyle(.switch)

      HStack(spacing: 8) {
        Spacer(minLength: 0)

        Button("Cancel") { dismiss() }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

        Button(justForToday ? "Use for today" : "Save format") {
          Task {
            if justForToday {
              await appState.writeStandup(instructionOverride: instruction)
            } else {
              await appState.setStandupFormat(instruction)
            }
            dismiss()
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground)
    .serenityDesktopSheetSize(minWidth: 560, minHeight: 520)
    .onAppear {
      instruction = appState.aiSettings.resolvedStandupFormat
    }
  }
}

enum StandupClipboard {
  static func copy(_ text: String) {
#if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#else
    UIPasteboard.general.string = text
#endif
  }
}

private struct DatabaseSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout

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

      DatabaseBackendConfigurationPanel()

      if compactLayout {
        VStack(alignment: .leading, spacing: 16) {
          databaseStatisticsPanel
          databaseSidePanels
        }
      } else {
        HStack(alignment: .top, spacing: 16) {
          databaseStatisticsPanel
            .frame(maxWidth: .infinity)

          databaseSidePanels
            .frame(width: 320)
        }
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


  private var databaseStatisticsPanel: some View {
    GroupBox("Database Statistics") {
        VStack(alignment: .leading, spacing: 14) {
          if compactLayout {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
              databaseStatMetricCards
            }
          } else {
            HStack(spacing: 10) {
              databaseStatMetricCards
            }
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
  }

  @ViewBuilder
  private var databaseStatMetricCards: some View {
    statMetricCard(title: "Size", value: sqlitePath == nil ? "N/A" : "Local")
    statMetricCard(title: "Records", value: "\(recordCount)")
    statMetricCard(title: "Tasks", value: "\(appState.tasks.count)")
    statMetricCard(title: "Error Rate", value: databaseHealthErrorRate)
  }

  private var databaseSidePanels: some View {
    VStack(spacing: 16) {
      GroupBox("Quick Actions") {
        VStack(alignment: .leading, spacing: 10) {
          Button("Create Backup") {
            Task { await appState.createDatabaseBackup() }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .serenityFullWidthOnCompact(compactLayout)

          Button("Integrity Check") {
            Task { await appState.runDatabaseIntegrityCheck() }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .serenityFullWidthOnCompact(compactLayout)

          Button("Export Snapshot") {
            Task { await appState.exportCoreDataSnapshot() }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .serenityFullWidthOnCompact(compactLayout)

          Button("Run Bootstrap") {
            Task { await appState.bootstrapLocalDatabase() }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
          .serenityFullWidthOnCompact(compactLayout)
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
  @Environment(\.serenityCompactLayout) private var compactLayout
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
          .frame(maxWidth: compactLayout ? .infinity : 300, alignment: .leading)
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
          .frame(maxWidth: compactLayout ? .infinity : 300, alignment: .leading)
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

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            postgresConfigurationActions
          }

          VStack(alignment: .leading, spacing: 10) {
            postgresConfigurationActions
          }
        }
      }
    }
  }

  @ViewBuilder
  private var postgresConfigurationActions: some View {
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

private struct SettingsSectionView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
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
  @State private var newCredentialDomain = ""
  @State private var keyVerification: KeyVerificationState = .idle
  @State private var selectedTab: SettingsTab = .appearance

  private enum KeyVerificationState: Equatable {
    case idle
    case validating
    case valid(models: [String])
    case invalid(message: String)
  }

  private let postgresSSLModes = ["disable", "prefer", "require", "verify-ca", "verify-full"]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsTabBar
      Divider().overlay(SerenityPalette.thinBorder)
      selectedPanel
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear {
      loadStoredSettingsValuesIfNeeded()
      consumePendingSettingsTab()
    }
    .onChange(of: appState.pendingSettingsTab) { _, _ in
      consumePendingSettingsTab()
    }
  }

  private func consumePendingSettingsTab() {
    guard let tab = appState.pendingSettingsTab else { return }
    if SettingsTab.allCases.contains(tab) {
      selectedTab = tab
    }
    appState.pendingSettingsTab = nil
  }

  private var settingsTabBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(SettingsTab.allCases) { tab in
          Button {
            selectedTab = tab
          } label: {
            VStack(spacing: 4) {
              ZStack(alignment: .topTrailing) {
                Image(systemName: tab.systemImage)
                  .font(SerenityType.scaledSystem(size: 16, weight: .semibold))
                  .frame(width: 28, height: 28)
                if let dotColor = warningDot(for: tab) {
                  Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(SerenityPalette.panelBackground, lineWidth: 1))
                    .offset(x: 3, y: -2)
                }
              }
              Text(tab.title)
                .font(SerenityType.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 78)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
              selectedTab == tab
                ? SerenityPalette.accent.opacity(0.18)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                  selectedTab == tab ? SerenityPalette.accent.opacity(0.35) : Color.clear,
                  lineWidth: 1
                )
            )
            .foregroundStyle(
              selectedTab == tab ? SerenityPalette.accent : SerenityPalette.textSecondary
            )
          }
          .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
        }
      }
      .padding(.horizontal, 2)
    }
  }

  private func warningDot(for tab: SettingsTab) -> Color? {
    switch tab {
    case .aiProvider:
      return hasEnabledCredential ? nil : .orange
    case .backend:
      return backendValidation.isAvailable ? nil : .orange
    default:
      return nil
    }
  }

  @ViewBuilder
  private var selectedPanel: some View {
    switch selectedTab {
    case .appearance:
      appearancePanel
    case .aiProvider:
      aiProviderPanel
    case .costCenter:
      CostCenterSectionView()
    case .backend:
      backendPanel
    case .auth:
      authPanel
    case .appLock:
      appLockPanel
    case .database:
      DatabaseSectionView()
    case .diagnostics:
      diagnosticsPanel
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

      settingsField("Due reminders", help: "Notify you when a task falls due. Tasks without a time are reminded at 9am.") {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(
            "Notify me when a task is due",
            isOn: Binding(
              get: { appState.notificationsEnabled },
              set: { enabled in
                Task { await appState.setNotificationsEnabled(enabled) }
              }
            )
          )
          .toggleStyle(.switch)

          if appState.notificationsEnabled {
            Picker(
              "Remind me",
              selection: Binding(
                get: { appState.notificationLeadMinutes },
                set: { appState.setNotificationLeadMinutes($0) }
              )
            ) {
              Text("At the due time").tag(0)
              Text("5 minutes before").tag(5)
              Text("15 minutes before").tag(15)
              Text("1 hour before").tag(60)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
          }
        }
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

      if newCredentialProvider == .custom {
        settingsField(
          "Domain",
          help: "Any service that speaks the OpenAI API. Serenity calls /v1/models and /v1/chat/completions under it."
        ) {
          TextField("https://example.com/llm/", text: $newCredentialDomain)
            .textFieldStyle(.plain)
            .serenityInputField()
            .frame(maxWidth: 520)
        }
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
              || isMissingCustomDomain
          )
        }

        keyVerificationStatusView
      }

      HStack(alignment: .top, spacing: 18) {
        settingsField("Model (optional)") {
          SerenityDropdownField(
            placeholder: "Default",
            selection: $newCredentialModel,
            options: addFormModelOptions,
            searchable: true
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
              availableModels: verifiedModels,
              baseURL: newCredentialDomain
            )
            newCredentialName = ""
            newCredentialAPIKey = ""
            newCredentialModel = ""
            newCredentialDomain = ""
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
            || isMissingCustomDomain
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
    .onChange(of: newCredentialDomain) { _, _ in
      if keyVerification != .validating { keyVerification = .idle }
    }
  }

  private var isMissingCustomDomain: Bool {
    newCredentialProvider == .custom
      && newCredentialDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        apiKey: trimmed,
        baseURL: newCredentialDomain
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
        Text("\(credentialProviderCaption(credential)) · \(credential.totalRequests) requests · \(credential.totalTokens) tokens")
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
        options: credentialModelOptions(for: credential),
        searchable: true
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

  private func credentialProviderCaption(_ credential: AICredentialEntity) -> String {
    guard credential.provider == .custom,
          let domain = AIWorkflowService.decodeCredentialBaseURL(from: credential.metadataJSON),
          let host = URL(string: AIProviderEndpoint.normalizedCustomBase(domain) ?? "")?.host
    else {
      return providerTitle(credential.provider)
    }
    return host
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
    [.openai, .gemini, .anthropic, .nvidia, .custom]
  }

  private func providerTitle(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "OpenAI"
    case .gemini:
      return "Gemini"
    case .anthropic:
      return "Anthropic"
    case .nvidia:
      return "NVIDIA NIM"
    case .custom:
      return "Custom"
    }
  }

  @ViewBuilder
  private func providerLogo(_ provider: AICredentialProvider, size: CGFloat) -> some View {
    if let asset = providerLogoAsset(provider) {
      Image(asset)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .foregroundStyle(providerTint(provider))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      Image(systemName: providerIcon(provider))
        .font(SerenityType.scaledSystem(size: size, weight: .semibold))
        .foregroundStyle(providerTint(provider))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }

  private func providerLogoAsset(_ provider: AICredentialProvider) -> String? {
    switch provider {
    case .openai:
      return "ProviderOpenAI"
    case .gemini:
      return "ProviderGemini"
    case .anthropic:
      return "ProviderAnthropic"
    case .nvidia:
      return "ProviderNvidia"
    case .custom:
      return nil
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
    case .nvidia:
      return "cpu.fill"
    case .custom:
      return "globe"
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
    case .nvidia:
      return .green
    case .custom:
      return .teal
    }
  }

  private func statusDot(isActive: Bool) -> some View {
    Circle()
      .fill(isActive ? Color.green : Color.orange)
      .frame(width: 8, height: 8)
  }

  private var backendPanel: some View {
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
          .frame(maxWidth: compactLayout ? .infinity : 300, alignment: .leading)
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
          .frame(maxWidth: compactLayout ? .infinity : 300, alignment: .leading)
        }

        backendConfigurationEditor

        HStack(spacing: 10) {
          Button {
            Task {
              await appState.refreshActiveBackendValidation()
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

  private var diagnosticsPanel: some View {
    settingsPanel(
      title: "Backend Diagnostics",
      subtitle: "\(appState.backendDiagnosticsLines.count) lines",
      systemImage: "waveform.path.ecg.rectangle",
      tint: SerenityPalette.accent
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if appState.backendDiagnosticsLines.isEmpty {
          statusBanner(
            "No diagnostics available yet.",
            systemImage: "info.circle",
            tint: SerenityPalette.textSecondary
          )
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(appState.backendDiagnosticsLines, id: \.self) { line in
              Text(line)
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

        Button {
          Task {
            await appState.refreshActiveBackendValidation()
            await appState.refreshBackendDiagnostics()
          }
        } label: {
          Label("Refresh diagnostics", systemImage: "arrow.clockwise")
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
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

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            postgresConfigurationActions
          }

          VStack(alignment: .leading, spacing: 10) {
            postgresConfigurationActions
          }
        }
      }
    }
  }

  @ViewBuilder
  private var postgresConfigurationActions: some View {
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
  @Environment(\.colorScheme) private var colorScheme
  @State private var password = ""
  @State private var revealPassword = false
  @State private var isUnlockingWithPassword = false
  @State private var isUnlockingWithBiometrics = false
  @FocusState private var passwordFieldFocused: Bool

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          lockColor(Color(red: 0.06, green: 0.12, blue: 0.24), dark: SerenityPalette.windowBackground),
          lockColor(Color(red: 0.04, green: 0.10, blue: 0.20), dark: SerenityPalette.windowBackgroundDepth),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      Circle()
        .fill(lockColor(Color(red: 0.30, green: 0.45, blue: 0.82).opacity(0.34), dark: .clear))
        .frame(width: 680, height: 680)
        .blur(radius: 120)
        .offset(x: -220, y: -300)

      Circle()
        .fill(lockColor(Color(red: 0.18, green: 0.32, blue: 0.62).opacity(0.30), dark: .clear))
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
            Image("SerenityAppMark")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 76, height: 76)
              .shadow(color: Color.black.opacity(0.28), radius: 14, y: 8)
              .accessibilityHidden(true)

            Text("Serenity Notes")
              .font(SerenityType.scaledSystem(size: 32, weight: .semibold, design: .rounded))
              .foregroundStyle(lockColor(Color.white.opacity(0.97), dark: SerenityPalette.textPrimary))

            Text("Enter your master password to unlock")
              .font(SerenityType.scaledSystem(size: 15, weight: .regular, design: .rounded))
              .foregroundStyle(lockColor(Color(red: 0.66, green: 0.72, blue: 0.82), dark: SerenityPalette.textSecondary))
          }
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 8) {
            Text("Master Password")
              .font(SerenityType.scaledSystem(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(lockColor(Color(red: 0.74, green: 0.79, blue: 0.88), dark: SerenityPalette.textSecondary))

            HStack(spacing: 10) {
              Image(systemName: "key")
                .font(SerenityType.scaledSystem(size: 15, weight: .semibold))
                .foregroundStyle(lockColor(Color(red: 0.61, green: 0.67, blue: 0.78), dark: SerenityPalette.accent))

              Group {
                if revealPassword {
                  TextField("", text: $password, prompt: Text("Enter master password").foregroundStyle(
                    lockColor(Color(red: 0.55, green: 0.62, blue: 0.73), dark: SerenityPalette.textSecondary)
                  ))
                    .textFieldStyle(.plain)
                } else {
                  SecureField("", text: $password, prompt: Text("Enter master password").foregroundStyle(
                    lockColor(Color(red: 0.55, green: 0.62, blue: 0.73), dark: SerenityPalette.textSecondary)
                  ))
                    .textFieldStyle(.plain)
                }
              }
              .font(SerenityType.scaledSystem(size: 15, weight: .medium, design: .rounded))
              .foregroundStyle(lockColor(Color(red: 0.84, green: 0.89, blue: 0.97), dark: SerenityPalette.textPrimary))
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
                  .foregroundStyle(lockColor(Color(red: 0.56, green: 0.63, blue: 0.75), dark: SerenityPalette.textSecondary))
              }
              .buttonStyle(.plain)
              .hoverCursor(.pointingHand)
              .disabled(isLockedOut || isUnlockingWithPassword)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(lockColor(Color(red: 0.03, green: 0.07, blue: 0.16).opacity(0.96), dark: SerenityPalette.inputBackground))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(lockColor(Color(red: 0.18, green: 0.35, blue: 0.60).opacity(0.82), dark: SerenityPalette.border), lineWidth: 1.2)
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
                  .tint(lockColor(Color(red: 0.10, green: 0.13, blue: 0.22), dark: SerenityPalette.textPrimary))
                Text("Validating...")
              } else {
                Text(isLockedOut ? "Locked" : "Unlock")
              }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
          }
          .font(SerenityType.scaledSystem(size: 16, weight: .semibold, design: .rounded))
          .foregroundStyle(unlockButtonForeground)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 11)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(unlockButtonFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(
                lockColor(
                  Color.white.opacity(unlockDisabled ? 0.05 : 0.14),
                  dark: SerenityPalette.border
                ),
                lineWidth: 1
              )
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
            .foregroundStyle(lockColor(Color(red: 0.82, green: 0.88, blue: 0.97), dark: SerenityPalette.textPrimary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(lockColor(Color(red: 0.11, green: 0.18, blue: 0.29), dark: SerenityPalette.panelBackgroundRaised))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(lockColor(Color(red: 0.26, green: 0.40, blue: 0.63).opacity(0.62), dark: SerenityPalette.border), lineWidth: 1)
            )
            .hoverCursor(.pointingHand)
            .buttonStyle(.plain)
            .disabled(isUnlockingWithBiometrics || isUnlockingWithPassword || isLockedOut)
          }

          if isBiometricAvailable {
            HStack(spacing: 10) {
              Rectangle()
                .fill(lockColor(Color(red: 0.30, green: 0.37, blue: 0.49), dark: SerenityPalette.thinBorder))
                .frame(height: 1)
              Text("or")
                .font(SerenityType.scaledSystem(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(lockColor(Color(red: 0.56, green: 0.62, blue: 0.73), dark: SerenityPalette.textSecondary))
              Rectangle()
                .fill(lockColor(Color(red: 0.30, green: 0.37, blue: 0.49), dark: SerenityPalette.thinBorder))
                .frame(height: 1)
            }
          }

          Button("Forgot your password?") {
            appState.setSection(.settings)
            appState.showToast("Open Settings to reset your local lock password.")
          }
          .buttonStyle(.plain)
          .font(SerenityType.scaledSystem(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(lockColor(Color(red: 0.43, green: 0.67, blue: 0.98), dark: SerenityPalette.accent))
          .frame(maxWidth: .infinity, alignment: .center)
          .hoverCursor(.pointingHand)

          VStack(alignment: .leading, spacing: 6) {
            Label("Your data is protected", systemImage: "shield")
              .font(SerenityType.scaledSystem(size: 14, weight: .semibold, design: .rounded))
              .foregroundStyle(lockColor(Color(red: 0.71, green: 0.83, blue: 1.0), dark: SerenityPalette.textPrimary))
            Text("All sensitive information is encrypted with your master password.")
              .font(SerenityType.scaledSystem(size: 13, weight: .regular, design: .rounded))
              .foregroundStyle(lockColor(Color(red: 0.74, green: 0.82, blue: 0.95), dark: SerenityPalette.textSecondary))
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(lockColor(Color(red: 0.10, green: 0.16, blue: 0.30).opacity(0.9), dark: SerenityPalette.panelBackgroundRaised))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(lockColor(Color(red: 0.20, green: 0.42, blue: 0.84).opacity(0.78), dark: SerenityPalette.border), lineWidth: 1)
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
                  lockColor(Color(red: 0.06, green: 0.12, blue: 0.24).opacity(0.96), dark: SerenityPalette.panelBackground),
                  lockColor(Color(red: 0.05, green: 0.10, blue: 0.21).opacity(0.98), dark: SerenityPalette.panelBackgroundRaised),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(lockColor(Color(red: 0.17, green: 0.31, blue: 0.50).opacity(0.7), dark: SerenityPalette.border), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 16, x: 0, y: 10)

        Text("Serenity Notes v2.0 • Privacy-First Productivity")
          .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .rounded))
          .foregroundStyle(lockColor(Color(red: 0.53, green: 0.59, blue: 0.69), dark: SerenityPalette.textSecondary))
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

  private func lockColor(_ light: Color, dark: Color) -> Color {
    colorScheme == .dark ? dark : light
  }

  private var unlockButtonForeground: Color {
    if colorScheme == .dark {
      return unlockDisabled ? SerenityPalette.textSecondary : Color.white
    }
    return unlockDisabled ? Color.white.opacity(0.62) : Color(red: 0.08, green: 0.11, blue: 0.20)
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
    if colorScheme == .dark {
      let fill = unlockDisabled
        ? SerenityPalette.activeItemBackground
        : SerenityPalette.primaryActionBackground
      return LinearGradient(
        colors: [fill, fill],
        startPoint: .leading,
        endPoint: .trailing
      )
    }

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

private struct MetricTile: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(SerenityType.scaledSystem(size: 24, weight: .bold, design: .rounded))
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.32), lineWidth: 1)
    )
  }
}

private struct GlobalSearchSheet: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.serenityCompactLayout) private var compactLayout
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
        if compactLayout {
          // The shortcut chip means nothing without a keyboard; a phone sheet
          // needs a dismiss control instead.
          Button("Done") {
            appState.closeGlobalSearch()
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        } else {
          Text("Cmd+K")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SerenityPalette.innerCardBackground, in: Capsule())
        }
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
    .serenityDesktopSheetSize(minWidth: 760, minHeight: 560)
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
  @Environment(\.serenityCompactLayout) private var compactLayout
  @State private var query = ""

  private let articles: [HelpCenterArticle] = [
    HelpCenterArticle(
      title: "Search across everything",
      summary: "Find tasks, projects, journal entries, and goals from one place.",
      keywords: ["search", "global", "find", "lookup"],
      shortcut: "Cmd+K",
      section: nil
    ),
    HelpCenterArticle(
      title: "Manage tasks in ActionHub",
      summary: "Create, edit, complete, or bulk-update tasks and subtasks.",
      keywords: ["actionhub", "tasks", "subtasks", "bulk"],
      shortcut: nil,
      section: .actionHub
    ),
    HelpCenterArticle(
      title: "Plan your day",
      summary: "Review today's work from Home.",
      keywords: ["home", "today", "due", "overdue"],
      shortcut: nil,
      section: .home
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
      summary: "Connect Google and GitHub providers and inspect sync health.",
      keywords: ["integrations", "google", "github", "sync"],
      shortcut: nil,
      section: .integrations
    ),
    HelpCenterArticle(
      title: "Review AI insights and summaries",
      summary: "Explore generated insights, recaps, and summary exports.",
      keywords: ["insights", "ai", "summary", "usage"],
      shortcut: nil,
      section: .insights
    ),
    HelpCenterArticle(
      title: "Monitor AI cost center",
      summary: "Review token usage, estimated spend, model rates, and recent AI calls.",
      keywords: ["cost", "tokens", "usage", "ai", "billing", "pricing"],
      shortcut: nil,
      section: .settings
    ),
    HelpCenterArticle(
      title: "Security and backend settings",
      summary: "Manage auth, local lock, database diagnostics, and backend selection.",
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
        if compactLayout {
          Button("Done") {
            appState.closeHelpCenter()
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        } else {
          Text("Cmd+/")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SerenityPalette.innerCardBackground, in: Capsule())
        }
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

              Button("Go to ActionHub") {
                appState.setSection(.actionHub)
                appState.closeHelpCenter()
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Quick Capture") {
                appState.closeHelpCenter()
                appState.focusQuickCapture()
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Open Settings") {
                appState.setSection(.settings)
                appState.closeHelpCenter()
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
              HelpShortcutRow(action: "Find in List", shortcut: "Cmd+F")
              HelpShortcutRow(action: "Help Center", shortcut: "Cmd+/")
              HelpShortcutRow(action: "Quick Capture", shortcut: "Cmd+Shift+N")
              HelpShortcutRow(action: "Capture (in the capture field)", shortcut: "Cmd+Return")
              HelpShortcutRow(action: "Switch section", shortcut: "Cmd+1 … Cmd+8")
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
                    appState.setSection(section)
                    appState.closeHelpCenter()
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
    .serenityDesktopSheetSize(minWidth: 760, minHeight: 560)
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

private struct DueDateSelectionField: View {
  @Binding var selection: Date
  @State private var showingPopover = false

  var body: some View {
    Button {
      showingPopover.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
          .foregroundStyle(SerenityPalette.accent)

        Text(selection.formatted(date: .abbreviated, time: .shortened))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Image(systemName: "chevron.down")
          .font(SerenityType.scaledSystem(size: 10, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(minWidth: 220, alignment: .leading)
      .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
      DueDateCalendarPopover(selection: $selection, isPresented: $showingPopover)
        .padding(12)
        .frame(width: 334)
    }
  }
}

private struct DueDateCalendarPopover: View {
  @Environment(\.serenityCompactLayout) private var compactLayout
  @Binding var selection: Date
  @Binding var isPresented: Bool
  @State private var visibleMonth: Date

  init(selection: Binding<Date>, isPresented: Binding<Bool>) {
    _selection = selection
    _isPresented = isPresented
    _visibleMonth = State(initialValue: Calendar.current.startOfMonth(for: selection.wrappedValue))
  }

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

  private var weekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var gridDates: [Date] {
    Calendar.current.monthGridDates(for: visibleMonth)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Button {
          shiftMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
            .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

        Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
          .font(SerenityType.bodyLarge.weight(.semibold))
          .frame(maxWidth: .infinity)

        Button {
          shiftMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
            .font(SerenityType.scaledSystem(size: 11, weight: .semibold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
      }

      HStack(spacing: 6) {
        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, 2)

      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(gridDates, id: \.self) { date in
          dueDateCell(date)
        }
      }

      Divider()
        .overlay(SerenityPalette.thinBorder)

      HStack(spacing: 10) {
        Text("Time")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
          .labelsHidden()
      }

      HStack(spacing: 8) {
        quickTimeButton("9:00", hour: 9, minute: 0)
        quickTimeButton("13:00", hour: 13, minute: 0)
        quickTimeButton("17:30", hour: 17, minute: 30)
      }

      HStack {
        Button("Today") {
          let today = Date()
          visibleMonth = Calendar.current.startOfMonth(for: today)
          selectDay(today)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

        Spacer()

        Button("Done") {
          isPresented = false
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
      }
      .padding(.top, 2)
    }
    .onChange(of: selection) { _, newValue in
      if !Calendar.current.isDate(newValue, equalTo: visibleMonth, toGranularity: .month) {
        visibleMonth = Calendar.current.startOfMonth(for: newValue)
      }
    }
  }

  private func dueDateCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let selectedDay = calendar.startOfDay(for: selection)
    let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
    let isToday = calendar.isDateInToday(day)
    let isInVisibleMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)

    return Button {
      selectDay(day)
    } label: {
      Text("\(calendar.component(.day, from: day))")
        .font(SerenityType.bodyMedium.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: compactLayout ? SerenityTouchMetrics.minimumTarget : 30)
        .background(
          (isSelected ? SerenityPalette.activeItemBackground : SerenityPalette.innerCardBackground.opacity(0.45)),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
              isToday ? SerenityPalette.accent.opacity(0.65) : (isSelected ? SerenityPalette.border : SerenityPalette.thinBorder),
              lineWidth: 1
            )
        )
        .opacity(isInVisibleMonth ? 1 : 0.42)
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func selectDay(_ day: Date) {
    let calendar = Calendar.current
    let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
    var components = calendar.dateComponents([.year, .month, .day], from: day)
    components.hour = time.hour ?? 9
    components.minute = time.minute ?? 0
    components.second = time.second ?? 0
    selection = calendar.date(from: components) ?? day
    visibleMonth = calendar.startOfMonth(for: day)
  }

  private func shiftMonth(by value: Int) {
    guard let shifted = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) else { return }
    visibleMonth = Calendar.current.startOfMonth(for: shifted)
  }

  private func quickTimeButton(_ label: String, hour: Int, minute: Int) -> some View {
    Button(label) {
      selection = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: selection) ?? selection
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)
  }
}

private struct TaskMarkdownDescriptionField: View {
  @Binding var text: String
  var minHeight: CGFloat = 132
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Description")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer(minLength: 0)

        Label("Markdown", systemImage: "text.badge.checkmark")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      ZStack(alignment: .topLeading) {
        TextEditor(text: $text)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textPrimary)
          .focused($isFocused)
          .serenityTextArea(minHeight: minHeight)

        if text.isEmpty && !isFocused {
          Text("Description (optional)")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary.opacity(0.76))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .allowsHitTesting(false)
        }
      }

      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Preview")
            .font(SerenityType.caption.weight(.semibold))
            .foregroundStyle(SerenityPalette.textSecondary)

          GitHubFlavoredMarkdownView(markdown: text)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SerenityPalette.thinBorder, lineWidth: 1)
            )
        }
      }
    }
  }
}

private struct GitHubFlavoredMarkdownView: View {
  let markdown: String
  var compact = false

  private var blocks: [TaskMarkdownBlock] {
    TaskMarkdownParser.parse(markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 5 : 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(_ block: TaskMarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(headingFont(level: level))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 2 : nil)
        .padding(.top, compact ? 0 : headingTopPadding(level: level))

    case .paragraph(let text):
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(compact ? 3 : nil)
        .fixedSize(horizontal: false, vertical: true)

    case .unorderedListItem(let text):
      unorderedListRow(text)

    case .orderedListItem(let number, let text):
      HStack(alignment: .top, spacing: 8) {
        Text("\(number).")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(width: 24, alignment: .trailing)
          .padding(.top, 1)
        Text(TaskMarkdownParser.inlineAttributedString(text))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(compact ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .taskListItem(let completed, let text):
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: completed ? "checkmark.square.fill" : "square")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(completed ? .green : SerenityPalette.textSecondary)
          .padding(.top, 2)
        Text(TaskMarkdownParser.inlineAttributedString(text))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .strikethrough(completed)
          .lineLimit(compact ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .blockquote(let text):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(SerenityPalette.accent.opacity(0.55))
          .frame(width: 3)
        GitHubFlavoredMarkdownView(markdown: text, compact: compact)
      }

    case .image(let image):
      MarkdownRemoteImage(image: image, compact: compact)

    case .table(let table):
      markdownTable(table)

    case .disclosure(let disclosure):
      MarkdownDisclosureSection(disclosure: disclosure, compact: compact)

    case .codeBlock(let text):
      Text(verbatim: text)
        .font(SerenityType.scaledSystem(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 4 : nil)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(SerenityPalette.thinBorder, lineWidth: 1)
        )

    case .divider:
      Rectangle()
        .fill(SerenityPalette.thinBorder)
        .frame(height: 1)
        .padding(.vertical, compact ? 1 : 4)
    }
  }

  private func unorderedListRow(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(SerenityPalette.textSecondary)
        .frame(width: 5, height: 5)
        .padding(.top, SerenityType.scaledSize(8))
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(compact ? 2 : nil)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case 1:
      return compact ? SerenityType.bodyLarge.weight(.semibold) : SerenityType.sectionTitle
    case 2:
      return SerenityType.bodyLarge.weight(.semibold)
    default:
      return SerenityType.bodyMedium.weight(.semibold)
    }
  }

  private func markdownTable(_ table: TaskMarkdownTable) -> some View {
    ScrollView(.horizontal, showsIndicators: !compact) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
            tableCell(header, column: index, alignment: table.alignments[safe: index] ?? .leading, isHeader: true)
          }
        }

        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(table.headers.indices), id: \.self) { index in
              tableCell(
                row[safe: index] ?? "",
                column: index,
                alignment: table.alignments[safe: index] ?? .leading,
                isHeader: false
              )
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
    }
  }

  private func tableCell(_ text: String, column: Int, alignment: TaskMarkdownTableAlignment, isHeader: Bool) -> some View {
    Text(TaskMarkdownParser.inlineAttributedString(text))
      .font(isHeader ? SerenityType.caption.weight(.semibold) : SerenityType.body)
      .foregroundStyle(isHeader ? SerenityPalette.textPrimary : SerenityPalette.textSecondary)
      .lineLimit(compact ? 2 : nil)
      .multilineTextAlignment(alignment.textAlignment)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, isHeader ? 8 : 9)
      .frame(minWidth: compact ? 96 : 118, maxWidth: compact ? 180 : 240, alignment: alignment.frameAlignment)
      .background(isHeader ? SerenityPalette.inputBackground : SerenityPalette.innerCardBackground.opacity(column.isMultiple(of: 2) ? 0.72 : 0.46))
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(SerenityPalette.thinBorder)
          .frame(width: 1)
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(SerenityPalette.thinBorder)
          .frame(height: 1)
      }
  }

  private func headingTopPadding(level: Int) -> CGFloat {
    level == 1 ? 4 : 2
  }
}

private struct MarkdownRemoteImage: View {
  let image: TaskMarkdownImage
  let compact: Bool

  var body: some View {
    if let url = URL(string: image.url), ["http", "https"].contains(url.scheme?.lowercased()) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .empty:
          imagePlaceholder(label: image.altText.isEmpty ? "Loading image..." : image.altText)
        case .success(let loadedImage):
          loadedImage
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: compact ? 140 : 320)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SerenityPalette.thinBorder, lineWidth: 1)
            )
            .accessibilityLabel(image.altText.isEmpty ? "Markdown image" : image.altText)
        case .failure:
          imagePlaceholder(label: image.altText.isEmpty ? "Image could not be loaded" : image.altText)
        @unknown default:
          imagePlaceholder(label: image.altText.isEmpty ? "Image unavailable" : image.altText)
        }
      }
    } else {
      imagePlaceholder(label: image.altText.isEmpty ? image.url : image.altText)
    }
  }

  private func imagePlaceholder(label: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "photo")
        .font(SerenityType.caption.weight(.semibold))
      Text(label)
        .font(SerenityType.body)
        .lineLimit(compact ? 2 : nil)
      Spacer(minLength: 0)
    }
    .foregroundStyle(SerenityPalette.textSecondary)
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: compact ? 72 : 96, alignment: .leading)
    .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private struct MarkdownDisclosureSection: View {
  let disclosure: TaskMarkdownDisclosure
  let compact: Bool

  @State private var isExpanded: Bool

  init(disclosure: TaskMarkdownDisclosure, compact: Bool) {
    self.disclosure = disclosure
    self.compact = compact
    _isExpanded = State(initialValue: disclosure.initiallyExpanded)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      GitHubFlavoredMarkdownView(markdown: disclosure.body, compact: compact)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(TaskMarkdownParser.inlineAttributedString(disclosure.summary))
        .font(SerenityType.bodyMedium.weight(.semibold))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 2 : nil)
    }
    .padding(12)
    .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private enum TaskMarkdownBlock {
  case heading(level: Int, text: String)
  case paragraph(String)
  case unorderedListItem(String)
  case orderedListItem(number: Int, text: String)
  case taskListItem(completed: Bool, text: String)
  case blockquote(String)
  case image(TaskMarkdownImage)
  case table(TaskMarkdownTable)
  case disclosure(TaskMarkdownDisclosure)
  case codeBlock(String)
  case divider
}

private struct TaskMarkdownImage {
  let altText: String
  let url: String
}

private struct TaskMarkdownTable {
  let headers: [String]
  let alignments: [TaskMarkdownTableAlignment]
  let rows: [[String]]
}

private struct TaskMarkdownDisclosure {
  let summary: String
  let body: String
  let initiallyExpanded: Bool
}

private enum TaskMarkdownTableAlignment {
  case leading
  case center
  case trailing

  var textAlignment: TextAlignment {
    switch self {
    case .leading:
      return .leading
    case .center:
      return .center
    case .trailing:
      return .trailing
    }
  }

  var frameAlignment: Alignment {
    switch self {
    case .leading:
      return .leading
    case .center:
      return .center
    case .trailing:
      return .trailing
    }
  }
}

private enum TaskMarkdownParser {
  static func parse(_ markdown: String) -> [TaskMarkdownBlock] {
    var blocks: [TaskMarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var insideCodeBlock = false
    let rawLines = markdown.components(separatedBy: .newlines)
    var index = 0

    func flushParagraph() {
      let paragraph = paragraphLines
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph))
      }
      paragraphLines.removeAll()
    }

    while index < rawLines.count {
      let rawLine = rawLines[index]
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

      if line.hasPrefix("```") {
        if insideCodeBlock {
          blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
          codeLines.removeAll()
          insideCodeBlock = false
        } else {
          flushParagraph()
          insideCodeBlock = true
        }
        index += 1
        continue
      }

      if insideCodeBlock {
        codeLines.append(rawLine)
        index += 1
        continue
      }

      guard !line.isEmpty else {
        flushParagraph()
        index += 1
        continue
      }

      if let disclosure = disclosure(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.disclosure(disclosure.value))
        index = disclosure.nextIndex
      } else if let blockquote = blockquote(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.blockquote(blockquote.value))
        index = blockquote.nextIndex
      } else if let table = table(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.table(table.value))
        index = table.nextIndex
      } else if let image = image(from: line) {
        flushParagraph()
        blocks.append(.image(image))
        index += 1
      } else if isDivider(line) {
        flushParagraph()
        blocks.append(.divider)
        index += 1
      } else if let heading = heading(from: line) {
        flushParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
      } else if let task = taskListItem(from: line) {
        flushParagraph()
        blocks.append(.taskListItem(completed: task.completed, text: task.text))
        index += 1
      } else if let unordered = unorderedListItem(from: line) {
        flushParagraph()
        blocks.append(.unorderedListItem(unordered))
        index += 1
      } else if let ordered = orderedListItem(from: line) {
        flushParagraph()
        blocks.append(.orderedListItem(number: ordered.number, text: ordered.text))
        index += 1
      } else {
        paragraphLines.append(rawLine)
        index += 1
      }
    }

    if insideCodeBlock {
      blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks
  }

  static func shouldCollapseInTaskList(_ markdown: String) -> Bool {
    let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let lineCount = trimmed.components(separatedBy: .newlines).count
    if trimmed.count > 320 || lineCount > 6 {
      return true
    }

    let blocks = parse(trimmed)
    if blocks.count > 4 {
      return true
    }

    return blocks.contains { block in
      switch block {
      case .codeBlock, .disclosure, .image, .table:
        return true
      case .heading, .paragraph, .unorderedListItem, .orderedListItem, .taskListItem, .blockquote, .divider:
        return false
      }
    }
  }

  static func inlineAttributedString(_ markdown: String) -> AttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
  }

  private static func heading(from line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") else {
      return nil
    }
    let text = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return (hashes.count, text)
  }

  private static func taskListItem(from line: String) -> (completed: Bool, text: String)? {
    for marker in ["- [ ] ", "* [ ] ", "+ [ ] "] where line.hasPrefix(marker) {
      return (false, String(line.dropFirst(marker.count)))
    }
    for marker in ["- [x] ", "* [x] ", "+ [x] ", "- [X] ", "* [X] ", "+ [X] "] where line.hasPrefix(marker) {
      return (true, String(line.dropFirst(marker.count)))
    }
    return nil
  }

  private static func unorderedListItem(from line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    return nil
  }

  private static func orderedListItem(from line: String) -> (number: Int, text: String)? {
    guard let dotIndex = line.firstIndex(of: ".") else { return nil }
    let numberText = line[..<dotIndex]
    guard let number = Int(numberText) else { return nil }

    let remainder = line[line.index(after: dotIndex)...]
    guard remainder.hasPrefix(" ") else { return nil }
    return (number, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func isDivider(_ line: String) -> Bool {
    let characters = Set(line)
    return line.count >= 3 &&
      (characters == Set<Character>("-") || characters == Set<Character>("*") || characters == Set<Character>("_"))
  }

  private static func image(from line: String) -> TaskMarkdownImage? {
    guard line.hasPrefix("!["), line.hasSuffix(")") else { return nil }
    guard let closeBracket = line.firstIndex(of: "]") else { return nil }
    let openParen = line.index(after: closeBracket)
    guard openParen < line.endIndex, line[openParen] == "(" else { return nil }

    let altText = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket])
    let urlStart = line.index(after: openParen)
    let urlEnd = line.index(before: line.endIndex)
    let url = line[urlStart..<urlEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return nil }
    return TaskMarkdownImage(altText: altText, url: url)
  }

  private static func blockquote(from rawLines: [String], startIndex: Int) -> (value: String, nextIndex: Int)? {
    guard rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") else {
      return nil
    }

    var quoteLines: [String] = []
    var index = startIndex
    while index < rawLines.count {
      let line = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix(">") else { break }
      quoteLines.append(strippingBlockquoteMarker(from: line))
      index += 1
    }

    return (quoteLines.joined(separator: "\n"), index)
  }

  private static func strippingBlockquoteMarker(from line: String) -> String {
    guard line.hasPrefix(">") else { return line }
    var stripped = String(line.dropFirst())
    if stripped.hasPrefix(" ") {
      stripped.removeFirst()
    }
    return stripped
  }

  private static func disclosure(from rawLines: [String], startIndex: Int) -> (value: TaskMarkdownDisclosure, nextIndex: Int)? {
    let firstLine = rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    guard firstLine.lowercased().hasPrefix("<details") else { return nil }

    var lines: [String] = []
    var index = startIndex
    var foundClosingTag = false
    while index < rawLines.count {
      lines.append(rawLines[index])
      if rawLines[index].range(of: "</details>", options: [.caseInsensitive]) != nil {
        foundClosingTag = true
        index += 1
        break
      }
      index += 1
    }

    let rawDisclosure = lines.joined(separator: "\n")
    let initiallyExpanded = firstLine.range(of: "open", options: [.caseInsensitive]) != nil
    let contentAfterOpeningTag = removingOpeningDetailsTag(from: rawDisclosure)
    let contentWithoutClosingTag = removingClosingDetailsTag(from: contentAfterOpeningTag, foundClosingTag: foundClosingTag)
    let extracted = extractingSummary(from: contentWithoutClosingTag)
    let summary = extracted.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)

    return (
      TaskMarkdownDisclosure(
        summary: summary.isEmpty ? "Details" : summary,
        body: body,
        initiallyExpanded: initiallyExpanded
      ),
      index
    )
  }

  private static func removingOpeningDetailsTag(from text: String) -> String {
    guard
      let start = text.range(of: "<details", options: [.caseInsensitive]),
      let close = text[start.lowerBound...].firstIndex(of: ">")
    else {
      return text
    }

    var result = text
    result.removeSubrange(start.lowerBound...close)
    return result
  }

  private static func removingClosingDetailsTag(from text: String, foundClosingTag: Bool) -> String {
    guard
      foundClosingTag,
      let range = text.range(of: "</details>", options: [.caseInsensitive])
    else {
      return text
    }

    var result = text
    result.removeSubrange(range)
    return result
  }

  private static func extractingSummary(from text: String) -> (summary: String, body: String) {
    guard
      let openingRange = text.range(of: "<summary>", options: [.caseInsensitive]),
      let closingRange = text.range(of: "</summary>", options: [.caseInsensitive])
    else {
      return ("Details", text)
    }

    let summary = String(text[openingRange.upperBound..<closingRange.lowerBound])
    let body = String(text[..<openingRange.lowerBound]) + String(text[closingRange.upperBound...])
    return (summary, body)
  }

  private static func table(from rawLines: [String], startIndex: Int) -> (value: TaskMarkdownTable, nextIndex: Int)? {
    guard startIndex + 1 < rawLines.count else { return nil }

    let headerLine = rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    let separatorLine = rawLines[startIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard headerLine.contains("|"), isTableSeparatorRow(separatorLine) else { return nil }

    let headers = tableCells(from: headerLine)
    let alignments = tableAlignments(from: separatorLine)
    guard !headers.isEmpty, !headers.allSatisfy(\.isEmpty), alignments.count == headers.count else { return nil }

    var rows: [[String]] = []
    var index = startIndex + 2
    while index < rawLines.count {
      let line = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, line.contains("|"), !isTableSeparatorRow(line) else { break }
      rows.append(normalizedTableRow(tableCells(from: line), columnCount: headers.count))
      index += 1
    }

    return (
      TaskMarkdownTable(headers: headers, alignments: alignments, rows: rows),
      index
    )
  }

  private static func tableCells(from line: String) -> [String] {
    var content = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.first == "|" {
      content.removeFirst()
    }
    if content.last == "|" {
      content.removeLast()
    }
    return content
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private static func tableAlignments(from line: String) -> [TaskMarkdownTableAlignment] {
    tableCells(from: line).map { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
        return .center
      }
      if trimmed.hasSuffix(":") {
        return .trailing
      }
      return .leading
    }
  }

  private static func isTableSeparatorRow(_ line: String) -> Bool {
    let cells = tableCells(from: line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
      let dashCount = trimmed.filter { $0 == "-" }.count
      let allowed = trimmed.allSatisfy { $0 == "-" || $0 == ":" }
      return allowed && dashCount >= 3
    }
  }

  private static func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
    if cells.count == columnCount {
      return cells
    }
    if cells.count > columnCount {
      return Array(cells.prefix(columnCount))
    }
    return cells + Array(repeating: "", count: columnCount - cells.count)
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

struct TaskEditorDraft: Equatable, Identifiable {
  let original: TaskEntity
  var title: String
  var description: String
  var priority: TaskPriority
  var hasDueDate: Bool
  var dueDate: Date
  var selectedProjectID: String
  var tags: [String]
  var tagInputText = ""
  var subtasks: [TaskSubtask]
  var subtaskInputText = ""
  var repeatRule: RepeatRule
  var repeatInterval: Int

  var id: String { original.id }

  /// Flattens `TaskRecurringPattern` into something a picker can bind to.
  enum RepeatRule: String, CaseIterable, Identifiable, Hashable {
    case never
    case daily
    case weekly
    case monthly
    case customDays

    var id: String { rawValue }

    var title: String {
      switch self {
      case .never:
        return "Never"
      case .daily:
        return "Daily"
      case .weekly:
        return "Weekly"
      case .monthly:
        return "Monthly"
      case .customDays:
        return "Every N days"
      }
    }

    init(_ pattern: TaskRecurringPattern?) {
      switch pattern?.type {
      case .none:
        self = .never
      case .daily:
        self = .daily
      case .weekly:
        self = .weekly
      case .monthly:
        self = .monthly
      case .custom:
        self = .customDays
      }
    }

    var recurringType: RecurringType? {
      switch self {
      case .never:
        return nil
      case .daily:
        return .daily
      case .weekly:
        return .weekly
      case .monthly:
        return .monthly
      case .customDays:
        return .custom
      }
    }
  }

  var savedRecurrence: TaskRecurringPattern? {
    guard let type = repeatRule.recurringType else { return nil }
    return TaskRecurringPattern(
      type: type,
      interval: repeatRule == .customDays ? max(repeatInterval, 1) : 1,
      endDate: original.recurring?.endDate
    )
  }

  init(task: TaskEntity) {
    original = task
    title = task.title
    description = task.description ?? ""
    priority = task.priority
    hasDueDate = task.dueDate != nil
    dueDate = task.dueDate ?? Date()
    selectedProjectID = task.projectId ?? ""
    tags = task.tags
    subtasks = task.subtasks
    repeatRule = RepeatRule(task.recurring)
    repeatInterval = task.recurring?.interval ?? 2
  }

  var isDirty: Bool {
    title != original.title
      || description != (original.description ?? "")
      || priority != original.priority
      || (hasDueDate ? dueDate : nil) != original.dueDate
      || selectedProjectID != (original.projectId ?? "")
      || tags != original.tags
      || !tagInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || subtasks != original.subtasks
      || !subtaskInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || savedRecurrence != original.recurring
  }

  var savedTags: [String] {
    tagsIncludingPendingInput(tags, input: tagInputText)
  }

  var savedSubtasks: [TaskSubtask] {
    var values = subtasks
    let pending = subtaskInputText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !pending.isEmpty {
      values.append(TaskSubtask(id: UUID().uuidString, title: pending, completed: false, order: values.count))
    }

    return values
      .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .enumerated()
      .map { offset, subtask in
        var normalized = subtask
        normalized.title = subtask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.order = offset
        return normalized
      }
  }
}

private func serenityChip(_ value: String, tint: Color = SerenityPalette.textSecondary) -> some View {
  Text(value)
    .font(SerenityType.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(SerenityPalette.innerCardBackground, in: Capsule())
    .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
}

/// The expanded task panel, shared by ActionHub's task list and Home's overview
/// so the two cannot drift apart.
private struct TaskDetailPanel: View {
  let task: TaskEntity
  let onEditTask: (TaskEntity) -> Void

  @EnvironmentObject private var appState: AppState

  @State private var subtaskDraft = ""
  @State private var descriptionExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Created \(task.createdAt.formatted(date: .numeric, time: .omitted))", systemImage: "clock")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)

      if let description = task.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        descriptionPreview(description)
      }

      if !task.tags.isEmpty {
        taskEditorButton(accessibilityLabel: "Edit task \(task.title) tags") {
          HStack(spacing: 6) {
            ForEach(task.tags.prefix(4), id: \.self) { tag in
              serenityChip(tag)
            }
            if task.tags.count > 4 {
              serenityChip("+\(task.tags.count - 4)")
            }
          }
        }
      }

      if !task.subtasks.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(task.subtasks, id: \.id) { subtask in
            Button {
              Task { await appState.toggleSubtask(taskID: task.id, subtaskID: subtask.id) }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(subtask.completed ? .green : SerenityPalette.textSecondary)
                Text(subtask.title)
                  .font(SerenityType.caption)
                  .strikethrough(subtask.completed)
                Spacer()
              }
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)
          }
        }
      }

      HStack(spacing: 8) {
        TextField("Add subtask", text: $subtaskDraft)
          .textFieldStyle(.plain)
          .serenityInputField()

        Button("Add") {
          let subtaskText = subtaskDraft
          Task { await appState.addSubtask(taskID: task.id, title: subtaskText) }
          subtaskDraft = ""
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }

      TaskActivityLogView(
        task: task,
        onAddComment: { text in
          Task { await appState.addTaskComment(taskID: task.id, text: text) }
        },
        onUpdateComment: { commentID, text in
          Task { await appState.updateTaskComment(taskID: task.id, commentID: commentID, text: text) }
        },
        onDeleteComment: { commentID in
          Task { await appState.deleteTaskComment(taskID: task.id, commentID: commentID) }
        }
      )

      HStack(spacing: 8) {
        Spacer()

        Button("Edit") {
          onEditTask(task)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Delete", role: .destructive) {
          Task { await appState.deleteTask(id: task.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private func taskEditorButton<Content: View>(
    accessibilityLabel: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      onEditTask(task)
    } label: {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
  }

  private func descriptionPreview(_ description: String) -> some View {
    let shouldCollapse = TaskMarkdownParser.shouldCollapseInTaskList(description)
    let isExpanded = descriptionExpanded

    return VStack(alignment: .leading, spacing: 6) {
      taskEditorButton(accessibilityLabel: "Edit task \(task.title) description") {
        GitHubFlavoredMarkdownView(markdown: description, compact: !isExpanded)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(maxHeight: shouldCollapse && !isExpanded ? 132 : nil, alignment: .top)
          .clipped()
          .mask(alignment: .bottom) {
            if shouldCollapse && !isExpanded {
              VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                  colors: [.black, .black.opacity(0)],
                  startPoint: .top,
                  endPoint: .bottom
                )
                .frame(height: 28)
              }
            } else {
              Rectangle()
            }
          }
      }

      if shouldCollapse {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            descriptionExpanded.toggle()
          }
        } label: {
          Label(isExpanded ? "Show less" : "Read more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
            .font(SerenityType.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SerenityPalette.accent)
        .hoverCursor(.pointingHand)
      }
    }
  }
}

/// A task's history on one rail: the comments you wrote and the events the task
/// recorded. Comments carry body weight and a solid dot, events stay at caption
/// with a hollow one — skim the solid dots and you have read the comments.
private struct TaskActivityLogView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all
    case comments

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all:
        return "All"
      case .comments:
        return "Comments"
      }
    }
  }

  private struct Entry: Identifiable {
    let id: String
    let isComment: Bool
    let text: String
    let date: Date
    let edited: Bool
  }

  let task: TaskEntity
  let onAddComment: (String) -> Void
  let onUpdateComment: (String, String) -> Void
  let onDeleteComment: (String) -> Void

  @State private var filter: Filter = .all
  @State private var draft = ""
  @State private var isComposing = false
  @State private var editingID: String?
  @State private var editDraft = ""
  @State private var confirmingID: String?
  @State private var showsEveryEntry = false
  @State private var hoveredID: String?
  @FocusState private var composerFocused: Bool

  /// Past this many entries the log folds to its first and last few. A task you
  /// have been chewing on for weeks should not push the list off the screen.
  private static let foldThreshold = 8
  private static let foldTail = 5
  private static let gutter: CGFloat = 22

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
        .overlay(SerenityPalette.thinBorder)

      header

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
          entryRow(entry)

          if index == 0, foldedCount > 0 {
            foldRow
          }
        }

        if filteredEntries.isEmpty {
          railed(dot: EmptyView()) {
            Text("No comments on this task yet.")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
          }
        }

        composerRow
      }
      .overlay(alignment: .topLeading) {
        Rectangle()
          .fill(SerenityPalette.thinBorder)
          .frame(width: 1)
      }
      .padding(.leading, 4)
    }
  }

  // MARK: entries

  private var allEntries: [Entry] {
    let created = Entry(
      id: "created-\(task.id)",
      isComment: false,
      text: "Task created",
      date: task.createdAt,
      edited: false
    )

    let logged = task.activity.map {
      Entry(
        id: $0.id,
        isComment: $0.kind == .comment,
        text: $0.text,
        date: $0.createdAt,
        edited: $0.editedAt != nil
      )
    }

    return ([created] + logged).sorted { $0.date < $1.date }
  }

  private var filteredEntries: [Entry] {
    filter == .comments ? allEntries.filter(\.isComment) : allEntries
  }

  private var commentCount: Int {
    task.activity.filter { $0.kind == .comment }.count
  }

  private var foldedCount: Int {
    guard !showsEveryEntry, filteredEntries.count > Self.foldThreshold else { return 0 }
    return filteredEntries.count - Self.foldTail - 1
  }

  private var visibleEntries: [Entry] {
    guard foldedCount > 0 else { return filteredEntries }
    return [filteredEntries[0]] + filteredEntries.suffix(Self.foldTail)
  }

  // MARK: chrome

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "clock")
      Text(headingText)
      Spacer(minLength: 8)
      filterControl
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  private var headingText: String {
    filter == .comments
      ? "Activity · \(commentCount) of \(allEntries.count)"
      : "Activity · \(allEntries.count)"
  }

  private var filterControl: some View {
    HStack(spacing: 2) {
      ForEach(Filter.allCases) { option in
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            filter = option
          }
        } label: {
          Text(option.title)
            .font(SerenityType.caption)
            .foregroundStyle(filter == option ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(filter == option ? SerenityPalette.activeItemBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
        .accessibilityLabel(option == .all ? "Show all activity" : "Show comments only")
      }
    }
    .padding(2)
    .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  // MARK: rows

  /// Every row hangs off the same rail: a fixed gutter holding the dot, then
  /// the content. The rail itself is one overlay on the stack.
  private func railed<Dot: View, Content: View>(
    dot: Dot,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ZStack(alignment: .topLeading) {
        Color.clear.frame(width: Self.gutter, height: 1)
        dot
      }
      content()
      Spacer(minLength: 0)
    }
    .padding(.vertical, 7)
  }

  private var solidDot: some View {
    Circle()
      .fill(SerenityPalette.textSecondary)
      .frame(width: 7, height: 7)
      .offset(x: -3, y: 5)
  }

  private var hollowDot: some View {
    Circle()
      .fill(SerenityPalette.panelBackground)
      .overlay(Circle().stroke(SerenityPalette.border, lineWidth: 1))
      .frame(width: 5, height: 5)
      .offset(x: -2, y: 6)
  }

  @ViewBuilder
  private func entryRow(_ entry: Entry) -> some View {
    railed(dot: entry.isComment ? AnyView(solidDot) : AnyView(hollowDot)) {
      if entry.id == editingID {
        editor(for: entry)
      } else if entry.id == confirmingID {
        deleteConfirmation(for: entry)
      } else if entry.isComment {
        comment(entry)
      } else {
        event(entry)
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      if hovering {
        hoveredID = entry.id
      } else if hoveredID == entry.id {
        hoveredID = nil
      }
    }
  }

  private func comment(_ entry: Entry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(stamp(for: entry))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer(minLength: 0)

        if showsActions(for: entry) {
          commentActions(entry)
        }
      }
      .frame(minHeight: 16)

      Text(entry.text)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func commentActions(_ entry: Entry) -> some View {
    HStack(spacing: 2) {
      Button {
        editDraft = entry.text
        editingID = entry.id
        confirmingID = nil
      } label: {
        Image(systemName: "pencil")
          .font(SerenityType.scaledSystem(size: 11, weight: .regular))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(SerenityPalette.textSecondary)
      .hoverCursor(.pointingHand)
      .accessibilityLabel("Edit comment")

      Button {
        confirmingID = entry.id
        editingID = nil
      } label: {
        Image(systemName: "trash")
          .font(SerenityType.scaledSystem(size: 11, weight: .regular))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(SerenityPalette.textSecondary)
      .hoverCursor(.pointingHand)
      .accessibilityLabel("Delete comment")
    }
  }

  private func event(_ entry: Entry) -> some View {
    HStack(spacing: 8) {
      Text(stamp(for: entry))
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary.opacity(0.7))
      Text(entry.text)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func editor(for entry: Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Comment", text: $editDraft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(2...10)
        .serenityInputField()

      HStack(spacing: 8) {
        Text(stamp(for: entry))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer(minLength: 0)

        Button("Cancel") {
          editingID = nil
          editDraft = ""
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)

        Button("Save") {
          onUpdateComment(entry.id, editDraft)
          editingID = nil
          editDraft = ""
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .hoverCursor(.pointingHand)
        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  /// Inline rather than a confirmationDialog: a sheet for one line of your own
  /// text is heavy. Deleting a project keeps its dialog — that one orphans tasks.
  private func deleteConfirmation(for entry: Entry) -> some View {
    HStack(spacing: 8) {
      Text("Delete this comment?")
        .font(SerenityType.bodyMedium)
        .foregroundStyle(SerenityPalette.textPrimary)

      Spacer(minLength: 0)

      Button("Cancel") {
        confirmingID = nil
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .hoverCursor(.pointingHand)

      Button("Delete", role: .destructive) {
        onDeleteComment(entry.id)
        confirmingID = nil
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
      .foregroundStyle(Color.red.opacity(0.9))
      .hoverCursor(.pointingHand)
    }
  }

  private var foldRow: some View {
    railed(
      dot: Circle()
        .fill(SerenityPalette.accent.opacity(0.5))
        .frame(width: 5, height: 5)
        .offset(x: -2, y: 6)
    ) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          showsEveryEntry = true
        }
      } label: {
        Label("Show \(foldedCount) earlier entries", systemImage: "chevron.down")
          .font(SerenityType.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(SerenityPalette.accent)
      .hoverCursor(.pointingHand)
    }
  }

  private var composerRow: some View {
    railed(
      dot: Circle()
        .fill(SerenityPalette.panelBackground)
        .overlay(Circle().stroke(SerenityPalette.border, lineWidth: 1))
        .overlay(
          Image(systemName: "plus")
            .font(SerenityType.scaledSystem(size: 6, weight: .bold))
            .foregroundStyle(SerenityPalette.textSecondary)
        )
        .frame(width: 11, height: 11)
        .offset(x: -5, y: 12)
    ) {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Write a comment…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(isComposing ? 3...8 : 1...4)
          .serenityInputField()
          .focused($composerFocused)

        if isComposing {
          HStack(spacing: 8) {
            Text("⌘↩ to post")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)

            Spacer(minLength: 0)

            Button("Cancel") {
              draft = ""
              composerFocused = false
              withAnimation(.easeOut(duration: 0.16)) {
                isComposing = false
              }
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)

            Button("Post", action: post)
              .buttonStyle(SerenityPrimaryButtonStyle())
              .hoverCursor(.pointingHand)
              .keyboardShortcut(.return, modifiers: .command)
              .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      .onChange(of: composerFocused) { _, focused in
        guard focused else { return }
        withAnimation(.easeOut(duration: 0.16)) {
          isComposing = true
        }
      }
    }
  }

  // MARK: actions

  private func post() {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    onAddComment(text)
    draft = ""
    composerFocused = false
    withAnimation(.easeOut(duration: 0.16)) {
      isComposing = false
    }
  }

  private func stamp(for entry: Entry) -> String {
    let elapsed = SerenityDateText.elapsed(entry.date)
    return entry.edited ? "\(elapsed) · edited" : elapsed
  }

  /// Hover reveals the per-comment controls on the Mac; touch has no hover, so
  /// they stay put there.
  private func showsActions(for entry: Entry) -> Bool {
#if os(macOS)
    return hoveredID == entry.id
#else
    return true
#endif
  }
}

private struct TaskEditorView: View {
  @Binding var draft: TaskEditorDraft
  let availableProjects: [ProjectEntity]
  let onCancel: () -> Void
  let onSave: () async -> Bool

  @State private var isSaving = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Edit Task")
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        Button(action: onCancel) {
          Image(systemName: "xmark")
            .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SerenityPalette.textSecondary)
        .hoverCursor(.pointingHand)
        .accessibilityLabel("Close task editor")
      }
      .padding(16)

      Divider()
        .overlay(SerenityPalette.thinBorder)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          editorSection("Title") {
            TextField("Title", text: $draft.title)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          editorSection("Description") {
            TaskMarkdownDescriptionField(text: $draft.description, minHeight: 150)
          }

          editorSection("Schedule") {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 10) {
                SerenityDropdownField(
                  placeholder: "Priority",
                  selection: $draft.priority,
                  options: priorityDropdownOptions
                )
                .frame(maxWidth: .infinity)

                Toggle("Due date", isOn: $draft.hasDueDate)
                  .toggleStyle(.switch)
              }

              if draft.hasDueDate {
                DueDateSelectionField(selection: $draft.dueDate)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }

          editorSection("Repeat") {
            VStack(alignment: .leading, spacing: 10) {
              SerenityDropdownField(
                placeholder: "Never",
                selection: $draft.repeatRule,
                options: repeatRuleOptions
              )
              .frame(maxWidth: .infinity)

              if draft.repeatRule == .customDays {
                Stepper(
                  "Every \(draft.repeatInterval) day\(draft.repeatInterval == 1 ? "" : "s")",
                  value: $draft.repeatInterval,
                  in: 1...365
                )
                .font(SerenityType.body)
              }

              if draft.repeatRule != .never {
                Text("Completing this task creates the next one automatically.")
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
            }
          }

          editorSection("Project") {
            SerenityDropdownField(
              placeholder: "No project",
              selection: $draft.selectedProjectID,
              options: projectDropdownOptions
            )
            .frame(maxWidth: .infinity)
          }

          editorSection("Tags") {
            SerenityTagInputField(tags: $draft.tags, inputText: $draft.tagInputText)
          }

          editorSection("Subtasks") {
            VStack(alignment: .leading, spacing: 8) {
              ForEach($draft.subtasks) { $subtask in
                HStack(spacing: 8) {
                  Button {
                    subtask.completed.toggle()
                  } label: {
                    Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                      .foregroundStyle(subtask.completed ? .green : SerenityPalette.textSecondary)
                  }
                  .buttonStyle(.plain)
                  .hoverCursor(.pointingHand)
                  .accessibilityLabel(subtask.completed ? "Mark subtask incomplete" : "Mark subtask complete")

                  TextField("Subtask", text: $subtask.title)
                    .textFieldStyle(.plain)

                  Button(role: .destructive) {
                    draft.subtasks.removeAll { $0.id == subtask.id }
                  } label: {
                    Image(systemName: "trash")
                      .foregroundStyle(Color.red.opacity(0.8))
                  }
                  .buttonStyle(.plain)
                  .hoverCursor(.pointingHand)
                  .accessibilityLabel("Delete subtask")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SerenityPalette.thinBorder, lineWidth: 1)
                )
              }

              HStack(spacing: 8) {
                TextField("Add subtask", text: $draft.subtaskInputText)
                  .textFieldStyle(.plain)
                  .serenityInputField()
                  .onSubmit(addPendingSubtask)

                Button("Add", action: addPendingSubtask)
                  .buttonStyle(SerenitySecondaryButtonStyle())
                  .disabled(draft.subtaskInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                  .hoverCursor(.pointingHand)
              }
            }
          }
        }
        .padding(16)
      }

      Divider()
        .overlay(SerenityPalette.thinBorder)

      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

        Button {
          Task {
            isSaving = true
            _ = await onSave()
            isSaving = false
          }
        } label: {
          if isSaving {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Save")
          }
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(isSaving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .hoverCursor(.pointingHand)
      }
      .padding(16)
      .background(SerenityPalette.panelBackground)
    }
    .background(SerenityPalette.panelBackground)
  }

  private func editorSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(SerenityType.caption.weight(.semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
      content()
    }
  }

  private func addPendingSubtask() {
    let title = draft.subtaskInputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    draft.subtasks.append(
      TaskSubtask(id: UUID().uuidString, title: title, completed: false, order: draft.subtasks.count)
    )
    draft.subtaskInputText = ""
  }

  private var projectDropdownOptions: [SerenityDropdownOption<String>] {
    [SerenityDropdownOption(value: "", title: "No project", systemImage: "minus.circle")] +
      availableProjects.map { project in
        SerenityDropdownOption(
          value: project.id,
          title: project.name,
          subtitle: project.description,
          tint: ProjectColorCodec.color(from: project.color) ?? SerenityPalette.accent
        )
      }
  }

  private var priorityDropdownOptions: [SerenityDropdownOption<TaskPriority>] {
    TaskPriority.allCases.map { value in
      SerenityDropdownOption(
        value: value,
        title: value.rawValue.capitalized,
        systemImage: priorityIcon(value),
        tint: priorityColor(value)
      )
    }
  }

  private var repeatRuleOptions: [SerenityDropdownOption<TaskEditorDraft.RepeatRule>] {
    TaskEditorDraft.RepeatRule.allCases.map { rule in
      SerenityDropdownOption(
        value: rule,
        title: rule.title,
        systemImage: rule == .never ? "minus.circle" : "repeat"
      )
    }
  }

  private func priorityIcon(_ value: TaskPriority) -> String {
    switch value {
    case .low:
      return "arrow.down.circle"
    case .medium:
      return "equal.circle"
    case .high:
      return "exclamationmark.circle"
    }
  }

  private func priorityColor(_ value: TaskPriority) -> Color {
    switch value {
    case .low:
      return .mint
    case .medium:
      return .orange
    case .high:
      return .red
    }
  }
}

private struct JournalEntryEditorView: View {
  let entry: JournalEntryEntity
  let onSave: (String, String, JournalMood?, [String]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var content: String
  @State private var mood: JournalMood?
  @State private var tags: [String]
  @State private var tagInputText = ""

  init(entry: JournalEntryEntity, onSave: @escaping (String, String, JournalMood?, [String]) -> Void) {
    self.entry = entry
    self.onSave = onSave
    _title = State(initialValue: entry.title ?? "")
    _content = State(initialValue: entry.content)
    _mood = State(initialValue: entry.mood)
    _tags = State(initialValue: entry.tags)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit Journal Entry")
        .font(SerenityType.bodyLarge.weight(.semibold))

      TextField("Title", text: $title)
        .textFieldStyle(.plain)
        .serenityInputField()
      TextEditor(text: $content)
        .serenityTextArea(minHeight: 150)

      Picker("Mood", selection: $mood) {
        Text("None").tag(Optional<JournalMood>.none)
        ForEach([JournalMood.happy, .neutral, .sad, .excited, .stressed], id: \.rawValue) { moodValue in
          Text(moodValue.rawValue.capitalized)
            .tag(Optional(moodValue))
        }
      }
      .frame(maxWidth: 240)

      SerenityTagInputField(tags: $tags, inputText: $tagInputText)

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .hoverCursor(.pointingHand)
        Button("Save") {
          onSave(title, content, mood, tagsIncludingPendingInput(tags, input: tagInputText))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)
      }
    }
    .padding(20)
  }
}

private struct ProjectEditorView: View {
  let project: ProjectEntity
  let onSave: (String, String, String) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var description: String
  @State private var color: Color

  init(project: ProjectEntity, onSave: @escaping (String, String, String) -> Void) {
    self.project = project
    self.onSave = onSave
    _name = State(initialValue: project.name)
    _description = State(initialValue: project.description ?? "")
    _color = State(initialValue: ProjectColorCodec.color(from: project.color) ?? ProjectColorCodec.fallbackColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit Project")
        .font(SerenityType.bodyLarge.weight(.semibold))

      TextField("Name", text: $name)
        .textFieldStyle(.plain)
        .serenityInputField()
      TextField("Description", text: $description)
        .textFieldStyle(.plain)
        .serenityInputField()
      HStack(spacing: 10) {
        ColorPicker("Project color", selection: $color, supportsOpacity: false)
        Text(ProjectColorCodec.hex(from: color))
          .font(SerenityType.scaledSystem(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .hoverCursor(.pointingHand)
        Button("Save") {
          onSave(name, description, ProjectColorCodec.hex(from: color))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)
      }
    }
    .padding(20)
  }
}

private extension Calendar {
  func startOfMonth(for date: Date) -> Date {
    let components = dateComponents([.year, .month], from: date)
    return self.date(from: components) ?? date
  }

  func orderedVeryShortStandaloneWeekdaySymbols() -> [String] {
    let symbols = veryShortStandaloneWeekdaySymbols
    let offset = max(min(firstWeekday - 1, symbols.count - 1), 0)
    return Array(symbols[offset...]) + Array(symbols[..<offset])
  }

  func monthGridDates(for month: Date) -> [Date] {
    let monthStart = startOfMonth(for: month)
    guard let dayRange = range(of: .day, in: .month, for: monthStart),
          let monthEnd = date(byAdding: .day, value: dayRange.count - 1, to: monthStart) else {
      return [startOfDay(for: monthStart)]
    }

    let leadingDays = (component(.weekday, from: monthStart) - firstWeekday + 7) % 7
    let trailingDays = (firstWeekday + 6 - component(.weekday, from: monthEnd) + 7) % 7

    guard let gridStart = date(byAdding: .day, value: -leadingDays, to: monthStart),
          let gridEnd = date(byAdding: .day, value: trailingDays, to: monthEnd) else {
      return [startOfDay(for: monthStart)]
    }

    var dates: [Date] = []
    var cursor = startOfDay(for: gridStart)
    let end = startOfDay(for: gridEnd)
    while cursor <= end {
      dates.append(cursor)
      guard let next = date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }
    return dates
  }
}

private enum ProjectColorCodec {
  static let fallbackHex = "#4A90E2"
  static let fallbackColor = Color(red: 0.29, green: 0.56, blue: 0.89)

  static func color(from hex: String) -> Color? {
    let sanitized = hex
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
      .uppercased()

    guard sanitized.count == 6 else { return nil }

    var value: UInt64 = 0
    guard Scanner(string: sanitized).scanHexInt64(&value) else { return nil }

    let red = Double((value & 0xFF0000) >> 16) / 255.0
    let green = Double((value & 0x00FF00) >> 8) / 255.0
    let blue = Double(value & 0x0000FF) / 255.0

    return Color(red: red, green: green, blue: blue)
  }

  static func hex(from color: Color) -> String {
#if os(macOS)
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
      return fallbackHex
    }

    let red = Int(round(converted.redComponent * 255))
    let green = Int(round(converted.greenComponent * 255))
    let blue = Int(round(converted.blueComponent * 255))
#else
    let converted = UIColor(color)
    var redComponent: CGFloat = 0
    var greenComponent: CGFloat = 0
    var blueComponent: CGFloat = 0
    var alphaComponent: CGFloat = 0

    guard converted.getRed(&redComponent, green: &greenComponent, blue: &blueComponent, alpha: &alphaComponent) else {
      return fallbackHex
    }

    let red = Int(round(redComponent * 255))
    let green = Int(round(greenComponent * 255))
    let blue = Int(round(blueComponent * 255))
#endif

    return String(format: "#%02X%02X%02X", red, green, blue)
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
