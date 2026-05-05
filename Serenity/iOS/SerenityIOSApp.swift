import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct SerenityIOSApp: App {
  @UIApplicationDelegateAdaptor(SerenityIOSAppDelegate.self) private var appDelegate
  @StateObject private var appState: AppState

  init() {
    SettingsSyncCoordinator.shared.start()
    _appState = StateObject(wrappedValue: AppState())
  }

  var body: some Scene {
    WindowGroup {
      SerenityAppScene(appState: appState)
        .onAppear {
          appDelegate.appState = appState
          UIApplication.shared.registerForRemoteNotifications()
        }
    }
  }
}

/// Receives CloudKit silent pushes for the SerenityZone subscription on iOS.
final class SerenityIOSAppDelegate: NSObject, UIApplicationDelegate {
  weak var appState: AppState?

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Task { @MainActor in
      appState?.handleICloudRemoteNotification()
      completionHandler(.newData)
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    AppLogger.error("Remote notification registration failed: \(error.localizedDescription)")
  }
}
