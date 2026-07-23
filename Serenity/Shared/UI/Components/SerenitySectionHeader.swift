import SwiftUI

/// In-content group header: title with optional subtitle and trailing accessory.
struct SerenitySectionHeader<Accessory: View>: View {
  let title: String
  var subtitle: String?
  private let accessory: Accessory

  init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
    self.title = title
    self.subtitle = subtitle
    self.accessory = accessory()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(SerenityType.sectionTitle)
          .foregroundStyle(SerenityPalette.textPrimary)
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }
      Spacer(minLength: 0)
      accessory
    }
  }
}
