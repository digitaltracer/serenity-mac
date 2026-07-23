import SwiftUI

private struct HelpCenterArticle: Identifiable {
  let title: String
  let summary: String
  let keywords: [String]
  let shortcut: String?
  let section: AppSection?

  var id: String { title }
}

private struct HelpCenterFAQ: Identifiable {
  let question: String
  let answer: String
  let keywords: [String]

  var id: String { question }
}

/// Cmd+/ sheet with quick actions, shortcuts, FAQs, and guides.
struct HelpCenterSheet: View {
  @EnvironmentObject private var appState: AppState
  @State private var query = ""
#if os(macOS)
  @Environment(\.openSettings) private var openSettings
#endif

  private let articles: [HelpCenterArticle] = [
    HelpCenterArticle(
      title: "Search across everything",
      summary: "Find tasks, projects, journal entries, and goals from one place.",
      keywords: ["search", "global", "find", "lookup"],
      shortcut: "Cmd+K",
      section: nil
    ),
    HelpCenterArticle(
      title: "Manage your tasks",
      summary: "Create, edit, complete, or bulk-update tasks and subtasks.",
      keywords: ["tasks", "subtasks", "bulk", "calendar"],
      shortcut: nil,
      section: .tasks
    ),
    HelpCenterArticle(
      title: "Plan your day",
      summary: "Review due and overdue work in Today view.",
      keywords: ["today", "due", "overdue"],
      shortcut: nil,
      section: .today
    ),
    HelpCenterArticle(
      title: "Capture journal entries",
      summary: "Track reflections, moods, and tags in the Journal.",
      keywords: ["journal", "mood", "entry", "notes"],
      shortcut: nil,
      section: .journal
    ),
    HelpCenterArticle(
      title: "Track goal progress",
      summary: "Use Goals to monitor weekly and project targets.",
      keywords: ["goals", "progress", "target"],
      shortcut: nil,
      section: .goals
    ),
    HelpCenterArticle(
      title: "Configure integrations",
      summary: "Connect Google and GitHub in Settings › Sync & Backend and inspect sync health.",
      keywords: ["integrations", "google", "github", "sync"],
      shortcut: nil,
      section: nil
    ),
    HelpCenterArticle(
      title: "Review AI insights, summaries, and costs",
      summary: "Explore generated insights, recaps, summary exports, and AI usage spend.",
      keywords: ["insights", "ai", "summary", "usage", "cost", "tokens", "billing", "pricing"],
      shortcut: nil,
      section: .insights
    ),
    HelpCenterArticle(
      title: "Security and backend settings",
      summary: "Manage auth, local lock, database tools, and backend selection in Settings.",
      keywords: ["settings", "security", "database", "backend"],
      shortcut: nil,
      section: .settings
    ),
  ]

  private let faqs: [HelpCenterFAQ] = [
    HelpCenterFAQ(
      question: "How do I jump to results without using the mouse?",
      answer: "Open Global Search with Cmd+K, use Up/Down to move selection, Return to open, and Escape to close.",
      keywords: ["keyboard", "search", "navigation", "shortcuts"]
    ),
    HelpCenterFAQ(
      question: "Why is a search result not showing up?",
      answer: "Search indexes current tasks, projects, journal entries, and goals after data refreshes. Run Refresh Data if you recently changed records.",
      keywords: ["search", "index", "missing", "refresh"]
    ),
    HelpCenterFAQ(
      question: "How can I verify local database health?",
      answer: "Use Run Integrity Check in Troubleshooting Actions. The result appears in the Database section diagnostics.",
      keywords: ["database", "integrity", "health", "troubleshoot"]
    ),
    HelpCenterFAQ(
      question: "How do I recover from stale integration status?",
      answer: "Run Refresh Integrations, then open Integrations to review OAuth state and sync diagnostics.",
      keywords: ["integration", "google", "github", "diagnostics"]
    ),
  ]

