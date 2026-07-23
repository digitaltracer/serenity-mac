import AppKit
import SwiftUI
import XCTest
@testable import SerenityMac

@MainActor
final class SerenityPaletteTests: XCTestCase {
  func testDarkPaletteUsesNeutralColors() {
    let colors: [(String, Color)] = [
      ("accent", SerenityPalette.accent),
      ("primaryActionBackground", SerenityPalette.primaryActionBackground),
      ("windowBackground", SerenityPalette.windowBackground),
      ("windowBackgroundDepth", SerenityPalette.windowBackgroundDepth),
      ("sidebarBackground", SerenityPalette.sidebarBackground),
      ("sidebarHeaderBackground", SerenityPalette.sidebarHeaderBackground),
      ("panelBackground", SerenityPalette.panelBackground),
      ("panelBackgroundRaised", SerenityPalette.panelBackgroundRaised),
      ("innerCardBackground", SerenityPalette.innerCardBackground),
      ("inputBackground", SerenityPalette.inputBackground),
      ("inputBackgroundHover", SerenityPalette.inputBackgroundHover),
      ("border", SerenityPalette.border),
      ("thinBorder", SerenityPalette.thinBorder),
      ("activeItemBackground", SerenityPalette.activeItemBackground),
      ("headerIconBackground", SerenityPalette.headerIconBackground),
      ("textSecondary", SerenityPalette.textSecondary),
      ("textPrimary", SerenityPalette.textPrimary),
      ("textOnInteractiveSurface", SerenityPalette.textOnInteractiveSurface),
      ("quickCaptureTint", SerenityPalette.quickCaptureTint),
      ("highlightStroke", SerenityPalette.highlightStroke),
    ]

    for (name, color) in colors {
      let components = rgba(color, appearance: .darkAqua)
      let chroma = max(components.red, components.green, components.blue)
        - min(components.red, components.green, components.blue)
      XCTAssertLessThan(chroma, 0.04, "\(name) retained a color cast")
    }
  }

  func testLightAccentRemainsBlue() {
    let components = rgba(SerenityPalette.accent, appearance: .aqua)

    XCTAssertEqual(components.red, 0.27, accuracy: 0.01)
    XCTAssertEqual(components.green, 0.52, accuracy: 0.01)
    XCTAssertEqual(components.blue, 0.95, accuracy: 0.01)
  }

  func testDarkAmbientGlowIsTransparent() {
    let components = rgba(SerenityPalette.ambientGlow, appearance: .darkAqua)

    XCTAssertEqual(components.alpha, 0, accuracy: 0.001)
  }

  func testDarkBordersBlendIntoSurfaces() {
    let border = rgba(SerenityPalette.border, appearance: .darkAqua)
    let thinBorder = rgba(SerenityPalette.thinBorder, appearance: .darkAqua)
    let highlight = rgba(SerenityPalette.highlightStroke, appearance: .darkAqua)

    XCTAssertLessThanOrEqual(border.alpha, 0.28)
    XCTAssertLessThanOrEqual(thinBorder.alpha, 0.15)
    XCTAssertLessThanOrEqual(highlight.alpha, 0.08)
  }

  func testDarkControlGlowIsTransparent() {
    let glow = rgba(SerenityPalette.controlGlow, appearance: .darkAqua)

    XCTAssertEqual(glow.alpha, 0, accuracy: 0.001)
  }

  func testDetailAccentGlowOnlyAppearsInLightMode() {
    let light = rgba(SerenityPalette.detailAccentGlow, appearance: .aqua)
    let dark = rgba(SerenityPalette.detailAccentGlow, appearance: .darkAqua)

    XCTAssertEqual(light.red, 0.27, accuracy: 0.01)
    XCTAssertEqual(light.green, 0.52, accuracy: 0.01)
    XCTAssertEqual(light.blue, 0.95, accuracy: 0.01)
    XCTAssertEqual(light.alpha, 0.07, accuracy: 0.001)
    XCTAssertEqual(dark.alpha, 0, accuracy: 0.001)
  }

  func testDarkPrimaryActionMeetsTextContrastRequirement() {
    let background = rgba(SerenityPalette.primaryActionBackground, appearance: .darkAqua)
    let foreground = rgba(SerenityPalette.textOnInteractiveSurface, appearance: .darkAqua)
    let canvas = rgba(SerenityPalette.windowBackground, appearance: .darkAqua)

    XCTAssertGreaterThanOrEqual(
      contrastRatio(foreground: foreground, background: background, canvas: canvas),
      4.5
    )
  }

  func testDarkPrimaryTextIsSoftenedAndReadable() {
    let foreground = rgba(SerenityPalette.textPrimary, appearance: .darkAqua)
    let canvas = rgba(SerenityPalette.windowBackground, appearance: .darkAqua)
    let backgrounds = [
      canvas,
      rgba(SerenityPalette.panelBackground, appearance: .darkAqua),
    ]

    XCTAssertEqual(foreground.alpha, 0.72, accuracy: 0.001)
    for background in backgrounds {
      XCTAssertGreaterThanOrEqual(
        contrastRatio(foreground: foreground, background: background, canvas: canvas),
        4.5
      )
    }
  }

  private func rgba(
    _ color: Color,
    appearance appearanceName: NSAppearance.Name
  ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let appearance = NSAppearance(named: appearanceName)!
    var resolved = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    }

    return (
      resolved.redComponent,
      resolved.greenComponent,
      resolved.blueComponent,
      resolved.alphaComponent
    )
  }

  private func contrastRatio(
    foreground: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
    background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
    canvas: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
  ) -> CGFloat {
    let renderedBackground = composite(background, over: canvas)
    let renderedForeground = composite(foreground, over: renderedBackground)
    let lighter = max(relativeLuminance(renderedBackground), relativeLuminance(renderedForeground))
    let darker = min(relativeLuminance(renderedBackground), relativeLuminance(renderedForeground))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func composite(
    _ foreground: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
    over background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
  ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
    guard alpha > 0 else { return (0, 0, 0, 0) }

    return (
      (foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
      (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
      (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
      alpha
    )
  }

  private func relativeLuminance(
    _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
  ) -> CGFloat {
    func linearize(_ component: CGFloat) -> CGFloat {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linearize(color.red)
      + 0.7152 * linearize(color.green)
      + 0.0722 * linearize(color.blue)
  }
}
