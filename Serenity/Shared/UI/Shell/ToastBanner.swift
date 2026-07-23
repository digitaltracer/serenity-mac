import SwiftUI

/// Transient confirmation banner shown at the top of the window.
struct ToastBanner: View {
  let message: String

  var body: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(SerenityPalette.accent)
      Text(message)
        .font(SerenityType.bodyMedium)
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.xs)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(
      Capsule()
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
