import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum SerenityUI {
  /// System semantic colors under the legacy token names so the whole app
  /// follows the native macOS/iOS appearance in both light and dark mode.
  enum Palette {
#if os(macOS)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let panelBackgroundRaised = Color(nsColor: .quaternarySystemFill)
    static let innerCardBackground = Color(nsColor: .quinarySystemFill)
    static let inputBackground = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
#else
    static let windowBackground = Color(uiColor: .systemGroupedBackground)
    static let panelBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let panelBackgroundRaised = Color(uiColor: .quaternarySystemFill)
    static let innerCardBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let inputBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let border = Color(uiColor: .separator)
#endif

    static let accent = Color.accentColor
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let thinBorder = border.opacity(0.5)
    static let activeItemBackground = accent.opacity(0.16)
    static let headerIconBackground = panelBackgroundRaised

    // Legacy tokens from the gradient/glow identity; still referenced by the
    // iOS top bar and resolve to no-op values.
    static let sidebarBackground = Color.clear
    static let sidebarHeaderBackground = Color.clear
  }

  /// Native SF Pro text-style ramp; sizes resolve per platform.
  enum Typography {
    static var fontScale: CGFloat { SerenityScreenMetrics.fontScale }

    static let pageTitle = Font.title.weight(.semibold)
    static let pageSubtitle = Font.title3
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.title2.weight(.semibold)
    static let bodyLarge = Font.body
    static let body = Font.body
    static let bodyMedium = Font.body.weight(.medium)
    static let caption = Font.caption.weight(.medium)

    static func scaledSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
      .system(size: scaledSize(size), weight: weight, design: design)
    }

    static func scaledSize(_ size: CGFloat) -> CGFloat {
      size
    }
  }

  enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
  }

  enum Radius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let large: CGFloat = 8
    static let xLarge: CGFloat = 10
  }
}

enum SerenityScreenMetrics {
  /// Pinned to 1.0: the native text-style ramp handles sizing; kept as a
  /// shim because scaledSystem/scaledSize call sites still route through it.
  static var fontScale: CGFloat { 1.0 }
}

typealias SerenityPalette = SerenityUI.Palette
typealias SerenityType = SerenityUI.Typography

struct SerenityPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, SerenityUI.Spacing.sm)
      .padding(.vertical, 6)
      .foregroundStyle(Color.white)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .fill(SerenityPalette.accent.opacity(configuration.isPressed ? 0.8 : 1))
      )
  }
}

struct SerenitySecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, SerenityUI.Spacing.sm)
      .padding(.vertical, 6)
      .foregroundStyle(SerenityPalette.textPrimary)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .fill(SerenityPalette.panelBackgroundRaised.opacity(configuration.isPressed ? 0.6 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
  }
}

struct SerenityPillButtonStyle: ButtonStyle {
  let selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SerenityType.bodyMedium)
      .padding(.horizontal, SerenityUI.Spacing.sm)
      .padding(.vertical, 5)
      .foregroundStyle(selected ? SerenityPalette.accent : SerenityPalette.textSecondary)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
          .fill(selected ? SerenityPalette.activeItemBackground : SerenityPalette.panelBackgroundRaised.opacity(configuration.isPressed ? 0.6 : 1))
      )
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
      .padding(.horizontal, SerenityUI.Spacing.xs)
      .padding(.vertical, 7)
      .frame(minWidth: 160, minHeight: 34, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .fill(SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
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
    .background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
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
  func body(content: Content) -> some View {
    content
      .font(SerenityType.body)
      .padding(.horizontal, SerenityUI.Spacing.xs)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .fill(SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
  }
}

struct SerenityTextAreaModifier: ViewModifier {
  let minHeight: CGFloat

  func body(content: Content) -> some View {
    content
      .font(SerenityType.body)
      .scrollContentBackground(.hidden)
      .padding(SerenityUI.Spacing.xs)
      .frame(minHeight: minHeight)
      .background(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
          .fill(SerenityPalette.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
  }
}

extension View {
  func serenityInputField() -> some View {
    modifier(SerenityInputFieldModifier())
  }

  func serenityPanel(cornerRadius: CGFloat = SerenityUI.Radius.xLarge) -> some View {
    background(SerenityPalette.panelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
  }

  func serenityTextArea(minHeight: CGFloat = 120) -> some View {
    modifier(SerenityTextAreaModifier(minHeight: minHeight))
  }
}
