# Serenity

Serenity is a native SwiftUI app with shared code for macOS and iOS.

The app combines personal planning, journaling, goals, integrations, AI-assisted insights, and database management in one codebase. The shared app currently ships these sections: Home, Action Hub, Today, Journal, Goals, Projects, Integrations, Insights, Database, and Settings.

## What The Codebase Includes

- SwiftUI app shell shared across macOS and iOS
- Local data storage with SQLite through GRDB
- Backend switching between local SQLite, Serenity Cloud, and external PostgreSQL
- Google OAuth and Google Calendar task sync
- Slack sign-in that proposes tasks from channel conversations for review
- GitHub token management
- AI credential management, insights, recaps, summaries, and usage tracking
- Local lock, biometric auth, security audit logging, and rate guarding
- Database bootstrap, migrations, backup, export, and integrity checks

## Project Structure

- `Serenity/Shared`: shared app state, views, domain models, services, and storage code
- `Serenity/macOS`: macOS app entry point
- `Serenity/iOS`: iOS app entry point
- `Serenity/Support`: platform Info.plist files
- `SerenityTests`: unit, parity, performance, security, and UI smoke tests
- `Serenity.xcodeproj`: native Xcode project with macOS and iOS app targets
- `Package.swift`: SwiftPM entry point used for the macOS build and test loop

## Dependencies

- `GRDB.swift` for SQLite access and migrations
- `PostgresNIO` for external PostgreSQL connectivity

## Development

### SwiftPM workflow

Use this for the fast macOS build and test loop.

- Build: `swift build`
- Test: `swift test`
- Run: `swift run SerenityMac`

### Environment variables

Copy `.env.example` to `.env` in the repo root and fill in values for the
integrations you want active. The app loads `.env` at startup (dev only — a
shipped `.app` launched from Finder will not). Shell variables always take
precedence over `.env`. See `.env.example` for the full list.

Google Calendar uses native Google Sign-In on macOS and iOS. Add the non-secret
`GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` values to the Xcode build
settings (or an xcconfig), and make sure the reversed client ID is present as a
URL scheme in the platform Info.plist.

### Slack

Slack turns channel conversations into task proposals you accept or dismiss in
ActionHub. It needs a Slack app you create in your own workspace:

1. Create an app at api.slack.com/apps **in your workspace**, and do not
   activate public distribution. Slack throttles `conversations.history` to one
   request per minute for distributed non-Marketplace apps; an app that stays
   internal keeps the usable limits, and that is what makes the feature work.
2. Under OAuth & Permissions, enable PKCE, add the redirect URL
   `serenity://slack-oauth`, and add these **user** token scopes:
   `channels:history`, `groups:history`, `channels:read`, `groups:read`,
   `users:read`, `usergroups:read`. Do not add `im:history` or `mpim:history` —
   Serenity never asks for them, so the token it holds cannot read your DMs.
3. Put the client ID in `SLACK_CLIENT_ID` in the Xcode build settings (or an
   xcconfig). There is no client secret to store: PKCE public clients do not use
   one.

Enabling PKCE is irreversible without contacting Slack support, and it forces
rotating tokens whose refresh token expires after 30 days. Serenity refreshes on
every sync, so an app left unopened for a month needs signing in again.

Colleagues in the same workspace can connect the same app without affecting its
rate limits; a different workspace cannot, without public distribution.

### Xcode workflow

Open `Serenity.xcodeproj` in Xcode for native app development.

- `SerenityMac` builds the macOS app
- `SerenityIOS` builds the iOS app

The SwiftPM target still builds only the macOS executable. The iOS app target is provided through the Xcode project.

## Release

The macOS release helper mirrors the Pipeline release flow for a single app
target:

- Example env: `scripts/release-macos.env.example`
- Dry run ZIP: `scripts/release-macos.sh --skip-notarization --format zip`
- Signed/notarized package: `scripts/release-macos.sh --format pkg`

The script auto-loads `scripts/release-macos.env` when present. That local file
is gitignored.

## Testing

The repository includes focused tests for:

- app state and navigation behavior
- data repositories and database migrations
- cloud sync and backend switching
- authentication and security services
- integrations and AI workflows
- feature parity and performance checks

## Notes

- The default local database is bootstrapped under Application Support.
- Secrets for integrations and AI credentials are stored through the keychain-backed secret store.
- On non-macOS systems, the npm wrapper scripts no-op by design.
