import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension Calendar {
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

/// Hex <-> Color conversion for project accent colors.
enum ProjectColorCodec {
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

/// Folds any uncommitted tag-input text into the committed tag list.
func tagsIncludingPendingInput(_ tags: [String], input: String) -> [String] {
  let pendingTag = input.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !pendingTag.isEmpty, !tags.contains(pendingTag) else { return tags }
  return tags + [pendingTag]
}
