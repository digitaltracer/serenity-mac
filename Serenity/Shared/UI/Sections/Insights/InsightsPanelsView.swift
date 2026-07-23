import SwiftUI

/// Insights tab: readiness command center, insight/recap/summary cards, and analysis settings.
struct InsightsPanelsView: View {
  @EnvironmentObject private var appState: AppState

  @State private var insightNoteDrafts: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      commandCenter

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.lg) {
          contentColumn
            .frame(maxWidth: .infinity, alignment: .topLeading)

          sideColumn
            .frame(width: 340, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
          contentColumn
          sideColumn
        }
      }
    }
  }

  // MARK: Command center

  private var commandCenter: some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
        HStack(alignment: .top, spacing: SerenityUI.Spacing.md) {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            HStack(spacing: SerenityUI.Spacing.xs) {
              Image(systemName: hasEnabledCredential ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasEnabledCredential ? .green : .orange)
              Text(hasEnabledCredential ? "Ready to analyze" : "Provider setup required")
                .font(SerenityType.bodyLarge.weight(.semibold))
            }

            Text(appState.aiStatusMessage)
              .font(SerenityType.body)
              .foregroundStyle(SerenityPalette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer()

          Button {
            Task { await appState.refreshAIWorkflows() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        }

        if !hasEnabledCredential {
          SerenityAISetupBanner()
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: SerenityUI.Spacing.xs) {
            generateInsightButton
            recapButton(title: "Weekly Recap", type: .weekly)
            recapButton(title: "Monthly Recap", type: .monthly)
            Divider().frame(height: 28)
            summaryButton(title: "Task Summary", type: .tasks)
            summaryButton(title: "Journal Summary", type: .journal)
            summaryButton(title: "Combined Summary", type: .combined)
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            HStack(spacing: SerenityUI.Spacing.xs) {
              generateInsightButton
              recapButton(title: "Weekly Recap", type: .weekly)
              recapButton(title: "Monthly Recap", type: .monthly)
            }
            HStack(spacing: SerenityUI.Spacing.xs) {
              summaryButton(title: "Task Summary", type: .tasks)
              summaryButton(title: "Journal Summary", type: .journal)
              summaryButton(title: "Combined Summary", type: .combined)
            }
          }
        }
      }
    }
  }

  // MARK: Columns

  private var contentColumn: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      insightsPanel
      recapsPanel
      summariesPanel
    }
  }

  private var sideColumn: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      analysisSettingsPanel
      usagePanel
    }
  }

  private var insightsPanel: some View {
    sectionPanel(title: "Latest Insights", subtitle: "\(appState.aiInsights.count) generated") {
      if appState.aiInsights.isEmpty {
        SerenityEmptyState(
          systemImage: "chart.bar.xaxis",
          title: "No insights yet",
          message: "Generate insights to surface recommendations from your tasks, journal, goals, and projects."
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          ForEach(appState.aiInsights.prefix(12)) { insight in
            insightCard(insight)
          }
        }
      }
    }
  }

  private var recapsPanel: some View {
    sectionPanel(title: "Recaps", subtitle: "\(appState.aiRecaps.count) saved") {
      if appState.aiRecaps.isEmpty {
        SerenityEmptyState(
          systemImage: "calendar.badge.clock",
          title: "No recaps yet",
          message: "Weekly and monthly recaps will appear here after generation."
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          ForEach(appState.aiRecaps.prefix(8)) { recap in
            recapCard(recap)
          }
        }
      }
    }
  }

  private var summariesPanel: some View {
    sectionPanel(title: "Summaries", subtitle: "\(appState.aiSummaries.count) generated") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        if appState.aiSummaries.isEmpty {
          SerenityEmptyState(
            systemImage: "sparkles",
            title: "No summaries yet",
            message: "Task, journal, and combined summaries will be listed here."
          )
          .frame(maxWidth: .infinity)
        } else {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            ForEach(appState.aiSummaries.prefix(10)) { summary in
              summaryCard(summary)
            }
          }
        }

        if let path = appState.lastSummaryExportPath {
          Text("Last export: \(path)")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var analysisSettingsPanel: some View {
    sectionPanel(title: "Analysis Settings", subtitle: "Scope and cadence") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        labeledPicker("Active Provider") {
          SerenityDropdownField(
            placeholder: activeProviderDropdownPlaceholder,
            selection: Binding(
              get: { selectedActiveProviderValue },
              set: { value in
                guard let provider = AICredentialProvider(rawValue: value) else { return }
                Task {
                  await appState.setAIActiveProvider(provider)
                }
              }
            ),
            options: activeProviderDropdownOptions
          )
          .frame(maxWidth: 260, alignment: .leading)
        }

        labeledPicker("Frequency") {
          SerenityDropdownField(
            placeholder: "Frequency",
            selection: Binding(
              get: { appState.aiSettings.analysisFrequency },
              set: { frequency in
                Task { await appState.setAIAnalysisFrequency(frequency) }
              }
            ),
            options: frequencyDropdownOptions
          )
          .frame(maxWidth: 220, alignment: .leading)
        }

        Toggle("Auto analyze", isOn: Binding(
          get: { appState.aiSettings.autoAnalyze },
          set: { enabled in
            Task { await appState.setAIAutoAnalyze(enabled) }
          }
        ))
        .toggleStyle(.switch)

        Divider()

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          Text("Included Data")
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
          dataScopeToggle(title: "Tasks", isOn: appState.aiSettings.dataTypes.includeTasks) { enabled in
            await appState.setAIDataTypes(
              includeTasks: enabled,
              includeJournal: appState.aiSettings.dataTypes.includeJournal,
              includeProjects: appState.aiSettings.dataTypes.includeProjects
            )
          }
          dataScopeToggle(title: "Journal", isOn: appState.aiSettings.dataTypes.includeJournal) { enabled in
            await appState.setAIDataTypes(
              includeTasks: appState.aiSettings.dataTypes.includeTasks,
              includeJournal: enabled,
              includeProjects: appState.aiSettings.dataTypes.includeProjects
            )
          }
          dataScopeToggle(title: "Projects", isOn: appState.aiSettings.dataTypes.includeProjects) { enabled in
            await appState.setAIDataTypes(
              includeTasks: appState.aiSettings.dataTypes.includeTasks,
              includeJournal: appState.aiSettings.dataTypes.includeJournal,
              includeProjects: enabled
            )
          }
        }
      }
    }
  }

  private var usagePanel: some View {
    sectionPanel(title: "Recent Usage", subtitle: "\(appState.aiUsageEntries.count) records") {
      if appState.aiUsageEntries.isEmpty {
        SerenityEmptyState(
          systemImage: "bolt.horizontal",
          title: "No usage records",
          message: "Token usage will appear after AI actions run."
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          ForEach(appState.aiUsageEntries.prefix(8)) { usage in
            HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
              VStack(alignment: .leading, spacing: 2) {
                Text(usage.operation.rawValue.capitalized)
                  .font(SerenityType.bodyMedium)
                Text(usage.provider.rawValue.capitalized)
                  .font(SerenityType.caption)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
              Spacer()
              Text("\(usage.totalTokens) tokens")
                .font(SerenityType.caption)
                .monospacedDigit()
                .foregroundStyle(SerenityPalette.textSecondary)
            }
          }
        }
      }
    }
  }

  // MARK: Actions

  private var generateInsightButton: some View {
    Button {
      Task { await appState.runAIAnalysis() }
    } label: {
      Label("Generate Insights", systemImage: "chart.bar.xaxis")
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .disabled(!hasEnabledCredential)
  }

  private func recapButton(title: String, type: AIRecapType) -> some View {
    Button {
      Task { await appState.generateAIRecap(type: type) }
    } label: {
      Label(title, systemImage: "calendar")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .disabled(!hasEnabledCredential)
  }

  private func summaryButton(title: String, type: SummaryType) -> some View {
    Button {
      Task { await appState.generateAISummary(type: type) }
    } label: {
      Label(title, systemImage: "doc.text")
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
    .disabled(!hasEnabledCredential)
  }

  // MARK: Cards

  private func insightCard(_ insight: AIInsightEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
        Image(systemName: insightIcon(for: insight.type))
          .foregroundStyle(SerenityPalette.accent)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
          HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
            Text(insight.title)
              .font(SerenityType.bodyLarge.weight(.semibold))
            Spacer()
            Text("\(Int(insight.confidence * 100))%")
              .font(SerenityType.caption)
              .monospacedDigit()
              .foregroundStyle(SerenityPalette.textSecondary)
          }

          Text(insight.description)
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: SerenityUI.Spacing.xxs) {
            SerenityBadge(insight.category.rawValue.capitalized)
            SerenityBadge(insight.type.rawValue.capitalized)
            if insight.actionable {
              SerenityBadge("Actionable", tint: SerenityPalette.accent)
            }
          }
        }
      }

      TextField("Notes", text: Binding(
        get: { insightNoteDrafts[insight.id] ?? insight.userNotes ?? "" },
        set: { insightNoteDrafts[insight.id] = $0 }
      ))
      .textFieldStyle(.plain)
      .serenityInputField()

      HStack(spacing: SerenityUI.Spacing.xs) {
        Button("Helpful") {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: insight.userRating,
              dismissed: nil,
              markedHelpful: true,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Dismiss") {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: insight.userRating,
              dismissed: true,
              markedHelpful: nil,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Spacer()

        ratingButtons(for: insight)
      }
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }

  private func ratingButtons(for insight: AIInsightEntity) -> some View {
    HStack(spacing: SerenityUI.Spacing.xxs) {
      ForEach(1...5, id: \.self) { rating in
        Button {
          Task {
            await appState.updateAIInsightFeedback(
              id: insight.id,
              userRating: rating,
              dismissed: nil,
              markedHelpful: nil,
              userNotes: insightNoteDrafts[insight.id]
            )
          }
        } label: {
          Text("\(rating)")
            .font(SerenityType.caption)
            .monospacedDigit()
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(
          RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
            .fill(insight.userRating == rating ? SerenityPalette.activeItemBackground : SerenityPalette.panelBackgroundRaised)
        )
        .overlay(
          RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
            .stroke(insight.userRating == rating ? SerenityPalette.accent.opacity(0.6) : SerenityPalette.thinBorder, lineWidth: 1)
        )
        .accessibilityLabel("Rate \(rating) of 5")
      }
    }
  }

  private func recapCard(_ recap: AIRecapEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
        Text(recap.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
        SerenityBadge(recap.type.rawValue.capitalized)
      }

      Text(recap.summary)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: SerenityUI.Spacing.xs) {
        Button(recap.viewed ? "Viewed" : "Mark viewed") {
          Task { await appState.markRecapViewed(id: recap.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button(recap.favorited ? "Unfavorite" : "Favorite") {
          Task { await appState.toggleRecapFavorite(id: recap.id) }
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.innerCardBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
  }

  private func summaryCard(_ summary: SummaryEntity) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: SerenityUI.Spacing.xs) {
        Text(summary.title)
          .font(SerenityType.bodyLarge.weight(.semibold))
        Spacer()
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
        SerenityBadge(summary.summaryType.rawValue.capitalized)
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

  // MARK: Helpers

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

  private func dataScopeToggle(title: String, isOn: Bool, action: @escaping (Bool) async -> Void) -> some View {
    HStack {
      Text(title)
        .font(SerenityType.bodyMedium)
      Spacer()
      Toggle(title, isOn: Binding(
        get: { isOn },
        set: { enabled in
          Task { await action(enabled) }
        }
      ))
      .toggleStyle(.switch)
      .labelsHidden()
    }
  }

  private func labeledPicker<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      content()
    }
  }

  private func insightIcon(for type: AIInsightType) -> String {
    switch type {
    case .productivity: return "chart.line.uptrend.xyaxis"
    case .behavior: return "waveform.path.ecg"
    case .recommendation: return "lightbulb"
    case .warning: return "exclamationmark.triangle"
    }
  }

  private var hasEnabledCredential: Bool {
    appState.aiCredentials.contains { $0.enabled }
  }

  private var enabledProviderOptions: [AICredentialProvider] {
    AIProviderDropdownAvailability.enabledProviders(from: appState.aiCredentials)
  }

  private var selectedActiveProviderValue: String {
    if let activeProvider = appState.aiSettings.activeProvider,
       enabledProviderOptions.contains(activeProvider) {
      return activeProvider.rawValue
    }

    return enabledProviderOptions.first?.rawValue ?? ""
  }

  private var activeProviderDropdownPlaceholder: String {
    enabledProviderOptions.isEmpty ? "No enabled provider keys" : "Active Provider"
  }

  private var activeProviderDropdownOptions: [SerenityDropdownOption<String>] {
    enabledProviderOptions.map { provider in
      SerenityDropdownOption(
        value: provider.rawValue,
        title: providerTitle(provider),
        systemImage: providerIcon(provider),
        tint: providerTint(provider)
      )
    }
  }

  private var frequencyDropdownOptions: [SerenityDropdownOption<AIAnalysisFrequency>] {
    AIAnalysisFrequency.allCases.map { frequency in
      SerenityDropdownOption(
        value: frequency,
        title: frequency.rawValue.capitalized,
        systemImage: frequency == .manual ? "hand.raised.fill" : "clock.arrow.circlepath",
        tint: frequency == .manual ? .orange : SerenityPalette.accent
      )
    }
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

  private func providerIcon(_ provider: AICredentialProvider) -> String {
    switch provider {
    case .openai:
      return "sparkles"
    case .gemini:
      return "diamond.fill"
    case .anthropic:
      return "brain.head.profile"
    }
  }

  private func providerTint(_ provider: AICredentialProvider) -> Color {
    switch provider {
    case .openai:
      return SerenityPalette.accent
    case .gemini:
      return .purple
    case .anthropic:
      return .orange
    }
  }
}
