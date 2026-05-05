import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SerenityAppScene: View {
  @ObservedObject var appState: AppState
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all

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
        TopBarButton(symbol: "magnifyingglass", accessibilityLabel: "Search") {
          appState.openGlobalSearch()
        }
        TopBarButton(symbol: "questionmark.circle", accessibilityLabel: "Help") {
          appState.openHelpCenter()
        }
        TopBarButton(symbol: appState.themePreference.topBarSymbol, accessibilityLabel: "Theme") {
          cycleThemePreference()
        }
        Spacer()
          .frame(width: 8)
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
        .fill(SerenityPalette.accent.opacity(0.07))
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
  static let sidebarHeaderVerticalPadding: CGFloat = 4
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
        .font(.system(size: SerenityChromeMetrics.buttonIconSize, weight: .semibold))
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

private struct SerenitySidebar: View {
  @Binding var selectedSection: AppSection?
  @State private var hoveredSection: AppSection?

  private let primarySections: [AppSection] = [.home, .actionHub, .today, .journal, .goals, .insights, .aiSummaries]
  private let systemSections: [AppSection] = [.integrations, .database, .settings]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarHeader

      VStack(alignment: .leading, spacing: 0) {
        Text("NAVIGATION")
          .font(.system(size: 11, weight: .semibold))
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
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: SerenityChromeMetrics.sidebarHeaderIconSize, height: SerenityChromeMetrics.sidebarHeaderIconSize)
        Image(systemName: "square.and.pencil")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text("Serenity Notes")
          .font(SerenityType.bodyLarge.weight(.semibold))
      }
      Spacer()
    }
    .padding(.horizontal, 18)
    .padding(.vertical, SerenityChromeMetrics.sidebarHeaderVerticalPadding)
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
          .font(.system(size: 14, weight: .semibold))

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
    case .today:
      return "Focus on what matters most right now"
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
    case .aiSummaries:
      return "Generate and view AI-powered summaries of your tasks and journal entries"
    case .database:
      return "Bootstrap, integrity checks, and export tooling"
    case .settings:
      return "Security, auth, backend, and environment controls"
    }
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
    case .regular: return .system(size: 28, weight: .semibold)
    case .compact: return .system(size: 24, weight: .semibold)
    case .tight: return .system(size: 21, weight: .medium)
    }
  }

  var sectionSubtitleFont: Font {
    switch self {
    case .regular: return .system(size: 17, weight: .regular)
    case .compact: return .system(size: 15, weight: .regular)
    case .tight: return .system(size: 14, weight: .regular)
    }
  }

  var heroAvatarSize: CGFloat {
    switch self {
    case .regular: return 76
    case .compact: return 64
    case .tight: return 56
    }
  }

  var heroLetterSize: CGFloat {
    switch self {
    case .regular: return 32
    case .compact: return 28
    case .tight: return 24
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
          if section != .home && section != .today {
            sectionHeader(density: density)
          }

          switch section {
          case .home:
            HomeSectionView(density: density, availableWidth: proxy.size.width)
          case .actionHub:
            ActionHubSectionView()
          case .today:
            TodaySectionView()
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
          case .aiSummaries:
            AISummariesSectionView()
          case .database:
            DatabaseSectionView()
          case .settings:
            SettingsSectionView()
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(density.contentPadding)
        .padding(.bottom, density.contentBottomPadding)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: section)
    .onAppear {
      AppLogger.info("Rendered section: \(section.rawValue)")
      if section == .insights || section == .aiSummaries {
        Task {
          await appState.refreshAIWorkflows()
        }
      }

      if [.home, .actionHub, .today, .journal, .goals, .projects, .integrations, .database].contains(section) {
        Task {
          await appState.refreshCoreWorkflowData()
        }
      }
    }
  }

  private func sectionHeader(density: SerenityContentDensity) -> some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: density.sectionIconContainer, height: density.sectionIconContainer)
        Image(systemName: section.systemImage)
          .font(.system(size: density.sectionIconSize, weight: .semibold))
          .foregroundStyle(SerenityPalette.accent)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(section.title)
          .font(density.sectionTitleFont)
        Text(section.subtitle)
          .font(density.sectionSubtitleFont)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()
    }
    .padding(.vertical, 4)
  }
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
    textView.font = .systemFont(ofSize: fontSize, weight: .regular)
    textView.textColor = NSColor(SerenityPalette.textPrimary)
    textView.insertionPointColor = NSColor(SerenityPalette.textPrimary)
    textView.typingAttributes[.foregroundColor] = NSColor(SerenityPalette.textPrimary)

    scrollView.documentView = textView
    context.coordinator.textView = textView

    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? QuickCaptureTextView else { return }

    let contentSize = nsView.contentView.bounds.size
    let targetHeight = max(contentSize.height, textView.frame.height)
    if textView.frame.width != contentSize.width || textView.frame.height < contentSize.height {
      textView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: targetHeight)
    }
    textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

    if textView.string != text {
      textView.string = text
    }

    textView.font = .systemFont(ofSize: fontSize, weight: .regular)
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
    weak var textView: QuickCaptureTextView?

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
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

  @FocusState private var editorFocused: Bool

  var body: some View {
    TextEditor(text: $text)
      .font(.system(size: fontSize, weight: .regular))
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
  }
}
#endif

private struct HomeSectionView: View {
  let density: SerenityContentDensity
  let availableWidth: CGFloat

  @EnvironmentObject private var appState: AppState

  @State private var quickCapture = ""
  @State private var submitting = false
  @State private var quickCaptureFocused = false

  var body: some View {
    VStack(alignment: .leading, spacing: density.sectionSpacing) {
      hero
      quickCaptureCard
      featureGrid
    }
  }

