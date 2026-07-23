import SwiftUI

/// Enabled-provider lookup shared by the insights dropdowns.
struct AIProviderDropdownAvailability {
  static func enabledProviders(from credentials: [AICredentialEntity]) -> [AICredentialProvider] {
    var providers: [AICredentialProvider] = []

    for credential in credentials where credential.enabled && !providers.contains(credential.provider) {
      providers.append(credential.provider)
    }

    return providers
  }
}

/// Insights section: segmented access to insights, summaries, and usage & cost.
struct InsightsSectionView: View {
  private enum InsightsTab: String, CaseIterable, Identifiable {
    case insights = "Insights"
    case summaries = "Summaries"
    case usage = "Usage & Cost"

    var id: String { rawValue }
  }

  @State private var tab: InsightsTab = .insights

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      Picker("View", selection: $tab) {
        ForEach(InsightsTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 380)

      switch tab {
      case .insights:
        InsightsPanelsView()
      case .summaries:
        AISummariesSectionView()
      case .usage:
        CostCenterSectionView()
      }
    }
  }
}
