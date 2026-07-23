import SwiftUI

enum TaskMarkdownBlock {
  case heading(level: Int, text: String)
  case paragraph(String)
  case unorderedListItem(String)
  case orderedListItem(number: Int, text: String)
  case taskListItem(completed: Bool, text: String)
  case blockquote(String)
  case image(TaskMarkdownImage)
  case table(TaskMarkdownTable)
  case disclosure(TaskMarkdownDisclosure)
  case codeBlock(String)
  case divider
}

struct TaskMarkdownImage {
  let altText: String
  let url: String
}

struct TaskMarkdownTable {
  let headers: [String]
  let alignments: [TaskMarkdownTableAlignment]
  let rows: [[String]]
}

struct TaskMarkdownDisclosure {
  let summary: String
  let body: String
  let initiallyExpanded: Bool
}

enum TaskMarkdownTableAlignment {
  case leading
  case center
  case trailing

  var textAlignment: TextAlignment {
    switch self {
    case .leading:
      return .leading
    case .center:
      return .center
    case .trailing:
      return .trailing
    }
  }

  var frameAlignment: Alignment {
    switch self {
    case .leading:
      return .leading
    case .center:
      return .center
    case .trailing:
      return .trailing
    }
  }
}

/// Line-oriented GitHub-flavored markdown parser for task descriptions.
enum TaskMarkdownParser {
  static func parse(_ markdown: String) -> [TaskMarkdownBlock] {
    var blocks: [TaskMarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var insideCodeBlock = false
    let rawLines = markdown.components(separatedBy: .newlines)
    var index = 0

    func flushParagraph() {
      let paragraph = paragraphLines
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph))
      }
      paragraphLines.removeAll()
    }

    while index < rawLines.count {
      let rawLine = rawLines[index]
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

      if line.hasPrefix("```") {
        if insideCodeBlock {
          blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
          codeLines.removeAll()
          insideCodeBlock = false
        } else {
          flushParagraph()
          insideCodeBlock = true
        }
        index += 1
        continue
      }

      if insideCodeBlock {
        codeLines.append(rawLine)
        index += 1
        continue
      }

      guard !line.isEmpty else {
        flushParagraph()
        index += 1
        continue
      }

      if let disclosure = disclosure(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.disclosure(disclosure.value))
        index = disclosure.nextIndex
      } else if let blockquote = blockquote(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.blockquote(blockquote.value))
        index = blockquote.nextIndex
      } else if let table = table(from: rawLines, startIndex: index) {
        flushParagraph()
        blocks.append(.table(table.value))
        index = table.nextIndex
      } else if let image = image(from: line) {
        flushParagraph()
        blocks.append(.image(image))
        index += 1
      } else if isDivider(line) {
        flushParagraph()
        blocks.append(.divider)
        index += 1
      } else if let heading = heading(from: line) {
        flushParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
      } else if let task = taskListItem(from: line) {
        flushParagraph()
        blocks.append(.taskListItem(completed: task.completed, text: task.text))
        index += 1
      } else if let unordered = unorderedListItem(from: line) {
        flushParagraph()
        blocks.append(.unorderedListItem(unordered))
        index += 1
      } else if let ordered = orderedListItem(from: line) {
        flushParagraph()
        blocks.append(.orderedListItem(number: ordered.number, text: ordered.text))
        index += 1
      } else {
        paragraphLines.append(rawLine)
        index += 1
      }
    }

    if insideCodeBlock {
      blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks
  }

  static func shouldCollapseInTaskList(_ markdown: String) -> Bool {
    let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let lineCount = trimmed.components(separatedBy: .newlines).count
    if trimmed.count > 320 || lineCount > 6 {
      return true
    }

    let blocks = parse(trimmed)
    if blocks.count > 4 {
      return true
    }

    return blocks.contains { block in
      switch block {
      case .codeBlock, .disclosure, .image, .table:
        return true
      case .heading, .paragraph, .unorderedListItem, .orderedListItem, .taskListItem, .blockquote, .divider:
        return false
      }
    }
  }

  static func inlineAttributedString(_ markdown: String) -> AttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
  }

  private static func heading(from line: String) -> (level: Int, text: String)? {
    let hashes = line.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") else {
      return nil
    }
    let text = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return (hashes.count, text)
  }

  private static func taskListItem(from line: String) -> (completed: Bool, text: String)? {
    for marker in ["- [ ] ", "* [ ] ", "+ [ ] "] where line.hasPrefix(marker) {
      return (false, String(line.dropFirst(marker.count)))
    }
    for marker in ["- [x] ", "* [x] ", "+ [x] ", "- [X] ", "* [X] ", "+ [X] "] where line.hasPrefix(marker) {
      return (true, String(line.dropFirst(marker.count)))
    }
    return nil
  }

  private static func unorderedListItem(from line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    return nil
  }

  private static func orderedListItem(from line: String) -> (number: Int, text: String)? {
    guard let dotIndex = line.firstIndex(of: ".") else { return nil }
    let numberText = line[..<dotIndex]
    guard let number = Int(numberText) else { return nil }

    let remainder = line[line.index(after: dotIndex)...]
    guard remainder.hasPrefix(" ") else { return nil }
    return (number, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func isDivider(_ line: String) -> Bool {
    let characters = Set(line)
    return line.count >= 3 &&
      (characters == Set<Character>("-") || characters == Set<Character>("*") || characters == Set<Character>("_"))
  }

  private static func image(from line: String) -> TaskMarkdownImage? {
    guard line.hasPrefix("!["), line.hasSuffix(")") else { return nil }
    guard let closeBracket = line.firstIndex(of: "]") else { return nil }
    let openParen = line.index(after: closeBracket)
    guard openParen < line.endIndex, line[openParen] == "(" else { return nil }

    let altText = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket])
    let urlStart = line.index(after: openParen)
    let urlEnd = line.index(before: line.endIndex)
    let url = line[urlStart..<urlEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return nil }
    return TaskMarkdownImage(altText: altText, url: url)
  }

  private static func blockquote(from rawLines: [String], startIndex: Int) -> (value: String, nextIndex: Int)? {
    guard rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") else {
      return nil
    }

    var quoteLines: [String] = []
    var index = startIndex
    while index < rawLines.count {
      let line = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix(">") else { break }
      quoteLines.append(strippingBlockquoteMarker(from: line))
      index += 1
    }

    return (quoteLines.joined(separator: "\n"), index)
  }

  private static func strippingBlockquoteMarker(from line: String) -> String {
    guard line.hasPrefix(">") else { return line }
    var stripped = String(line.dropFirst())
    if stripped.hasPrefix(" ") {
      stripped.removeFirst()
    }
    return stripped
  }

  private static func disclosure(from rawLines: [String], startIndex: Int) -> (value: TaskMarkdownDisclosure, nextIndex: Int)? {
    let firstLine = rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    guard firstLine.lowercased().hasPrefix("<details") else { return nil }

    var lines: [String] = []
    var index = startIndex
    var foundClosingTag = false
    while index < rawLines.count {
      lines.append(rawLines[index])
      if rawLines[index].range(of: "</details>", options: [.caseInsensitive]) != nil {
        foundClosingTag = true
        index += 1
        break
      }
      index += 1
    }

    let rawDisclosure = lines.joined(separator: "\n")
    let initiallyExpanded = firstLine.range(of: "open", options: [.caseInsensitive]) != nil
    let contentAfterOpeningTag = removingOpeningDetailsTag(from: rawDisclosure)
    let contentWithoutClosingTag = removingClosingDetailsTag(from: contentAfterOpeningTag, foundClosingTag: foundClosingTag)
    let extracted = extractingSummary(from: contentWithoutClosingTag)
    let summary = extracted.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)

    return (
      TaskMarkdownDisclosure(
        summary: summary.isEmpty ? "Details" : summary,
        body: body,
        initiallyExpanded: initiallyExpanded
      ),
      index
    )
  }

  private static func removingOpeningDetailsTag(from text: String) -> String {
    guard
      let start = text.range(of: "<details", options: [.caseInsensitive]),
      let close = text[start.lowerBound...].firstIndex(of: ">")
    else {
      return text
    }

    var result = text
    result.removeSubrange(start.lowerBound...close)
    return result
  }

  private static func removingClosingDetailsTag(from text: String, foundClosingTag: Bool) -> String {
    guard
      foundClosingTag,
      let range = text.range(of: "</details>", options: [.caseInsensitive])
    else {
      return text
    }

    var result = text
    result.removeSubrange(range)
    return result
  }

  private static func extractingSummary(from text: String) -> (summary: String, body: String) {
    guard
      let openingRange = text.range(of: "<summary>", options: [.caseInsensitive]),
      let closingRange = text.range(of: "</summary>", options: [.caseInsensitive])
    else {
      return ("Details", text)
    }

    let summary = String(text[openingRange.upperBound..<closingRange.lowerBound])
    let body = String(text[..<openingRange.lowerBound]) + String(text[closingRange.upperBound...])
    return (summary, body)
  }

  private static func table(from rawLines: [String], startIndex: Int) -> (value: TaskMarkdownTable, nextIndex: Int)? {
    guard startIndex + 1 < rawLines.count else { return nil }

    let headerLine = rawLines[startIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    let separatorLine = rawLines[startIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard headerLine.contains("|"), isTableSeparatorRow(separatorLine) else { return nil }

    let headers = tableCells(from: headerLine)
    let alignments = tableAlignments(from: separatorLine)
    guard !headers.isEmpty, !headers.allSatisfy(\.isEmpty), alignments.count == headers.count else { return nil }

    var rows: [[String]] = []
    var index = startIndex + 2
    while index < rawLines.count {
      let line = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, line.contains("|"), !isTableSeparatorRow(line) else { break }
      rows.append(normalizedTableRow(tableCells(from: line), columnCount: headers.count))
      index += 1
    }

    return (
      TaskMarkdownTable(headers: headers, alignments: alignments, rows: rows),
      index
    )
  }

  private static func tableCells(from line: String) -> [String] {
    var content = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.first == "|" {
      content.removeFirst()
    }
    if content.last == "|" {
      content.removeLast()
    }
    return content
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private static func tableAlignments(from line: String) -> [TaskMarkdownTableAlignment] {
    tableCells(from: line).map { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
        return .center
      }
      if trimmed.hasSuffix(":") {
        return .trailing
      }
      return .leading
    }
  }

  private static func isTableSeparatorRow(_ line: String) -> Bool {
    let cells = tableCells(from: line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
      let dashCount = trimmed.filter { $0 == "-" }.count
      let allowed = trimmed.allSatisfy { $0 == "-" || $0 == ":" }
      return allowed && dashCount >= 3
    }
  }

  private static func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
    if cells.count == columnCount {
      return cells
    }
    if cells.count > columnCount {
      return Array(cells.prefix(columnCount))
    }
    return cells + Array(repeating: "", count: columnCount - cells.count)
  }
}
