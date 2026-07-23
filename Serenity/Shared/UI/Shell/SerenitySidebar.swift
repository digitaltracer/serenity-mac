import SwiftUI

/// Native source-list sidebar; gets the translucent sidebar material for free.
struct SerenitySidebar: View {
  @Binding var selectedSection: AppSection?

  private let primarySections: [AppSection] = [.today, .tasks, .projects, .journal, .goals, .insights]

  var body: some View {
    List(selection: $selectedSection) {
      Section {
        ForEach(primarySections) { section in
          Label(section.title, systemImage: section.systemImage)
            .tag(section)
        }
      }

#if os(iOS)
      Section {
        Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
          .tag(AppSection.settings)
      }
#endif
    }
    .listStyle(.sidebar)
  }
}
