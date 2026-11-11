import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide shortcut through Carbon's hot key API, which needs no accessibility permission.
final class GlobalHotKey {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let keyCode: UInt32
  private let modifiers: UInt32
  fileprivate let onPress: () -> Void
  fileprivate let onRelease: () -> Void

  init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.onPress = onPress
    self.onRelease = onRelease
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
  }

  @discardableResult
  func register() -> Bool {
    var eventTypes = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let context = Unmanaged.passUnretained(self).toOpaque()
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return noErr }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
          hotKey.onPress()
        } else {
          hotKey.onRelease()
        }
        return noErr
      },
      eventTypes.count,
      &eventTypes,
      context,
      &handlerRef
    )
    guard installed == noErr else { return false }
    let id = EventHotKeyID(signature: OSType(0x5352_4E59), id: 1)
    return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
  }
}

/// Voice capture over whatever app is in front: Option-Space opens a floating panel and starts
/// recording. A second press, or letting go after holding, stops it.
@MainActor
final class VoiceCapturePanelController: NSObject, NSWindowDelegate {
  static let shared = VoiceCapturePanelController()

  /// A press held longer than this counts as hold-to-talk, so letting go ends the recording.
  private static let holdThreshold: TimeInterval = 0.6

  private weak var appState: AppState?
  private var panel: NSPanel?
  private var hotKey: GlobalHotKey?
  private var pressedAt: Date?

  func install(appState: AppState) {
    self.appState = appState
    guard hotKey == nil else { return }
    let hotKey = GlobalHotKey(
      keyCode: UInt32(kVK_Space),
      modifiers: UInt32(optionKey),
      onPress: { Task { @MainActor in VoiceCapturePanelController.shared.hotKeyPressed() } },
      onRelease: { Task { @MainActor in VoiceCapturePanelController.shared.hotKeyReleased() } }
    )
    if hotKey.register() {
      self.hotKey = hotKey
    } else {
      AppLogger.error("Voice capture: Option-Space is taken by another app.")
    }
  }

  func show() {
    guard let appState else { return }
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      return
    }

    let root = VoiceCaptureView { [weak self] in
      self?.close()
    }
    .environmentObject(appState)
    .tint(SerenityPalette.accent)
    .foregroundStyle(SerenityPalette.textPrimary)

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.appearance = Self.appearance(for: appState.themePreference)
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentView = hosting
    panel.delegate = self
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
  }

  func close() {
    panel?.close()
    panel = nil
  }

  func windowWillClose(_ notification: Notification) {
    panel = nil
  }

  private func hotKeyPressed() {
    pressedAt = Date()
    if panel == nil {
      show()
    } else {
      NotificationCenter.default.post(name: .voiceCaptureFinishRequested, object: nil)
    }
  }

  private func hotKeyReleased() {
    defer { pressedAt = nil }
    guard let pressedAt, Date().timeIntervalSince(pressedAt) > Self.holdThreshold else { return }
    NotificationCenter.default.post(name: .voiceCaptureFinishRequested, object: nil)
  }

  private static func appearance(for theme: AppThemePreference) -> NSAppearance? {
    switch theme {
    case .system:
      return nil
    case .light:
      return NSAppearance(named: .aqua)
    case .dark, .trueBlack:
      return NSAppearance(named: .darkAqua)
    }
  }
}
