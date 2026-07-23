import SwiftUI

/// Popover calendar for choosing a start/end date range, with an optional enable toggle.
struct SerenityDateRangePicker: View {
  @Binding var isEnabled: Bool
  @Binding var startDate: Date
  @Binding var endDate: Date
  let title: String
  let showsEnableToggle: Bool
  let onApply: () -> Void
  let onClose: () -> Void

  @State private var visibleMonth: Date
  @State private var nextPick: NextPick = .start

  private enum NextPick { case start, end }

  init(
    isEnabled: Binding<Bool>,
    startDate: Binding<Date>,
    endDate: Binding<Date>,
    title: String = "Filter by date range",
    showsEnableToggle: Bool = true,
    onApply: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    _isEnabled = isEnabled
    _startDate = startDate
    _endDate = endDate
    self.title = title
    self.showsEnableToggle = showsEnableToggle
    self.onApply = onApply
    self.onClose = onClose
    let anchor = isEnabled.wrappedValue ? startDate.wrappedValue : Date()
    _visibleMonth = State(initialValue: Calendar.current.startOfMonth(for: anchor))
  }

  private let columns = Array(repeating: GridItem(.flexible(), spacing: SerenityUI.Spacing.xxs), count: 7)

  private var weekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var gridDates: [Date] {
    Calendar.current.monthGridDates(for: visibleMonth)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      if showsEnableToggle {
        Toggle(isOn: $isEnabled) {
          Text(title)
            .font(SerenityType.bodyMedium)
        }
        .toggleStyle(.switch)
        .onChange(of: isEnabled) { _, _ in onApply() }
      } else {
        Text(title)
          .font(SerenityType.bodyMedium.weight(.semibold))
      }

      if isEnabled || !showsEnableToggle {
        calendarBody
      }
    }
    .padding(SerenityUI.Spacing.md)
    .frame(width: 320)
  }

  private var calendarBody: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      monthHeader
      weekdayRow
      grid
      Divider()
      rangeSummary
      footerButtons
    }
  }

  private var monthHeader: some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Button { shiftMonth(by: -1) } label: {
        Image(systemName: "chevron.left")
          .font(.caption.weight(.semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())

      Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
        .font(SerenityType.body.weight(.semibold))
        .frame(maxWidth: .infinity)

      Button { shiftMonth(by: 1) } label: {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())
    }
  }

  private var weekdayRow: some View {
    HStack(spacing: SerenityUI.Spacing.xxs) {
      ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 2)
  }

  private var grid: some View {
    LazyVGrid(columns: columns, spacing: SerenityUI.Spacing.xxs) {
      ForEach(gridDates, id: \.self) { date in
        dayCell(date)
      }
    }
  }

  private func dayCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let start = calendar.startOfDay(for: startDate)
    let end = calendar.startOfDay(for: endDate)
    let isStart = day == start
    let isEnd = day == end
    let isEndpoint = isStart || isEnd
    let isInRange = day > start && day < end
    let isToday = calendar.isDateInToday(day)
    let isInVisibleMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)

    return Button { handleTap(day) } label: {
      Text("\(calendar.component(.day, from: day))")
        .font(SerenityType.bodyMedium.weight(isEndpoint ? .semibold : .regular))
        .foregroundStyle(isEndpoint ? Color.white : SerenityPalette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
          dayBackground(isEndpoint: isEndpoint, isInRange: isInRange),
          in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
            .stroke(
              dayBorderColor(isEndpoint: isEndpoint, isInRange: isInRange, isToday: isToday),
              lineWidth: 1
            )
        )
        .opacity(isInVisibleMonth ? 1 : 0.32)
    }
    .buttonStyle(.plain)
  }

  private func dayBackground(isEndpoint: Bool, isInRange: Bool) -> Color {
    if isEndpoint { return SerenityPalette.accent }
    if isInRange { return SerenityPalette.activeItemBackground }
    return Color.clear
  }

  private func dayBorderColor(isEndpoint: Bool, isInRange: Bool, isToday: Bool) -> Color {
    if isEndpoint { return SerenityPalette.accent }
    if isToday { return SerenityPalette.accent.opacity(0.6) }
    if isInRange { return SerenityPalette.accent.opacity(0.25) }
    return SerenityPalette.thinBorder
  }

  private var rangeSummary: some View {
    HStack(spacing: SerenityUI.Spacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text("FROM")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(startDate.formatted(.dateTime.month(.abbreviated).day().year()))
          .font(SerenityType.bodyMedium)
      }
      Spacer()
      Image(systemName: "arrow.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(SerenityPalette.textSecondary)
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("TO")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)
        Text(endDate.formatted(.dateTime.month(.abbreviated).day().year()))
          .font(SerenityType.bodyMedium)
      }
    }
  }

  private var footerButtons: some View {
    HStack {
      Button("Today") {
        let today = Date()
        startDate = today
        endDate = today
        nextPick = .end
        visibleMonth = Calendar.current.startOfMonth(for: today)
      }
      .buttonStyle(SerenitySecondaryButtonStyle())

      Spacer()

      Button("Apply") {
        onApply()
        onClose()
      }
      .buttonStyle(SerenityPrimaryButtonStyle())
    }
  }

  private func handleTap(_ day: Date) {
    let calendar = Calendar.current
    if !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
      visibleMonth = calendar.startOfMonth(for: day)
    }
    switch nextPick {
    case .start:
      startDate = day
      endDate = day
      nextPick = .end
    case .end:
      if calendar.compare(day, to: startDate, toGranularity: .day) == .orderedAscending {
        endDate = startDate
        startDate = day
      } else {
        endDate = day
      }
      nextPick = .start
    }
  }

  private func shiftMonth(by value: Int) {
    guard let shifted = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) else { return }
    visibleMonth = Calendar.current.startOfMonth(for: shifted)
  }
}
