import SwiftUI

/// Standard empty state built on ContentUnavailableView, with an optional action.
struct SerenityEmptyState: View {
  let systemImage: String
  let title: String
  var message: String?
  var actionTitle: String?
  var action: (() -> Void)?

  init(
    systemImage: String,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      if let message {
        Text(message)
      }
    } actions: {
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(SerenityPrimaryButtonStyle())
      }
    }
  }
}
