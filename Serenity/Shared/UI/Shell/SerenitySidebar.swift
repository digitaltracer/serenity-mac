import SwiftUI

/// Native source-list sidebar; gets the translucent sidebar material for free.
struct SerenitySidebar: View {
  @Binding var selectedSection: AppSection?

  private let primarySections: [AppSection] = [.home, .actionHub, .today, .journal, .goals, .insights, .aiSummaries]
  private let systemSections: [AppSection] = [.integrations, .costCenter, .database, .settings]

  var body: some View {
    List(selection: $selectedSection) {
      Section {
        ForEach(primarySections) { section in
          Label(section.title, systemImage: section.systemImage)
            .tag(section)
        }
      }

      Section("System") {
        ForEach(systemSections) { section in
          Label(section.title, systemImage: section.systemImage)
            .tag(section)
        }
      }
    }
    .listStyle(.sidebar)
  }
}
