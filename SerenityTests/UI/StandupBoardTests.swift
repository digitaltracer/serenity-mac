import Foundation
import SwiftUI
import XCTest
@testable import SerenityMac

/// The board's rules about moving cards live in AppState and are testable
/// directly; the parts that only exist as SwiftUI — drag targets, the phone's
/// swipe, the accessible fallback — are asserted against the source the way the
/// other shell tests do.
@MainActor
final class StandupBoardTests: XCTestCase {
  // MARK: - Moving cards

  func testMovingACardRekeysItSoASecondMoveDoesNotCollide() {
    let state = makeState(cards: [card(id: "t1:since", taskID: "t1", column: .since)])

    state.moveStandupCard(id: "t1:since", to: .blocked)
    XCTAssertEqual(state.standupBoard?.cards.map(\.id), ["t1:blocked"])

    state.moveStandupCard(id: "t1:blocked", to: .today)
    XCTAssertEqual(state.standupBoard?.cards.map(\.id), ["t1:today"])
    XCTAssertEqual(state.standupBoard?.cards.first?.column, .today)
  }

  /// A task can legitimately sit in two columns, but landing on a column it is
  /// already in must not leave two copies behind.
  func testMovingOntoAColumnTheTaskAlreadyOccupiesLeavesOneCard() {
    let state = makeState(cards: [
      card(id: "t1:since", taskID: "t1", column: .since),
      card(id: "t1:today", taskID: "t1", column: .today),
    ])

    state.moveStandupCard(id: "t1:since", to: .today)

    XCTAssertEqual(state.standupBoard?.cards.map(\.id), ["t1:today"])
  }

  func testMovingACardToWhereItAlreadyIsChangesNothing() {
    let state = makeState(cards: [card(id: "t1:today", taskID: "t1", column: .today)])

    state.moveStandupCard(id: "t1:today", to: .today)

    XCTAssertEqual(state.standupBoard?.cards.count, 1)
  }

  /// Dropping something needs a destination and a way back, so leaving a card
  /// out keeps it on the board rather than deleting it.
  func testLeavingACardOutKeepsItRecoverable() {
    let state = makeState(cards: [card(id: "t1:today", taskID: "t1", column: .today)])

    state.moveStandupCard(id: "t1:today", to: .leftOut)
    XCTAssertEqual(state.standupBoard?.cards(in: .leftOut).count, 1)
    XCTAssertFalse(state.standupBoard?.hasAnythingToSay == true)

    state.moveStandupCard(id: "t1:leftOut", to: .today)
    XCTAssertEqual(state.standupBoard?.cards(in: .today).count, 1)
  }

  func testATypedCardIsMarkedAsYoursAndCarriesNoTask() {
    let state = makeState(cards: [])

    state.addStandupCard(title: "  Sat in the infra sync  ", to: .today)

    let added = state.standupBoard?.cards.first
    XCTAssertEqual(added?.title, "Sat in the infra sync")
    XCTAssertEqual(added?.source, .manual)
    XCTAssertNil(added?.taskID)
  }

  func testAnEmptyTypedCardIsIgnored() {
    let state = makeState(cards: [])

    state.addStandupCard(title: "   ", to: .today)

    XCTAssertTrue(state.standupBoard?.cards.isEmpty == true)
  }

  // MARK: - The view

  func testStandupSectionViewCanBeConstructed() {
    let view = StandupSectionView().environmentObject(makeState(cards: []))
    XCTAssertNotNil(view)
  }

  func testEveryColumnIsADropTargetAndEveryCardIsDraggable() throws {
    let board = try standupSource()

    XCTAssertTrue(board.contains(".draggable(card.id)"))
    XCTAssertTrue(board.contains(".dropDestination(for: String.self)"))
  }

  /// Drag has no keyboard or VoiceOver path, so the same moves must exist as a
  /// menu. This is also what the phone's move list is built from.
  func testEveryCardOffersTheSameMovesAsAMenu() throws {
    let board = try standupSource()

    XCTAssertTrue(board.contains(".contextMenu {"))
    XCTAssertTrue(board.contains("Button(\"Move to \\(target.title)\")"))
  }

  func testThePhoneMovesCardsBySwipeRatherThanDrag() throws {
    let board = try standupSource()

    XCTAssertTrue(board.contains("#if os(iOS)"))
    XCTAssertTrue(board.contains(".serenitySwipeActions("))
  }

  /// A guess presented as something you said is the one failure that puts a
  /// fiction in front of the team, so it has to be labelled on the card.
  func testAGuessedCardIsLabelledOnTheBoard() throws {
    let board = try standupSource()

    XCTAssertTrue(board.contains("if card.source.isGuess {"))
    XCTAssertTrue(board.contains("provenanceChip(card.source.label, tint: .red)"))
  }

  func testTheOutputOffersBothRenderingsAndTheFoldedDetail() throws {
    let board = try standupSource()

    XCTAssertTrue(board.contains("Text(\"Out loud\").tag(false)"))
    XCTAssertTrue(board.contains("Text(\"To paste\").tag(true)"))
    XCTAssertTrue(board.contains("Detail it folded away"))
  }

  // MARK: - Helpers

  private func standupSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Serenity/Shared/App/SerenityAppScene.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    return String(try XCTUnwrap(source.slice(from: "struct StandupSectionView", to: "private struct StandupFormatSheet")))
  }

  private func makeState(cards: [StandupCard]) -> AppState {
    let state = AppState(serenityCloudAdapter: nil, externalPostgresAdapter: nil)
    state.standupBoard = StandupBoard(
      window: StandupWindow(
        start: Date(timeIntervalSince1970: 1_789_000_000),
        end: Date(timeIntervalSince1970: 1_789_200_000),
        anchor: .lastStandup
      ),
      cards: cards
    )
    return state
  }

  private func card(id: String, taskID: String, column: StandupColumn) -> StandupCard {
    StandupCard(
      id: id,
      taskID: taskID,
      column: column,
      title: "Ship Slack PKCE token refresh",
      fact: "Finished Friday 4:12 PM",
      source: .completed
    )
  }
}

private extension String {
  func slice(from start: String, to end: String) -> Substring? {
    guard let startRange = range(of: start),
          let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
      return nil
    }
    return self[startRange.lowerBound..<endRange.lowerBound]
  }
}
