import SwiftUI

/// Sheet editor for an existing journal entry: title, content, mood, tags.
struct JournalEntryEditorView: View {
  let entry: JournalEntryEntity
  let onSave: (String, String, JournalMood?, [String]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var title: String
  @State private var content: String
  @State private var mood: JournalMood?
  @State private var tags: [String]
  @State private var tagInputText = ""

  init(entry: JournalEntryEntity, onSave: @escaping (String, String, JournalMood?, [String]) -> Void) {
    self.entry = entry
    self.onSave = onSave
    _title = State(initialValue: entry.title ?? "")
    _content = State(initialValue: entry.content)
    _mood = State(initialValue: entry.mood)
    _tags = State(initialValue: entry.tags)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.sm) {
      Text("Edit Journal Entry")
        .font(SerenityType.sectionTitle)

      TextField("Title", text: $title)
        .textFieldStyle(.plain)
        .serenityInputField()

      TextEditor(text: $content)
        .serenityTextArea(minHeight: 150)

      Picker("Mood", selection: $mood) {
        Text("None").tag(Optional<JournalMood>.none)
        ForEach([JournalMood.happy, .neutral, .sad, .excited, .stressed], id: \.rawValue) { moodValue in
          Text(moodValue.rawValue.capitalized)
            .tag(Optional(moodValue))
        }
      }
      .frame(maxWidth: 240)

      SerenityTagInputField(tags: $tags, inputText: $tagInputText)

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(SerenitySecondaryButtonStyle())

        Button("Save") {
          onSave(title, content, mood, tagsIncludingPendingInput(tags, input: tagInputText))
          dismiss()
        }
        .buttonStyle(SerenityPrimaryButtonStyle())
      }
    }
    .padding(SerenityUI.Spacing.lg)
  }
}
