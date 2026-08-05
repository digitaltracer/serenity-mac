import AppKit
import SwiftUI
import XCTest
@testable import SerenityMac

@MainActor
final class SerenityPaletteTests: XCTestCase {
  func testDarkSurfacesAndTextStayNeutral() {
    let colors: [(String, Color)] = [
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
      ("highlightStroke", SerenityPalette.highlightStroke),
      ("textSecondary", SerenityPalette.textSecondary),
      ("textPrimary", SerenityPalette.textPrimary),
      ("textOnInteractiveSurface", SerenityPalette.textOnInteractiveSurface),
    ]

    for (name, color) in colors {
      let components = rgba(color, appearance: .darkAqua)
      let chroma = max(components.red, components.green, components.blue)
        - min(components.red, components.green, components.blue)
      XCTAssertLessThan(chroma, 0.04, "\(name) retained a color cast")
    }
  }

  func testDarkEmphasisSurfacesCarryBrandHue() {
    let colors: [(String, Color)] = [
      ("accent", SerenityPalette.accent),
      ("primaryActionBackground", SerenityPalette.primaryActionBackground),
      ("activeItemBackground", SerenityPalette.activeItemBackground),
      ("headerIconBackground", SerenityPalette.headerIconBackground),
      ("quickCaptureTint", SerenityPalette.quickCaptureTint),
    ]

    for (name, color) in colors {
      let components = rgba(color, appearance: .darkAqua)
      let chroma = max(components.red, components.green, components.blue)
        - min(components.red, components.green, components.blue)
      XCTAssertGreaterThan(chroma, 0.2, "\(name) lost the brand hue and fell back to grey")
    }
  }

  func testDarkElevationRampRisesInSubtleSteps() {
    let ramp: [(String, Color)] = [
      ("sidebarBackground", SerenityPalette.sidebarBackground),
      ("windowBackground", SerenityPalette.windowBackground),
      ("panelBackground", SerenityPalette.panelBackground),
      ("panelBackgroundRaised", SerenityPalette.panelBackgroundRaised),
      ("inputBackgroundHover", SerenityPalette.inputBackgroundHover),
    ]

    let lightness = ramp.map { lstar(rgba($0.1, appearance: .darkAqua)) }

    for index in 1..<ramp.count {
      let step = lightness[index] - lightness[index - 1]
      XCTAssertGreaterThan(
        step,
        1.5,
        "\(ramp[index].0) is not distinguishable from \(ramp[index - 1].0)"
      )
      XCTAssertLessThan(
        step,
        6.0,
        "\(ramp[index].0) jumps far enough above \(ramp[index - 1].0) to read as highlighted"
      )
    }
  }

  func testDarkCardsSeparateByFillNotOutline() {
    let canvas = rgba(SerenityPalette.windowBackground, appearance: .darkAqua)
    let panel = rgba(SerenityPalette.panelBackground, appearance: .darkAqua)
    let border = rgba(SerenityPalette.border, appearance: .darkAqua)

    let fillStep = lstar(panel) - lstar(canvas)
    let outlineStep = lstar(composite(border, over: panel)) - lstar(panel)

    XCTAssertGreaterThan(fillStep, 1.5, "cards do not lift off the canvas at all")
    XCTAssertLessThan(
      outlineStep,
      3 * fillStep,
      "the outline overpowers the fill, which reads as a wireframe box"
    )
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

  func testDarkBordersStayHairlineQuiet() {
    let panel = rgba(SerenityPalette.panelBackground, appearance: .darkAqua)
    let strokes: [(String, Color, CGFloat)] = [
      ("border", SerenityPalette.border, 0.10),
      ("thinBorder", SerenityPalette.thinBorder, 0.07),
      ("highlightStroke", SerenityPalette.highlightStroke, 0.04),
    ]

    for (name, color, maximumAlpha) in strokes {
      let stroke = rgba(color, appearance: .darkAqua)
      XCTAssertLessThanOrEqual(stroke.alpha, maximumAlpha, "\(name) is too opaque to read as a hairline")

      let rendered = contrastRatio(foreground: stroke, background: panel, canvas: panel)
      XCTAssertLessThan(rendered, 1.6, "\(name) stands too far off its surface")
    }
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

  func testDarkTextHierarchyIsReadableAndSeparated() {
    let canvas = rgba(SerenityPalette.windowBackground, appearance: .darkAqua)
    let primary = rgba(SerenityPalette.textPrimary, appearance: .darkAqua)
    let secondary = rgba(SerenityPalette.textSecondary, appearance: .darkAqua)
    let backgrounds = [
      canvas,
      rgba(SerenityPalette.panelBackground, appearance: .darkAqua),
      rgba(SerenityPalette.panelBackgroundRaised, appearance: .darkAqua),
    ]

    XCTAssertEqual(primary.alpha, 0.92, accuracy: 0.001)
    for background in backgrounds {
      XCTAssertGreaterThanOrEqual(
        contrastRatio(foreground: primary, background: background, canvas: canvas),
        4.5
      )
      XCTAssertGreaterThanOrEqual(
        contrastRatio(foreground: secondary, background: background, canvas: canvas),
        4.5
      )
    }

    let separation = lstar(composite(primary, over: canvas)) - lstar(composite(secondary, over: canvas))
    XCTAssertGreaterThan(separation, 15, "primary and secondary text are too close to rank")
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

  /// CIE L*, the perceptual lightness axis — equal steps here look equally spaced.
  private func lstar(
    _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
  ) -> CGFloat {
    let luminance = relativeLuminance(color)
    return luminance > 0.008856
      ? 116 * pow(luminance, 1.0 / 3.0) - 16
      : 903.3 * luminance
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
