import SwiftUI

/// Flat content container: panel surface, hairline stroke, standard padding.
struct SerenityCard<Content: View>: View {
  private let padding: CGFloat
  private let content: Content

  init(padding: CGFloat = SerenityUI.Spacing.md, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .serenityPanel()
  }
}