  private var filteredArticles: [HelpCenterArticle] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return articles }

    return articles.filter { article in
      let haystack = [
        article.title,
        article.summary,
        article.shortcut ?? "",
        article.section?.title ?? "",
        article.keywords.joined(separator: " "),
      ]
        .joined(separator: " ")
        .lowercased()
      return haystack.contains(trimmed)
    }
  }

  private var filteredFAQs: [HelpCenterFAQ] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return faqs }

    return faqs.filter { faq in
      let haystack = [
        faq.question,
        faq.answer,
        faq.keywords.joined(separator: " "),
      ]
        .joined(separator: " ")
        .lowercased()
      return haystack.contains(trimmed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.md) {
      HStack {
        Label("Help Center", systemImage: "questionmark.circle")
          .font(SerenityType.sectionTitle)
        Spacer()
        ShortcutKeycap(text: "Cmd+/")
      }

      HStack(spacing: SerenityUI.Spacing.xs) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(SerenityPalette.textSecondary)
        TextField("Search help topics", text: $query)
          .textFieldStyle(.plain)
      }
      .serenityInputField()

      ScrollView {
        VStack(alignment: .leading, spacing: SerenityUI.Spacing.lg) {
          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SerenitySectionHeader("Quick Actions")
            SerenityCard {
              HStack(spacing: SerenityUI.Spacing.xs) {
                Button("Open Search") {
                  appState.closeHelpCenter()
                  appState.openGlobalSearch()
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Go to Tasks") {
                  appState.setSection(.tasks)
                  appState.closeHelpCenter()
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Open Settings") {
                  appState.closeHelpCenter()
                  appState.requestSettings(tab: .general)
#if os(macOS)
                  openSettings()
#endif
                }
                .buttonStyle(SerenitySecondaryButtonStyle())
              }
            }
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SerenitySectionHeader("Troubleshooting Actions")
            SerenityCard {
              HStack(spacing: SerenityUI.Spacing.xs) {
                Button("Refresh Data") {
                  Task {
                    await appState.refreshCoreWorkflowData()
                    appState.showToast("Core data refreshed")
                  }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Refresh Integrations") {
                  Task {
                    await appState.refreshIntegrationDiagnostics()
                    appState.showToast("Integration diagnostics refreshed")
                  }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Refresh AI Workflows") {
                  Task {
                    await appState.refreshAIWorkflows()
                    appState.showToast("AI workflows refreshed")
                  }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())

                Button("Run Integrity Check") {
                  Task {
                    await appState.runDatabaseIntegrityCheck()
                  }
                }
                .buttonStyle(SerenitySecondaryButtonStyle())
              }
            }
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SerenitySectionHeader("Keyboard Shortcuts")
            SerenityCard {
              VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
                HelpShortcutRow(action: "Global Search", shortcut: "Cmd+K")
                HelpShortcutRow(action: "Help Center", shortcut: "Cmd+/")
                HelpShortcutRow(action: "Quick Capture", shortcut: "Cmd+Shift+N")
              }
            }
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SerenitySectionHeader("Frequently Asked Questions")
            if filteredFAQs.isEmpty {
              SerenityCard {
                Text("No FAQ entries matched your search.")
                  .font(SerenityType.body)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
            } else {
              SerenityCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                  ForEach(filteredFAQs) { faq in
                    HelpFAQRow(faq: faq)

                    if faq.id != filteredFAQs.last?.id {
                      Divider()
                        .padding(.leading, SerenityUI.Spacing.md)
                    }
                  }
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: SerenityUI.Spacing.xs) {
            SerenitySectionHeader("Guides")
            if filteredArticles.isEmpty {
              SerenityCard {
                Text("No help topics matched your search.")
                  .font(SerenityType.body)
                  .foregroundStyle(SerenityPalette.textSecondary)
              }
            } else {
              SerenityCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                  ForEach(filteredArticles) { article in
                    HelpArticleRow(article: article) {
                      guard let section = article.section else { return }
                      appState.closeHelpCenter()
#if os(macOS)
                      if section == .settings {
                        appState.requestSettings(tab: .general)
                        openSettings()
                        return
                      }
#endif
                      appState.setSection(section)
                    }

                    if article.id != filteredArticles.last?.id {
                      Divider()
                        .padding(.leading, SerenityUI.Spacing.md)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    .padding(SerenityUI.Spacing.lg)
    .frame(minWidth: 760, minHeight: 560)
    .background(SerenityPalette.windowBackground)
  }
}

private struct HelpFAQRow: View {
  let faq: HelpCenterFAQ

  var body: some View {
    VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
      Text(faq.question)
        .font(SerenityType.bodyMedium)
      Text(faq.answer)
        .font(SerenityType.body)
        .foregroundStyle(SerenityPalette.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.sm)
  }
}

private struct HelpShortcutRow: View {
  let action: String
  let shortcut: String

  var body: some View {
    HStack {
      Text(action)
        .font(SerenityType.body)
      Spacer()
      ShortcutKeycap(text: shortcut)
    }
  }
}

private struct HelpArticleRow: View {
  let article: HelpCenterArticle
  let openAction: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: SerenityUI.Spacing.sm) {
      Image(systemName: article.section?.systemImage ?? "info.circle")
        .frame(width: 18)
        .foregroundStyle(SerenityPalette.textSecondary)

      VStack(alignment: .leading, spacing: SerenityUI.Spacing.xxs) {
        Text(article.title)
          .font(SerenityType.bodyMedium)
        Text(article.summary)
          .font(SerenityType.body)
          .foregroundStyle(SerenityPalette.textSecondary)
      }

      Spacer()

      if let shortcut = article.shortcut {
        ShortcutKeycap(text: shortcut)
      }

      if article.section != nil {
        Button("Open", action: openAction)
          .buttonStyle(SerenitySecondaryButtonStyle())
      }
    }
    .padding(.horizontal, SerenityUI.Spacing.md)
    .padding(.vertical, SerenityUI.Spacing.sm)
  }
}
