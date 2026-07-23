import SwiftUI

/// Compact due-date field that opens a month calendar with time controls.
struct DueDateSelectionField: View {
  @Binding var selection: Date
  @State private var showingPopover = false

  var body: some View {
    Button {
      showingPopover.toggle()
    } label: {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "calendar")
          .foregroundStyle(SerenityPalette.accent)

        Text(selection.formatted(date: .abbreviated, time: .shortened))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textPrimary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
      }
      .padding(.horizontal, SerenityUI.Spacing.sm)
      .padding(.vertical, 9)
      .frame(minWidth: 220, alignment: .leading)
      .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
          .stroke(SerenityPalette.border, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
      DueDateCalendarPopover(selection: $selection, isPresented: $showingPopover)
        .padding(SerenityUI.Spacing.sm)
        .frame(width: 334)
    }
  }
}

struct DueDateCalendarPopover: View {
  @Binding var selection: Date
  @Binding var isPresented: Bool
  @State private var visibleMonth: Date

  init(selection: Binding<Date>, isPresented: Binding<Bool>) {
    _selection = selection
    _isPresented = isPresented
    _visibleMonth = State(initialValue: Calendar.current.startOfMonth(for: selection.wrappedValue))
  }

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

  private var weekdaySymbols: [String] {
    Calendar.current.orderedVeryShortStandaloneWeekdaySymbols()
  }

  private var gridDates: [Date] {
    Calendar.current.monthGridDates(for: visibleMonth)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      HStack(spacing: SerenityUI.Spacing.xs) {
        Button {
          shiftMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
            .font(SerenityType.caption)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
          .font(SerenityType.bodyMedium)
          .frame(maxWidth: .infinity)

        Button {
          shiftMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
            .font(SerenityType.caption)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())
      }

      HStack(spacing: 6) {
        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(SerenityType.caption)
            .foregroundStyle(SerenityPalette.textSecondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, 2)

      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(gridDates, id: \.self) { date in
          dueDateCell(date)
        }
      }

      Divider()

      HStack(spacing: SerenityUI.Spacing.xs) {
        Text("Time")
          .font(SerenityType.caption)
          .foregroundStyle(SerenityPalette.textSecondary)

        DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
          .labelsHidden()
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        quickTimeButton("9:00", hour: 9, minute: 0)
        quickTimeButton("13:00", hour: 13, minute: 0)
        quickTimeButton("17:30", hour: 17, minute: 30)
      }

      HStack {
        Button("Today") {
          let today = Date()
          visibleMonth = Calendar.current.startOfMonth(for: today)
          selectDay(today)
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Spacer()

        Button("Done") {
          isPresented = false
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
      }
      .padding(.top, 2)
    }
    .onChange(of: selection) { _, newValue in
      if !Calendar.current.isDate(newValue, equalTo: visibleMonth, toGranularity: .month) {
        visibleMonth = Calendar.current.startOfMonth(for: newValue)
      }
    }
  }

  private func dueDateCell(_ date: Date) -> some View {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let selectedDay = calendar.startOfDay(for: selection)
    let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
    let isToday = calendar.isDateInToday(day)
    let isInVisibleMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)

    return Button {
      selectDay(day)
    } label: {
      Text("\(calendar.component(.day, from: day))")
        .font(SerenityType.bodyMedium.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(SerenityPalette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
          isSelected ? SerenityPalette.activeItemBackground : Color.clear,
          in: RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: SerenityUI.Radius.medium, style: .continuous)
            .stroke(isToday ? SerenityPalette.accent : SerenityPalette.thinBorder, lineWidth: 1)
        )
        .opacity(isInVisibleMonth ? 1 : 0.42)
    }
    .buttonStyle(.plain)
  }

  private func selectDay(_ day: Date) {
    let calendar = Calendar.current
    let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
    var components = calendar.dateComponents([.year, .month, .day], from: day)
    components.hour = time.hour ?? 9
    components.minute = time.minute ?? 0
    components.second = time.second ?? 0
    selection = calendar.date(from: components) ?? day
    visibleMonth = calendar.startOfMonth(for: day)
  }

  private func shiftMonth(by value: Int) {
    guard let shifted = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) else { return }
    visibleMonth = Calendar.current.startOfMonth(for: shifted)
  }

  private func quickTimeButton(_ label: String, hour: Int, minute: Int) -> some View {
    Button(label) {
      selection = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: selection) ?? selection
    }
    .buttonStyle(SerenitySecondaryButtonStyle())
  }
}
