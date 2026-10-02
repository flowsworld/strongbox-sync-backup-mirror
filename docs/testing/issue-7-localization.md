# German and English localization

Issue #7 requires native German and English resources for the C1 interface,
system app-language selection with English fallback, localized formatting,
language-independent history and a prominent explanation of one-way local
backup copies. The approved final product name belongs to #8.

## Implementation

Both native `.lproj` resource sets cover menus, settings, folder prompts,
notifications, copy/configuration errors and diagnostic prompts. English is the
Swift package and app bundle development language. `Bundle` selects supported
languages from the system preferences; the app adds no language preference.
The main bundle advertises both languages and the build script embeds the
SwiftPM resource bundle. `appName` provides the displayed development name and
the localized `InfoPlist.strings` values generated during the build.

The selected language is combined with the current regional settings for dates,
byte counts and numbers. The native API behavior is documented by Apple's
[preferred localizations](https://developer.apple.com/documentation/foundation/bundle/preferredlocalizations)
and [development region](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledevelopmentregion).

History and saved failures contain resource keys, arguments and nested causes,
not already-rendered sentences. Error deduplication compares those values.
Existing JSON strings decode without changing bookmarks, database selection,
IDs, dates or notification choices. Fixed old messages map to resource keys;
opaque OS descriptions retain the full original text with an explicit
original-language label. Database names and filenames remain user data.

The C1 arrangement and the meaning of its copy disclaimer are preserved.

## Local evidence

Tested on macOS 27.0.1, build 26A434, on Apple silicon. A separately signed
app under `/private/tmp` used the identifier
`cloud.diesis.sync-copies.localization-qa`. Its demo mode did not copy files,
save preferences, request notification permission or register a login item.
No daily-use source, destination, LaunchAgent or helper configuration changed.

- Focused Swift tests pass for supported-language selection, unsupported-language
  fallback, regional formatting, a history language switch after JSON round-trip,
  known/opaque legacy text and nested filesystem error causes.
- An actual old preferences JSON fixture retains source/default/override
  bookmarks, selected databases, notification choices and existing history IDs.
- The packaged app displayed German with `AppleLanguages=(de)` and English with
  `(en)`. With `(fr)` and a French region, the packaged app displayed English.
  These launch arguments do not write system language settings.
- Native screenshots and accessibility trees were collected for all five pages
  in both languages. The local-copy warning was readable in the database page.
  English at the minimum window size used wrapping and scrolling rather than
  cutting off its disclaimer. Copy-details disclosure was operable through AX.
- The accessibility tree included localized sidebar rows, checkbox/button labels,
  status-menu items, the status-item description and rendered history messages.
  Native role descriptions followed the selected app language as well.
- AppleScript activated only the isolated app and arrow keys changed its selected
  sidebar page. Tab behavior respected the existing macOS keyboard-navigation
  preference; that system preference was not changed for testing.

The Computer Use transport failed with `native pipe closed before response`.
Direct native accessibility inspection and AppleScript remained available.
Screen-reader evidence covers the actual AX text, roles and available actions;
no complete spoken VoiceOver session or older-macOS UI session was recorded.

## Automated checks

The CI workflow runs the native Swift tests and builds/verifies the signed app,
in addition to the existing Python/helper tests. The build verifies resource
packaging through the runnable app and its ad-hoc signature. The final local
suite counts and review outcomes are recorded in the PR.
