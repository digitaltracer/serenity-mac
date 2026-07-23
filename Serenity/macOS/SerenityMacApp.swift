import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct SerenityMacApp: App {
  @NSApplicationDelegateAdaptor(SerenityMacAppDelegate.self) private var appDelegate
  @StateObject private var appState: AppState
  @Environment(\.openWindow) private var openWindow

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
    .defaultSize(width: 1280, height: 820)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Quick Capture") {
          openWindow(id: "quick-capture")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(appState.isLockOverlayVisible)

        Divider()

        Button("Global Search") {
          appState.openGlobalSearch()
        }
        .keyboardShortcut("k", modifiers: [.command])

        Button("Help Center") {
          appState.openHelpCenter()
        }
        .keyboardShortcut("/", modifiers: [.command])
      }
    }

    Window("Quick Capture", id: "quick-capture") {
      QuickCapturePanelView()
        .environmentObject(appState)
        .preferredColorScheme(appState.themePreference.colorScheme)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)

    Settings {
      SettingsSectionView()
        .environmentObject(appState)
        .preferredColorScheme(appState.themePreference.colorScheme)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 520, idealHeight: 560)
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
