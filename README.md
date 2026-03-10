# Serenity

Serenity is a native SwiftUI app with shared code for macOS and iOS.

The app combines personal planning, journaling, goals, integrations, AI-assisted insights, and database management in one codebase. The shared app currently ships these sections: Home, Action Hub, Today, Journal, Goals, Projects, Integrations, Insights, Database, and Settings.

## What The Codebase Includes

- SwiftUI app shell shared across macOS and iOS
- Local data storage with SQLite through GRDB
- Backend switching between local SQLite, Serenity Cloud, and external PostgreSQL
- Google OAuth and Google Calendar task sync
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

There are matching npm wrappers:

- Build: `npm run build`
- Test: `npm run test`
- Run: `npm run dev`

### Xcode workflow

Open `Serenity.xcodeproj` in Xcode for native app development.

- `SerenityMac` builds the macOS app
- `SerenityIOS` builds the iOS app

The SwiftPM target still builds only the macOS executable. The iOS app target is provided through the Xcode project.

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
