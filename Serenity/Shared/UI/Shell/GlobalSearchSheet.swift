import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Cmd+K sheet searching tasks, projects, journal entries, and goals.
struct GlobalSearchSheet: View {
  @EnvironmentObject private var appState: AppState
  @FocusState private var queryFocused: Bool
  @State private var highlightedResultID: String?
  @State private var keyMonitor: Any?

  private var queryBinding: Binding<String> {
    Binding(
      get: { appState.globalSearchQuery },
      set: { appState.setGlobalSearchQuery($0) }
    )
  }

  private var hasSearchQuery: Bool {
    !appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var displayedResults: [GlobalSearchResult] {
    Array(appState.globalSearchResults.prefix(40))
  }

  private var groupedResults: [(GlobalSearchResultType, [GlobalSearchResult])] {
    GlobalSearchResultType.allCases.compactMap { type in
      let matches = displayedResults.filter { $0.type == type }
      guard !matches.isEmpty else { return nil }
      return (type, matches)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      HStack {
        Label("Global Search", systemImage: "magnifyingglass")
          .font(SerenityType.sectionTitle)
        Spacer()
        ShortcutKeycap(text: "Cmd+K")
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(SerenityPalette.textSecondary)
        TextField("Search tasks, projects, journal, or goals", text: queryBinding)
          .textFieldStyle(.plain)
          .focused($queryFocused)
      }
      .serenityInputField()

      if !hasSearchQuery {
        ContentUnavailableView(
          "Start typing to search",
          systemImage: "text.magnifyingglass",
          description: Text("Use keywords, tags, project names, or journal terms.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appState.globalSearchResults.isEmpty {
        ContentUnavailableView(
          "No matches found",
          systemImage: "magnifyingglass",
          description: Text("Try fewer keywords or a broader term.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
            ForEach(groupedResults, id: \.0.id) { type, results in
              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
                Text(type.title.uppercased())
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
                ForEach(results) { result in
                  Button {
                    appState.selectGlobalSearchResult(result)
                  } label: {
                    GlobalSearchResultRow(
                      result: result,
                      isHighlighted: highlightedResultID == result.id
                    )
                  }
                  .buttonStyle(.plain)
                  .onHover { isHovering in
                    guard isHovering else { return }
                    highlightedResultID = result.id
                  }
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(SerenityUI.Spacing.lg)
    .frame(minWidth: 760, minHeight: 560)
    .background(SerenityPalette.windowBackground)
    .onAppear {
      queryFocused = true
      syncHighlightedResult()
      installKeyMonitor()
    }
    .onDisappear {
      removeKeyMonitor()
    }
    .onChange(of: appState.globalSearchResults) { _, _ in
      syncHighlightedResult()
    }
    .onChange(of: appState.globalSearchQuery) { _, _ in
      syncHighlightedResult()
    }
    .onSubmit(of: .text) {
      openHighlightedResult()
    }
  }

  private func syncHighlightedResult() {
    guard hasSearchQuery else {
      highlightedResultID = nil
      return
    }

    guard !displayedResults.isEmpty else {
      highlightedResultID = nil
      return
    }

    if let highlightedResultID,
       displayedResults.contains(where: { $0.id == highlightedResultID }) {
      return
    }

    highlightedResultID = displayedResults.first?.id
  }

  private func moveHighlightedResult(step: Int) {
    guard !displayedResults.isEmpty else {
      highlightedResultID = nil
      return
    }

    guard let selectedResultID = highlightedResultID,
          let currentIndex = displayedResults.firstIndex(where: { $0.id == selectedResultID }) else {
      highlightedResultID = step >= 0 ? displayedResults.first?.id : displayedResults.last?.id
      return
    }

    let nextIndex = (currentIndex + step + displayedResults.count) % displayedResults.count
    highlightedResultID = displayedResults[nextIndex].id
  }

  private func openHighlightedResult() {
    guard let result =
      displayedResults.first(where: { $0.id == highlightedResultID }) ?? displayedResults.first else {
      return
    }

    appState.selectGlobalSearchResult(result)
  }

  private func installKeyMonitor() {
#if os(macOS)
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleKeyDown(event)
    }
#endif
  }

  private func removeKeyMonitor() {
#if os(macOS)
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
#endif
  }

#if os(macOS)
  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard appState.isGlobalSearchPresented else { return event }
    guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else {
      return event
    }

    switch event.keyCode {
    case 125: // Down arrow
      moveHighlightedResult(step: 1)
      return nil
    case 126: // Up arrow
      moveHighlightedResult(step: -1)
      return nil
    case 36: // Return
      openHighlightedResult()
      return nil
    case 53: // Escape
      appState.closeGlobalSearch()
      return nil
    default:
      return event
    }
  }
#endif
}

private struct GlobalSearchResultRow: View {
  let result: GlobalSearchResult
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: SerenityUI.Spacing.sm) {
      Image(systemName: result.type.systemImage)
        .foregroundStyle(SerenityPalette.textSecondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(result.title)
          .font(SerenityType.bodyMedium)
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineLimit(1)
        Text(result.subtitle.isEmpty ? "No additional details" : result.subtitle)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(1)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Text(result.type.title)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(result.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .padding(.horizontal, SerenityUI.Spacing.sm)
    .padding(.vertical, SerenityUI.Spacing.xs)
    .background(
      isHighlighted ? SerenityPalette.activeItemBackground : Color.clear,
      in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
    )
    .contentShape(Rectangle())
  }
}

/// Quiet monospaced chip used for keyboard-shortcut hints.
struct ShortcutKeycap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(SerenityType.caption.monospaced())
      .foregroundStyle(SerenityPalette.textSecondary)
      .padding(.horizontal, SerenityUI.Spacing.xs)
      .padding(.vertical, 3)
      .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.small, style: .continuous))
  }
}
