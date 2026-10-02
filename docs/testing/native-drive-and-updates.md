# Native Drive and update integration checks

Checked on 2026-10-02 and repeated after the final fixes on 2026-10-03,
on macOS 27.0.1, Apple Silicon, Xcode 27.0 and Swift 6.4.
The implementation is split across PRs [#17](https://github.com/flowsworld/strongbox-sync-backup-mirror/pull/17),
[#18](https://github.com/flowsworld/strongbox-sync-backup-mirror/pull/18) and the
native Drive provider PR linked from issue #9. The full ordinary-app acceptance
pass remains [#16](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/16).

The approved UI choices are Drive A with multiple accounts, updates A on the
Info page, first-start checklist B and one-way-copy icon C. Direct builds use
Sparkle 2.10.0. Development and Store builds exclude Sparkle and its helpers.

## Automated and packaging results

At source revision `8b746fa`, all 210 Swift test functions passed: 89 core
Swift Testing tests, 93 app Swift Testing tests and 28 XCTest tests. All 116
Python tests passed. Shell syntax checks passed for repository scripts, and
Bash syntax plus ShellCheck passed for the prepared local Google wizard.

| Check | Result |
| --- | --- |
| Development candidate | Universal release candidate 0.2.0, build 20261003; strict ad-hoc signature verification passed |
| Architectures and minimum OS | arm64 and x86_64 slices; both Mach-O headers declare macOS 13.0 |
| Archive | Recorded ZIP SHA-256 matched; extracted signature verified |
| Detached copy diagnostics | 19 isolated packaged copy checks passed while the entire `.build` directory was unavailable |
| Detached launch | English, German and French fallback demo processes remained running without `.build` resources |
| Direct compilation | Swift 6 typechecks passed for arm64 and x86_64 at macOS 13 with Sparkle 2.10.0 |
| Privacy manifest | Embedded file timestamp and elapsed-time declarations validated; no tracking or developer-collected data declared |

The detached diagnostic uses two synthetic databases and private sandbox
fixtures. It covers newest backups, initial copies, unchanged inode preservation,
per-database overrides, restoring changed copies, newer replacements, empty
backup preservation and ASCII/Unicode filename collisions. It does not exercise
login, wake, real folder grants or cloud accounts. All diagnostic processes and
extracted apps were removed; build resources were restored afterward.

## Verified behavior

The Swift tests use synthetic files, account stores and provider responses.
The transport tests use local URLProtocol fixtures; the browser callback test
uses only an isolated 127.0.0.1 listener. No test contacted Google or accessed
existing helper credentials. The account tests simulate credential storage,
including cancellation after storage, failed cleanup and retry after restart.

Current cloud confirmation requires a new successful check of the local file.
The hashing adapter holds the original directory and file descriptors through
the remote request and revalidates the selected copy. Restored confirmations
remain historical until that check succeeds. Account, folder, destination and
content changes invalidate results. Folder and filename matching rejects
ambiguous and incomplete provider results. The metadata scope covers all Drive
files; the consent copy explains that the chosen folder limits queries rather
than the OAuth grant. The app never uploads, modifies or downloads Drive files.

Controller tests cover coalesced requests, pending and overdue timing, error
and recovery notifications, deduplication, obsolete delivery removal, stopped
mutations and cancellation ownership. Local-copy tests include already matching
copies with no write history and cloud callbacks after local notification
completion. These ensure cloud checks begin only after the local scan settles.

Update tests cover durable settings, an active-copy wait, a newly prepared
installer during quit, cancellation during that wait, failed persistence and
resuming monitoring. The quit gate retains the instance lock and folder grants
until owned copy/provider work settles. Updater cancellation cannot restart
workers while termination owns the gate. Direct-update configuration rejects
invalid feeds or keys. The app disables Sparkle profile reporting and adds no
database data to its feed requests.

The copy engine uses exclusive publication for a new target and atomic exchange
for an existing target. Race fixtures confirm that a concurrently changed target
is preserved. Successful replacement also retains its displaced predecessor as
`.synccopies-UUID.tmp`; automatic deletion would introduce another unlink race.
These files consume space and require deliberate manual inspection/cleanup.
Filesystems without the required atomic rename operations fail safely.

## Reviews and fixes

Fresh Standards and Spec reviewers and local Codex Review found and verified
lifecycle and current-result defects. Focused failing fixtures preceded their
fixes, including updater cancellation during quit, unchecked restored cloud
confirmation, an unchanged existing local copy, replaced connection-cancellation
ownership, stale recovery wording, deferred credential cleanup and unowned
startup cleanup, staged-credential rollback journaling, directory durability
before credential deletion and already scheduled notification cancellation.
Each verified defect has a focused regression test. The last local full Codex
run was interrupted by its usage limit and is not counted as completed. GitHub
Codex reviews are requested only after current CI passes.
Greptile and Bugbot remain disabled.

## Remaining coverage

No Google project or Desktop OAuth client exists yet. The separate native-client
setup guide and local wizard are prepared, checked, and have not been run.
Actual OAuth consent, refresh after restart, two real accounts, revocation and
signed Data Protection Keychain access remain unverified. See
[the setup guide](../manual/native-google-setup.md).

Flo explicitly deferred signed beta #10. No Apple Developer account, Developer
ID certificate, notarization, App Store submission, production update host or
private update-signing key was provisioned. A signed old-to-new Sparkle update,
tampered production payload handling and Store delivery cannot be marked passed
using an ad-hoc candidate. Real Intel/macOS 13 runtime, VoiceOver, login/reboot,
NAS/SMB atomic rename support and unavailable real volumes also remain separate
acceptance coverage. Cross-compilation proves compilation and binary slices,
not those runtime behaviors.

The installed helper, real databases, daily-use targets, login items and system
notification permissions were not changed.
