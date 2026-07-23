import SwiftUI

/// Summaries tab: date-range generate card, the summary library, and scope metrics.
struct AISummariesSectionView: View {
  @EnvironmentObject private var appState: AppState

  private enum SummaryFilter: String, CaseIterable, Identifiable {
    case all
    case tasks
    case journal
    case combined

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: return "All"
      case .tasks: return "Tasks"
      case .journal: return "Journal"
      case .combined: return "Combined"
      }
    }
  }

  @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
  @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
  @State private var dateRangeEnabled = true
  @State private var datePopoverOpen = false
  @State private var includeTasks = true
  @State private var includeJournal = true
  @State private var filter: SummaryFilter = .all

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      generateCard

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.lg) {
          summariesPanel
            .frame(maxWidth: .infinity, alignment: .topLeading)
          sidePanel
            .frame(width: 320, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
          summariesPanel
          sidePanel
        }
      }
    }
  }

  // MARK: Generate

  private var generateCard: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
            Text("Generate Summary")
              .font(SerenityType.sectionTitle)
            Text("Create a focused recap for the selected period and sources.")
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          Spacer()

          dateRangeButton
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: SerenityUI.Spacing.xs) {
            presetButton(title: "Last 7 Days", days: 7)
            presetButton(title: "Last 30 Days", days: 30)
            presetButton(title: "Last 3 Months", days: 90)
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            presetButton(title: "Last 7 Days", days: 7)
            presetButton(title: "Last 30 Days", days: 30)
            presetButton(title: "Last 3 Months", days: 90)
          }
        }

        HStack(alignment: .top, spacing: SerenityUI.Spacing.md) {
          summaryScopeCard(
            title: "Period",
            value: dateRangeLabel,
            icon: "calendar",
            detail: "\(dayCount) day\(dayCount == 1 ? "" : "s") selected"
          )

          summaryScopeCard(
            title: "Sources",
            value: selectedSourceTitle,
            icon: "tray.full",
            detail: "\(selectedTaskCount) task\(selectedTaskCount == 1 ? "" : "s") and \(selectedJournalCount) journal entr\(selectedJournalCount == 1 ? "y" : "ies")"
          )
        }

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          Text("Include")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          HStack(spacing: SerenityUI.Spacing.xs) {
            includeToggle(title: "Tasks", systemImage: "checklist", isOn: $includeTasks)
            includeToggle(title: "Journal", systemImage: "book", isOn: $includeJournal)
          }
        }

        if !isAIConfigured {
          SerenityAISetupBanner()
        }

        Button {
          Task { await generate() }
        } label: {
          HStack(spacing: SerenityUI.Spacing.xs) {
            Image(systemName: "sparkles")
            Text("Generate Summary")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, SerenityUI.Spacing.xxs)
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
        .disabled(!isAIConfigured || resolvedSummaryType == nil)
      }
    }
  }

  private var dateRangeButton: some View {
    Button {
      datePopoverOpen.toggle()
    } label: {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "calendar")
        VStack(alignment: .leading, spacing: 2) {
          Text("Summary Period")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          Text(dateRangeLabel)
            .font(SerenityType.bodyMedium)
        }
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
      }
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .popover(isPresented: $datePopoverOpen, arrowEdge: .top) {
      SerenityDateRangePicker(
        isEnabled: $dateRangeEnabled,
        startDate: $startDate,
        endDate: $endDate,
        title: "Summary period",
        showsEnableToggle: false,
        onApply: normalizeDateRange,
        onClose: {
          normalizeDateRange()
          datePopoverOpen = false
        }
      )
    }
  }

  // MARK: Library

  private var summariesPanel: some View {
    sectionPanel(title: "Your Summaries", subtitle: "\(filteredSummaries.count) shown") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: SerenityUI.Spacing.sm) {
            summaryLibraryContext
            Spacer()
            filterPicker
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
            summaryLibraryContext
            filterPicker
          }
        }

        summariesList
      }
    }
  }

  private var summaryLibraryContext: some View {
    Text("Browse generated summaries by type and export the ones you want to keep.")
      .font(SerenityType.body)
      .foregroundStyle(SerenityPalette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $filter) {
      ForEach(SummaryFilter.allCases) { option in
        Text(option.title).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 320)
  }

  private var sidePanel: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      sectionPanel(title: "Current Scope", subtitle: resolvedSummaryType?.rawValue.capitalized ?? "Incomplete") {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
          summaryMetricRow(title: "Period", value: dateRangeLabel)
          summaryMetricRow(title: "Tasks", value: "\(selectedTaskCount)")
          summaryMetricRow(title: "Journal entries", value: "\(selectedJournalCount)")
          summaryMetricRow(title: "Saved summaries", value: "\(appState.aiSummaries.count)")
        }
      }

      sectionPanel(title: "Provider", subtitle: isAIConfigured ? "Ready" : "Required") {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
          Circle()
            .fill(isAIConfigured ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .padding(.top, 5)

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
            Text(isAIConfigured ? "AI provider configured" : "AI provider not configured")
              .font(SerenityType.bodyMedium)
            Text(isAIConfigured ? "Summaries can be generated for the selected scope." : "Configure a provider key before generating summaries.")
              .font(SerenityType.caption)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if let path = appState.lastSummaryExportPath {
        sectionPanel(title: "Last Export") {
          Text(path)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }

  @ViewBuilder
  private var summariesList: some View {
    if filteredSummaries.isEmpty {
      SerenityEmptyState(
        systemImage: "sparkles",
        title: "No summaries yet",
        message: "Generate your first summary using the controls above."
      )
      .frame(maxWidth: .infinity)
    } else {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        ForEach(filteredSummaries) { summary in
          summaryRow(summary)
        }
      }
    }
  }

  private func summaryRow(_ summary: SummaryEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
        Text(summary.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        SerenityBadge(summary.summaryType.rawValue.capitalized)
        Text("\(summary.wordCount) words")
          .font(SerenityType.caption)
          .monospacedDigit()
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Text(summary.content)
        .lineLimit(3)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)

      HStack(spacing: SerenityUI.Spacing.xs) {
        Label(summaryDateLabel(summary), systemImage: "calendar")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        Spacer()

        Button("Export") {
          Task { await appState.exportAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Delete", role: .destructive) {
          Task { await appState.deleteAISummary(id: summary.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }

  // MARK: Controls

  private func presetButton(title: String, days: Int) -> some View {
    Button {
      let end = Calendar.current.startOfDay(for: Date())
      let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
      startDate = start
      endDate = end
    } label: {
      HStack(spacing: SerenityUI.Spacing.xxs) {
        Image(systemName: "calendar")
        Text(title)
      }
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
  }

  private func includeToggle(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
    Button {
      isOn.wrappedValue.toggle()
    } label: {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(SerenityPillButtonStyle(selected: isOn.wrappedValue))
  }

  private func summaryScopeCard(title: String, value: String, icon: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
      Image(systemName: icon)
        .foregroundStyle(SerenityPalette.accent)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(value)
          .font(SerenityType.bodyMedium)
        Text(detail)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(2)
      }
      Spacer()
    }
    .padding(SerenityUI.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }

  private func sectionPanel<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      SerenitySectionHeader(title) {
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(SerenityPalette.textSecondary)
        }
      }

      SerenityCard {
        content()
      }
    }
  }

  private func summaryMetricRow(title: String, value: String) -> some View {
    SerenityStatRow(title, value: value)
  }

  // MARK: Derived state

  private var filteredSummaries: [SummaryEntity] {
    switch filter {
    case .all: return appState.aiSummaries
    case .tasks: return appState.aiSummaries.filter { $0.summaryType == .tasks }
    case .journal: return appState.aiSummaries.filter { $0.summaryType == .journal }
    case .combined: return appState.aiSummaries.filter { $0.summaryType == .combined }
    }
  }

  private var selectedTaskCount: Int {
    tasksInRange.count
  }

  private var selectedJournalCount: Int {
    journalEntriesInRange.count
  }

  private var tasksInRange: [TaskEntity] {
    let calendar = Calendar.current
    let rangeStart = calendar.startOfDay(for: startDate)
    let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
    return appState.tasks.filter { task in
      let taskDate = task.completedAt ?? task.dueDate ?? task.updatedAt
      return taskDate >= rangeStart && taskDate < rangeEnd
    }
  }

  private var journalEntriesInRange: [JournalEntryEntity] {
    let calendar = Calendar.current
    let rangeStart = calendar.startOfDay(for: startDate)
    let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
    return appState.journalEntries.filter { entry in
      let entryDate = calendar.startOfDay(for: entry.date)
      return entryDate >= rangeStart && entryDate < rangeEnd
    }
  }

  private var isAIConfigured: Bool {
    appState.aiCredentials.contains { $0.enabled }
  }

  private var resolvedSummaryType: SummaryType? {
    switch (includeTasks, includeJournal) {
    case (true, true): return .combined
    case (true, false): return .tasks
    case (false, true): return .journal
    case (false, false): return nil
    }
  }

  private var selectedSourceTitle: String {
    switch resolvedSummaryType {
    case .tasks: return "Tasks"
    case .journal: return "Journal"
    case .combined: return "Tasks and journal"
    case nil: return "Choose a source"
    }
  }

  private var dateRangeLabel: String {
    "\(startDate.formatted(.dateTime.month(.abbreviated).day())) - \(endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
  }

  private var dayCount: Int {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.startOfDay(for: endDate)
    return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
  }

  private func summaryDateLabel(_ summary: SummaryEntity) -> String {
    "\(summary.startDate.formatted(.dateTime.month(.abbreviated).day())) - \(summary.endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
  }

  private func normalizeDateRange() {
    let calendar = Calendar.current
    let normalizedStart = calendar.startOfDay(for: startDate)
    let normalizedEnd = calendar.startOfDay(for: endDate)
    if normalizedEnd < normalizedStart {
      startDate = normalizedEnd
      endDate = normalizedStart
    } else {
      startDate = normalizedStart
      endDate = normalizedEnd
    }
  }

  private func generate() async {
    guard let type = resolvedSummaryType else { return }
    normalizeDateRange()
    await appState.generateAISummary(type: type, startDate: startDate, endDate: endDate)
  }
}