  private var hero: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: density.heroAvatarSize, height: density.heroAvatarSize)
          .shadow(color: SerenityPalette.accent.opacity(0.35), radius: 22)
        Text("S")
          .font(.system(size: density.heroLetterSize, weight: .medium))
          .foregroundStyle(SerenityPalette.accent)
      }

      Text("Serenity Notes")
        .font(.system(size: density.heroTitleSize, weight: density.heroTitleWeight))
      Text("Boost your productivity and mindfulness with a powerful integrated task management and journaling experience.")
        .font(density.sectionSubtitleFont)
        .foregroundStyle(SerenityPalette.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: min(density.heroSubtitleMaxWidth, max(360, availableWidth - (density.contentPadding * 2))))
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .padding(.bottom, 4)
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
          fontSize: density.quickCaptureEditorFontSize
        )
          .padding(density.quickCaptureEditorPadding)
          .frame(height: density.quickCaptureEditorHeight)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Text("Write naturally. Prefix with `journal:` to create an entry; otherwise we create a task.")
            .font(SerenityType.bodyLarge)
            .foregroundStyle(SerenityPalette.textSecondary)

          Spacer()

          providerBadge
          submitButton
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Write naturally. Prefix with `journal:` to create an entry; otherwise we create a task.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)

          HStack {
            Spacer()
            providerBadge
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
    .animation(.easeInOut(duration: 0.18), value: quickCaptureFocused)
  }

  private var featureGrid: some View {
    LazyVGrid(columns: density.featureColumns, spacing: density.featureGridSpacing) {
      featureCard(title: "ActionHub", subtitle: "Efficiently manage tasks, projects, and priorities with a customizable workflow.", icon: "checklist", section: .actionHub)
      featureCard(title: "Journal", subtitle: "Capture thoughts, ideas, and reflections with a private, secure journaling system.", icon: "book", section: .journal)
      featureCard(title: "Projects", subtitle: "Organize related tasks into projects with visual progress tracking.", icon: "folder", section: .projects)
      featureCard(title: "AI Summaries", subtitle: "Generate AI-powered summaries of your tasks and journal entries by date range.", icon: "sparkles", section: .aiSummaries)
      featureCard(title: "Insights Hub", subtitle: "AI-powered insights, analytics, and personalized recommendations.", icon: "chart.bar.xaxis", section: .insights)
    }
  }

  private var providerBadge: some View {
    Text("Provider: native")
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(SerenityPalette.innerCardBackground, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
  }

  private var submitButton: some View {
    Button(submitting ? "Submitting..." : "Submit") {
      Task {
        await submitQuickCapture()
      }
    }
    .disabled(submitting || quickCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .buttonStyle(SerenityPrimaryButtonStyle())
    .hoverCursor(.pointingHand)
  }

  private func featureCard(title: String, subtitle: String, icon: String, section: AppSection) -> some View {
    Button {
      appState.setSection(section)
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(SerenityPalette.headerIconBackground)
            .frame(width: density.featureIconContainer, height: density.featureIconContainer)
          Image(systemName: icon)
            .font(.system(size: density.featureIconSize, weight: .semibold))
            .foregroundStyle(SerenityPalette.accent)
        }
        Text(title)
          .font(SerenityType.cardTitle)
          .multilineTextAlignment(.leading)
        Text(subtitle)
          .font(SerenityType.pageSubtitle)
          .foregroundStyle(SerenityPalette.textSecondary)
          .multilineTextAlignment(.leading)
      }
      .padding(density.featureCardPadding)
      .frame(maxWidth: .infinity, minHeight: density.featureCardMinHeight, alignment: .topLeading)
      .background(
        LinearGradient(
          colors: [
            SerenityPalette.panelBackgroundRaised,
            SerenityPalette.innerCardBackground,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .hoverCursor(.pointingHand)
  }

  private func submitQuickCapture() async {
    let text = quickCapture.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    submitting = true
    defer { submitting = false }

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
      await appState.createTask(
        title: text,
        priority: .medium,
        dueDate: nil,
        tags: [],
        subtaskTitles: []
      )
    }

    quickCapture = ""
    await appState.refreshCoreWorkflowData()
  }
}

struct IntegrationsSectionView: View {
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
      cloudSyncHardeningCard
    }
  }

  private var syncStatusCard: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SerenityPalette.headerIconBackground)
          .frame(width: 40, height: 40)
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 17, weight: .semibold))
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
        .font(.system(size: 15, weight: .semibold))
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

  private var cloudSyncHardeningCard: some View {
    GroupBox("Cloud Sync Hardening") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Conflict policy", selection: Binding(
          get: { appState.cloudSyncPolicy },
          set: { policy in
            appState.cloudSyncPolicy = policy
            Task {
              await appState.refreshCloudSyncDiagnostics()
            }
          }
        )) {
          ForEach([CloudSyncResolutionPolicy.deferConflicts, .preferNewest, .preferLocal, .preferRemote], id: \.rawValue) { policy in
            Text(policy.rawValue).tag(policy)
          }
        }
        .frame(maxWidth: 240)

        HStack {
          Button("Run Full Entity Sync") {
            Task {
              await appState.runCloudSync()
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)

          switch appState.cloudSyncState {
          case .idle:
            EmptyView()
          case .syncing:
            Label("Syncing...", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption)
          case .succeeded(let message):
            Text(message)
              .font(.caption)
              .foregroundStyle(.green)
          case .failed(let message):
            Text(message)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }

        if appState.cloudSyncConflicts.isEmpty {
          Text("No unresolved conflicts.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(appState.cloudSyncConflicts) { conflict in
            VStack(alignment: .leading, spacing: 6) {
              Text("\(conflict.entityType.rawValue.capitalized): \(conflict.summary)")
                .font(.subheadline)
              Text("Local: \(conflict.localUpdatedAt.formatted()) | Remote: \(conflict.remoteUpdatedAt.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)

              HStack {
                Button("Use Local") {
                  Task {
                    await appState.resolveCloudSyncConflict(conflict, policy: .preferLocal)
                  }
                }
                .buttonStyle(.bordered)
                .hoverCursor(.pointingHand)

                Button("Use Remote") {
                  Task {
                    await appState.resolveCloudSyncConflict(conflict, policy: .preferRemote)
                  }
                }
                .buttonStyle(.bordered)
                .hoverCursor(.pointingHand)
              }
            }
            .padding(8)
            .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8))
          }
        }

        ForEach(appState.cloudSyncDiagnostics, id: \.self) { line in
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 8)
    }
  }
}


private struct ActionHubSectionView: View {
  @EnvironmentObject private var appState: AppState

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
    case all
    case active
    case completed

