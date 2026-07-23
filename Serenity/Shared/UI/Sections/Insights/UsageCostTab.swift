import Charts
import SwiftUI

/// Usage & Cost tab: token/cost metrics, spend charts, usage tables, and the model rate editor.
struct CostCenterSectionView: View {
  @EnvironmentObject private var appState: AppState

  @State private var selectedWindow: CostWindow = .thirtyDays
  @State private var rateProvider: AIUsageProvider = .openai
  @State private var rateModel = ""
  @State private var inputRate = 0.0
  @State private var outputRate = 0.0
  @State private var refreshingLiteLLM = false

  private enum CostWindow: String, CaseIterable, Identifiable {
    case sevenDays = "Last 7 days"
    case fourteenDays = "Last 14 days"
    case thirtyDays = "Last 30 days"
    case all = "All time"

    var id: String { rawValue }

    var segmentTitle: String {
      switch self {
      case .sevenDays: return "7 Days"
      case .fourteenDays: return "14 Days"
      case .thirtyDays: return "30 Days"
      case .all: return "All Time"
      }
    }

    var cutoffDate: Date? {
      switch self {
      case .sevenDays:
        Calendar.current.date(byAdding: .day, value: -7, to: Date())
      case .fourteenDays:
        Calendar.current.date(byAdding: .day, value: -14, to: Date())
      case .thirtyDays:
        Calendar.current.date(byAdding: .day, value: -30, to: Date())
      case .all:
        nil
      }
    }
  }

  private struct BreakdownRow: Identifiable {
    let id: String
    let label: String
    let calls: Int
    let tokens: Int
    let cost: Double
  }

  private var filteredUsage: [AIUsageEntity] {
    guard let cutoff = selectedWindow.cutoffDate else {
      return appState.aiUsageEntries
    }
    return appState.aiUsageEntries.filter { $0.timestamp >= cutoff }
  }

  private var sortedRates: [AIModelRateEntity] {
    appState.aiModelRates.sorted {
      if $0.provider == $1.provider {
        return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
      }
      return $0.provider.rawValue < $1.provider.rawValue
    }
  }

  private var totalTokens: Int {
    filteredUsage.reduce(0) { $0 + $1.totalTokens }
  }

  private var totalCost: Double {
    filteredUsage.reduce(0) { $0 + ($1.totalCostUSD ?? 0) }
  }

  private var missingRateRows: [AIUsageEntity] {
    filteredUsage.filter { $0.totalTokens > 0 && $0.totalCostUSD == nil }
  }

  private var providerBreakdown: [BreakdownRow] {
    groupedBreakdown { providerTitle($0.provider) }
  }

  private var operationBreakdown: [BreakdownRow] {
    groupedBreakdown { $0.operation.rawValue.capitalized }
  }

  private var modelBreakdown: [BreakdownRow] {
    groupedBreakdown { normalizedModel($0.model) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
      controlsRow
      summaryCards
      spendPanels
      modelBreakdownPanel
      recentUsagePanel
      missingRatesPanel
      rateEditorPanel
    }
    .task {
      await appState.refreshAIWorkflows()
    }
  }

  // MARK: Controls

  private var controlsRow: some View {
    HStack(alignment: .center, spacing: SerenityUI.Spacing.sm) {
      Picker("Time window", selection: $selectedWindow) {
        ForEach(CostWindow.allCases) { window in
          Text(window.segmentTitle).tag(window)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 380)

      Spacer()

      Button {
        Task { await appState.refreshAIWorkflows() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
    }
  }

  // MARK: Metrics

  private var summaryCards: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
        metricCard(title: "Total Tokens", value: formatTokens(totalTokens), icon: "number", tint: .blue)
        metricCard(title: "Estimated Cost", value: formatUSD(totalCost), icon: "dollarsign.circle.fill", tint: .green)
        metricCard(title: "API Calls", value: "\(filteredUsage.count)", icon: "waveform.path.ecg", tint: .orange)
        metricCard(title: "Missing Rates", value: "\(missingRateKeys.count)", icon: "exclamationmark.triangle.fill", tint: missingRateKeys.isEmpty ? SerenityPalette.textSecondary : .orange)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SerenityUI.Spacing.sm) {
        metricCard(title: "Total Tokens", value: formatTokens(totalTokens), icon: "number", tint: .blue)
        metricCard(title: "Estimated Cost", value: formatUSD(totalCost), icon: "dollarsign.circle.fill", tint: .green)
        metricCard(title: "API Calls", value: "\(filteredUsage.count)", icon: "waveform.path.ecg", tint: .orange)
        metricCard(title: "Missing Rates", value: "\(missingRateKeys.count)", icon: "exclamationmark.triangle.fill", tint: missingRateKeys.isEmpty ? SerenityPalette.textSecondary : .orange)
      }
    }
  }

