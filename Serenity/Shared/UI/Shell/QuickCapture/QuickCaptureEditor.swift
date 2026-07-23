import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Borderless multiline capture editor shared by the quick-capture surfaces.
#if os(macOS)
final class QuickCaptureTextView: NSTextView {
  var focusChanged: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      focusChanged?(true)
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      focusChanged?(false)
    }
    return accepted
  }
}

final class QuickCaptureContainerScrollView: NSScrollView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .iBeam)
  }

  override func mouseDown(with event: NSEvent) {
    if let textView = documentView as? NSTextView {
      window?.makeFirstResponder(textView)
    }
    super.mouseDown(with: event)
  }
}

struct QuickCaptureEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let fontSize: CGFloat

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = QuickCaptureContainerScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.backgroundColor = .clear

    let textView = QuickCaptureTextView()
    textView.delegate = context.coordinator
    textView.focusChanged = { focused in
      if context.coordinator.isFocused != focused {
        context.coordinator.isFocused = focused
      }
    }
    textView.string = text
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFindBar = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.isContinuousSpellCheckingEnabled = true
    textView.textContainerInset = NSSize(width: 0, height: 0)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
    textView.font = .systemFont(ofSize: SerenityType.scaledSize(fontSize), weight: .regular)
    textView.textColor = NSColor(SerenityPalette.textPrimary)
    textView.insertionPointColor = NSColor(SerenityPalette.textPrimary)
    textView.typingAttributes[.foregroundColor] = NSColor(SerenityPalette.textPrimary)

    scrollView.documentView = textView
    context.coordinator.textView = textView

    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? QuickCaptureTextView else { return }

    let contentSize = nsView.contentView.bounds.size
    let targetHeight = max(contentSize.height, textView.frame.height)
    if textView.frame.width != contentSize.width || textView.frame.height < contentSize.height {
      textView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: targetHeight)
    }
    textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

    if textView.string != text {
      textView.string = text
    }

    textView.font = .systemFont(ofSize: SerenityType.scaledSize(fontSize), weight: .regular)
    textView.textColor = NSColor(SerenityPalette.textPrimary)
    textView.insertionPointColor = NSColor(SerenityPalette.textPrimary)
    textView.typingAttributes[.foregroundColor] = NSColor(SerenityPalette.textPrimary)

    if isFocused {
      if nsView.window?.firstResponder !== textView {
        nsView.window?.makeFirstResponder(textView)
      }
    } else if nsView.window?.firstResponder === textView {
      nsView.window?.makeFirstResponder(nil)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var isFocused: Bool
    weak var textView: QuickCaptureTextView?

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      text = textView.string
    }

    func textDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
      isFocused = false
    }
  }
}
#else
struct QuickCaptureEditor: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  let fontSize: CGFloat

  @FocusState private var editorFocused: Bool

  var body: some View {
    TextEditor(text: $text)
      .font(SerenityType.scaledSystem(size: fontSize, weight: .regular))
      .foregroundStyle(SerenityPalette.textPrimary)
      .scrollContentBackground(.hidden)
      .focused($editorFocused)
      .onAppear {
        editorFocused = isFocused
      }
      .onChange(of: editorFocused) { _, newValue in
        isFocused = newValue
      }
      .onChange(of: isFocused) { _, newValue in
        editorFocused = newValue
      }
  }
}
#endif
