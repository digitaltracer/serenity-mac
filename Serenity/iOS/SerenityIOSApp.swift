import SwiftUI

@main
struct SerenityIOSApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      SerenityAppScene(appState: appState)
    }
  }
}
