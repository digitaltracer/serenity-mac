import SwiftUI

/// Quiet capsule badge for statuses, counts, and tags.
struct SerenityBadge: View {
  let text: String
  var tint: Color = SerenityPalette.textSecondary
  var systemImage: String?

  init(_ text: String, tint: Color = SerenityPalette.textSecondary, systemImage: String? = nil) {
    self.text = text
    self.tint = tint
    self.systemImage = systemImage
  }

  var body: some View {
    HStack(spacing: SerenityUI.Spacing.xxs) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.caption2)
      }
      Text(text)
        .font(SerenityType.caption)
    }
    .padding(.horizontal, SerenityUI.Spacing.xs)
    .padding(.vertical, 3)
    .foregroundStyle(tint)
    .background(tint.opacity(0.12), in: Capsule())
  }
}
