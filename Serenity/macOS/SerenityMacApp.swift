import SwiftUI

@main
struct SerenityMacApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      SerenityAppScene(appState: appState)
        .frame(minWidth: 1080, minHeight: 680)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Global Search") {
          appState.openGlobalSearch()
        }
        .keyboardShortcut("k", modifiers: [.command])

        Button("Help Center") {
          appState.openHelpCenter()
        }
        .keyboardShortcut("/", modifiers: [.command])

        Divider()

        Button("Quick Add Task") {
          Task {
            await appState.quickAddTaskFromCommand()
          }
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      }
    }
  }
}
