# macOS release preparation

Preparation for [#10](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/10), checked on 2026-10-02. This is a local release candidate workflow and submission checklist. It does not establish a signed beta, notarization, Store approval or supported runtime coverage on every advertised Mac.

## Candidate builds

Run from a clean checkout after the Swift and Python suites pass:

```sh
zsh macos-app/release.zsh development 0.1.0 101
```

The script builds arm64 and x86_64 from the same Swift package, retains the sandbox entitlements, writes explicit product/build versions and `DIESISDistributionChannel`, and creates a fresh app bundle and ZIP. It records the source commit, toolchain, Mach-O build commands and archive SHA-256 beside them. Each channel/version/build directory is immutable to this script; a lock rejects a concurrent packager. Development artifacts from a modified checkout carry a `WORKTREE_DIRTY` marker. This is process reproducibility, not a promise of byte-identical signed output.

The default `build.zsh` development workflow remains available. `--universal` builds both architectures, and `--output /absolute/path/Candidate.app` permits isolated staging. Release packaging uses those options in its own ignored build directory. It does not install the candidate, register a login item, change the existing helper or publish anything.

For an explicitly selected Developer ID Application certificate already installed with its private key:

```sh
zsh macos-app/release.zsh direct 0.1.0 102 'Developer ID Application: SELECTED IDENTITY'
```

The direct path requires a clean committed tree and an explicit available identity. It enables Hardened Runtime and secure timestamping, then verifies the Developer ID certificate requirement. It never falls back to ad-hoc signing. It creates a **signed candidate**, not a completed distributable beta. The current bundle identifier remains `cloud.diesis.sync-copies`; final distribution identity and grant continuity are still decisions recorded in [the update design](macos-update-distribution.md).

No Sparkle code, helper, update feed or additional updater entitlement is embedded. Do not use this packager unchanged after adding nested executable dependencies. It currently signs only the dependency-free host and its data resources.

## Recommended beta route and remaining signing work

Recommend a small direct Developer ID beta first, using synthetic databases and an isolated macOS user. This exercises the custom packager and sandbox without requiring a Store listing to be approved first. Distribution is conditional on notarization and explicit authorization. A later Store beta should use TestFlight and the same copy engine. This recommendation does not register an identity or publish a build.

Developer ID signing requires the relevant Apple Developer team and certificate. Apple documents who can create those certificates and the separate Application/Installer roles. No valid codesigning identity was found by `security find-identity -v -p codesigning` on this machine on 2026-10-02. Account membership and certificates on other machines remain unknown. [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)

For a direct candidate, submit its ZIP with `xcrun notarytool` using credentials stored in a named Keychain profile. Require an accepted result, inspect its log, staple and validate the app ticket, then recreate the final ZIP from that stapled app. A ZIP itself cannot carry the stapled ticket. Assess the final app with Gatekeeper and test a quarantined download, including offline launch. Keep the final archive hash and notarization result with the release evidence. No notarization submission occurred here. [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

The CLI deliberately rejects `app-store`. A Store/TestFlight package still needs selected Store signing, provisioning with the app identifier, the app record, a submission-ready icon and metadata, and validated export/upload tooling. TestFlight supports macOS, requires appropriate provisioning, and distributes each beta build for at most 90 days. Do not call a Developer ID ZIP a TestFlight package. [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)

## Privacy manifest and current data flow

[PrivacyInfo.xcprivacy](../../macos-app/PrivacyInfo.xcprivacy) declares no tracking and no developer-collected data for the current offline app. Its file timestamp reasons cover the app's container (`C617.1`), user-granted source/target folders (`3B52.1`) and timestamps shown to the user (`DDA9.1`). These match descriptor metadata checks, backup selection, private state files and the latest-backup display. The manifest is embedded in the app's resources before signing. No UserDefaults, disk-space or device-uptime category is claimed for code that does not use those APIs. Review this inventory again after introducing any dependency or network feature. [Apple required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

The current app reads Strongbox metadata and encrypted local backups after a folder grant. It writes selected local copies, private settings/bookmarks and bounded history. It does not decrypt databases or transmit their contents, names, paths or checksums to DIESIS. A separately chosen sync client may upload a target copy under its own account and privacy policy. The optional future Google feature queries Google metadata and needs its own disclosures; the updater host likewise requires a separate access-log assessment. [Google design](native-google-drive-verification.md), [update privacy](macos-update-distribution.md)

Apple requires a privacy policy URL for every app. Choose an owned, public support/privacy origin before preparing a final Store record. Support requests can contain information voluntarily supplied by a user and need their own retention/contact policy. No production support URL or legal publisher identity is invented here. [App privacy fields](https://developer.apple.com/help/app-store-connect/reference/app-privacy/)

## Submission copy drafts

These drafts are review material. They are not inserted into the app or a Store listing. The selected German and English product names still await the rights clarification in #8. Material setup, icon and update UI changes require Flo's selection of the published static variants before implementation.

German description draft:

> Erstelle lokale Kopien deiner Strongbox-Sync-Backups in einem Ordner deiner Wahl. Nutze einen Cloud-Ordner, ein Netzlaufwerk oder einen USB-Datenträger. Die App kopiert die neueste vorhandene lokale Sicherung und entschlüsselt keine Datenbank. Strongbox Sync bleibt der primäre Speicher. Änderungen an einer Kopie werden beim nächsten erfolgreichen Kopieren ersetzt und niemals zurück übertragen. Öffne die Kopie deshalb schreibgeschützt. Der automatische Start und Mitteilungen sind wählbar. Eine erfolgreiche Kopie bestätigt weder den aktuellen CloudKit-Stand noch einen Cloud-Upload. Die optionale Google-Drive-Prüfung ist für ein späteres Update geplant und in dieser Fassung noch nicht verfügbar.

English description draft:

> Create local copies of your Strongbox Sync backups in a folder you choose. Use a cloud folder, network volume or USB drive. The app copies the newest available local backup without decrypting your database. Strongbox Sync remains the primary storage. Changes to a copy are replaced on the next successful copy and never transferred back. Open the copy read-only. Startup at login and notifications are optional. A successful copy confirms neither the current CloudKit state nor a cloud upload. Optional Google Drive verification is planned for a later update and is not available in this version.

Draft support instructions should request OS/app version, a fixed error message and reproduction steps using synthetic files. They should explicitly exclude database/key files, tokens, folder bookmarks and unredacted history. Pricing remains Flo's approximately EUR 5 one-time-purchase intention, subject to the actual Store price selection and agreements.

For screenshots, use the final signed build, fictitious database names and both languages. Capture database selection, the local-backup/one-way explanation, independent notification preferences and error recovery. Do not show Google verification as working before it ships. Apple lists accepted Mac sizes, including 1280×800, 1440×900, 2560×1600 and 2880×1800. Capture a supported size rather than stretching the UI. Final screenshots remain pending final name/icon/setup. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), [localizable metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/)

## Verification required before submission

| Area | Required evidence |
| --- | --- |
| Architecture/OS | Both Mach-O slices declare macOS 13.0. Runtime tests on an actual Intel Mac and supported older macOS remain separate from cross-compilation or Rosetta. Do not advertise those combinations as tested. |
| Packaged resources | Launch the detached final app with `.build` hidden; verify both languages and English fallback without a development-resource fallback. |
| Signed identity | Inspect the selected TeamIdentifier, Hardened Runtime and sandbox entitlements. Validate source-read and target-write grants before/after relaunch, moved app and upgrade. |
| Startup/lifecycle | In an isolated macOS user, test opt-in login registration, login/reboot/wake, denied permissions and ordinary quit during a copy using the production identity. |
| State/version | Preserve database choices, source/target bookmark bytes, history and notification suppression through the tested upgrade. Re-run schema migration cases when the schema changes. |
| Notifications | Production-signed delivery, denial, permission changes, cancellation and notification clicks with synthetic database selections. |
| Target integrity | Atomic copy behavior, absent volumes, lost grants, NAS/cloud-client targets and concurrent copy attempts. Existing copies remain intact on failure. |
| Distribution | Notarized and stapled direct candidate, quarantined Gatekeeper assessment and offline launch. Store package separately excludes every external updater and receives Store/TestFlight validation. |
| Product assets | Approved name/attribution, final icon/setup, real DE/EN screenshots, owned support/privacy URLs, publisher contact, export-compliance answers and selected price. |

Check the relevant earlier evidence under `docs/testing/` after #5–#7 land. Those development tests do not replace testing the production signing identity. Release publication and helper migration require their respective authorization.

Issue #10 remains open until the signing material, production tests, product assets and reviewable Store submission actually exist. The local packaging and research should be merged as preparation, not described as full completion.
