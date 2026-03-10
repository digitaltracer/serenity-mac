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
    dark: (CGFloat, CGFloat, CGFloat, CGFloat)
  ) -> SerenityNativeColor {
#if os(macOS)
    NSColor(name: nil) { appearance in
      let bestMatch = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
      let active = (bestMatch == .darkAqua || bestMatch == .vibrantDark) ? dark : light
      return NSColor(
        srgbRed: active.0,
        green: active.1,
        blue: active.2,
        alpha: active.3
      )
    }
#else
    SerenityNativeColor { traits in
      let active = traits.userInterfaceStyle == .dark ? dark : light
      return SerenityNativeColor(
        red: active.0,
        green: active.1,
        blue: active.2,
        alpha: active.3
      )
    }
#endif
  }

  private static func dynamicColor(
    light: (CGFloat, CGFloat, CGFloat, CGFloat),
    dark: (CGFloat, CGFloat, CGFloat, CGFloat)
  ) -> Color {
    let nativeColor = dynamicNativeColor(light: light, dark: dark)
#if os(macOS)
    return Color(nsColor: nativeColor)
#else
    return Color(uiColor: nativeColor)
#endif
  }

  enum Palette {
    static let accent = Color(red: 0.27, green: 0.52, blue: 0.95)
    static let windowBackground = SerenityUI.dynamicColor(
      light: (0.96, 0.97, 0.99, 1.0),
      dark: (0.02, 0.07, 0.18, 1.0)
    )
    static let windowBackgroundDepth = SerenityUI.dynamicColor(
      light: (0.95, 0.96, 0.98, 1.0),
      dark: (0.02, 0.07, 0.18, 1.0)
    )
    static let ambientGlow = SerenityUI.dynamicColor(
      light: (0.45, 0.33, 0.92, 0.015),
      dark: (0.45, 0.33, 0.92, 0.09)
    )
    static let sidebarBackground = SerenityUI.dynamicColor(
      light: (0.94, 0.95, 0.97, 1.0),
      dark: (0.03, 0.07, 0.16, 1.0)
    )
    static let sidebarHeaderBackground = SerenityUI.dynamicColor(
      light: (0.95, 0.96, 0.98, 1.0),
      dark: (0.03, 0.08, 0.18, 1.0)
    )
    static let panelBackground = SerenityUI.dynamicColor(
      light: (0.97, 0.98, 0.99, 1.0),
      dark: (0.04, 0.09, 0.20, 1.0)
    )
    static let panelBackgroundRaised = SerenityUI.dynamicColor(
      light: (0.95, 0.96, 0.98, 1.0),
      dark: (0.07, 0.13, 0.25, 1.0)
    )
    static let innerCardBackground = SerenityUI.dynamicColor(
      light: (0.93, 0.95, 0.97, 1.0),
      dark: (0.08, 0.14, 0.25, 1.0)
    )
    static let inputBackground = SerenityUI.dynamicColor(
      light: (0.98, 0.99, 1.00, 1.0),
      dark: (0.08, 0.14, 0.25, 1.0)
    )
    static let inputBackgroundHover = SerenityUI.dynamicColor(
      light: (0.97, 0.98, 1.00, 1.0),
      dark: (0.10, 0.16, 0.27, 1.0)
    )
    static let border = SerenityUI.dynamicColor(
      light: (0.60, 0.66, 0.76, 0.45),
      dark: (0.24, 0.34, 0.50, 0.55)
    )
    static let thinBorder = SerenityUI.dynamicColor(
      light: (0.60, 0.66, 0.76, 0.24),
      dark: (0.24, 0.34, 0.50, 0.32)
    )
    static let activeItemBackground = SerenityUI.dynamicColor(
      light: (0.79, 0.86, 0.97, 1.0),
      dark: (0.17, 0.25, 0.38, 1.0)
    )
    static let headerIconBackground = SerenityUI.dynamicColor(
      light: (0.89, 0.92, 0.97, 1.0),
      dark: (0.10, 0.17, 0.30, 1.0)
    )
    static let textSecondary = SerenityUI.dynamicColor(
      light: (0.31, 0.39, 0.51, 1.0),
      dark: (0.57, 0.65, 0.78, 1.0)
    )
    static let textPrimary = SerenityUI.dynamicColor(
      light: (0.14, 0.20, 0.31, 1.0),
      dark: (0.90, 0.94, 0.99, 1.0)
    )
    static let textOnInteractiveSurface = SerenityUI.dynamicColor(
      light: (0.14, 0.20, 0.31, 1.0),
      dark: (0.97, 0.98, 1.00, 1.0)
    )
    static let quickCaptureTint = SerenityUI.dynamicColor(
      light: (0.49, 0.58, 0.88, 0.10),
      dark: (0.24, 0.17, 0.44, 0.55)
    )
    static let highlightStroke = SerenityUI.dynamicColor(
      light: (1.00, 1.00, 1.00, 0.28),
      dark: (1.00, 1.00, 1.00, 0.06)
    )
  }

  enum Typography {
    static let pageTitle = Font.system(size: 28, weight: .semibold)
    static let pageSubtitle = Font.system(size: 17, weight: .regular)
    static let sectionTitle = Font.system(size: 19, weight: .semibold)
    static let cardTitle = Font.system(size: 22, weight: .semibold)
    static let bodyLarge = Font.system(size: 16, weight: .regular)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyMedium = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
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
          .fill(SerenityPalette.accent.opacity(configuration.isPressed ? 0.78 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(SerenityPalette.accent.opacity(0.65), lineWidth: 1)
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
      .shadow(color: SerenityPalette.accent.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 8 : 5, x: 0, y: 1)
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
      .shadow(color: SerenityPalette.accent.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 8 : 5, x: 0, y: 1)
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
