import SwiftUI

/// Journal section: composer for new entries plus a filterable list of past reflections.
struct JournalSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var newEntryTitle = ""
  @State private var newEntryContent = ""
  @State private var newEntryMood: JournalMood?
  @State private var newEntryTagList: [String] = []
  @State private var tagInputText = ""

  @State private var editingEntry: JournalEntryEntity?
  @State private var datePopoverOpen = false
  @State private var hoveredEntryId: String?
  @FocusState private var newEntryContentFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      composer
      entriesSection
    }
    .sheet(item: $editingEntry) { entry in
      JournalEntryEditorView(entry: entry) { updatedTitle, updatedContent, updatedMood, updatedTags in
        Task {
          await appState.updateJournalEntry(
            id: entry.id,
            title: updatedTitle,
            content: updatedContent,
            mood: updatedMood,
            tags: updatedTags
          )
        }
      }
      .frame(minWidth: 460, minHeight: 380)
    }
  }

  // MARK: Composer

  private var composer: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        TextField("Title (optional)", text: $newEntryTitle)
          .textFieldStyle(.plain)
          .serenityInputField()

        ZStack(alignment: .topLeading) {
          TextEditor(text: $newEntryContent)
            .focused($newEntryContentFocused)
            .serenityTextArea(minHeight: 140)

          if newEntryContent.isEmpty && !newEntryContentFocused {
            Text("What's on your mind?")
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
              .padding(.horizontal, SerenityUI.Spacing.sm)
              .padding(.vertical, SerenityUI.Spacing.sm)
              .allowsHitTesting(false)
          }
        }

        moodPicker

        SerenityTagInputField(tags: $newEntryTagList, inputText: $tagInputText)

        HStack {
          Spacer()
          Button("Save Entry") {
            submitNewEntry()
          }
          .buttonStyle(SerenityPrimaryButtonStyle())
          .disabled(saveDisabled)
          .opacity(saveDisabled ? 0.5 : 1)
        }
      }
    }
  }

  private var moodPicker: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      Text("How are you feeling?")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)

      HStack(spacing: SerenityUI.Spacing.xs) {
        ForEach(journalMoods, id: \.rawValue) { mood in
          Button {
            newEntryMood = (newEntryMood == mood) ? nil : mood
          } label: {
            Text("\(Self.emoji(for: mood))  \(mood.rawValue.capitalized)")
          }
          .buttonStyle(SerenityPillButtonStyle(selected: newEntryMood == mood))
          .accessibilityLabel(mood.rawValue.capitalized)
        }
      }
    }
  }

  private func submitNewEntry() {
    let title = newEntryTitle
    let content = newEntryContent
    let mood = newEntryMood
    let tags = tagsIncludingPendingInput(newEntryTagList, input: tagInputText)

    Task {
      await appState.createJournalEntry(
        title: title,
        content: content,
        mood: mood,
        tags: tags
      )
    }

    newEntryTitle = ""
    newEntryContent = ""
    newEntryMood = nil
    newEntryTagList = []
    tagInputText = ""
  }

  private var saveDisabled: Bool {
    newEntryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: Entries

  private var entriesSection: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader("Entries", subtitle: entryCountLabel) {
        dateRangeChip
      }

      entriesContent
    }
  }

  private var entryCountLabel: String {
    let count = appState.filteredJournalEntries.count
    return "\(count) \(count == 1 ? "entry" : "entries")"
  }

  private var dateRangeChip: some View {
    Button {
      datePopoverOpen.toggle()
    } label: {
      HStack(spacing: SerenityUI.Spacing.xxs) {
        Image(systemName: "calendar")
          .font(.caption)
        Text("Date range")
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
    }
    .buttonStyle(SerenityPillButtonStyle(selected: appState.journalDateRangeEnabled))
    .popover(isPresented: $datePopoverOpen, arrowEdge: .top) {
      SerenityDateRangePicker(
        isEnabled: $appState.journalDateRangeEnabled,
        startDate: $appState.journalRangeStartDate,
        endDate: $appState.journalRangeEndDate,
        onApply: {
          Task { await appState.refreshCoreWorkflowData() }
        },
        onClose: {
          datePopoverOpen = false
        }
      )
    }
  }

  @ViewBuilder
  private var entriesContent: some View {
    if appState.filteredJournalEntries.isEmpty {
      SerenityCard {
        SerenityEmptyState(
          systemImage: "book.closed",
          title: "No entries yet",
          message: "Your reflections will appear here."
        )
        .frame(maxWidth: .infinity)
      }
    } else {
      SerenityCard(padding: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(appState.filteredJournalEntries) { entry in
            entryRow(entry)

            if entry.id != appState.filteredJournalEntries.last?.id {
              Divider()
                .padding(.leading, SerenityUI.Spacing.md)
            }
          }
        }
      }
    }
  }

  private func entryRow(_ entry: JournalEntryEntity) -> some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
      if let mood = entry.mood {
        Text(Self.emoji(for: mood))
          .font(SerenityType.body)
          .frame(width: 24, alignment: .center)
          .accessibilityLabel(mood.rawValue.capitalized)
      }

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        HStack(spacing: SerenityUI.Spacing.xxs) {
          Text(displayTitle(for: entry))
            .font(SerenityType.bodyMedium)
            .foregroundStyle(SerenityPalette.textPrimary)
          if entry.pinned {
            Image(systemName: "pin.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Spacer()
          Text(entry.date, style: .date)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Text(entry.content)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        if !entry.tags.isEmpty {
          SerenityFlowLayout(spacing: SerenityUI.Spacing.xxs) {
            ForEach(entry.tags, id: \.self) { tag in
              SerenityBadge(tag)
            }
          }
        }
      }

      HStack(spacing: SerenityUI.Spacing.xxs) {
        rowAction(systemName: entry.pinned ? "pin.slash" : "pin") {
          Task { await appState.toggleJournalPin(id: entry.id) }
        }
        rowAction(systemName: "pencil") {
          editingEntry = entry
        }
        rowAction(systemName: "trash") {
          Task { await appState.deleteJournalEntry(id: entry.id) }
        }
      }
      .opacity(hoveredEntryId == entry.id ? 1 : 0)
      .animation(.easeOut(duration: 0.12), value: hoveredEntryId)
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.sm)
    .contentShape(Rectangle())
    .onHover { isHovering in
      hoveredEntryId = isHovering ? entry.id : nil
    }
  }

  private func rowAction(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.subheadline)
        .frame(width: 24, height: 24)
        .foregroundStyle(SerenityPalette.textSecondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func displayTitle(for entry: JournalEntryEntity) -> String {
    if let title = entry.title, !title.isEmpty { return title }
    return "Untitled entry"
  }

  private var journalMoods: [JournalMood] {
    [.happy, .neutral, .sad, .excited, .stressed]
  }

  private static func emoji(for mood: JournalMood) -> String {
    switch mood {
    case .happy: return "😊"
    case .neutral: return "😐"
    case .sad: return "😢"
    case .excited: return "✨"
    case .stressed: return "😣"
    }
  }
}
