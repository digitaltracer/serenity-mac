import SwiftUI

/// Renders GitHub-flavored markdown blocks parsed by TaskMarkdownParser.
struct GitHubFlavoredMarkdownView: View {
  let markdown: String
  var compact = false

  private var blocks: [TaskMarkdownBlock] {
    TaskMarkdownParser.parse(markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 5 : SerenityUI.Spacing.xs) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(_ block: TaskMarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(headingFont(level: level))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 2 : nil)
        .padding(.top, compact ? 0 : headingTopPadding(level: level))

    case .paragraph(let text):
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(compact ? 3 : nil)
        .fixedSize(horizontal: false, vertical: true)

    case .unorderedListItem(let text):
      unorderedListRow(text)

    case .orderedListItem(let number, let text):
      HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
        Text("\(number).")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(SerenityPalette.textSecondary)
          .frame(width: 24, alignment: .trailing)
          .padding(.top, 1)
        Text(TaskMarkdownParser.inlineAttributedString(text))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .lineLimit(compact ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .taskListItem(let completed, let text):
      HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
        Image(systemName: completed ? "checkmark.square.fill" : "square")
          .font(SerenityType.caption.weight(.semibold))
          .foregroundStyle(completed ? .green : SerenityPalette.textSecondary)
          .padding(.top, 2)
        Text(TaskMarkdownParser.inlineAttributedString(text))
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
          .strikethrough(completed)
          .lineLimit(compact ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true)
      }

    case .blockquote(let text):
      HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
        RoundedRectangle(cornerRadius: 2)
          .fill(SerenityPalette.accent.opacity(0.55))
          .frame(width: 3)
        GitHubFlavoredMarkdownView(markdown: text, compact: compact)
      }

    case .image(let image):
      MarkdownRemoteImage(image: image, compact: compact)

    case .table(let table):
      markdownTable(table)

    case .disclosure(let disclosure):
      MarkdownDisclosureSection(disclosure: disclosure, compact: compact)

    case .codeBlock(let text):
      Text(verbatim: text)
        .font(SerenityType.scaledSystem(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 4 : nil)
        .padding(SerenityUI.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
            .stroke(SerenityPalette.thinBorder, lineWidth: 1)
        )

    case .divider:
      Rectangle()
        .fill(SerenityPalette.thinBorder)
        .frame(height: 1)
        .padding(.vertical, compact ? 1 : SerenityUI.Spacing.xxs)
    }
  }

  private func unorderedListRow(_ text: String) -> some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.xs) {
      Circle()
        .fill(SerenityPalette.textSecondary)
        .frame(width: 5, height: 5)
        .padding(.top, SerenityType.scaledSize(8))
      Text(TaskMarkdownParser.inlineAttributedString(text))
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
        .lineLimit(compact ? 2 : nil)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case 1:
      return compact ? SerenityType.bodyLarge.weight(.semibold) : SerenityType.sectionTitle
    case 2:
      return SerenityType.bodyLarge.weight(.semibold)
    default:
      return SerenityType.bodyMedium.weight(.semibold)
    }
  }

  private func markdownTable(_ table: TaskMarkdownTable) -> some View {
    ScrollView(.horizontal, showsIndicators: !compact) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
            tableCell(header, column: index, alignment: table.alignments[safe: index] ?? .leading, isHeader: true)
          }
        }

        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(table.headers.indices), id: \.self) { index in
              tableCell(
                row[safe: index] ?? "",
                column: index,
                alignment: table.alignments[safe: index] ?? .leading,
                isHeader: false
              )
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: SerenityUI.Radius.large, style: .continuous)
          .stroke(SerenityPalette.thinBorder, lineWidth: 1)
      )
    }
  }

  private func tableCell(_ text: String, column: Int, alignment: TaskMarkdownTableAlignment, isHeader: Bool) -> some View {
    Text(TaskMarkdownParser.inlineAttributedString(text))
      .font(isHeader ? SerenityType.caption.weight(.semibold) : SerenityType.body)
      .foregroundStyle(isHeader ? SerenityPalette.textPrimary : SerenityPalette.textSecondary)
      .lineLimit(compact ? 2 : nil)
      .multilineTextAlignment(alignment.textAlignment)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, isHeader ? 8 : 9)
      .frame(minWidth: compact ? 96 : 118, maxWidth: compact ? 180 : 240, alignment: alignment.frameAlignment)
      .background(isHeader ? SerenityPalette.inputBackground : SerenityPalette.innerCardBackground.opacity(column.isMultiple(of: 2) ? 0.72 : 0.46))
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(SerenityPalette.thinBorder)
          .frame(width: 1)
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(SerenityPalette.thinBorder)
          .frame(height: 1)
      }
  }

  private func headingTopPadding(level: Int) -> CGFloat {
    level == 1 ? 4 : 2
  }
}

struct MarkdownRemoteImage: View {
  let image: TaskMarkdownImage
  let compact: Bool

  var body: some View {
    if let url = URL(string: image.url), ["http", "https"].contains(url.scheme?.lowercased()) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .empty:
          imagePlaceholder(label: image.altText.isEmpty ? "Loading image..." : image.altText)
        case .success(let loadedImage):
          loadedImage
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: compact ? 140 : 320)
            .clipShape(RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous)
                .stroke(SerenityPalette.thinBorder, lineWidth: 1)
            )
            .accessibilityLabel(image.altText.isEmpty ? "Markdown image" : image.altText)
        case .failure:
          imagePlaceholder(label: image.altText.isEmpty ? "Image could not be loaded" : image.altText)
        @unknown default:
          imagePlaceholder(label: image.altText.isEmpty ? "Image unavailable" : image.altText)
        }
      }
    } else {
      imagePlaceholder(label: image.altText.isEmpty ? image.url : image.altText)
    }
  }

  private func imagePlaceholder(label: String) -> some View {
    HStack(spacing: SerenityUI.Spacing.xs) {
      Image(systemName: "photo")
        .font(SerenityType.caption.weight(.semibold))
      Text(label)
        .font(SerenityType.body)
        .lineLimit(compact ? 2 : nil)
      Spacer(minLength: 0)
    }
    .foregroundStyle(SerenityPalette.textSecondary)
    .padding(SerenityUI.Spacing.sm)
    .frame(maxWidth: .infinity, minHeight: compact ? 72 : 96, alignment: .leading)
    .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

struct MarkdownDisclosureSection: View {
  let disclosure: TaskMarkdownDisclosure
  let compact: Bool

  @State private var isExpanded: Bool

  init(disclosure: TaskMarkdownDisclosure, compact: Bool) {
    self.disclosure = disclosure
    self.compact = compact
    _isExpanded = State(initialValue: disclosure.initiallyExpanded)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      GitHubFlavoredMarkdownView(markdown: disclosure.body, compact: compact)
        .padding(.top, SerenityUI.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(TaskMarkdownParser.inlineAttributedString(disclosure.summary))
        .font(SerenityType.bodyMedium.weight(.semibold))
        .foregroundStyle(SerenityPalette.textPrimary)
        .lineLimit(compact ? 2 : nil)
    }
    .padding(SerenityUI.Spacing.sm)
    .background(SerenityPalette.inputBackground, in: RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SerenityUI.Radius.xLarge, style: .continuous)
        .stroke(SerenityPalette.thinBorder, lineWidth: 1)
    )
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
