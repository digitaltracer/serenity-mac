import SwiftUI

/// Warning banner shown when no AI provider is configured; links to Settings › AI.
struct SerenityAISetupBanner: View {
  @EnvironmentObject private var appState: AppState
#if os(macOS)
  @Environment(\.openSettings) private var openSettings
#endif

  var body: some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("AI provider not configured")
          .font(SerenityType.bodyMedium)
        HStack(spacing: 4) {
          Text("Add a provider in Settings to use this feature.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
          Button("Open Settings") {
            appState.requestSettings(tab: .ai)
#if os(macOS)
            openSettings()
#endif
          }
          .buttonStyle(.plain)
          .foregroundStyle(SerenityPalette.accent)
        }
      }
      Spacer()
    }
    .padding(SerenityUI.Spacing.sm)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }
}
