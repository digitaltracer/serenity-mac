import SwiftUI
#if os(macOS)
import AppKit
typealias SerenityNativeColor = NSColor
#elseif os(iOS)
import UIKit
typealias SerenityNativeColor = UIColor
#endif

enum SerenityUI {
  private static func dynamicNativeColor(
    light: (CGFloat, CGFloat, CGFloat, CGFloat),
    dark: SerenityNativeColor
  ) -> SerenityNativeColor {
#if os(macOS)
    NSColor(name: nil) { appearance in
      let bestMatch = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
      if bestMatch == .darkAqua || bestMatch == .vibrantDark {
        return dark
      }
      return NSColor(
        srgbRed: light.0,
        green: light.1,
        blue: light.2,
        alpha: light.3
      )
    }
#else
    SerenityNativeColor { traits in
      if traits.userInterfaceStyle == .dark {
        return dark
      }
      return SerenityNativeColor(
        red: light.0,
        green: light.1,
        blue: light.2,
        alpha: light.3
      )
    }
#endif
  }

  private static func dynamicColor(
    light: (CGFloat, CGFloat, CGFloat, CGFloat),
    dark: SerenityNativeColor
  ) -> Color {
    let nativeColor = dynamicNativeColor(light: light, dark: dark)
#if os(macOS)
    return Color(nsColor: nativeColor)
#else
    return Color(uiColor: nativeColor)
#endif
  }

  enum Palette {
    static let accent = SerenityUI.dynamicColor(
      light: (0.27, 0.52, 0.95, 1.0),
      dark: SerenityDarkPalette.accent
    )
    static let primaryActionBackground = SerenityUI.dynamicColor(
      light: (0.27, 0.52, 0.95, 1.0),
      dark: SerenityDarkPalette.primaryActionBackground
    )
    static let detailAccentGlow = SerenityUI.dynamicColor(
      light: (0.27, 0.52, 0.95, 0.07),
      dark: .clear
    )
    static let controlGlow = SerenityUI.dynamicColor(
      light: (0.27, 0.52, 0.95, 1.0),
      dark: .clear
    )
    static let windowBackground = SerenityUI.dynamicColor(
      light: (0.96, 0.97, 0.99, 1.0),
      dark: SerenityDarkPalette.windowBackground
    )
    static let windowBackgroundDepth = SerenityUI.dynamicColor(
      light: (0.93, 0.94, 0.97, 1.0),
      dark: SerenityDarkPalette.windowBackgroundDepth
    )
    static let ambientGlow = SerenityUI.dynamicColor(
      light: (0.45, 0.33, 0.92, 0.015),
      dark: .clear
    )
    static let sidebarBackground = SerenityUI.dynamicColor(
      light: (0.93, 0.94, 0.97, 1.0),
      dark: SerenityDarkPalette.sidebarBackground
    )
    static let sidebarHeaderBackground = SerenityUI.dynamicColor(
      light: (0.93, 0.94, 0.97, 1.0),
      dark: SerenityDarkPalette.sidebarBackground
    )
    static let panelBackground = SerenityUI.dynamicColor(
      light: (0.97, 0.98, 0.99, 1.0),
      dark: SerenityDarkPalette.panelBackground
    )
    static let panelBackgroundRaised = SerenityUI.dynamicColor(
      light: (0.95, 0.96, 0.98, 1.0),
      dark: SerenityDarkPalette.panelBackgroundRaised
    )
    static let innerCardBackground = SerenityUI.dynamicColor(
      light: (0.93, 0.95, 0.97, 1.0),
      dark: SerenityDarkPalette.panelBackgroundRaised
    )
    static let inputBackground = SerenityUI.dynamicColor(
      light: (0.98, 0.99, 1.00, 1.0),
      dark: SerenityDarkPalette.panelBackgroundRaised
    )
    static let inputBackgroundHover = SerenityUI.dynamicColor(
      light: (0.97, 0.98, 1.00, 1.0),
      dark: SerenityDarkPalette.hoverBackground
    )
    static let border = SerenityUI.dynamicColor(
      light: (0.60, 0.66, 0.76, 0.45),
      dark: SerenityDarkPalette.border
    )
    static let thinBorder = SerenityUI.dynamicColor(
      light: (0.60, 0.66, 0.76, 0.24),
      dark: SerenityDarkPalette.thinBorder
    )
    static let activeItemBackground = SerenityUI.dynamicColor(
      light: (0.79, 0.86, 0.97, 1.0),
      dark: SerenityDarkPalette.activeItemBackground
    )
    static let headerIconBackground = SerenityUI.dynamicColor(
      light: (0.89, 0.92, 0.97, 1.0),
      dark: SerenityDarkPalette.headerIconBackground
    )
    static let textSecondary = SerenityUI.dynamicColor(
      light: (0.31, 0.39, 0.51, 1.0),
      dark: SerenityDarkPalette.textSecondary
    )
    static let textPrimary = SerenityUI.dynamicColor(
      light: (0.14, 0.20, 0.31, 1.0),
      dark: SerenityDarkPalette.textPrimary
    )
    static let textOnInteractiveSurface = SerenityUI.dynamicColor(
      light: (0.14, 0.20, 0.31, 1.0),
      dark: SerenityDarkPalette.textOnInteractiveSurface
    )
    static let quickCaptureTint = SerenityUI.dynamicColor(
      light: (0.49, 0.58, 0.88, 0.10),
      dark: SerenityDarkPalette.quickCaptureTint
    )
    static let highlightStroke = SerenityUI.dynamicColor(
      light: (1.00, 1.00, 1.00, 0.28),
      dark: SerenityDarkPalette.highlightStroke
    )
  }

