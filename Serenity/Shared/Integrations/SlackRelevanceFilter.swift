import Foundation

struct SlackRelevanceSettings: Equatable, Sendable, Codable {
  /// `@here` and `@channel` are announcements in most workspaces. Including
  /// them is the difference between a few proposals a day and dozens.
  var includeBroadcastMentions: Bool
  /// Bot posts usually describe work that is already tracked somewhere else.
  var includeBotMessages: Bool

  static let `default` = SlackRelevanceSettings(
    includeBroadcastMentions: false,
    includeBotMessages: false
  )
}

/// One message worth spending an AI call on, plus enough of the surrounding
/// conversation to read it as more than a fragment.
struct SlackSignal: Equatable, Sendable, Identifiable {
  var anchor: SlackMessage
  var context: [SlackMessage]
  /// Every message that would have anchored on its own before the thread was
  /// collapsed. All of them get marked seen together, or the ones left over
  /// would anchor again on the next pass.
  var covered: [SlackMessage] = []

  var id: String { anchor.id }

  var seenCandidates: [SlackMessage] {
    covered.isEmpty ? [anchor] : covered
  }
}

struct SlackFilterResult: Sendable {
  var signals: [SlackSignal]
  /// Messages seen and rejected. Recorded so they are never re-read, which is
  /// what keeps a dismissed conversation dismissed.
  var rejected: [SlackMessage]
}

enum SlackRelevanceFilter {
  static let contextCharacterBudget = 4000

  /// Slack message subtypes that describe housekeeping rather than anything a
  /// person said.
  private static let ignoredSubtypes: Set<String> = [
    "channel_join",
    "channel_leave",
    "channel_topic",
    "channel_purpose",
    "channel_name",
    "channel_archive",
    "channel_unarchive",
    "group_join",
    "group_leave",
    "pinned_item",
    "unpinned_item",
    "bot_add",
    "bot_remove",
    "reminder_add",
  ]

  private static let broadcastTokens = ["<!here>", "<!channel>", "<!everyone>"]

  static func filter(
    messages: [SlackMessage],
    ownUserID: String,
    ownGroupIDs: Set<String> = [],
    participatedThreads: Set<String> = [],
    seenKeys: Set<String> = [],
    settings: SlackRelevanceSettings = .default
  ) -> SlackFilterResult {
    let byChannel = Dictionary(grouping: messages, by: \.channelID)
      .mapValues { $0.sorted { SlackTimestamp.isAfter($1.ts, $0.ts) } }

    var rejected: [SlackMessage] = []
    var anchorsByThread: [String: [SlackMessage]] = [:]

    for message in messages.sorted(by: { SlackTimestamp.isAfter($1.ts, $0.ts) }) {
      guard !seenKeys.contains(message.id) else { continue }

      guard isAnchor(
        message,
        ownUserID: ownUserID,
        ownGroupIDs: ownGroupIDs,
        participatedThreads: participatedThreads,
        settings: settings
      ) else {
        rejected.append(message)
        continue
      }

      let root = message.threadTS ?? message.ts
      anchorsByThread["\(message.channelID):\(root)", default: []].append(message)
    }

    // One conversation is one piece of work. Anchoring every reply separately
    // asks the model the same question repeatedly and answers it with a stack
    // of near-identical proposals.
    var signals: [SlackSignal] = []
    for anchors in anchorsByThread.values {
      let ordered = anchors.sorted { SlackTimestamp.isAfter($1.ts, $0.ts) }
      guard let anchor = ordered.last else { continue }
      signals.append(
        SlackSignal(
          anchor: anchor,
          context: context(for: anchor, in: byChannel[anchor.channelID] ?? []),
          covered: ordered
        )
      )
    }

    signals.sort { SlackTimestamp.isAfter($1.anchor.ts, $0.anchor.ts) }
    return SlackFilterResult(signals: signals, rejected: rejected)
  }

  static func isAnchor(
    _ message: SlackMessage,
    ownUserID: String,
    ownGroupIDs: Set<String>,
    participatedThreads: Set<String>,
    settings: SlackRelevanceSettings
  ) -> Bool {
    if let subtype = message.subtype, ignoredSubtypes.contains(subtype) {
      return false
    }
    if message.isBot && !settings.includeBotMessages {
      return false
    }
    // Your own words still travel as context, but they never open a proposal.
    if message.isOwn {
      return false
    }
    if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }

    if !ownUserID.isEmpty && message.text.contains("<@\(ownUserID)>") {
      return true
    }
    if ownGroupIDs.contains(where: { message.text.contains("<!subteam^\($0)") }) {
      return true
    }
    if let threadTS = message.threadTS, participatedThreads.contains(threadTS) {
      return true
    }
    if settings.includeBroadcastMentions, broadcastTokens.contains(where: message.text.contains) {
      return true
    }

    return false
  }

  /// A thread reply reads as a fragment on its own, so context is the rest of
  /// its thread; a channel message gets its neighbours instead.
  static func context(for anchor: SlackMessage, in channelMessages: [SlackMessage]) -> [SlackMessage] {
    var candidates: [SlackMessage]

    if let threadTS = anchor.threadTS {
      candidates = channelMessages.filter { $0.id != anchor.id && ($0.threadTS == threadTS || $0.ts == threadTS) }
    } else if let index = channelMessages.firstIndex(where: { $0.id == anchor.id }) {
      let lower = channelMessages.index(index, offsetBy: -3, limitedBy: channelMessages.startIndex)
        ?? channelMessages.startIndex
      let upper = channelMessages.index(index, offsetBy: 3, limitedBy: channelMessages.index(before: channelMessages.endIndex))
        ?? channelMessages.index(before: channelMessages.endIndex)
      candidates = Array(channelMessages[lower...upper]).filter { $0.id != anchor.id }
    } else {
      candidates = []
    }

    candidates.sort { SlackTimestamp.isAfter($1.ts, $0.ts) }
    return trimmed(candidates, budget: contextCharacterBudget - anchor.text.count)
  }

  /// Drops from the middle so the thread opener and the most recent replies —
  /// the two ends that carry the decision — both survive.
  private static func trimmed(_ messages: [SlackMessage], budget: Int) -> [SlackMessage] {
    var kept = messages
    var total = kept.reduce(0) { $0 + $1.text.count }

    while total > max(0, budget), kept.count > 2 {
      let middle = kept.count / 2
      total -= kept[middle].text.count
      kept.remove(at: middle)
    }

    return kept
  }
}
