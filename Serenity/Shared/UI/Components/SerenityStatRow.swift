import SwiftUI

/// Label/value row for compact stat lists (e.g. Completed / Remaining / Total).
struct SerenityStatRow: View {
  let label: String
  let value: String
  var systemImage: String?
  var tint: Color = SerenityPalette.textSecondary

  init(_ label: String, value: String, systemImage: String? = nil, tint: Color = SerenityPalette.textSecondary) {
    self.label = label
    self.value = value
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.subheadline)
          .foregroundStyle(tint)
          .frame(width: 18)
      }
      Text(label)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer(minLength: SerenityUI.Spacing.xs)
      Text(value)
        .font(SerenityType.bodyMedium)
        .monospacedDigit()
        .foregroundStyle(SerenityPalette.textPrimary)
    }
  }
}