  enum Typography {
    static var fontScale: CGFloat { SerenityScreenMetrics.fontScale }

    static let pageTitle = scaledSystem(size: 28, weight: .semibold)
    static let pageSubtitle = scaledSystem(size: 17, weight: .regular)
    static let sectionTitle = scaledSystem(size: 19, weight: .semibold)
    static let cardTitle = scaledSystem(size: 22, weight: .semibold)
    static let bodyLarge = scaledSystem(size: 16, weight: .regular)
    static let body = scaledSystem(size: 15, weight: .regular)
    static let bodyMedium = scaledSystem(size: 14, weight: .medium)
    static let caption = scaledSystem(size: 11, weight: .medium)

    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
      .system(size: scaledSize(size), weight: weight, design: design)
    }

    static func scaledSize(_ size: CGFloat) -> CGFloat {
      size * fontScale
    }
  }
}

private enum SerenityDarkPalette {
  private static func srgb(
    _ red: CGFloat,
    _ green: CGFloat,
    _ blue: CGFloat,
    _ alpha: CGFloat = 1
  ) -> SerenityNativeColor {
#if os(macOS)
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
#else
    UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
#endif
  }

  private static func white(_ alpha: CGFloat) -> SerenityNativeColor {
    srgb(255, 255, 255, alpha)
  }

  private static func accentTint(_ alpha: CGFloat) -> SerenityNativeColor {
    srgb(76, 141, 255, alpha)
  }

  // Elevation ramp, ~3 L* per step: surfaces separate by fill, not by outline.
  static let sidebarBackground = srgb(20, 20, 23)
  static let windowBackgroundDepth = srgb(20, 20, 23)
  static let windowBackground = srgb(27, 27, 30)
  static let panelBackground = srgb(33, 33, 37)
  static let panelBackgroundRaised = srgb(38, 38, 43)
  static let hoverBackground = srgb(44, 44, 50)

  // Hairlines only confirm an edge the fill step has already established.
  static let border = white(0.08)
  static let thinBorder = white(0.055)
  static let highlightStroke = white(0.03)

  // Selected/emphasised surfaces read as a brand tint instead of a grey slab.
  static let accent = srgb(76, 141, 255)
  static let primaryActionBackground = srgb(37, 99, 235)
  static let activeItemBackground = accentTint(0.16)
  static let headerIconBackground = accentTint(0.10)
  // Spans half the capture card as a gradient stop, so it has to stay near-invisible.
  static let quickCaptureTint = accentTint(0.035)

