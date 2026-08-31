import XCTest
@testable import SerenityMac

/// `NSDataDetector` resolves relative phrases against the real current time in
/// the system time zone and cannot be given a reference date, so these assert
/// shapes and offsets rather than fixed instants.
final class QuickCaptureDateParserTests: XCTestCase {
  private let calendar = Calendar.current

  private func parse(_ input: String) -> QuickCaptureDateParser.Result {
    QuickCaptureDateParser.parse(input, calendar: calendar)
  }

  func testPlainTextGetsNoDueDate() {
    let result = parse("review the Q3 numbers")

    XCTAssertEqual(result.title, "review the Q3 numbers")
    XCTAssertNil(result.dueDate)
    XCTAssertFalse(result.hasTime)
  }

  func testTimeBearingPhraseIsStrippedFromTitleAndKeepsItsTime() throws {
    let result = parse("call the bank tomorrow at 3pm")

    XCTAssertEqual(result.title, "call the bank")
    XCTAssertTrue(result.hasTime)

    let due = try XCTUnwrap(result.dueDate)
    XCTAssertEqual(calendar.component(.hour, from: due), 15)

    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
    XCTAssertEqual(calendar.startOfDay(for: due), tomorrow)
  }

  func testDayOnlyPhraseNormalizesToStartOfDay() throws {
    let result = parse("submit expenses friday")

    XCTAssertEqual(result.title, "submit expenses")
    XCTAssertFalse(result.hasTime, "a bare weekday must not be reported as carrying a time")

    let due = try XCTUnwrap(result.dueDate)
    XCTAssertEqual(due, calendar.startOfDay(for: due), "a dateless phrase must not imply midnight-as-a-time")
  }

  func testAfternoonCountsAsATime() {
    XCTAssertTrue(parse("call mom tomorrow afternoon").hasTime)
    XCTAssertEqual(parse("call mom tomorrow afternoon").title, "call mom")
  }

  func testAdjacentLeadInWordIsAbsorbedIntoTheDatePhrase() {
    XCTAssertEqual(parse("dentist on friday").title, "dentist")
    XCTAssertEqual(parse("ship the release by tomorrow").title, "ship the release")
  }

  func testNonAdjacentPrepositionsSurvive() {
    XCTAssertEqual(
      parse("meet the team at the office tomorrow").title,
      "meet the team at the office",
      "only the word touching the date phrase belongs to it"
    )
  }

  func testBareDateKeepsOriginalTextAsTitle() {
    let result = parse("tomorrow")

    XCTAssertEqual(result.title, "tomorrow", "never save a task with an empty title")
    XCTAssertNotNil(result.dueDate)
  }

  func testTimeLikeTextThatIsNotADateIsLeftAlone() {
    let result = parse("1:1 with Sam")

    XCTAssertEqual(result.title, "1:1 with Sam")
    XCTAssertNil(result.dueDate)
  }

  func testEmptyInputIsHandled() {
    let result = parse("   ")

    XCTAssertEqual(result.title, "")
    XCTAssertNil(result.dueDate)
  }
}
