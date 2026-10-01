# macOS sandbox feasibility probe

Throwaway, read-only experiment for the proposed Strongbox Sync mirror app. This is not the app implementation or a UI design. It installs no LaunchAgent, changes no existing helper configuration, and never copies or decrypts a database.

## Build and verify

```sh
zsh experiments/macos-sandbox-probe/build.zsh
python3 experiments/macos-sandbox-probe/verify.py
```

Requires macOS and Swift 6. Builds for the current CPU architecture with a macOS 13 deployment target. Compatibility has only been exercised on the machine recorded in the research findings. The app is ad-hoc signed, not Developer ID or App Store signed. Build outputs are ignored by git.

Fixtures exercise native parsing of binary keyed archives, multiple Sync databases, nicknames distinct from filenames, provider filtering, percent encoding, conflicting UUIDs, unsafe names, empty newest backups and symlinks. A separate signed process must fail to read an unselected fixture in the checkout. No real source is read by this verification command.

## Real source access

First try the known source path without an open panel:

```sh
open -n -W experiments/macos-sandbox-probe/build/StrongboxSandboxProbe.app --args --direct "$HOME/Library/Group Containers/group.strongbox.mac.mcguill"
```

If that fails, grant access through the standard macOS folder picker, opened at the known path:

```sh
open -n -W experiments/macos-sandbox-probe/build/StrongboxSandboxProbe.app --args --grant "$HOME/Library/Group Containers/group.strongbox.mac.mcguill"
```

Select the group container itself, not just `backups`. Its metadata provides display names and maps database identities to backup subfolders. The app requests only user-selected read access and saves a read-only security-scoped bookmark. Backups are read in chunks to exercise actual byte access. No bytes, hashes, database names, UUIDs or source paths are written to the reports.

Then launch fresh processes without a picker:

```sh
open -n -W experiments/macos-sandbox-probe/build/StrongboxSandboxProbe.app --args --resume
open -n -W experiments/macos-sandbox-probe/build/StrongboxSandboxProbe.app --args --background
```

The background mode has no window. It reads immediately and twice more at five-second intervals. This tests retained access within the same app identity. It does not register a login item or prove access from a separate helper, after reboot, or after sleep/wake.

The latest count-only report is stored at:

```text
~/Library/Containers/cloud.diesis.strongbox-sandbox-probe/Data/Library/Application Support/probe-result.json
```

The bookmark is saved in this probe's sandbox preferences. Nothing is stored in Strongbox's container. Cancelling the picker produces `selectionCancelled`. Missing or stale bookmarks fail instead of silently asking for broader permissions.

`--catalog` and `--inspect-fixture` are diagnostic CLI modes used only by generated-fixture verification. The unsigned fixture CLI does not prove sandbox behavior. Its catalog output includes artificial fixture names. Use the signed `.app` for permission tests.

## Limits and next steps

- The adapter understands the archive structure in the inspected public Strongbox revision. Unknown layouts fail. No application schema/version marker was found, so this is not a complete future-version compatibility gate.
- This probe reads sources only. Its symlink checks are not a production defense against replacement races. A shipping copy engine needs descriptor-based file identity checks and atomic destination replacement.
- Neither the test nor a successful bookmark establishes the latest CloudKit state.
- No cloud service, Keychain credential, login item or existing mirror target is touched.
- Production signing, App Review, login/reboot, sleep/wake, revoked grants and actual target copying remain separate validation tasks.

See [the feasibility findings](../../docs/research/macos-app-feasibility.md) and [Strongbox interface research](../../docs/research/strongbox-supported-interfaces.md).
