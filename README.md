# Actual Companion iOS

SwiftUI iOS companion app for Actual Budget focused on fast daily transaction entry for tracked variable categories.

## Current implementation

- Home screen with tracked categories and recent transactions
- Add/Edit transaction sheet with:
  - Autofocus amount field
  - Payee and category search
  - Split mode (2-4 lines, remainder validation)
- Swipe delete for recent transactions
- Undo toast hooks for save/delete
- Settings screen for:
  - API base URL / Sync ID / API key
  - Recent filter mode
  - Tracked category selection (5-8)
- Offline-first local storage using GRDB (SQLite)
- Pending mutation queue with retry backoff
- Sync engine for reference data + recents + queue processing

## Project setup

1. Generate the Xcode project:
   - `xcodegen generate`
2. Open `ActualCompanion.xcodeproj` in Xcode.
3. Run on iOS simulator/device.

## Backend expectation

This app targets `actual-http-api` exposed over Tailnet HTTPS (example):

- `https://budget.neon-artichoke.ts.net:8443`

Headers used:

- `x-api-key`
- `budget-encryption-password` (optional)

## Notes

- In this environment, `xcodebuild` was unavailable because only Command Line Tools are active. Build/test in full Xcode.
- Endpoint payloads are implemented against common `actual-http-api` patterns and may need minor field mapping adjustments for your exact deployed version.
