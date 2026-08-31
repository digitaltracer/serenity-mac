import Foundation

/// Pulls a due date out of freeform capture text on-device, so the capture box
/// keeps the promise its placeholder makes ("Remind me to call mom tomorrow
/// afternoon") without needing a configured AI provider.
enum QuickCaptureDateParser {
  struct Result: Equatable {
    var title: String
    var dueDate: Date?
    /// False when the phrase named a day but no clock time, so callers can avoid
    /// claiming a task is due at midnight.
    var hasTime: Bool
  }

  private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

  /// A preposition sitting immediately before the date phrase belongs to it, not
  /// to the title — "dentist on Friday" should leave "dentist", not "dentist on".
  /// Only the directly adjacent word is considered, so "at the office tomorrow"
  /// keeps its "at".
  private static let leadInWords: Set<String> = ["on", "at", "by", "due", "before", "until", "till"]

  /// `NSDataDetector` reports noon for a bare day, which is indistinguishable
  /// from a real "12pm". Read the matched text instead of guessing from the hour.
  private static let timeMarkers = try? NSRegularExpression(
    pattern: #"(\d{1,2}\s*:\s*\d{2})|(\d{1,2}\s*(am|pm))|\b(noon|midday|midnight|morning|afternoon|evening|tonight)\b"#,
    options: [.caseInsensitive]
  )

  /// `calendar` only normalizes the day boundary. Its time zone must match the
  /// system's, because `NSDataDetector` resolves relative phrases against the
  /// system time zone and offers no way to override it — which is also why there
  /// is no reference-date parameter here.
  static func parse(_ input: String, calendar: Calendar = .current) -> Result {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let detector else {
      return Result(title: trimmed, dueDate: nil, hasTime: false)
    }

    let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    guard
      let match = detector.matches(in: trimmed, options: [], range: fullRange).first,
      let date = match.date,
      let matchRange = Range(match.range, in: trimmed)
    else {
      return Result(title: trimmed, dueDate: nil, hasTime: false)
    }

    let hasTime = namesATime(String(trimmed[matchRange]))
    let dueDate = hasTime ? date : calendar.startOfDay(for: date)
    let title = collapse(trimmed, removing: expand(matchRange, in: trimmed))

    // A bare date ("tomorrow") is a date, not a task — keep the original text as
    // the title rather than saving something blank.
    guard !title.isEmpty else {
      return Result(title: trimmed, dueDate: dueDate, hasTime: hasTime)
    }

    return Result(title: title, dueDate: dueDate, hasTime: hasTime)
  }

  private static func namesATime(_ matched: String) -> Bool {
    guard let timeMarkers else { return false }
    let range = NSRange(matched.startIndex..<matched.endIndex, in: matched)
    return timeMarkers.firstMatch(in: matched, options: [], range: range) != nil
  }

  /// Grows the match backwards over whitespace and one adjacent lead-in word.
  private static func expand(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
    var start = range.lowerBound
    while start > text.startIndex {
      let previous = text.index(before: start)
      guard text[previous].isWhitespace else { break }
      start = previous
    }
    guard start > text.startIndex else { return start..<range.upperBound }

    var wordStart = start
    while wordStart > text.startIndex {
      let previous = text.index(before: wordStart)
      guard !text[previous].isWhitespace else { break }
      wordStart = previous
    }

    let word = text[wordStart..<start].lowercased()
    return leadInWords.contains(word) ? wordStart..<range.upperBound : start..<range.upperBound
  }

  private static func collapse(_ text: String, removing range: Range<String.Index>) -> String {
    var remainder = text
    remainder.removeSubrange(range)
    return remainder
      .replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}
