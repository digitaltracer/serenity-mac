import SwiftUI

/// Quick Capture window content: free-text capture with optional AI
/// classification. Native parsing creates a task (or a journal entry with the
/// "journal:" prefix); an AI provider returns a preview to confirm.
struct QuickCapturePanelView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""
  @State private var submitting = false
  @State private var editorFocused = false
  @State private var selectedCredentialID = ""

  private static let nativeProviderID = "native"
  private static let previewDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    Group {
      if appState.isLockOverlayVisible {
        SerenityEmptyState(
          systemImage: "lock.fill",
          title: "Serenity is locked",
          message: "Unlock the main window to capture."
        )
        .frame(width: 480, height: 200)
      } else {
        content
      }
    }
    .onDisappear {
      appState.discardPendingAIQuickCapturePreview()
    }
  }

  private var content: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text("Capture a task… or start with journal: for an entry")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary.opacity(0.7))
            .allowsHitTesting(false)
        }

        QuickCaptureEditor(text: $text, isFocused: $editorFocused, fontSize: 14)
          .frame(minHeight: 84, maxHeight: 180)
      }
      .padding(SerenityUI.Spacing.md)

      if let preview = appState.pendingAIQuickCapturePreview {
        Divider()
        previewSection(preview)
          .padding(SerenityUI.Spacing.md)
      }

      Divider()
      footer
    }
    .frame(width: 480)
    .onAppear {
      editorFocused = true
    }
  }

  private var footer: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      providerPicker
        .disabled(hasPendingPreview)

      Spacer()

      Button("Cancel") {
        if hasPendingPreview {
          appState.discardPendingAIQuickCapturePreview()
        } else {
          dismiss()
        }
      }
      .keyboardShortcut(.cancelAction)
      .buttonStyle(SerenitySecondaryButtonStyle())

      Button(primaryButtonTitle) {
        Task {
          if hasPendingPreview {
            await savePendingPreview()
          } else {
            await submit()
          }
        }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .buttonStyle(SerenityPrimaryButtonStyle())
      .disabled(submitting || (!hasPendingPreview && trimmedText.isEmpty))
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.sm)
  }

  private var providerPicker: some View {
    Picker("Provider", selection: providerSelection) {
      Label("On-device", systemImage: "macwindow")
        .tag(Self.nativeProviderID)
      ForEach(enabledCredentials) { credential in
        Text("\(providerTitle(credential.provider)) · \(credential.name)")
          .tag(credential.id)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel("Capture provider")
  }

  // MARK: - AI preview

  private func previewSection(_ preview: AIQuickCapturePreview) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .firstTextBaseline) {
        Label(previewTitle(for: preview.classification), systemImage: "sparkles")
          .font(SerenityType.bodyMedium)
        Spacer()
        Text("\(Int(preview.classification.confidence * 100))% confident")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      switch preview.classification.kind {
      case .tasks:
        ForEach(preview.classification.tasks) { task in
          taskPreviewRow(task)
        }
      case .journal:
        if let journal = preview.classification.journal {
          journalPreview(journal)
        }
      }
    }
  }

  private func taskPreviewRow(_ task: AIQuickCaptureTaskDraft) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(SerenityPalette.accent)
        Text(task.title)
          .font(SerenityType.body)
          .lineLimit(2)
        Spacer()
        SerenityBadge(task.priority.rawValue.capitalized)
      }

      let metadata = taskMetadata(task)
      if !metadata.isEmpty {
        Text(metadata.joined(separator: " · "))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
      }
    }
    .padding(SerenityUI.Spacing.xs)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous))
  }

  private func journalPreview(_ journal: AIQuickCaptureJournalDraft) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let title = journal.title, !title.isEmpty {
        Text(title)
          .font(SerenityType.bodyMedium)
      }

      Text(journal.content)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(5)

      let metadata = journalMetadata(journal)
      if !metadata.isEmpty {
        Text(metadata.joined(separator: " · "))
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .padding(SerenityUI.Spacing.xs)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous))
  }

  // MARK: - Actions

  private func submit() async {
    let input = trimmedText
    guard !input.isEmpty else { return }

    submitting = true
    defer { submitting = false }

    if let credential = selectedCredential {
      let saved = await appState.submitAIQuickCapture(input: input, credentialID: credential.id)
      if saved {
        text = ""
        dismiss()
      }
      return
    }

    appState.discardPendingAIQuickCapturePreview()

    if input.lowercased().hasPrefix("journal:") {
      let content = input.replacingOccurrences(of: "journal:", with: "", options: [.caseInsensitive])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      await appState.createJournalEntry(
        title: "",
        content: content.isEmpty ? input : content,
        mood: nil,
        tags: []
      )
    } else {
      await appState.createTask(
        title: input,
        priority: .medium,
        dueDate: nil,
        tags: [],
        subtaskTitles: []
      )
    }

    text = ""
    await appState.refreshCoreWorkflowData()
    dismiss()
  }

  private func savePendingPreview() async {
    submitting = true
    defer { submitting = false }

    let saved = await appState.savePendingAIQuickCapturePreview()
    if saved {
      text = ""
      dismiss()
    }
  }

  // MARK: - Provider selection

  private var providerSelection: Binding<String> {
    Binding(
      get: { resolvedCredentialID },
      set: { credentialID in
        selectedCredentialID = credentialID
        guard credentialID != Self.nativeProviderID else {
          Task {
            await appState.setAIActiveProvider(nil)
          }
          return
        }
        guard let credential = enabledCredentials.first(where: { $0.id == credentialID }) else { return }
        Task {
          await appState.setAIActiveProvider(credential.provider)
        }
      }
    )
  }

  private var resolvedCredentialID: String {
    if selectedCredentialID == Self.nativeProviderID {
      return Self.nativeProviderID
    }

    if enabledCredentials.contains(where: { $0.id == selectedCredentialID }) {
      return selectedCredentialID
    }

    if let activeProvider = appState.aiSettings.activeProvider,
       let activeCredential = enabledCredentials.first(where: { $0.provider == activeProvider }) {
      return activeCredential.id
    }

    return enabledCredentials.first?.id ?? Self.nativeProviderID
  }

  private var selectedCredential: AICredentialEntity? {
    enabledCredentials.first { $0.id == resolvedCredentialID }
  }

  private var enabledCredentials: [AICredentialEntity] {
    appState.aiCredentials
      .filter(\.enabled)
      .sorted { lhs, rhs in
        if lhs.priority == rhs.priority {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.priority < rhs.priority
      }
  }

  // MARK: - Helpers

  private var hasPendingPreview: Bool {
    appState.pendingAIQuickCapturePreview != nil
  }

  private var primaryButtonTitle: String {
    if hasPendingPreview {
      return submitting ? "Saving…" : "Save"
    }
    return submitting ? "Capturing…" : "Capture"
  }

  private var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func previewTitle(for classification: AIQuickCaptureClassification) -> String {
    switch classification.kind {
    case .tasks:
      return "Review \(classification.tasks.count) task\(classification.tasks.count == 1 ? "" : "s")"
    case .journal:
      return "Review journal entry"
    }
  }

  private func taskMetadata(_ task: AIQuickCaptureTaskDraft) -> [String] {
    var metadata: [String] = []
    if let dueDate = task.dueDate {
      metadata.append(Self.previewDateFormatter.string(from: dueDate))
    }
    if let projectID = task.projectId,
       let project = appState.projects.first(where: { $0.id == projectID }) {
      metadata.append(project.name)
    }
    if !task.tags.isEmpty {
      metadata.append(task.tags.map { "#\($0)" }.joined(separator: " "))
    }
    if !task.subtasks.isEmpty {
      metadata.append("\(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s")")
    }
    return metadata
  }

  private func journalMetadata(_ journal: AIQuickCaptureJournalDraft) -> [String] {
    var metadata: [String] = []
    if let mood = journal.mood {
      metadata.append(mood.rawValue.capitalized)
    }
    if !journal.tags.isEmpty {
      metadata.append(journal.tags.map { "#\($0)" }.joined(separator: " "))
    }
    return metadata
  }

  private func providerTitle(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "OpenAI"
    case .gemini:
      return "Gemini"
    case .anthropic:
      return "Anthropic"
    }
  }
}
