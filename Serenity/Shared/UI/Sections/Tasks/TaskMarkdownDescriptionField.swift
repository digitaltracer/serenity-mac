import SwiftUI

/// Markdown-aware description input with a live rendered preview.
struct TaskMarkdownDescriptionField: View {
  @Binding var text: String
  var minHeight: CGFloat = 132
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Text("Description")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer(minLength: 0)

        Label("Markdown", systemImage: "text.badge.checkmark")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      ZStack(alignment: .topLeading) {
        TextEditor(text: $text)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textPrimary)
          .focused($isFocused)
          .serenityTextArea(minHeight: minHeight)

        if text.isEmpty && !isFocused {
          Text("Description (optional)")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary.opacity(0.76))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .allowsHitTesting(false)
        }
      }

      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          Text("Preview")
            .font(SerenityType.caption.weight(.semibold))
            .foregroundStyle(SerenityPalette.textSecondary)

          GitHubFlavoredMarkdownView(markdown: text)
            .padding(SerenityUI.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
                .stroke(SerenityPalette.thinBorder, lineWidth: 1)
            )
        }
      }
    }
  }
}