  private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        HStack(spacing: SerenityUI.Spacing.xxs) {
          Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(tint)
          Text(title)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
        }

        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }

  // MARK: Charts

  private var spendPanels: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
        chartPanel(title: "Spend by Provider", rows: providerBreakdown, chart: .bar)
        chartPanel(title: "Spend by Operation", rows: operationBreakdown, chart: .sector)
      }
      VStack(spacing: SerenityUI.Spacing.sm) {
        chartPanel(title: "Spend by Provider", rows: providerBreakdown, chart: .bar)
        chartPanel(title: "Spend by Operation", rows: operationBreakdown, chart: .sector)
      }
    }
  }

  private enum ChartKind {
    case bar
    case sector
  }

  private func chartPanel(title: String, rows: [BreakdownRow], chart: ChartKind) -> some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        Text(title)
          .font(.headline)

        if rows.isEmpty {
          emptyPanelText("No usage in \(selectedWindow.rawValue.lowercased()).")
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if chart == .bar {
          Chart(rows) { row in
            BarMark(
              x: .value("Category", row.label),
              y: .value("Cost", row.cost)
            )
            .cornerRadius(SerenityUI.Radius.small)
            .foregroundStyle(by: .value("Category", row.label))
          }
          .chartYAxis {
            AxisMarks(position: .leading)
          }
          .frame(height: 180)
        } else {
          Chart(rows) { row in
            SectorMark(
              angle: .value("Cost", row.cost),
              innerRadius: .ratio(0.55),
              angularInset: 2
            )
            .foregroundStyle(by: .value("Operation", row.label))
          }
          .chartLegend(position: .bottom, alignment: .center, spacing: SerenityUI.Spacing.xs)
          .frame(height: 180)
        }
      }
    }
  }

  // MARK: Tables

  private var modelBreakdownPanel: some View {
    tablePanel(title: "Breakdown by Model") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        modelHeader
        Divider()
        if modelBreakdown.isEmpty {
          emptyPanelText("No model usage in \(selectedWindow.rawValue.lowercased()).")
            .padding(.vertical, SerenityUI.Spacing.sm)
        } else {
          ForEach(modelBreakdown.prefix(12)) { row in
            HStack(spacing: SerenityUI.Spacing.xs) {
              Text(row.label)
                .font(SerenityType.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("\(row.calls)")
                .font(SerenityType.caption)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
              Text(formatTokens(row.tokens))
                .font(SerenityType.caption)
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
              Text(formatUSD(row.cost))
                .font(SerenityType.caption)
                .monospacedDigit()
                .frame(width: 108, alignment: .trailing)
            }
            Divider()
          }
        }
      }
    }
  }

  private var modelHeader: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Calls").frame(width: 64, alignment: .trailing)
      Text("Tokens").frame(width: 96, alignment: .trailing)
      Text("Cost").frame(width: 108, alignment: .trailing)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  private var recentUsagePanel: some View {
    tablePanel(title: "Recent Usage Log") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        recentUsageHeader
        Divider()
        if filteredUsage.isEmpty {
          emptyPanelText("AI calls will appear here after usage is recorded.")
            .padding(.vertical, SerenityUI.Spacing.sm)
        } else {
          ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(filteredUsage.prefix(24))) { row in
                HStack(spacing: SerenityUI.Spacing.xs) {
                  Text(formatDate(row.timestamp))
                    .font(SerenityType.caption)
                    .frame(width: 124, alignment: .leading)
                  Text(providerTitle(row.provider))
                    .font(SerenityType.caption)
                    .frame(width: 82, alignment: .leading)
                  Text(normalizedModel(row.model))
                    .font(SerenityType.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  Text(row.operation.rawValue.capitalized)
                    .font(SerenityType.caption)
                    .frame(width: 84, alignment: .leading)
                  Text(formatTokens(row.totalTokens))
                    .font(SerenityType.caption)
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
                  Text(row.totalCostUSD.map(formatUSD) ?? "N/A")
                    .font(SerenityType.caption)
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 7)
                Divider()
              }
            }
          }
          .frame(maxHeight: 360)
        }
      }
    }
  }

  private var recentUsageHeader: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Text("Time").frame(width: 124, alignment: .leading)
      Text("Provider").frame(width: 82, alignment: .leading)
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Operation").frame(width: 84, alignment: .leading)
      Text("Tokens").frame(width: 90, alignment: .trailing)
      Text("Cost").frame(width: 84, alignment: .trailing)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  // MARK: Missing rates

  @ViewBuilder
  private var missingRatesPanel: some View {
    if !missingRateKeys.isEmpty {
      SerenityCard {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
          HStack(alignment: .center, spacing: SerenityUI.Spacing.xs) {
            Label("Missing pricing for \(missingRateKeys.count) model\(missingRateKeys.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
              .font(.headline)
              .foregroundStyle(.orange)
            Spacer()
            Button {
              Task { await refreshLiteLLM() }
            } label: {
              Label(refreshingLiteLLM ? "Refreshing" : "Fetch LiteLLM Prices", systemImage: "arrow.down.circle")
            }
            .buttonStyle(SerenitySecondaryButtonStyle())
            .disabled(refreshingLiteLLM)
          }

          Text("These rows keep their token counts, but cost is unavailable until a matching provider/model rate exists.")
            .font(SerenityType.body)
            .foregroundStyle(SerenityPalette.textSecondary)

          SerenityFlowLayout(spacing: SerenityUI.Spacing.xs) {
            ForEach(missingRateKeys, id: \.self) { key in
              SerenityBadge(key)
            }
          }
        }
      }
    }
  }

  // MARK: Rate editor

  private var rateEditorPanel: some View {
    tablePanel(title: "Provider Cost Table (USD per 1M tokens)") {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        rateForm

        HStack {
          Spacer()
          Button {
            Task { await appState.resetAIModelRatesToDefaults() }
          } label: {
            Label("Reset Defaults", systemImage: "arrow.counterclockwise")
              .frame(height: rateFormButtonLabelHeight)
          }
          .buttonStyle(SerenitySecondaryButtonStyle())
        }

        rateHeader
        Divider()

        if sortedRates.isEmpty {
          emptyPanelText("No model rates available yet.")
            .padding(.vertical, SerenityUI.Spacing.sm)
        } else {
          ForEach(sortedRates) { rate in
            HStack(spacing: SerenityUI.Spacing.xs) {
              Text(providerTitle(rate.provider))
                .font(SerenityType.caption)
                .frame(width: 92, alignment: .leading)
              Text(rate.model)
                .font(SerenityType.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(formatRate(rate.inputUSDPerMillion))
                .font(SerenityType.caption)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
              Text(formatRate(rate.outputUSDPerMillion))
                .font(SerenityType.caption)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
              SerenityBadge(rate.source.rawValue.capitalized)
                .frame(width: 82, alignment: .leading)
              if rate.source == .seeded {
                Image(systemName: "lock")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(SerenityPalette.textSecondary)
                  .help("Seeded rates can be overridden or reset, but not deleted.")
                  .frame(width: 28, alignment: .trailing)
              } else {
                Button {
                  Task { await appState.deleteAIModelRate(provider: rate.provider, model: rate.model) }
                } label: {
                  Image(systemName: "trash")
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Remove this provider/model rate")
                .frame(width: 28, alignment: .trailing)
              }
            }
            .padding(.vertical, 5)
            Divider()
          }
        }
      }
    }
  }

  private var rateForm: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .bottom, spacing: SerenityUI.Spacing.xs) {
        providerPicker.frame(width: 190)
        rateTextField("Model", text: $rateModel).frame(minWidth: 300)
        rateNumberField("Input", value: $inputRate)
        rateNumberField("Output", value: $outputRate)
        saveRateButton
      }
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
        providerPicker.frame(maxWidth: 260)
        rateTextField("Model", text: $rateModel)
        HStack(spacing: SerenityUI.Spacing.xs) {
          rateNumberField("Input", value: $inputRate)
          rateNumberField("Output", value: $outputRate)
        }
        saveRateButton
      }
    }
  }

  private var rateFormControlHeight: CGFloat { 44 }

  private var rateFormButtonLabelHeight: CGFloat { rateFormControlHeight - 14 }

  private var providerPicker: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text("Provider")
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)

      SerenityDropdownField(
        placeholder: "Provider",
        selection: $rateProvider,
        options: rateProviderDropdownOptions,
        maxMenuHeight: 180
      )
      .frame(maxWidth: .infinity, minHeight: rateFormControlHeight, maxHeight: rateFormControlHeight)
    }
  }

  private var rateProviderDropdownOptions: [SerenityDropdownOption<AIUsageProvider>] {
    AIUsageProvider.allCases.map { provider in
      SerenityDropdownOption(
        value: provider,
        title: providerTitle(provider),
        subtitle: rateProviderSubtitle(provider),
        systemImage: providerIcon(provider),
        tint: providerTint(provider)
      )
    }
  }

  private func rateTextField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      TextField(title, text: text)
        .textFieldStyle(.plain)
        .serenityInputField()
        .frame(height: rateFormControlHeight)
    }
  }

  private func rateNumberField(_ title: String, value: Binding<Double>) -> some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text(title)
        .font(SerenityType.caption)
        .foregroundStyle(SerenityPalette.textSecondary)
      TextField(title, value: value, format: .number.precision(.fractionLength(4)))
        .textFieldStyle(.plain)
        .serenityInputField()
        .frame(height: rateFormControlHeight)
        .frame(width: 104)
    }
  }

  private var saveRateButton: some View {
    Button {
      let model = rateModel.trimmingCharacters(in: .whitespacesAndNewlines)
      Task {
        await appState.saveAIModelRate(
          provider: rateProvider,
          model: model,
          inputUSDPerMillion: inputRate,
          outputUSDPerMillion: outputRate
        )
        rateModel = ""
        inputRate = 0
        outputRate = 0
      }
    } label: {
      Label("Add / Update", systemImage: "plus.circle.fill")
        .frame(height: rateFormButtonLabelHeight)
    }
    .buttonStyle(SerenityPrimaryButtonStyle())
    .disabled(rateModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private var rateHeader: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Text("Provider").frame(width: 92, alignment: .leading)
      Text("Model").frame(maxWidth: .infinity, alignment: .leading)
      Text("Input").frame(width: 86, alignment: .trailing)
      Text("Output").frame(width: 86, alignment: .trailing)
      Text("Source").frame(width: 82, alignment: .leading)
      Text("").frame(width: 28)
    }
    .font(SerenityType.caption.weight(.semibold))
    .foregroundStyle(SerenityPalette.textSecondary)
  }

  // MARK: Helpers

  private func tablePanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    SerenityCard {
      VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
        Text(title)
          .font(.headline)
        content()
      }
    }
  }

  private func groupedBreakdown(label: (AIUsageEntity) -> String) -> [BreakdownRow] {
    var grouped: [String: (calls: Int, tokens: Int, cost: Double)] = [:]
    for row in filteredUsage {
      let key = label(row)
      var entry = grouped[key, default: (calls: 0, tokens: 0, cost: 0)]
      entry.calls += 1
      entry.tokens += row.totalTokens
      entry.cost += row.totalCostUSD ?? 0
      grouped[key] = entry
    }

    return grouped.map { key, value in
      BreakdownRow(id: key, label: key, calls: value.calls, tokens: value.tokens, cost: value.cost)
    }
    .sorted {
      if $0.cost == $1.cost { return $0.tokens > $1.tokens }
      return $0.cost > $1.cost
    }
  }

  private var missingRateKeys: [String] {
    Array(Set(missingRateRows.map { "\(providerTitle($0.provider))/\(normalizedModel($0.model))" })).sorted()
  }

  private func refreshLiteLLM() async {
    refreshingLiteLLM = true
    defer { refreshingLiteLLM = false }
    await appState.refreshMissingAIModelRatesFromLiteLLM()
  }

  private func providerTitle(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "OpenAI"
    case .gemini: return "Gemini"
    case .anthropic: return "Anthropic"
    }
  }

  private func rateProviderSubtitle(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "OpenAI usage rates"
    case .gemini: return "Google Gemini usage rates"
    case .anthropic: return "Anthropic usage rates"
    }
  }

  private func providerIcon(_ provider: AIUsageProvider) -> String {
    switch provider {
    case .openai: return "sparkles"
    case .gemini: return "diamond.fill"
    case .anthropic: return "brain.head.profile"
    }
  }

  private func providerTint(_ provider: AIUsageProvider) -> Color {
    switch provider {
    case .openai: return SerenityPalette.accent
    case .gemini: return .purple
    case .anthropic: return .orange
    }
  }

  private func normalizedModel(_ model: String?) -> String {
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Unknown" : trimmed
  }

  private func formatUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = value < 1 ? 4 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
  }

  private func formatRate(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 4
    return formatter.string(from: NSNumber(value: value)) ?? "0"
  }

  private func formatTokens(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "0"
  }

  private func formatDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private func emptyPanelText(_ text: String) -> some View {
    Text(text)
      .font(SerenityType.body)
      .foregroundStyle(SerenityPalette.textSecondary)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}
