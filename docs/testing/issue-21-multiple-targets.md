# Multiple targets per file

Issue #21, approved UI A: https://pages.diesis.cloud/d/4b5dgwfjox2b.
Flo confirmed per-target Google Drive verification and tests at the existing
preferences, model, destination planner and Drive controller boundaries.

## Verified on 2026-10-03

Host: Apple Silicon, macOS 27.0.1. Xcode was selected only through
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Full Swift suite passed: 103 core Swift Testing tests, 117 app Swift Testing
  tests and 37 XCTest tests, 257 in total.
- Full Python suite passed: 116 tests.
- Shell syntax checks passed for root and macOS app zsh scripts and
  `setup-google-drive.sh`.
- Universal development bundle built successfully. `lipo -archs` confirmed
  arm64 and x86_64; strict deep signature verification and privacy manifest
  validation passed.
- The packaged app launched with `--demo`, German and Austrian locale.
  Its window was captured through the native window API and visually inspected.
  It displayed two current local targets, an unavailable NAS and the aggregate
  `2 von 3 Zielen aktuell`. Paths and errors were readable and target controls
  remained inside the window.
- German and English resources passed localization tests and plist validation.

## Behavior covered by focused tests

- A failed target leaves healthy targets of the same file updating and eligible
  for Drive verification.
- A returning target receives the newest backup; missed versions are not replayed.
- Adding a common target copies immediately without changing an own target list.
- Different bookmark values for the same physical folder are rejected.
- Filename conflicts block only the conflicting copy operations.
- Removing the last own target preserves its existing copy and does not silently
  switch to common targets. Explicit common selection creates the new copy.
- Own empty lists survive persistence; old bookmark bytes, history, notification
  choices and failure suppression survive migration.
- Identical failures on two targets notify independently and remain quiet after
  restart.
- Legacy Drive bindings, opt-outs, records and pending alerts move only to the
  original target. Events retain the actual database ID for navigation.
- Drive checks, disabling and freshness are independent for copies of one file.

All automated copy tests used synthetic backups and isolated temporary settings.
Provider replies and operating-system notification delivery were simulated at
the existing boundaries. No real Strongbox contents, Drive metadata, credentials,
login items or daily-use target folders were touched.

## Limits

This is an ad-hoc signed development build. Intel compilation is not an Intel
runtime test. Real NAS/cloud volumes, Google provider access, VoiceOver and older
macOS versions were not exercised in this task. The complete final application
acceptance pass remains tracked separately in #16.