    var id: String { rawValue }
  }

  @State private var activeTab: HubTab = .tasks
  @State private var taskFilter: TaskListFilter = .all
  @State private var searchQuery = ""
  @State private var showQuickAddForm = false

  @State private var newTaskTitle = ""
  @State private var newTaskDescription = ""
  @State private var newTaskTags = ""
  @State private var newTaskProjectID = ""
  @State private var newTaskPriority: TaskPriority = .medium
  @State private var includeDueDate = false
  @State private var dueDate = Date()
  @State private var calendarVisibleMonth = Calendar.current.startOfMonth(for: Date())
  @State private var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
  @State private var subtaskDraftByTaskID: [String: String] = [:]
  @State private var editingTask: TaskEntity?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      tabSelector

      switch activeTab {
      case .tasks:
        tasksView
      case .projects:
        projectsView
      case .calendar:
        calendarView
      }
    }
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
    VStack(alignment: .leading, spacing: 16) {
      if showQuickAddForm {
        VStack(spacing: 14) {
          progressPanel
          quickAddPanel
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) {
            progressPanel
            quickAddPanel
          }
          VStack(spacing: 14) {
            progressPanel
            quickAddPanel
          }
        }
      }

      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(SerenityPalette.textSecondary)
          TextField("Search tasks, projects, or tags...", text: $searchQuery)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .regular))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SerenityPalette.panelBackgroundRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(SerenityPalette.thinBorder, lineWidth: 1)
        )

        Spacer(minLength: 8)

        ForEach(TaskListFilter.allCases) { filter in
          Button(filter.rawValue.capitalized) {
            taskFilter = filter
          }
          .buttonStyle(SerenityPillButtonStyle(selected: taskFilter == filter))
          .hoverCursor(.pointingHand)
        }
      }

      HStack(spacing: 8) {
        Button("Complete Selected") {
          Task { await appState.markSelectedTasksCompleted() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        .disabled(appState.selectedTaskIDs.isEmpty)

        Button("Delete Selected", role: .destructive) {
          Task { await appState.deleteSelectedTasks() }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        .disabled(appState.selectedTaskIDs.isEmpty)
      }

      if displayedTasks.isEmpty {
        Text("No tasks match your current filters.")
          .foregroundStyle(SerenityPalette.textSecondary)
          .padding(.top, 4)
      } else {
        ForEach(displayedTasks) { task in
          taskRow(task)
        }
      }
    }
    .sheet(item: $editingTask) { task in
      TaskEditorView(task: task, availableProjects: assignableProjects) {
        title,
        description,
        priority,
        dueDate,
        projectID,
        tags in
        Task {
          await appState.updateTask(
            id: task.id,
            title: title,
            description: description,
            priority: priority,
            dueDate: dueDate,
            projectID: projectID,
            tags: tags
          )
        }
      }
      .frame(minWidth: 500, minHeight: 430)
    }
  }

  private var progressPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Overall Progress")
          .font(SerenityType.sectionTitle)
        Spacer()
      }

      HStack(spacing: 18) {
        progressRing

        VStack(alignment: .leading, spacing: 8) {
          statLine("Completed", "\(completedCount)", tint: .green)
          statLine("Remaining", "\(max(totalTaskCount - completedCount, 0))", tint: .orange)
          statLine("Total Tasks", "\(totalTaskCount)", tint: SerenityPalette.accent)
        }
      }

      Divider()
        .overlay(SerenityPalette.thinBorder)

      Text("\(max(totalTaskCount - completedCount, 0)) tasks left to complete")
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var quickAddPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showQuickAddForm {
        TextField("Task title", text: $newTaskTitle)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Description (optional)", text: $newTaskDescription, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(2...4)
          .serenityInputField()

        TextField("Tags (comma-separated)", text: $newTaskTags)
          .textFieldStyle(.plain)
          .serenityInputField()

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Project")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            Picker("Project", selection: $newTaskProjectID) {
              Text("No project").tag("")
              ForEach(assignableProjects) { project in
                Text(project.name).tag(project.id)
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Priority")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            Picker("Priority", selection: $newTaskPriority) {
              ForEach(TaskPriority.allCases, id: \.rawValue) { priority in
                Text(priority.rawValue.capitalized)
                  .tag(priority)
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity)

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
            let tags = csvValues(from: newTaskTags)
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
              newTaskTags = ""
              newTaskProjectID = ""
              searchQuery = ""
              taskFilter = .all
              includeDueDate = false
              showQuickAddForm = false
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)
          .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("Cancel") {
            showQuickAddForm = false
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      } else {
        Button {
          showQuickAddForm = true
        } label: {
          VStack(spacing: 8) {
            Image(systemName: "plus")
              .font(.system(size: 28, weight: .light))
              .foregroundStyle(SerenityPalette.textSecondary)
            Text("Add new task...")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(SerenityPalette.textSecondary)
          }
          .frame(maxWidth: .infinity, minHeight: 178)
          .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(SerenityPalette.thinBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
          )
          .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func taskRow(_ task: TaskEntity) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button {
          appState.toggleTaskSelection(id: task.id)
        } label: {
          Image(systemName: appState.selectedTaskIDs.contains(task.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(appState.selectedTaskIDs.contains(task.id) ? SerenityPalette.accent : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
          .hoverCursor(.pointingHand)

        Button {
          Task { await appState.toggleTaskCompletion(id: task.id) }
        } label: {
          Image(systemName: task.completed ? "checkmark.square.fill" : "square")
            .foregroundStyle(task.completed ? .green : SerenityPalette.textSecondary)
        }
        .buttonStyle(.plain)
          .hoverCursor(.pointingHand)

        Text(task.title)
          .font(.system(size: 20, weight: .medium))
          .strikethrough(task.completed)
          .lineLimit(2)

        Spacer()

        Text(task.priority.rawValue.capitalized)
          .font(SerenityType.caption)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(priorityColor(task.priority).opacity(0.18), in: Capsule())
      }

      HStack(spacing: 8) {
        chip("Created \(task.createdAt.formatted(date: .numeric, time: .omitted))")
        if let dueDate = task.dueDate {
          chip("Due \(dueDate.formatted(date: .numeric, time: .omitted))", tint: isOverdue(task) ? .red : SerenityPalette.accent)
        }
        if let projectName = projectName(for: task.projectId) {
          chip(projectName, tint: SerenityPalette.accent)
        }
      }

      if let description = task.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(description)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(3)
      }

      if !task.tags.isEmpty {
        HStack(spacing: 6) {
          ForEach(task.tags.prefix(4), id: \.self) { tag in
            chip(tag)
          }
          if task.tags.count > 4 {
            chip("+\(task.tags.count - 4)")
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
                  .font(.caption)
                  .strikethrough(subtask.completed)
                Spacer()
              }
            }
            .buttonStyle(.plain)
          .hoverCursor(.pointingHand)
          }
        }
      }

      HStack {
        TextField("Add subtask", text: subtaskBinding(for: task.id))
          .textFieldStyle(.plain)
          .serenityInputField()

        Button("Add") {
          let subtaskText = subtaskBinding(for: task.id).wrappedValue
          Task { await appState.addSubtask(taskID: task.id, title: subtaskText) }
          subtaskBinding(for: task.id).wrappedValue = ""
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

        Spacer()

        Button("Edit") {
          editingTask = task
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
    .padding(14)
    .background(isOverdue(task) ? Color.red.opacity(0.14) : SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(isOverdue(task) ? Color.red.opacity(0.75) : SerenityPalette.border, lineWidth: 1)
    )
  }

  private var projectsView: some View {
    GroupBox("Projects") {
      VStack(alignment: .leading, spacing: 10) {
        if appState.projects.isEmpty {
          Text("No projects yet. Create one from ActionHub task assignments.")
            .foregroundStyle(SerenityPalette.textSecondary)
        } else {
          ForEach(appState.projects) { project in
            HStack {
              Text(project.name)
                .font(.title3)
              Spacer()
              Text(project.archived ? "Archived" : "Active")
                .font(.caption)
                .foregroundStyle(project.archived ? SerenityPalette.textSecondary : .green)
            }
            .padding(.vertical, 4)
          }
        }
      }
      .padding(.top, 4)
    }
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

        chip("Today \(appState.todayTasks.count)", tint: SerenityPalette.accent)
        chip("Overdue \(appState.overdueTasks.count)", tint: appState.overdueTasks.isEmpty ? SerenityPalette.textSecondary : .red)

        HStack(spacing: 6) {
          Button {
            shiftCalendarMonth(by: -1)
          } label: {
            Image(systemName: "chevron.left")
              .font(.system(size: 11, weight: .semibold))
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
              .font(.system(size: 11, weight: .semibold))
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

  private var totalTaskCount: Int {
    appState.tasks.count
  }

  private var completedCount: Int {
    appState.tasks.filter(\.completed).count
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
        chip("\(selectedDayTasks.count) due", tint: SerenityPalette.accent)
      }

      HStack(spacing: 8) {
        chip("\(selectedDayTasks.filter { !$0.completed }.count) open", tint: .orange)
        chip("\(selectedDayTasks.filter(\.completed).count) done", tint: .green)
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

  private var progressRing: some View {
    let percent = totalTaskCount == 0 ? 0 : Int((Double(completedCount) / Double(totalTaskCount)) * 100)
    let progress = totalTaskCount == 0 ? 0 : Double(completedCount) / Double(totalTaskCount)

    return ZStack {
      Circle()
        .stroke(SerenityPalette.thinBorder, lineWidth: 11)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(SerenityPalette.accent, style: StrokeStyle(lineWidth: 11, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Text("\(percent)%")
        .font(.title2.bold())
    }
    .frame(width: 108, height: 108)
  }

  private func statLine(_ label: String, _ value: String, tint: Color) -> some View {
    HStack {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
      Text(label)
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer()
      Text(value)
        .foregroundStyle(tint)
        .font(.title3.weight(.semibold))
    }
  }

  private func chip(_ value: String, tint: Color = SerenityPalette.textSecondary) -> some View {
    Text(value)
      .font(SerenityType.caption)
      .foregroundStyle(tint)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(SerenityPalette.innerCardBackground, in: Capsule())
      .overlay(Capsule().stroke(SerenityPalette.thinBorder, lineWidth: 1))
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

  private func subtaskBinding(for taskID: String) -> Binding<String> {
    Binding(
      get: { subtaskDraftByTaskID[taskID, default: ""] },
      set: { subtaskDraftByTaskID[taskID] = $0 }
    )
  }

  private var assignableProjects: [ProjectEntity] {
    appState.projects.filter { !$0.archived }
  }

  private func projectName(for projectID: String?) -> String? {
    guard let projectID else { return nil }
    return appState.projects.first(where: { $0.id == projectID })?.name
  }

  private func csvValues(from value: String) -> [String] {
    value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct TodaySectionView: View {
  @EnvironmentObject private var appState: AppState

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 16) {
          progressCard
          focusCard
        }
        VStack(spacing: 16) {
          progressCard
          focusCard
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        Text("Today's Tasks")
          .font(SerenityType.sectionTitle)

        tasksPanel
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "calendar")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(SerenityPalette.accent)

      VStack(alignment: .leading, spacing: 2) {
        Text("Today")
          .font(SerenityType.pageTitle)
        Text("Focus on what matters most right now")
          .font(SerenityType.pageSubtitle)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(Self.dateFormatter.string(from: Date()))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary.opacity(0.8))
      }

      Spacer()
    }
  }

  private var progressCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Today's Progress")
        .font(SerenityType.sectionTitle)

      Text("\(Int(completionPercent * 100))%")
        .font(.system(size: 38, weight: .semibold))

      ProgressView(value: completionPercent)
        .progressViewStyle(.linear)
        .tint(SerenityPalette.accent)

      Text("\(completedTodayCount) of \(totalTodayCount) tasks completed")
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private var focusCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Today's Focus")
        .font(SerenityType.sectionTitle)

      focusRow(dotColor: SerenityPalette.textSecondary.opacity(0.6), label: "Planned for today", value: totalTodayCount)
      focusRow(dotColor: .green, label: "Completed today", value: completedTodayCount)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  private func focusRow(dotColor: Color, label: String, value: Int) -> some View {
    HStack {
      Circle()
        .fill(dotColor)
        .frame(width: 8, height: 8)
      Text(label)
        .font(SerenityType.body)
      Spacer()
      Text("\(value)")
        .font(SerenityType.bodyLarge.weight(.semibold))
    }
  }

  @ViewBuilder
  private var tasksPanel: some View {
    if appState.todayTasks.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "calendar")
          .font(.system(size: 32, weight: .regular))
          .foregroundStyle(SerenityPalette.textSecondary.opacity(0.7))
        Text("No tasks scheduled for today")
          .font(SerenityType.bodyLarge.weight(.medium))
        Text("You're clear for today. Add a task to plan something.")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
        Button("Add a Task") {
          appState.setSection(.actionHub)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
        .hoverCursor(.pointingHand)
        .padding(.top, 4)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 40)
      .padding(.horizontal, 20)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(appState.todayTasks) { task in
          HStack {
            Button {
              Task { await appState.toggleTaskCompletion(id: task.id) }
            } label: {
              Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(task.completed ? Color.green : SerenityPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)

            Text(task.title)
              .strikethrough(task.completed, color: SerenityPalette.textSecondary)
              .foregroundStyle(task.completed ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)

            Spacer()

            if let dueDate = task.dueDate {
              Text(dueDate, style: .time)
                .font(.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
      .padding(16)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    }
  }

  private var totalTodayCount: Int {
    appState.todayTasks.count
  }

  private var completedTodayCount: Int {
    appState.todayTasks.filter { $0.completed }.count
  }

  private var completionPercent: Double {
    guard totalTodayCount > 0 else { return 0 }
    return Double(completedTodayCount) / Double(totalTodayCount)
  }
}

private struct JournalSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newEntryTitle = ""
  @State private var newEntryContent = ""
  @State private var newEntryMood: JournalMood?
  @State private var newEntryTags = ""

  @State private var editingEntry: JournalEntryEntity?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("New Journal Entry") {
        VStack(alignment: .leading, spacing: 10) {
          TextField("Title (optional)", text: $newEntryTitle)
            .textFieldStyle(.plain)
            .serenityInputField()
          TextEditor(text: $newEntryContent)
            .serenityTextArea(minHeight: 120)

          HStack {
            Picker("Mood", selection: $newEntryMood) {
              Text("None").tag(Optional<JournalMood>.none)
              ForEach(journalMoods, id: \.rawValue) { mood in
                Text(mood.rawValue.capitalized)
                  .tag(Optional(mood))
              }
            }
            .frame(maxWidth: 220)

            TextField("Tags (comma-separated)", text: $newEntryTags)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          HStack {
            Button("Create Entry") {
              let tags = csvValues(from: newEntryTags)
              Task {
                await appState.createJournalEntry(
                  title: newEntryTitle,
                  content: newEntryContent,
                  mood: newEntryMood,
                  tags: tags
                )
              }

              newEntryTitle = ""
              newEntryContent = ""
              newEntryMood = nil
              newEntryTags = ""
            }
            .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)

            Button("Refresh") {
              Task {
                await appState.refreshCoreWorkflowData()
              }
            }
            .hoverCursor(.pointingHand)
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Filters") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Filter by date range", isOn: $appState.journalDateRangeEnabled)
            .onChange(of: appState.journalDateRangeEnabled) { _, _ in
              Task {
                await appState.refreshCoreWorkflowData()
              }
            }

          if appState.journalDateRangeEnabled {
            HStack {
              DatePicker("From", selection: $appState.journalRangeStartDate, displayedComponents: .date)
              DatePicker("To", selection: $appState.journalRangeEndDate, displayedComponents: .date)
              Button("Apply") {
                Task {
                  await appState.refreshCoreWorkflowData()
                }
              }
              .hoverCursor(.pointingHand)
            }
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Entries") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.filteredJournalEntries.isEmpty {
            Text("No journal entries available")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.filteredJournalEntries) { entry in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(entry.title ?? "Untitled entry")
                    .font(.headline)
                  if entry.pinned {
                    Image(systemName: "pin.fill")
                      .foregroundStyle(.orange)
                  }
                  Spacer()
                  Text(entry.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(entry.content)
                  .lineLimit(3)
                  .font(.subheadline)

                HStack(spacing: 8) {
                  if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: ", "))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }

                  Spacer()

                  Button(entry.pinned ? "Unpin" : "Pin") {
                    Task {
                      await appState.toggleJournalPin(id: entry.id)
                    }
                  }
                  .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)

                  Button("Edit") {
                    editingEntry = entry
                  }
                  .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)

                  Button("Delete", role: .destructive) {
                    Task {
                      await appState.deleteJournalEntry(id: entry.id)
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
      .frame(minWidth: 460, minHeight: 380)
    }
  }

  private var journalMoods: [JournalMood] {
    [.happy, .neutral, .sad, .excited, .stressed]
  }

  private func csvValues(from value: String) -> [String] {
    value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct GoalsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newGoalTitle = ""
  @State private var newGoalTarget = "5"
  @State private var newGoalType: GoalType = .weeklyTasks
  @State private var newGoalPriority: GoalPriority = .medium

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("New Goal") {
        VStack(alignment: .leading, spacing: 10) {
          TextField("Goal title", text: $newGoalTitle)
            .textFieldStyle(.plain)
            .serenityInputField()

          HStack {
            TextField("Target", text: $newGoalTarget)
              .textFieldStyle(.plain)
              .serenityInputField()
              .frame(maxWidth: 140)

            Picker("Type", selection: $newGoalType) {
              ForEach(goalTypes, id: \.rawValue) { type in
                Text(type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                  .tag(type)
              }
            }
            .frame(maxWidth: 220)

            Picker("Priority", selection: $newGoalPriority) {
              ForEach(goalPriorities, id: \.rawValue) { priority in
                Text(priority.rawValue.capitalized)
                  .tag(priority)
              }
            }
            .frame(maxWidth: 180)
          }

          HStack {
            Button("Create Goal") {
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
            }
            .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)

            Button("Refresh") {
              Task {
                await appState.refreshCoreWorkflowData()
              }
            }
            .hoverCursor(.pointingHand)
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Goals") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.goals.isEmpty {
            Text("No goals found")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.goals) { goal in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title)
                      .font(.headline)

                    Text("\(goal.progress.current, specifier: "%.0f") / \(goal.progress.target, specifier: "%.0f") (\(goal.progress.percentage, specifier: "%.0f")%)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }

                  Spacer()

                  Text(goal.status.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(goal.status == .completed ? Color.green.opacity(0.2) : Color.blue.opacity(0.2), in: Capsule())
                }

                ProgressView(value: goal.progress.percentage, total: 100)

                HStack {
                  Button("Increment") {
                    Task {
                      await appState.incrementGoalProgress(id: goal.id)
                    }
                  }
                  .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)

                  Spacer()

                  Button("Delete", role: .destructive) {
                    Task {
                      await appState.deleteGoal(id: goal.id)
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
              .font(.caption.monospaced())
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
                      .font(.headline)
                    Text(project.description ?? "No description")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                      Circle()
                        .fill(ProjectColorCodec.color(from: project.color) ?? Color.secondary)
                        .frame(width: 10, height: 10)
                      Text("Color: \(project.color)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }

                  Spacer()

                  if project.archived {
                    Text("Archived")
                      .font(.caption)
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
      .frame(minWidth: 420, minHeight: 260)
    }
  }
}

struct InsightsSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newCredentialProvider: AICredentialProvider = .openai
  @State private var newCredentialName = ""
  @State private var newCredentialAPIKey = ""
  @State private var newCredentialModel = ""
  @State private var insightNoteDrafts: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("AI Status and Settings") {
        VStack(alignment: .leading, spacing: 10) {
          Text(appState.aiStatusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack {
            Picker("Active Provider", selection: Binding(
              get: { appState.aiSettings.activeProvider?.rawValue ?? "none" },
              set: { value in
                Task {
                  await appState.setAIActiveProvider(AICredentialProvider(rawValue: value))
                }
              }
            )) {
              Text("Auto").tag("none")
              ForEach([AICredentialProvider.openai, .gemini, .anthropic], id: \.rawValue) { provider in
                Text(provider.rawValue.capitalized).tag(provider.rawValue)
              }
            }
            .frame(maxWidth: 230)

            Toggle("Auto analyze", isOn: Binding(
              get: { appState.aiSettings.autoAnalyze },
              set: { enabled in
                Task {
                  await appState.setAIAutoAnalyze(enabled)
                }
              }
            ))
            .toggleStyle(.switch)
            .frame(maxWidth: 180)

            Picker("Frequency", selection: Binding(
              get: { appState.aiSettings.analysisFrequency },
              set: { frequency in
                Task {
                  await appState.setAIAnalysisFrequency(frequency)
                }
              }
            )) {
              ForEach([AIAnalysisFrequency.daily, .weekly, .manual], id: \.rawValue) { frequency in
                Text(frequency.rawValue.capitalized).tag(frequency)
              }
            }
            .frame(maxWidth: 180)
          }

          HStack {
            Toggle("Use tasks", isOn: Binding(
              get: { appState.aiSettings.dataTypes.includeTasks },
              set: { enabled in
                Task {
                  await appState.setAIDataTypes(
                    includeTasks: enabled,
                    includeJournal: appState.aiSettings.dataTypes.includeJournal,
                    includeProjects: appState.aiSettings.dataTypes.includeProjects
                  )
                }
              }
            ))
            .toggleStyle(.switch)

            Toggle("Use journal", isOn: Binding(
              get: { appState.aiSettings.dataTypes.includeJournal },
              set: { enabled in
                Task {
                  await appState.setAIDataTypes(
                    includeTasks: appState.aiSettings.dataTypes.includeTasks,
                    includeJournal: enabled,
                    includeProjects: appState.aiSettings.dataTypes.includeProjects
                  )
                }
              }
            ))
            .toggleStyle(.switch)

            Toggle("Use projects", isOn: Binding(
              get: { appState.aiSettings.dataTypes.includeProjects },
              set: { enabled in
                Task {
                  await appState.setAIDataTypes(
                    includeTasks: appState.aiSettings.dataTypes.includeTasks,
                    includeJournal: appState.aiSettings.dataTypes.includeJournal,
                    includeProjects: enabled
                  )
                }
              }
            ))
            .toggleStyle(.switch)
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Credentials and Models") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Picker("Provider", selection: $newCredentialProvider) {
              ForEach([AICredentialProvider.openai, .gemini, .anthropic], id: \.rawValue) { provider in
                Text(provider.rawValue.capitalized).tag(provider)
              }
            }
            .frame(maxWidth: 200)

            TextField("Credential name", text: $newCredentialName)
              .textFieldStyle(.plain)
              .serenityInputField()
              .frame(maxWidth: 220)
          }

          SecureField("API key", text: $newCredentialAPIKey)
            .textFieldStyle(.plain)
            .serenityInputField()

          Picker("Model preference", selection: $newCredentialModel) {
            Text("Default").tag("")
            ForEach(appState.aiModelCatalog[newCredentialProvider] ?? [], id: \.self) { model in
              Text(model).tag(model)
            }
          }
          .frame(maxWidth: 280)

          Button("Add Credential") {
            Task {
              await appState.addAICredential(
                provider: newCredentialProvider,
                name: newCredentialName,
                apiKey: newCredentialAPIKey,
                modelPreference: newCredentialModel.isEmpty ? nil : newCredentialModel
              )
              newCredentialName = ""
              newCredentialAPIKey = ""
              newCredentialModel = ""
            }
          }
          .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)

          if appState.aiCredentials.isEmpty {
            Text("No credentials configured.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.aiCredentials) { credential in
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(credential.name)
                    Text("\(credential.provider.rawValue.capitalized) • priority \(credential.priority)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Toggle("Enabled", isOn: Binding(
                    get: { credential.enabled },
                    set: { enabled in
                      Task {
                        await appState.updateAICredentialEnabled(id: credential.id, enabled: enabled)
                      }
                    }
                  ))
                  .toggleStyle(.switch)
                  .labelsHidden()

                  Button("Delete", role: .destructive) {
                    Task {
                      await appState.deleteAICredential(id: credential.id)
                    }
                  }
                  .buttonStyle(.borderless)
          .hoverCursor(.pointingHand)
                }

                Picker("Model", selection: Binding(
                  get: { credential.modelPreference ?? "" },
                  set: { model in
                    Task {
                      await appState.updateAICredentialModel(id: credential.id, modelPreference: model.isEmpty ? nil : model)
                    }
                  }
                )) {
                  Text("Default").tag("")
                  ForEach(appState.aiModelCatalog[credential.provider] ?? [], id: \.self) { model in
                    Text(model).tag(model)
                  }
                }
                .frame(maxWidth: 260)
              }
              .padding(8)
              .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .padding(.top, 8)
      }

      GroupBox("AI Actions") {
        VStack(alignment: .leading, spacing: 10) {
          if !appState.aiCredentials.contains(where: { $0.enabled }) {
            Text("No-key mode: add and enable at least one provider credential to run AI actions.")
              .font(.caption)
              .foregroundStyle(.orange)
          }

          HStack {
            Button("Generate Insights") {
              Task {
                await appState.runAIAnalysis()
              }
            }
            .buttonStyle(.borderedProminent)
          .hoverCursor(.pointingHand)

            Button("Weekly Recap") {
              Task {
                await appState.generateAIRecap(type: .weekly)
              }
            }
            .hoverCursor(.pointingHand)

            Button("Monthly Recap") {
              Task {
                await appState.generateAIRecap(type: .monthly)
              }
            }
            .hoverCursor(.pointingHand)
          }

          HStack {
            Button("Task Summary") {
              Task {
                await appState.generateAISummary(type: .tasks)
              }
            }
            .hoverCursor(.pointingHand)

            Button("Journal Summary") {
              Task {
                await appState.generateAISummary(type: .journal)
              }
            }
            .hoverCursor(.pointingHand)

            Button("Combined Summary") {
              Task {
                await appState.generateAISummary(type: .combined)
              }
            }
            .hoverCursor(.pointingHand)

            Button("Refresh") {
              Task {
                await appState.refreshAIWorkflows()
              }
            }
            .hoverCursor(.pointingHand)
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Insights") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.aiInsights.isEmpty {
            Text("No insights generated yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.aiInsights.prefix(12)) { insight in
              VStack(alignment: .leading, spacing: 8) {
                Text(insight.title)
                  .font(.headline)
                Text(insight.description)
                  .font(.subheadline)
                Text("Confidence: \(Int(insight.confidence * 100))%")
                  .font(.caption)
                  .foregroundStyle(.secondary)

                TextField("Notes", text: Binding(
                  get: { insightNoteDrafts[insight.id] ?? insight.userNotes ?? "" },
                  set: { insightNoteDrafts[insight.id] = $0 }
                ))
                .textFieldStyle(.plain)
                .serenityInputField()

                HStack {
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
                  .hoverCursor(.pointingHand)

                  Spacer()

                  ForEach(1...5, id: \.self) { rating in
                    Button("\(rating)") {
                      Task {
                        await appState.updateAIInsightFeedback(
                          id: insight.id,
                          userRating: rating,
                          dismissed: nil,
                          markedHelpful: nil,
                          userNotes: insightNoteDrafts[insight.id]
                        )
                      }
                    }
                    .buttonStyle(.bordered)
          .hoverCursor(.pointingHand)
                  }
                }
              }
              .padding(8)
              .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Recaps") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.aiRecaps.isEmpty {
            Text("No recaps generated yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.aiRecaps.prefix(8)) { recap in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(recap.title)
                    .font(.headline)
                  Spacer()
                  Text(recap.type.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(recap.summary)
                  .font(.subheadline)
                HStack {
                  Button("Mark viewed") {
                    Task {
                      await appState.markRecapViewed(id: recap.id)
                    }
                  }
                  .hoverCursor(.pointingHand)
                  Button(recap.favorited ? "Unfavorite" : "Favorite") {
                    Task {
                      await appState.toggleRecapFavorite(id: recap.id)
                    }
                  }
                  .hoverCursor(.pointingHand)
                }
              }
              .padding(8)
              .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .padding(.top, 8)
      }

      GroupBox("Summaries and Usage") {
        VStack(alignment: .leading, spacing: 10) {
          if appState.aiSummaries.isEmpty {
            Text("No summaries generated yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.aiSummaries.prefix(10)) { summary in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(summary.title)
                  Spacer()
                  Text("\(summary.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(summary.content)
                  .lineLimit(3)
                  .font(.caption)
                HStack {
                  Button("Export") {
                    Task {
                      await appState.exportAISummary(id: summary.id)
                    }
                  }
                  .hoverCursor(.pointingHand)
                  Button("Delete", role: .destructive) {
                    Task {
                      await appState.deleteAISummary(id: summary.id)
                    }
                  }
                  .hoverCursor(.pointingHand)
                }
              }
              .padding(8)
              .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
          }

          if let path = appState.lastSummaryExportPath {
            Text("Last exported summary: \(path)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }

          Divider()
          Text("Recent Usage")
            .font(.subheadline)
          if appState.aiUsageEntries.isEmpty {
            Text("No usage records yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(appState.aiUsageEntries.prefix(8)) { usage in
              HStack {
                Text("\(usage.provider.rawValue.capitalized) • \(usage.operation.rawValue)")
                Spacer()
                Text("\(usage.totalTokens) tokens")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .font(.caption)
            }
          }
        }
        .padding(.top, 8)
      }
    }
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
  @State private var includeTasks = true
  @State private var includeJournal = true
  @State private var filter: SummaryFilter = .all

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      generateCard

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Your Summaries")
            .font(SerenityType.sectionTitle)
          Spacer()
          filterPills
        }

        summariesList
      }
    }
  }

  private var generateCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Generate New Summary")
        .font(SerenityType.sectionTitle)

      HStack(spacing: 10) {
        presetButton(title: "Last 7 Days", days: 7)
        presetButton(title: "Last 30 Days", days: 30)
        presetButton(title: "Last 3 Months", days: 90)
      }

      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Start Date")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          #if os(macOS)
          DatePicker("", selection: $startDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
          #else
          DatePicker("", selection: $startDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
          #endif
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("End Date")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          #if os(macOS)
          DatePicker("", selection: $endDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
          #else
          DatePicker("", selection: $endDate, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
          #endif
        }

        Spacer()
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Include")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        HStack(spacing: 8) {
          includeToggle(title: "Tasks", isOn: $includeTasks)
          includeToggle(title: "Journal", isOn: $includeJournal)
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
            appState.setSection(.settings)
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

  private var filterPills: some View {
    HStack(spacing: 6) {
      ForEach(SummaryFilter.allCases) { option in
        Button(option.title) {
          filter = option
        }
        .buttonStyle(SerenityPillButtonStyle(selected: filter == option))
        .hoverCursor(.pointingHand)
      }
    }
  }

  @ViewBuilder
  private var summariesList: some View {
    let filtered = filteredSummaries

    if filtered.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "sparkles")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(SerenityPalette.textSecondary.opacity(0.7))
        Text("No summaries yet")
          .font(SerenityType.bodyLarge.weight(.medium))
        Text("Generate your first summary using the form above")
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 36)
      .padding(.horizontal, 20)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(filtered) { summary in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(summary.title)
                .font(SerenityType.bodyLarge.weight(.medium))
              Spacer()
              Text(summary.summaryType.rawValue.capitalized)
                .font(SerenityType.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(SerenityPalette.innerCardBackground, in: Capsule())
              Text("\(summary.wordCount) words")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
            }
            Text(summary.content)
              .lineLimit(3)
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
            HStack {
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
      }
      .padding(16)
      .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    }
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

  private func includeToggle(title: String, isOn: Binding<Bool>) -> some View {
    Button(title) {
      isOn.wrappedValue.toggle()
    }
    .buttonStyle(SerenityPillButtonStyle(selected: isOn.wrappedValue))
    .hoverCursor(.pointingHand)
  }

  private var filteredSummaries: [SummaryEntity] {
    switch filter {
    case .all: return appState.aiSummaries
    case .tasks: return appState.aiSummaries.filter { $0.summaryType == .tasks }
    case .journal: return appState.aiSummaries.filter { $0.summaryType == .journal }
    case .combined: return appState.aiSummaries.filter { $0.summaryType == .combined }
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

  private func generate() async {
    guard let type = resolvedSummaryType else { return }
    await appState.generateAISummary(type: type)
  }
}

private struct DatabaseSectionView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Spacer()
        Button("Refresh") {
          Task {
            await appState.refreshCoreWorkflowData()
            await appState.refreshDatabaseManagement()
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        .controlSize(.large)

        Button("Configure Database") {
          appState.setSection(.settings)
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
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
                .font(.caption)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.top, 8)
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
        .font(.caption2)
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

private struct SettingsSectionView: View {
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

  private let postgresSSLModes = ["disable", "prefer", "require", "verify-ca", "verify-full"]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Appearance") {
        VStack(alignment: .leading, spacing: 12) {
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
          .pickerStyle(.segmented)
          .frame(maxWidth: 340)

          Text("Choose whether Serenity follows the system appearance or forces light/dark mode.")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
        .padding(.top, 8)
      }

      GroupBox("Backend Configuration") {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Primary backend", selection: $appState.settings.backendProfile) {
            ForEach(BackendProfile.allCases) { profile in
              Text(profile.title).tag(profile)
            }
          }
          .pickerStyle(.menu)
          .frame(maxWidth: 280)

          let validation = appState.validationState(for: appState.settings.backendProfile)
          Text(validation.message)
            .font(SerenityType.caption)
            .foregroundStyle(validation.isAvailable ? SerenityPalette.textSecondary : Color.orange)

          Picker("Edit configuration", selection: $backendConfigProfile) {
            ForEach(BackendProfile.allCases) { profile in
              Text(profile.title).tag(profile)
            }
          }
          .pickerStyle(.menu)
          .frame(maxWidth: 280)

          backendConfigurationEditor

          Button("Validate active backend") {
            Task {
              await appState.refreshActiveBackendValidation()
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

          backendSwitchStatus
        }
        .padding(.top, 8)
      }

      GroupBox("Backend Diagnostics") {
        VStack(alignment: .leading, spacing: 8) {
          if appState.backendDiagnosticsLines.isEmpty {
            Text("No diagnostics available yet.")
              .foregroundStyle(SerenityPalette.textSecondary)
          } else {
            ForEach(appState.backendDiagnosticsLines, id: \.self) { line in
              Text(line)
                .font(SerenityType.caption)
                .textSelection(.enabled)
            }
          }

          Button("Refresh diagnostics") {
            Task {
              await appState.refreshActiveBackendValidation()
              await appState.refreshBackendDiagnostics()
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
        .padding(.top, 8)
      }

      GroupBox("Auth Session") {
        VStack(alignment: .leading, spacing: 10) {
          authSessionStatus

          VStack(alignment: .leading, spacing: 8) {
            Text("OAuth configuration")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)

            TextField("Base URL (https://...)", text: $oauthBaseURL)
              .textFieldStyle(.plain)
              .serenityInputField()

            TextField("Client ID", text: $oauthClientID)
              .textFieldStyle(.plain)
              .serenityInputField()

            TextField("Redirect URI", text: $oauthRedirectURI)
              .textFieldStyle(.plain)
              .serenityInputField()

            if let oauthConfigurationError {
              Text(oauthConfigurationError)
                .font(SerenityType.caption)
                .foregroundStyle(.red)
            }

            if !isOAuthConfigured {
              Text("Save OAuth configuration to enable sign in on this Mac.")
                .font(SerenityType.caption)
                .foregroundStyle(Color.orange)
            }

            HStack {
              Button("Save OAuth config") {
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
              }
              .buttonStyle(SerenityPrimaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Clear") {
                Task {
                  await appState.clearOAuthConfiguration()
                  oauthConfigurationError = nil
                  syncOAuthConfigurationFields()
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Authorization code")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
            TextField("Paste OAuth authorization code", text: $authorizationCode)
              .textFieldStyle(.plain)
              .serenityInputField()
          }

          HStack {
            Button("Sign in") {
              let submittedCode = authorizationCode
              Task {
                await appState.loginWithAuthorizationCode(submittedCode)
                if case .authenticated = appState.authSessionState {
                  authorizationCode = ""
                }
              }
            }
            .buttonStyle(SerenityPrimaryButtonStyle())
            .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isOAuthConfigured)
            .hoverCursor(.pointingHand)

            Button("Sign out") {
              Task {
                await appState.logout()
              }
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .hoverCursor(.pointingHand)
          }
        }
        .padding(.top, 8)
      }

      GroupBox("App Lock") {
        VStack(alignment: .leading, spacing: 12) {
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

          Text(appState.statusMessage(for: appState.localLockStatus))
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)

          if appState.settings.localLockEnabled, case .disabled = appState.localLockStatus {
            VStack(alignment: .leading, spacing: 8) {
              Text("Set local lock password")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)

              SecureField("New password", text: $localLockPassword)
                .textFieldStyle(.plain)
                .serenityInputField()

              SecureField("Confirm password", text: $localLockConfirmPassword)
                .textFieldStyle(.plain)
                .serenityInputField()

              if let localLockFormError {
                Text(localLockFormError)
                  .font(SerenityType.caption)
                  .foregroundStyle(.red)
              }

              Button("Set password and enable lock") {
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
              }
              .buttonStyle(SerenityPrimaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
          }

          if appState.settings.localLockEnabled {
            VStack(alignment: .leading, spacing: 8) {
              Text("Unlock with password")
                .font(SerenityType.caption)
                .foregroundStyle(SerenityPalette.textSecondary)
              SecureField("Enter local lock password", text: $unlockPassword)
                .textFieldStyle(.plain)
                .serenityInputField()
            }

            HStack {
              Button("Unlock with password") {
                let submittedPassword = unlockPassword
                Task {
                  await appState.unlockAppWithPassword(submittedPassword)
                  if case .unlocked = appState.localLockStatus {
                    unlockPassword = ""
                  }
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Lock now") {
                Task {
                  await appState.lockAppNow()
                }
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)
            }
          }

          biometricStatus
        }
        .padding(.top, 8)
      }

      GroupBox("Local Database") {
        VStack(alignment: .leading, spacing: 8) {
          databaseStatusContent

          Button("Run bootstrap") {
            Task {
              await appState.bootstrapLocalDatabase()
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
        .padding(.top, 8)
      }
    }
    .onAppear {
      loadStoredSettingsValuesIfNeeded()
    }
    .onChange(of: appState.settings.backendProfile) { _, newValue in
      Task {
        await appState.handleBackendProfileSelection(newValue)
      }
    }
  }

  @ViewBuilder
  private var backendConfigurationEditor: some View {
    switch backendConfigProfile {
    case .sqliteLocal:
      Text("SQLite local backend is ready with no additional setup.")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)

    case .serenityCloud:
      VStack(alignment: .leading, spacing: 8) {
        Text("Serenity Cloud")
          .font(SerenityType.bodyMedium)

        Text("Sign in under Auth Session, then use your signed-in session to configure cloud access automatically.")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        TextField("Base URL (https://...)", text: $cloudBaseURL)
          .textFieldStyle(.plain)
          .serenityInputField()

        if hasAuthenticatedSession {
          Text("Signed-in session available for one-click cloud setup.")
            .font(SerenityType.caption)
            .foregroundStyle(.green)
        } else {
          Text("Not signed in yet. Use Auth Session below, or provide an access token manually.")
            .font(SerenityType.caption)
            .foregroundStyle(Color.orange)
        }

        SecureField("Access token", text: $cloudAccessToken)
          .textFieldStyle(.plain)
          .serenityInputField()

        HStack {
          Button("Use signed-in session") {
            Task {
              await appState.configureSerenityCloudFromSignedInSession(baseURLOverride: cloudBaseURL)
              cloudAccessToken = ""
            }
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .disabled(!hasAuthenticatedSession)
          .hoverCursor(.pointingHand)

          Button("Save cloud config") {
            Task {
              await appState.configureSerenityCloud(baseURL: cloudBaseURL, accessToken: cloudAccessToken)
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)

          Button("Clear") {
            Task {
              await appState.clearSerenityCloudConfiguration()
              cloudAccessToken = ""
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      }

    case .externalPostgres:
      VStack(alignment: .leading, spacing: 8) {
        Text("External PostgreSQL")
          .font(SerenityType.bodyMedium)

        TextField("Host", text: $postgresHost)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Port", text: $postgresPort)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Database", text: $postgresDatabase)
          .textFieldStyle(.plain)
          .serenityInputField()

        TextField("Username", text: $postgresUsername)
          .textFieldStyle(.plain)
          .serenityInputField()

        SecureField("Password", text: $postgresPassword)
          .textFieldStyle(.plain)
          .serenityInputField()

        Picker("SSL mode", selection: $postgresSSLMode) {
          ForEach(postgresSSLModes, id: \.self) { mode in
            Text(mode).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 280)

        HStack {
          Button("Save PostgreSQL config") {
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
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .hoverCursor(.pointingHand)

          Button("Clear") {
            Task {
              await appState.clearExternalPostgresConfiguration()
              postgresPassword = ""
            }
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
          .hoverCursor(.pointingHand)
        }
      }
    }
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
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
            }

            Text("Serenity Notes")
              .font(.system(size: 32, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.white.opacity(0.97))

            Text("Enter your master password to unlock")
              .font(.system(size: 15, weight: .regular, design: .rounded))
              .foregroundStyle(Color(red: 0.66, green: 0.72, blue: 0.82))
          }
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 8) {
            Text("Master Password")
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color(red: 0.74, green: 0.79, blue: 0.88))

            HStack(spacing: 10) {
              Image(systemName: "key")
                .font(.system(size: 15, weight: .semibold))
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
              .font(.system(size: 15, weight: .medium, design: .rounded))
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
                  .font(.system(size: 15, weight: .semibold))
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
          .font(.system(size: 16, weight: .semibold, design: .rounded))
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
            .font(.system(size: 16, weight: .semibold, design: .rounded))
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
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(Color(red: 0.56, green: 0.62, blue: 0.73))
              Rectangle()
                .fill(Color(red: 0.30, green: 0.37, blue: 0.49))
                .frame(height: 1)
            }
          }

          Button("Forgot your password?") {
            appState.setSection(.settings)
            appState.showToast("Open Settings to reset your local lock password.")
          }
          .buttonStyle(.plain)
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color(red: 0.43, green: 0.67, blue: 0.98))
          .frame(maxWidth: .infinity, alignment: .center)
          .hoverCursor(.pointingHand)

          VStack(alignment: .leading, spacing: 6) {
            Label("Your data is protected", systemImage: "shield")
              .font(.system(size: 14, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 0.71, green: 0.83, blue: 1.0))
            Text("All sensitive information is encrypted with your master password.")
              .font(.system(size: 13, weight: .regular, design: .rounded))
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
          .font(.system(size: 11, weight: .regular, design: .rounded))
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
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.top, 2)
      Text(text)
        .font(.system(size: 13, weight: .medium, design: .rounded))
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
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 24, weight: .bold, design: .rounded))
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
          .font(.system(size: 16, weight: .regular))
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
                  .font(.caption.weight(.semibold))
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

              Button("Go to ActionHub") {
                appState.setSection(.actionHub)
                appState.closeHelpCenter()
              }
              .buttonStyle(SerenitySecondaryButtonStyle())
              .hoverCursor(.pointingHand)

              Button("Quick Add Task") {
                Task {
                  await appState.quickAddTaskFromCommand()
                  appState.closeHelpCenter()
                }
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
              HelpShortcutRow(action: "Help Center", shortcut: "Cmd+/")
              HelpShortcutRow(action: "Quick Add Task", shortcut: "Cmd+Shift+N")
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
          .font(.system(size: 10, weight: .semibold))
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
            .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: 11, weight: .semibold))
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
        .frame(maxWidth: .infinity, minHeight: 30)
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

private struct TaskEditorView: View {
  let task: TaskEntity
  let availableProjects: [ProjectEntity]
  let onSave: (String, String, TaskPriority, Date?, String?, [String]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var description: String
  @State private var priority: TaskPriority
  @State private var hasDueDate: Bool
  @State private var dueDate: Date
  @State private var selectedProjectID: String
  @State private var tags: String

  init(
    task: TaskEntity,
    availableProjects: [ProjectEntity],
    onSave: @escaping (String, String, TaskPriority, Date?, String?, [String]) -> Void
  ) {
    self.task = task
    self.availableProjects = availableProjects
    self.onSave = onSave
    _title = State(initialValue: task.title)
    _description = State(initialValue: task.description ?? "")
    _priority = State(initialValue: task.priority)
    _hasDueDate = State(initialValue: task.dueDate != nil)
    _dueDate = State(initialValue: task.dueDate ?? Date())
    _selectedProjectID = State(initialValue: task.projectId ?? "")
    _tags = State(initialValue: task.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit Task")
        .font(.headline)

      TextField("Title", text: $title)
        .textFieldStyle(.plain)
        .serenityInputField()

      TextField("Description (optional)", text: $description, axis: .vertical)
        .lineLimit(2...6)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack(spacing: 12) {
        Picker("Priority", selection: $priority) {
          ForEach(TaskPriority.allCases, id: \.rawValue) { value in
            Text(value.rawValue.capitalized).tag(value)
          }
        }
        .frame(maxWidth: 180)

        Toggle("Due date", isOn: $hasDueDate)
          .toggleStyle(.switch)

        if hasDueDate {
          DueDateSelectionField(selection: $dueDate)
            .frame(maxWidth: 280, alignment: .leading)
        }
      }

      Picker("Project", selection: $selectedProjectID) {
        Text("No project").tag("")
        ForEach(availableProjects) { project in
          Text(project.name).tag(project.id)
        }
      }
      .frame(maxWidth: 260)

      TextField("Tags (comma-separated)", text: $tags)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .hoverCursor(.pointingHand)

        Button("Save") {
          let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

          onSave(
            title,
            description,
            priority,
            hasDueDate ? dueDate : nil,
            selectedProjectID.isEmpty ? nil : selectedProjectID,
            parsedTags
          )
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .hoverCursor(.pointingHand)
      }
    }
    .padding(20)
  }
}

private struct JournalEntryEditorView: View {
  let entry: JournalEntryEntity
  let onSave: (String, String, JournalMood?, [String]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var content: String
  @State private var mood: JournalMood?
  @State private var tags: String

  init(entry: JournalEntryEntity, onSave: @escaping (String, String, JournalMood?, [String]) -> Void) {
    self.entry = entry
    self.onSave = onSave
    _title = State(initialValue: entry.title ?? "")
    _content = State(initialValue: entry.content)
    _mood = State(initialValue: entry.mood)
    _tags = State(initialValue: entry.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit Journal Entry")
        .font(.headline)

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

      TextField("Tags (comma-separated)", text: $tags)
        .textFieldStyle(.plain)
        .serenityInputField()

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .hoverCursor(.pointingHand)
        Button("Save") {
          let splitTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

          onSave(title, content, mood, splitTags)
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
        .font(.headline)

      TextField("Name", text: $name)
        .textFieldStyle(.plain)
        .serenityInputField()
      TextField("Description", text: $description)
        .textFieldStyle(.plain)
        .serenityInputField()
      HStack(spacing: 10) {
        ColorPicker("Project color", selection: $color, supportsOpacity: false)
        Text(ProjectColorCodec.hex(from: color))
          .font(.caption.monospaced())
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
        .font(.callout.weight(.medium))
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
