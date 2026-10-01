# macOS app feasibility

Investigated on 2026-10-01. This records an isolated technical spike, not a shipping app or App Store approval.

## Agreed product

Flo wants a small native macOS GUI app for Strongbox Sync users who need encrypted read copies in other KeePass clients, especially on Windows. The intended price is €5 as a one-time purchase.

- List only Strongbox Sync databases, showing resolved Strongbox display names.
- Support multiple selected databases in the first version.
- Offer a common target folder with per-database overrides. Block destination collisions.
- Copy in one direction. Changes in the target do not flow back to Strongbox.
- React promptly to local backup changes, check periodically, and catch up after wake. Show the source backup and last local copy time without guaranteeing cloud freshness.
- Restore the current optional Google Drive upload-verification capability in a subsequent update. Flo's own complete migration waits for that capability.
- Prefer the Mac App Store. Consider notarized direct distribution if sandbox restrictions prevent a reliable product.
- Offer independently selectable notifications for errors, new successful copies and recovered errors. Successful unchanged checks stay silent.
- Limit the initial feasibility investigation to one or two working days.

## Result

**The principal source-access hurdle passed on the test machine.** A sandboxed native app, with only user-selected read access and app-scoped bookmarks, read Strongbox metadata and the newest encrypted backup of both detected Strongbox Sync databases. After the user selected the known group container once, fresh app processes reused the persisted bookmark without another picker. This supports pursuing the native app.

The known path alone was insufficient: a direct read without user selection failed with `NSCocoaErrorDomain:257`. A standard `NSOpenPanel`, initially opened at the known path, granted access. This is authorization, not asking the user to discover where Strongbox stores its data.

Apple requires App Sandbox for Mac App Store distribution. Its filesystem documentation describes user-selected folder access and persisted security-scoped bookmarks, while warning that other macOS protections can still deny access. The practical result above is therefore stronger than relying on the documentation alone. [App Sandbox requirement](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [filesystem access and bookmarks](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox?changes=_4)

## Evidence

Environment: macOS 27.0.1, build 26A434, Apple Silicon, Swift 6.4.0. Full Xcode 27.0 is installed, but Command Line Tools are the selected developer directory. No valid code-signing identity was available. The probe uses ad-hoc signing and the public Foundation, AppKit and CryptoKit APIs.

| Test | Observation | What it establishes |
| --- | --- | --- |
| Signed app reads an unselected checkout fixture | Denied | Sandbox restriction is active |
| Direct read of known Strongbox group-container path | Error 257 | Knowing the path does not grant access in this build |
| User selects Strongbox group container once | 2 Sync databases, 2 readable newest backups | Names, source mapping and encrypted bytes are accessible |
| Fresh process resolves persisted bookmark | 2 databases, 2 readable backups | Access survives app termination and relaunch |
| Fresh windowless process reads three times over 10 seconds | All reads succeed | Same app identity can retain access during background execution |
| Generated binary archive fixtures | Pass | Multiple sources, display names, filename decoding and selected failure cases work |

Reports contain counts, generic error codes and timestamps. Actual database names, identifiers, source paths, hashes and encrypted contents are excluded. Only the probe's own sandbox preferences and report files are written. Existing scripts, config, LaunchAgents, credentials, Strongbox files and mirror targets are unchanged.

The source group container was read only after explicit task authorization; the successful panel grant was confirmed by Flo. Grant, resume and background report snapshots remain in the ignored experiment build directory.

## Supported Strongbox integration

No documented supported interface satisfying password-free Sync discovery and encrypted backup access was found. That is not proof that none exists. The public source revision inspected is 1.65.0; any later MCP capabilities remain unverified. The current candidate is a narrow filesystem adapter, with explicit maintenance responsibility. See [the primary-source interface research](strongbox-supported-interfaces.md).

The probe distinguishes `nickName` from the filename, filters provider `kCloudKit`, and maps UUIDs to backup subfolders. It validates the expected archive root/classes and cross-checks the URL's UUID against the metadata UUID. The archive is inspected as property-list values rather than instantiating archived Strongbox classes.

## Reviews

Two fresh agents independently reviewed the experiment: one for correctness and one for source safety and proof limitations. Both findings were verified and fixed:

- Post-read URL resource metadata could be cached, undermining concurrent-change detection. The probe now clears cached values before checking the source again.
- Contradictory UUIDs in metadata and the CloudKit URL were accepted. They are now rejected, with a generated-fixture check.

No review findings were dismissed. The safety review also identified a production limitation: checking symlinks before opening a source does not eliminate replacement races. That remains documented because this experiment never copies data to a real target. A production implementation needs stronger descriptor-based checks.

## Limits

This is a positive feasibility result for this local, ad-hoc-signed app. It is not evidence of App Store acceptance or permission behavior under production signing.

The spike did **not** test reboot, login-item registration, sleep/wake, revoked grants, older macOS releases, a separately signed helper, real target copying, file-change notifications, long-running scheduling or Google Drive verification. The background test uses fresh launches of the same app bundle, not a LaunchAgent. No existing background job was changed.

App Store rules require sandboxing, consent for autostart/background continuation and store-distributed updates. These replace the current shell installer and git-based updater in the shipping app. [App Review Guidelines, 2.4.5](https://developer.apple.com/app-store/review/guidelines/)

## Recommended next step

Use Swift/SwiftUI for the app, keeping the background work within the main app identity initially. Investigate `SMAppService.mainApp` for opt-in login startup instead of introducing a separate helper before it is necessary. Apple's service API supports managing app login/background services on macOS 13 and later. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

Before implementing the product UI, prepare distinct static mocks for Flo to choose. Before paid distribution, verify actual production signing, login and wake behavior, revoked permissions, safe atomic copying, multiple-target collision handling and testability for App Review. Keep the original helper available until Flo can migrate with the Google Drive verification capability intact.

The investigation was materially below the agreed time limit. No conclusion requires using the rest of that budget.

## Reproduce

See [experiment instructions](../../experiments/macos-sandbox-probe/README.md). The experiment is kept separate from the existing helper and is explicitly throwaway code.

## Selected design and development implementation

Flo selected C1, with a settings sidebar and all databases on one page. Per-database
copy details can be expanded. Global options, independently selectable notification
events, the future Google Drive verification and history have separate pages.
The native implementation and safe sample-data preview are in
[macos-app](../../macos-app/README.md). The app copies locally and performs no upload.

## Follow-up: actual copy core

The sandboxed native app's isolated copy mode now passes with both actual
Strongbox Sync databases and an explicitly granted private temporary target.
The existing helper and targets remain unchanged. Generated fixtures also
exercise newer and empty backups and destination collisions. A fresh process
reuses both grants. See the dated results and remaining limits in
[the app README](../../macos-app/README.md#ergebnis-des-kopiertests-vom-1-oktober-2026).
