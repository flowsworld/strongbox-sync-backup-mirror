# macOS update distribution

Research for [issue #11](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/11), checked on 2026-10-02. The initial research proposed Sparkle. Flo has since approved Sparkle 2.10.0 and a separate Info page. The direct-only adapter and local packaging are implemented; a production-signed old-to-new update is not proven. No production account, update host, signing key or public release was created.

## Verified baseline

The app targets macOS 13 in [Package.swift](../../macos-app/Package.swift). Its default development and Store graphs depend only on `SyncCopiesCore`; explicit direct builds additionally resolve Sparkle 2.10.0. The development build initially inspected for this research uses the bundle identifier `cloud.diesis.sync-copies`, version `0.1.0`, build `1` and ad-hoc signing in [build.zsh](../../macos-app/build.zsh). The accompanying release-preparation work adds offline universal macOS 13+ development and direct candidate packaging in [release.zsh](../../macos-app/release.zsh), keeping that identifier. The release-preparation baseline had no updater. Direct candidates now embed the adapter and framework, disabled without an explicit HTTPS feed and Ed25519 public key. They establish neither a selected production identity nor signed grant continuity.

[entitlements.plist](../../macos-app/entitlements.plist) grants App Sandbox, user-selected read/write files and app-scoped bookmarks. Strongbox source selection creates a read-only security-scoped bookmark in [Services.swift](../../macos-app/Sources/SyncCopies/Services.swift). The updater must not change that restriction.

[Application.swift](../../macos-app/Sources/SyncCopies/Application.swift) postpones ordinary termination until `AppModel.shutdown()` completes. That method stops triggers, waits for the active scan and releases access and the instance lock. It does not report whether all preference writes succeeded. [AppModel.swift](../../macos-app/Sources/SyncCopies/AppModel.swift) stores bookmarks, selections, notification preferences and history as Codable JSON without a schema version. These are useful existing boundaries, but they do not prove safe Sparkle termination or migration.

## Facts from primary sources

| Question | Verified fact and source |
| --- | --- |
| Current release | Sparkle's latest stable release is **2.10.0**, published on 2026-09-13. Its deployment target is macOS 12.0. It is compatible with the app's declared macOS 13 minimum; actual app integration still requires testing. [Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0), [pinned manifest](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift). |
| Package identity | The 2.10.0 manifest declares a binary Swift package artifact with SHA-256 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`. GitHub's release API reports the matching asset digest. The tools archive `Sparkle-2.10.0.tar.xz` has digest `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`. These were checked as published metadata, not by downloading and inspecting the binaries. [Manifest](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift), [release API](https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/2.10.0). |
| License | Sparkle uses an MIT-style license and includes notices for bsdiff, sais-lite, Ed25519 and signature-verification code. Ship the complete pinned `LICENSE`, including the component notices, in the direct bundle's third-party notices. Preserve notices and mark altered source where required. [2.10.0 license](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE). |
| Store distribution | Guideline 2.4.5(vii) requires Mac App Store updates to use the Store. Beta distribution through Apple's channel uses TestFlight. This does not guarantee approval of this app's private Strongbox metadata access. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility). |
| Direct signing | Apple requires appropriate Developer ID signing, Hardened Runtime, secure timestamps and no enabled `get-task-allow` for notarization. Store submission includes its own security checks. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). |
| Packaging | Apple accepts ZIP submissions for notarization, but a ZIP cannot carry a stapled ticket. Staple the app and recreate its distribution ZIP afterward. Stapling supports offline ticket discovery. [Apple custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). |

Sparkle's online guides describe the current integration. The selected release's [ConfigCommon.xcconfig](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Configurations/ConfigCommon.xcconfig) independently confirms macOS 12.0, the `Installer` and `Downloader` service names, embedded service defaults and Hardened Runtime. Recheck online instructions against the pinned artifact when implementing.

## Proposed distribution decisions

Use one copy engine and app UI with an explicit build configuration. Keep updater code in a direct-only target or dependency graph. A Store build must not resolve, link or embed Sparkle, its installer helpers or updater resources. Disabling the updater at runtime is insufficient. Verify the packaged Store app with a recursive file inventory, linked-library inspection and an entitlement audit.

| Build | Proposed identity | Updates and signing |
| --- | --- | --- |
| Development and current direct candidate tooling | Retain `cloud.diesis.sync-copies` | Offline development/candidate preparation; no production feed, install or publication. |
| Store | `cloud.diesis.sync-copies.store` | App Store distribution signing and provisioning under the selected Apple team. Store updates only. |
| Direct stable | Prefer retaining `cloud.diesis.sync-copies` if Flo confirms production continuity. Alternative `cloud.diesis.sync-copies.direct` needs migration. | Developer ID Application under the selected team, notarized; stable HTTPS appcast. |
| Direct beta | `cloud.diesis.sync-copies.direct.beta` | Developer ID Application, notarized; separate beta HTTPS appcast and container. |

Production bundle identifiers are proposals, not registered identities. The current candidate tooling's shared identifier is development-only evidence. Prefer identity continuity for the eventual direct app where it can preserve existing settings and grants. An ad-hoc-to-Developer-ID change still needs a real grant-persistence test; the identifier alone does not prove continuity. Separate Store/beta identifiers make side-by-side installation, containers, login registration and feed isolation explicit, but require migration and new grants. Flo must confirm continuity, the final product name, Apple team and identities before registration or the first persistent signed installation. Keep the final app bundle filename unchanged within each identity's update stream.

Sparkle is approved and pinned exactly to 2.10.0. Commit the resolved version and verify the downloaded artifact against its pinned checksum. Keep the framework and release tools at the same version. Do not use a floating dependency range or nightly build for release packaging.

Use `CFBundleShortVersionString` for the user-visible three-part product version. Allocate a globally increasing positive integer `CFBundleVersion` for each release build. For example, product `0.2.0`, build `100` can be a beta and product `0.2.0`, build `101` its stable successor. Failed release builds consume their number. Channel configurations built for one release may share the number if their source and product version match. The allocator must check previous shipped builds, not just CI's current run number. Sparkle selects newer builds through `CFBundleVersion`; do not substitute a custom comparator. [Sparkle integration](https://sparkle-project.org/documentation/), [delegate version-comparison contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).

Recommend an already controlled static HTTPS origin, with no update application server or database. A placeholder layout is `https://updates.example.invalid/sync-copies/direct/stable/appcast.xml` and `.../beta/appcast.xml`. Immutable archives live under build-number paths. This is a URL specification, not a real host. Choose and authorize the real hostname/provider separately. A release configuration must reject placeholder URLs.

Use separate beta and stable Ed25519 keys. Generate keys only on an authorized signing machine, keep them in its Keychain, and maintain an encrypted offline backup controlled by Flo. Commit only public keys and fingerprints. Keep Apple certificate private keys, notarization credentials and Sparkle private keys out of the repository, app, archive, feed, logs and hosting environment. Hosts need upload permission, never signing keys. Sparkle supports changing an Ed25519 key or Developer ID identity in an update, with restrictions; do not rotate both simultaneously. With pre-extraction verification, the documented key-recovery route needs a Developer ID signed DMG. Test a recovery release before relying on that route. [Sparkle key handling and rotation](https://sparkle-project.org/documentation/).

## Direct sandbox and helper integration

The proposed direct build stays sandboxed. Enable `SUEnableInstallerLauncherService` and retain `Installer.xpc` inside `Sparkle.framework/Versions/B/XPCServices`. Set `com.apple.security.temporary-exception.mach-lookup.global-name` to an array containing exactly `<direct bundle identifier>-spks` and `<direct bundle identifier>-spki`. Omit it from Store builds. A custom packager must expand the actual identifier. [Sparkle sandbox integration](https://sparkle-project.org/documentation/sandboxing/).

Embed the framework in the host's `Contents/Frameworks`, with the executable runpath `@executable_path/../Frameworks`. Keep XPC services inside the framework rather than the host's `Contents/XPCServices`. The pinned updater checks for misplaced services. [2.10.0 integration checks](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdater.m), [framework setup](https://sparkle-project.org/documentation/).

Prefer host `com.apple.security.network.client` in direct builds and leave `SUEnableDownloaderService` false. The Google verification proposal also requires outgoing network access. The network entitlement permits connections, not Strongbox writes. The Store variant may need network access for Google independently of updates; it must not acquire updater exceptions for that reason.

If the app remains entirely offline except for updates, the documented alternative enables `Downloader.xpc`. The prebuilt downloader is unsandboxed by default and uses legacy release-note rendering when the host lacks network access. A sandboxed downloader needs a source build with a unique service identifier and its own outgoing-network entitlement. This is a different integration choice and must be audited separately. Do not enable both download paths. [Pinned downloader configuration](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Configurations/ConfigCommon.xcconfig), [downloader entitlements](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Downloader/Downloader.entitlements).

Inspect this direct helper inventory before signing:

| Nested component | Required handling |
| --- | --- |
| `XPCServices/Installer.xpc` | Sign with the app's Developer ID Application identity and Hardened Runtime. Do not apply the host's App Sandbox entitlements to it. |
| `XPCServices/Downloader.xpc` | Prefer removal before signing when unused. If retained, preserve its appropriate entitlements while signing; do not copy the host entitlement file onto it. |
| `Autoupdate` | Sign with the same identity and Hardened Runtime. |
| `Updater.app` | Sign with the same identity and Hardened Runtime. |
| `Sparkle.framework` | Sign after its nested code. Preserve framework symlinks and executable permissions. |
| Host app | Sign last with the channel's host entitlements and Hardened Runtime. |

Xcode archive/export handles Sparkle's nested signatures. A plain framework "sign on copy" operation does not finish helper signing. For this repository's custom packager, sign inside out, add secure timestamps and verify each nested component. Do not use `codesign --deep` to sign. [Sparkle signing instructions](https://sparkle-project.org/documentation/sandboxing/).

Run `codesign --verify --deep --strict` for verification, inspect signatures and entitlements, check all components use the intended TeamIdentifier, and reject `get-task-allow` or disabled library validation in a release. Submit for notarization, require an accepted result, staple and validate the tickets, and run Gatekeeper assessment on the distributed artifact. Neither the current ad-hoc development build nor a successful unit suite substitutes for these checks. [Apple signing requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Proposed behavior and privacy

Use Sparkle's standard controller for its own update flow. Flo approved the separate Info page; its controls are implemented there. The app must provide German and English manual-check actions and separate choices for automatic checking and automatic download/installation. Recommended defaults are automatic checks off and automatic installation off; the user can enable each. Store builds show the Store destination and explain that automatic updates follow Store preferences. They must not offer a direct-install action.

For the direct proposal, configure `SUEnableAutomaticChecks=false`, `SUAutomaticallyUpdate=false`, `SUEnableSystemProfiling=false`, `SUEnableJavaScript=false`, `SUVerifyUpdateBeforeExtraction=true` and `SURequireSignedFeed=true`. Set `SUSignedFeedFailureExpirationInterval=0` so a broken feed signature does not silently expire. This fails closed if the signing key is lost, so the key backup and manually authenticated recovery procedure are release requirements. Bind user changes through Sparkle's settings APIs, not repeated default resets. [Sparkle customization](https://sparkle-project.org/documentation/customization/).

Do not implement profile reporting, custom feed query parameters, cookies, update credentials or a persistent client identifier. Sparkle's optional system profile sends device and application metadata as URL query parameters. Disable it explicitly. Audit outbound requests after integration, including headers, redirects and release-note loading. [Sparkle profiling](https://sparkle-project.org/documentation/system-profiling/).

The update service receives only requests for appcasts, app archives and release notes. It must never receive database names, identifiers, paths, encrypted database files, checksums, history, folder bookmarks or Google credentials. OS and app metadata may still appear in transport headers; the host sees the connection IP and request time. Before publication, inspect the actual provider's access-log defaults, retention and subcontractor policy. Prefer no analytics, no third-party assets in release notes and minimal retained access logs. Document the chosen provider and retention rather than claiming that static hosting collects nothing. Produce self-contained German and English notes as meaningful static HTML.

## Shutdown, migration and switching

Route update termination through the existing model shutdown boundary, extended to report durable preference-save success. Suspend new timer, wake and file triggers before waiting for the active copy/check. Do not cancel the atomic file replacement midway. Persist settings and history before allowing installation or relaunch. A failed save must block update termination and let the app resume safely. Do not release the process lock before the state is durable.

Sparkle exposes a relaunch-postponement delegate and an install-on-quit delegate. The relaunch hook is not called on every termination path. Integrate them with `applicationShouldTerminate`, test ordinary quit and update quit, and release any deferred installer callback only once. Preserve a usable app if termination is cancelled. [Pinned 2.10.0 delegate contracts](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdaterDelegate.h).

Before the first updater-bearing build, define a versioned settings envelope. Treat the current unversioned JSON as schema zero. Migrate to a temporary file, validate the full typed result and commit atomically. Keep a private local recovery copy of schema-zero settings. Reject unsupported future schemas without replacing them or starting copies. Tests must cover missing new keys, malformed data and an interrupted write. Preserve all source/target bookmark bytes, enabled selections, per-database destinations, notification choices, error suppression and the bounded history. Resolve grants under the new signed process and verify their scope without exporting them.

For the first release, support automatic upgrades only within the same signed identity and feed. Store/direct and beta/stable switches must never happen automatically. Prefer preserving existing development settings and grants for the eventual direct identity when a signed continuity test proves that safe. If grants cannot survive the signing change, preserve selections and history locally, leave copying inactive and request new folder grants through the approved setup flow.

Alternative channel identifiers require an explicit local export/import migration or fresh setup with new grants. A migration must preserve supported selections, destinations and history without promising portable security scopes. Until that feature is approved and implemented, separate installations start with empty configuration and copy disabled. A user who changes distribution must quit the old app and disable its login item before reauthorizing folders and enabling copies in the new one. Two channels pointing at one target must still respect the shared destination lock. The export/import workflow needs its own approved UI and tests; file bookmarks and Google tokens must not be put in a portable export by default.

If stable has a lower build number than an installed beta, do not downgrade automatically. Returning to stable requires the separate installation workflow or waiting for a later supported stable build. Never change feed URLs from remote content or infer distribution from a Store receipt at runtime.

## Reproducible release and appcast plan

Reproducible means a recorded process with immutable inputs and auditable output hashes. Apple signing timestamps and notarization tickets prevent a promise of byte-identical signed builds.

1. Record commit, product/build version, distribution, architecture set, minimum OS, Xcode/SDK version, pinned Sparkle checksum and public-key fingerprint. Require a clean source tree and passing local tests. Produce and test both arm64 and x86_64 slices if both are advertised.
2. Package the chosen channel from a fresh staging directory. Reject unknown distributions, missing identity/feed/key and placeholder values. Audit Store exclusion and direct helper inventory before inside-out signing.
3. For the initial direct package, use an app-only ZIP created with `ditto` and preserved framework links. Notarize that submission, staple the app, and recreate the final update ZIP. Record its SHA-256 and byte length. Do not repackage the ZIP after appcast signing. [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [Apple stapling](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
4. Run the pinned `generate_appcast` tool in a disposable copy of the channel's release archive inventory. Use `--maximum-deltas 0` initially, explicit HTTPS `--download-url-prefix` and `--release-notes-url-prefix`, and a separate output feed. Supply private keys through the Keychain. The tool reads OS/architecture requirements from the bundle and can move older artifacts, so do not point it at the sole release archive. [2.10.0 tool options](https://github.com/sparkle-project/Sparkle/blob/2.10.0/generate_appcast/main.swift).
5. Validate the generated XML, signed feed and notes, archive signature, build ordering, exact enclosure size, OS floor `13.0`, architecture availability and channel identity. Include only releases that the installed schema can upgrade to. Retain an older compatible item if a later release raises its OS minimum. Verify that stable never contains beta artifacts and vice versa.
6. Exercise the staged old-to-new update over isolated HTTPS with no real databases. Keep the final bytes and test reports. Production hosting and publication require Flo's explicit authorization.
7. After authorization, upload immutable archives and notes first, verify the hosted bytes, then atomically replace the signed feed. Hosts must not rewrite XML or HTML after signing. Store the previous feed for recovery. Withdraw a bad item rather than automatically downgrading installed clients. Ship a corrective higher-numbered build when necessary.

The initial package uses full ZIP updates. Delta updates, phased rollouts and DMG-based key recovery are later release capabilities with separate tests. Keep signing tools and symbols in private release storage; publish only the app artifacts, feed and sanitized release notes.

## Signed old-to-new validation matrix

Create two genuine production-signed, notarized isolated direct builds, A and B, with the same test identity, app name, signing team and increasing build number. Use synthetic databases and private local targets. Give A source-read and target-write grants through normal dialogs, set preferences/history and exercise its login registration in a disposable macOS user. Perform every case on macOS 13 and the current supported macOS on available Apple Silicon and Intel machines or VMs. Record missing combinations as untested, not passed. Test intermediate supported major versions before advertising the complete compatibility range.

| Case | Required observation |
| --- | --- |
| A to B, manual check | The signed archive installs and relaunches B; B reads A's settings and preserves history and bookmarks without broader source access. Record before/after build and TeamIdentifier. |
| A to B, automatic check | Defaults stay off; enabling checks downloads the feed without opting into installation. Enabling automatic download/install preserves the user's choice after restart. |
| Active copy/check | Trigger the update while a large artificial copy is active. Replacement finishes or reports its normal failure, state becomes durable, and only then does the updater terminate/relaunch. Check target contents and temporary-file behavior. |
| Persistence failure | Deny settings writes in the test fixture. Installation/termination stays blocked, the old app remains usable and the previous settings survive. Restore permissions and retry. |
| Offline and feed failure | Disconnect or return DNS/TLS/HTTP errors. Copying continues and the manual check explains failure. No old target is changed by the updater. |
| Cancelled/interrupted download | Cancel and drop the connection at different stages. A remains installed; retry succeeds and partial downloads never become an installed app. |
| Archive tampering | Alter final ZIP bytes or its Ed25519 signature. Reject before extraction/installation and preserve A and its settings. |
| Feed/notes tampering | Alter a signed feed item or release note. Reject the changed information, with no unsigned-feed expiration fallback. |
| Signing mismatch | Serve an artifact with a wrong signing identity or invalid nested signature. Verify the exact rejection and that A remains usable. |
| Unsupported OS | Serve an item requiring a newer OS than the test machine. Do not download/install it; retain a compatible older feed item. Also confirm the app cannot launch below its declared macOS 13 floor. |
| Installation failure | Use a read-only location and deny required authorization. Record the failure and retry behavior; A and existing target copies remain intact. |
| Interrupted installation | Terminate the disposable test VM at installation/relaunch boundaries. After recovery, verify a valid installed bundle, settings, grants, login item and target integrity. |
| Migration | Upgrade schema-zero A to B, including per-database targets and suppressed identical errors. Test corrupt, unknown-future and interrupted-migration settings separately. |
| Grants | Test persisted grants after signed upgrade, moved app, denied source grant, denied target grant and an unavailable external volume. Require reauthorization where needed; never replace failure with broader access. |
| Channel isolation | Stable cannot find beta updates; no package can replace a Store installation through Sparkle. New channel installation starts inactive and does not inherit the old login item or credentials. |
| Store package | Inspect the final submitted package for any Sparkle binary, helper, feed/key setting, external updater linkage or Mach exceptions. Verify Store update behavior separately after an authorized Store/TestFlight submission. |
| Privacy | Capture all update requests and review the hosting logs. Confirm the absence of database/Google data, query profiles and third-party note resources. |

For each run, record OS/architecture, commit, A/B versions, artifact hashes, signature identities, notarization IDs, grant/setup conditions and fixed check results. Use synthetic names only. Keep targets private and retain them only for the agreed test duration. Existing real backups and daily-driver app installations are outside this matrix.

## Work still required for issue #11

The research and unconfigured direct/Store candidate implementation are complete. The following acceptance criteria remain open:

- Flo's confirmation of final production distribution identities and the actual feed/public key.
- An authorized Apple account/team, Developer ID and Store signing/provisioning material, and controlled key backups.
- Independent review of the new direct-only packager and updater adapter.
- Parent integration of the approved Info page and its German/English resources.
- Final host shutdown integration, cancellation recovery and tested durable schema migration.
- A real signed A-to-B sandbox test, nested helper/notarization checks and grant-persistence evidence across the supported OS/architecture matrix.
- An approved production HTTPS host and privacy/log-retention decision. Public publication is a separate authorization.

Do not close issue #11 or label the app updater-ready from this document alone.

## Local implementation evidence

`DIESIS_DISTRIBUTION=direct` selects the Sparkle package, compiler flag and executable runpath. The default development and explicit Store manifests have empty external dependency graphs. The direct dependency lock is [ThirdParty/Sparkle-Package.resolved](../../macos-app/ThirdParty/Sparkle-Package.resolved); the build script installs it for direct resolution and removes its own temporary root lock afterward. This avoids SwiftPM resolving stale direct pins while building a dependency-free channel. The full license is included in direct app resources.

[AppUpdates.swift](../../macos-app/Sources/SyncCopies/AppUpdates.swift) starts only after the app launches, only with valid direct feed/key settings, and never in preview. It uses the standard Sparkle driver, signed feeds and pre-extraction archive verification. Automatic checks and installation default off. System profiling is forced off; the adapter supplies no feed parameters. The Info page presents version, build, distribution, manual checking and separate automatic preferences. Store controls open only an explicitly configured `apps.apple.com` HTTPS destination.

The host supplies `prepareForUpdate`, which must wait for active copy/check work and durably save settings. The adapter retains a postponed installation after a failed save for explicit retry. `isInstallingUpdate` also identifies install-on-quit so the host applies the same durability gate to that path. The host's idempotent `resumeAfterCancelledUpdate` callback restores normal copying if Sparkle aborts after preparation. These callbacks are separately tested; they do not replace signed installer validation.

On 2026-10-02, seven focused adapter/configuration tests passed using the dependency-free development graph. Universal local direct and Store candidates built successfully. Their Mach-O deployment floor is 13.0 for both arm64 and x86_64. Direct has Sparkle and inside-out ad-hoc helper signatures. Store has no Sparkle framework, updater linkage, XPC helpers, update plist keys or Mach exceptions. Both channel manifests were inspected; deep/strict signatures passed. Both packaged executables loaded in isolated preview processes, which were then terminated. Invalid cross-channel feed settings, incomplete keys, HTTP feeds and non-Apple Store links failed before compilation. No candidate was installed, no signing identity or account was used, and no update feed was contacted. Full host integration and final channel audits are recorded in the parent task before release.

The local SwiftPM binary downloader stalled. The same official artifact downloaded through `curl`, matched the pinned SHA-256 and was supplied through an isolated scratch cache. SwiftPM then validated/extracted it. No global package cache was changed and no alternate dependency source was used.
