import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct SerenityMacApp: App {
  @NSApplicationDelegateAdaptor(SerenityMacAppDelegate.self) private var appDelegate
  @StateObject private var appState: AppState

  init() {
    DotEnv.loadIfPresent()
    SettingsSyncCoordinator.shared.start()
    _appState = StateObject(wrappedValue: AppState())
  }

  var body: some Scene {
    WindowGroup {
      SerenityAppScene(appState: appState)
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
          appDelegate.appState = appState
          NSApplication.shared.registerForRemoteNotifications()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1280, height: 820)
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

/// Receives CloudKit silent pushes for the SerenityZone subscription and
/// forwards them to AppState so the engine can pull deltas.
final class SerenityMacAppDelegate: NSObject, NSApplicationDelegate {
  weak var appState: AppState?

  func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
    Task { @MainActor in
      appState?.handleICloudRemoteNotification()
    }
  }

  func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    AppLogger.error("Remote notification registration failed: \(error.localizedDescription)")
  }
}