  static let textPrimary = white(0.92)
  static let textSecondary = white(0.60)
  static let textOnInteractiveSurface = white(0.95)
}

enum SerenityScreenMetrics {
  static let smallScreenFontScale: CGFloat = 0.85

  static var fontScale: CGFloat {
    screenDiagonalInches.map { $0 < 15 ? smallScreenFontScale : 1.0 } ?? 1.0
  }

  private static var screenDiagonalInches: CGFloat? {
#if os(macOS)
    guard
      let screen = NSScreen.main,
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else {
      return nil
    }

    let size = CGDisplayScreenSize(displayID)
    guard size.width > 0, size.height > 0 else { return nil }
    return hypot(size.width, size.height) / 25.4
#elseif os(iOS)
    return 14.9
#else
    return nil
#endif
  }
}

typealias SerenityPalette = SerenityUI.Palette
typealias SerenityType = SerenityUI.Typography

struct SerenityPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .foregroundStyle(Color.white)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SerenityPalette.primaryActionBackground.opacity(configuration.isPressed ? 0.78 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(SerenityPalette.primaryActionBackground.opacity(0.65), lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SerenitySecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .foregroundStyle(SerenityPalette.textPrimary)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SerenityPalette.panelBackgroundRaised.opacity(configuration.isPressed ? 0.72 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SerenityPillButtonStyle: ButtonStyle {
  let selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .foregroundStyle(selected ? SerenityPalette.textOnInteractiveSurface : SerenityPalette.textSecondary)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(selected ? SerenityPalette.activeItemBackground.opacity(configuration.isPressed ? 0.72 : 1) : SerenityPalette.panelBackgroundRaised.opacity(configuration.isPressed ? 0.75 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(selected ? SerenityPalette.border : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SerenityDropdownOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  let subtitle: String?
  let systemImage: String?
  let tint: Color?

  var id: Value { value }

  init(
    value: Value,
    title: String,
    subtitle: String? = nil,
    systemImage: String? = nil,
    tint: Color? = nil
  ) {
    self.value = value
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.tint = tint
  }
}

struct SerenityFlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth && x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    let resolvedWidth = maxWidth.isFinite ? maxWidth : x
    return CGSize(width: resolvedWidth, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x: CGFloat = bounds.minX
    var y: CGFloat = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX && x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

private struct SerenityScrollMetrics: Equatable {
  var offset: CGFloat
  var content: CGFloat
  var viewport: CGFloat
}

struct SerenityThemedScrollView<Content: View>: View {
  private let content: Content

  @State private var contentHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var scrollOffset: CGFloat = 0
  @State private var hovered = false

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  private var shouldShowScrollbar: Bool {
    viewportHeight > 0 && contentHeight > viewportHeight + 4
  }

  private var thumbHeight: CGFloat {
    guard shouldShowScrollbar else { return 0 }
    let trackHeight = max(viewportHeight - 24, 1)
    return min(trackHeight, max(44, trackHeight * viewportHeight / contentHeight))
  }

  private var thumbOffset: CGFloat {
    guard shouldShowScrollbar else { return 0 }
    let trackHeight = max(viewportHeight - 24, 1)
    let maxScrollOffset = max(contentHeight - viewportHeight, 1)
    let maxThumbOffset = max(trackHeight - thumbHeight, 0)
    return 12 + min(max(scrollOffset / maxScrollOffset, 0), 1) * maxThumbOffset
  }

  var body: some View {
    if #available(macOS 15.0, iOS 18.0, *) {
      ScrollView(.vertical, showsIndicators: false) {
        content
      }
      .onScrollGeometryChange(for: SerenityScrollMetrics.self) { geometry in
        SerenityScrollMetrics(
          offset: max(0, geometry.contentOffset.y),
          content: geometry.contentSize.height,
          viewport: geometry.containerSize.height
        )
      } action: { _, metrics in
        scrollOffset = metrics.offset
        contentHeight = metrics.content
        viewportHeight = metrics.viewport
      }
      .overlay(alignment: .topTrailing) {
        if shouldShowScrollbar {
          scrollbar
            .opacity(hovered ? 1 : 0.72)
            .animation(.easeOut(duration: 0.16), value: hovered)
        }
      }
      .onHover { isHovering in
        hovered = isHovering
      }
    } else {
      ScrollView(.vertical) {
        content
      }
      .scrollIndicators(.automatic)
    }
  }

  private var scrollbar: some View {
    ZStack(alignment: .top) {
      Capsule()
        .fill(SerenityPalette.thinBorder.opacity(0.55))
        .frame(width: 5)

      Capsule()
        .fill(SerenityPalette.textSecondary.opacity(hovered ? 0.62 : 0.42))
        .frame(width: 5, height: thumbHeight)
        .offset(y: thumbOffset)
    }
    .frame(width: 12)
    .padding(.trailing, 6)
    .allowsHitTesting(false)
  }
}

struct SerenityTagInputField: View {
  @Binding var tags: [String]
  @Binding var inputText: String

  let emptyPlaceholder: String
  let filledPlaceholder: String

  init(
    tags: Binding<[String]>,
    inputText: Binding<String>,
    emptyPlaceholder: String = "Add a tag, press comma or return",
    filledPlaceholder: String = "Add another tag..."
  ) {
    _tags = tags
    _inputText = inputText
    self.emptyPlaceholder = emptyPlaceholder
    self.filledPlaceholder = filledPlaceholder
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !tags.isEmpty {
        SerenityFlowLayout(spacing: 6) {
          ForEach(tags, id: \.self) { tag in
            tagChip(tag)
          }
        }
      }

      TextField(tags.isEmpty ? emptyPlaceholder : filledPlaceholder, text: $inputText)
        .textFieldStyle(.plain)
        .serenityInputField()
        .onChange(of: inputText) { _, newValue in
          handleInputChange(newValue)
        }
        .onSubmit {
          commitPendingTag()
        }
    }
  }

  func committedTagsIncludingPendingInput() -> [String] {
    let pendingTag = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pendingTag.isEmpty, !tags.contains(pendingTag) else { return tags }
    return tags + [pendingTag]
  }

  private func tagChip(_ tag: String) -> some View {
    HStack(spacing: 6) {
      Text(tag)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textPrimary)
      Button {
        removeTag(tag)
      } label: {
        Image(systemName: "xmark")
          .font(SerenityType.scaledSystem(size: 9, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(SerenityPalette.headerIconBackground, in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }

  private func handleInputChange(_ value: String) {
    guard value.contains(",") else { return }
    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
    let tagsToCommit = parts.dropLast()
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    for tag in tagsToCommit where !tags.contains(tag) {
      tags.append(tag)
    }
    inputText = String(parts.last ?? "")
  }

  private func commitPendingTag() {
    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    inputText = ""
    guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
    tags.append(trimmed)
  }

  private func removeTag(_ tag: String) {
    tags.removeAll { $0 == tag }
  }
}

struct SerenityDropdownField<Value: Hashable, Footer: View>: View {
  let placeholder: String
  let options: [SerenityDropdownOption<Value>]
  let maxMenuHeight: CGFloat
  let footerDismissesOnTap: Bool
  let footer: Footer

  @Binding var selection: Value
  @State private var showingPopover = false
  @State private var hovered = false
  @State private var hoveredOption: Value?
  @State private var menuContentHeight: CGFloat = 0
  @State private var menuViewportHeight: CGFloat = 0
  @State private var menuScrollOffset: CGFloat = 0

  private var selectedOption: SerenityDropdownOption<Value>? {
    options.first { $0.value == selection }
  }

  private var shouldShowMenuScrollbar: Bool {
    menuViewportHeight > 0 && menuContentHeight > menuViewportHeight + 4
  }

  private var menuScrollbarThumbHeight: CGFloat {
    guard shouldShowMenuScrollbar else { return 0 }
    let trackHeight = max(menuViewportHeight - 12, 1)
    return min(trackHeight, max(34, trackHeight * menuViewportHeight / menuContentHeight))
  }

  private var menuScrollbarThumbOffset: CGFloat {
    guard shouldShowMenuScrollbar else { return 0 }
    let trackHeight = max(menuViewportHeight - 12, 1)
    let maxScrollOffset = max(menuContentHeight - menuViewportHeight, 1)
    let maxThumbOffset = max(trackHeight - menuScrollbarThumbHeight, 0)
    return 6 + min(max(menuScrollOffset / maxScrollOffset, 0), 1) * maxThumbOffset
  }

  var body: some View {
    Button {
      showingPopover.toggle()
    } label: {
      HStack(spacing: 9) {
        if let selectedOption, let systemImage = selectedOption.systemImage {
          Image(systemName: systemImage)
            .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
            .foregroundStyle(selectedOption.tint ?? SerenityPalette.accent)
        } else if let selectedOption, let tint = selectedOption.tint {
          Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
        }

        Text(selectedOption?.title ?? placeholder)
          .font(SerenityType.body)
          .foregroundStyle(selectedOption == nil ? SerenityPalette.textSecondary : SerenityPalette.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Image(systemName: "chevron.down")
          .font(SerenityType.scaledSystem(size: 10, weight: .semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
          .rotationEffect(.degrees(showingPopover ? 180 : 0))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(minWidth: 160, minHeight: 40, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(hovered || showingPopover ? SerenityPalette.inputBackgroundHover : SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(hovered || showingPopover ? SerenityPalette.border : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(SerenityPalette.highlightStroke, lineWidth: 1)
      )
      .shadow(color: SerenityPalette.controlGlow.opacity(hovered || showingPopover ? 0.12 : 0.06), radius: hovered || showingPopover ? 8 : 5, x: 0, y: 1)
    }
    .buttonStyle(.plain)
    .disabled(options.isEmpty)
    .accessibilityLabel(placeholder)
    .accessibilityValue(selectedOption?.title ?? "No selection")
    .onHover { isHovering in
      hovered = isHovering
    }
    .animation(.easeOut(duration: 0.16), value: hovered)
    .animation(.easeOut(duration: 0.16), value: showingPopover)
    .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
      dropdownMenu
        .padding(8)
        .frame(minWidth: 220)
    }
  }

  private var dropdownMenu: some View {
    VStack(alignment: .leading, spacing: 6) {
      dropdownScrollArea

      footer
        .simultaneousGesture(
          TapGesture().onEnded {
            if footerDismissesOnTap {
              showingPopover = false
            }
          }
        )
    }
    .padding(4)
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(SerenityPalette.border, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var dropdownScrollArea: some View {
    if #available(macOS 15.0, iOS 18.0, *) {
      ScrollView(.vertical, showsIndicators: false) {
        dropdownOptionsList
      }
      .frame(maxHeight: maxMenuHeight)
      .fixedSize(horizontal: false, vertical: true)
      .onScrollGeometryChange(for: SerenityScrollMetrics.self) { geometry in
        SerenityScrollMetrics(
          offset: max(0, geometry.contentOffset.y),
          content: geometry.contentSize.height,
          viewport: geometry.containerSize.height
        )
      } action: { _, metrics in
        menuScrollOffset = metrics.offset
        menuContentHeight = metrics.content
        menuViewportHeight = metrics.viewport
      }
      .overlay(alignment: .topTrailing) {
        if shouldShowMenuScrollbar {
          Capsule()
            .fill(SerenityPalette.textSecondary.opacity(0.48))
            .frame(width: 4, height: menuScrollbarThumbHeight)
            .offset(y: menuScrollbarThumbOffset)
            .padding(.trailing, 2)
            .allowsHitTesting(false)
        }
      }
    } else {
      ScrollView(.vertical) {
        dropdownOptionsList
      }
      .frame(maxHeight: maxMenuHeight)
      .fixedSize(horizontal: false, vertical: true)
      .scrollIndicators(.automatic)
    }
  }

  private var dropdownOptionsList: some View {
    VStack(alignment: .leading, spacing: 4) {
      if options.isEmpty {
        Text("No options")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
      } else {
        ForEach(options) { option in
          dropdownRow(option)
        }
      }
    }
  }

  private func dropdownRow(_ option: SerenityDropdownOption<Value>) -> some View {
    let isSelected = option.value == selection
    let isHovered = hoveredOption == option.value

    return Button {
      selection = option.value
      showingPopover = false
    } label: {
      HStack(spacing: 9) {
        if let systemImage = option.systemImage {
          Image(systemName: systemImage)
            .font(SerenityType.scaledSystem(size: 12, weight: .semibold))
            .foregroundStyle(option.tint ?? SerenityPalette.accent)
        } else if let tint = option.tint {
          Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(option.title)
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
            .lineLimit(1)

          if let subtitle = option.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if isSelected {
          Image(systemName: "checkmark")
            .font(SerenityType.scaledSystem(size: 11, weight: .bold))
            .foregroundStyle(SerenityPalette.accent)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isSelected ? SerenityPalette.activeItemBackground.opacity(0.72) : SerenityPalette.panelBackgroundRaised.opacity(isHovered ? 0.48 : 0))
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering in
      hoveredOption = isHovering ? option.value : nil
    }
  }
}

extension SerenityDropdownField where Footer == EmptyView {
  init(
    placeholder: String,
    selection: Binding<Value>,
    options: [SerenityDropdownOption<Value>],
    maxMenuHeight: CGFloat = 240
  ) {
    self.placeholder = placeholder
    self._selection = selection
    self.options = options
    self.maxMenuHeight = maxMenuHeight
    self.footerDismissesOnTap = false
    self.footer = EmptyView()
  }
}

extension SerenityDropdownField {
  init(
    placeholder: String,
    selection: Binding<Value>,
    options: [SerenityDropdownOption<Value>],
    maxMenuHeight: CGFloat = 240,
    footerDismissesOnTap: Bool = true,
    @ViewBuilder footer: () -> Footer
  ) {
    self.placeholder = placeholder
    self._selection = selection
    self.options = options
    self.maxMenuHeight = maxMenuHeight
    self.footerDismissesOnTap = footerDismissesOnTap
    self.footer = footer()
  }
}

struct SerenityInputFieldModifier: ViewModifier {
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .font(SerenityType.body)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(hovered ? SerenityPalette.inputBackgroundHover : SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(hovered ? SerenityPalette.border : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(SerenityPalette.highlightStroke, lineWidth: 1)
      )
      .shadow(color: SerenityPalette.controlGlow.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 8 : 5, x: 0, y: 1)
      .animation(.easeOut(duration: 0.16), value: hovered)
      .onHover { isHovering in
        hovered = isHovering
      }
  }
}

struct SerenityTextAreaModifier: ViewModifier {
  let minHeight: CGFloat
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .font(SerenityType.body)
      .scrollContentBackground(.hidden)
      .padding(8)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(hovered ? SerenityPalette.inputBackgroundHover : SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(hovered ? SerenityPalette.border : SerenityPalette.thinBorder, lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(SerenityPalette.highlightStroke, lineWidth: 1)
      )
      .shadow(color: SerenityPalette.controlGlow.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 8 : 5, x: 0, y: 1)
      .animation(.easeOut(duration: 0.16), value: hovered)
      .onHover { isHovering in
        hovered = isHovering
      }
  }
}

extension View {
  func serenityInputField() -> some View {
    modifier(SerenityInputFieldModifier())
  }

  func serenityPanel(cornerRadius: CGFloat = 16) -> some View {
    background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
  }

  func serenityTextArea(minHeight: CGFloat = 120) -> some View {
    modifier(SerenityTextAreaModifier(minHeight: minHeight))
  }
}
