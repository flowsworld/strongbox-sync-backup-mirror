# Remaining-work preparation checks

This is the historical preparation pass. The completed native integration and
its latest evidence are recorded in [native Drive and updates](native-drive-and-updates.md).

Tested on 2026-10-02 with code revision `22f0de7`, macOS 27.0.1 on Apple Silicon,
Xcode 27.0 and Swift 6.4. This covers the verification core and local packaging
prepared for #9–#11. Flo explicitly deferred #10 because an Apple Developer
account does not exist. The complete ordinary-app acceptance pass is tracked
separately in [#16](https://github.com/flowsworld/strongbox-sync-backup-mirror/issues/16).

| Check | Result |
| --- | --- |
| Swift full suite | 92 test functions passed, 51 core and 41 app tests |
| Python full suite | 111 tests passed, including four release CLI tests |
| Universal development candidate | Release build, sandbox ad-hoc signing and strict verification passed |
| Architecture/minimum OS | arm64 and x86_64 slices present; both Mach-O build commands declare macOS 13.0 |
| Archive integrity | ZIP SHA-256 matches the recorded checksum; extracted signature verifies |
| Payload permissions | Extracted executable mode is `0755`; the enclosing local artifacts remain private |
| Embedded resources | Localizations and the privacy manifest are inside the extracted app |
| Detached packaged startup | English, German and French-fallback demo launches remained running with the entire `.build` directory temporarily unavailable |
| Existing/concurrent releases | CLI rejects an existing artifact, preserves its contents and rejects another packager's lock |
| Direct-signing rejection | CLI rejects ad-hoc fallback and an unavailable explicit Developer ID identity |

The detached checks used a freshly extracted candidate and `--demo`. They
started only their own processes, requested no folder/notification permissions,
registered no login item and copied no database. All extracted apps and their
processes were removed afterward; `.build` was restored. Private local build
artifacts are ignored by Git. The installed helper and real source/target data
were not changed.

The 15 new verification tests use known synthetic digests and public APIs.
They cover SHA-256 precedence, MD5 fallback, size mismatch, absent checksums,
waiting/overdue/recovery, paused error intervals, historical confirmations,
content/context reset, recreated IDs, persistence, corrupt state and bounded
arithmetic. They perform no network requests or credential access. This core
is not yet connected to the app.

The startup checks prove resource independence and process startup. They do
not prove every translated string, layout or accessibility action. Those
earlier checks are recorded in [the localization evidence](issue-7-localization.md).
Cross-compilation does not prove Intel or older-macOS runtime compatibility.
Developer ID signing, notarization, Store submission, real Google integration
and signed updater upgrades were not tested.
