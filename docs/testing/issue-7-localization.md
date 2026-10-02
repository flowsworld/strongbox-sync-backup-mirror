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
Packaged apps explicitly resolve this bundle from `Contents/Resources`;
SwiftPM's generated `Bundle.module` accessor is used only by tests and CLI hosts.
This avoids the different lookup locations used by the native and swiftbuild
build systems.

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

The C1 arrangement and the meaning of its copy disclaimer are preserved. The
final change includes #5's merged copy/recovery implementation, including its
General-only source/common-target controls, full paths and copy-details button.
It also preserves #6's merged notification authorization and cancellation logic.

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
  Both languages at the minimum window size used wrapping and scrolling rather
  than cutting off their disclaimers. AppleScript operated the whole-row
  copy-details button; its AX value changed from collapsed to expanded, and the
  revealed dates and labels used the selected language.
- The accessibility tree included localized sidebar rows, checkbox/button labels,
  status-menu items, the status-item description and rendered history messages.
  Native role descriptions followed the selected app language as well.
- AppleScript activated only the isolated app and arrow keys changed its selected
  sidebar page. Tab behavior respected the existing macOS keyboard-navigation
  preference; that system preference was not changed for testing.

The Computer Use transport failed with `native pipe closed before response`.
Direct native accessibility inspection and AppleScript remained available.
VoiceOver was started through its native first-use dialog and a navigation
command was issued in the isolated app. Its spoken output could not be read
through AppleScript. Flo heard the spoken output during this session and
confirmed it was satisfactory. VoiceOver was switched off again, and its original disabled
preference and absence of running processes were verified. Screen-reader
evidence covers the actual AX text, roles and available actions together with
Flo's listening check. No spoken recording or older-macOS UI session was made.

## Automated checks

The CI workflow runs the native Swift tests and builds/verifies the signed app,
then launches the demo with `.build` temporarily moved out of reach, in addition
to the existing Python/helper tests. The build verifies resource
packaging through the runnable app and its ad-hoc signature. The final local run
passed all 77 Swift tests and all 107 Python tests. A release build and signature
verification passed. Both resource sets contain 166 matching keys and matching
format placeholders.

Independent standards and specification reviews covered the final diff after
integration with #5 and #6. Resource parsing now reports errors, an unused identity API
was removed, and two redundant nested resource lookups were simplified. The
specification review found no source defects. No findings were dismissed.

External Codex review found that the older native SwiftPM resource accessor
could fall back to an absolute build path and crash after distribution. This
was reproduced with the native-build resource bundle hidden, then fixed with
the explicit app resource lookup. Isolated packaged apps built with both native
and swiftbuild subsequently displayed German, English and the English fallback
while their development resource bundles were hidden. All 69 Swift tests and the
release build passed again. A focused independent verification found no defects
in this correction or the added CI check.

After #6 merged, both independent reviews were repeated against the new base
with no new findings. Its notification status strings now use the existing
resources; history assertions use event keys. The final 77-test Swift suite
includes all eight new notification tests from #6.
