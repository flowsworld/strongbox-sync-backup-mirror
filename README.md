# Strongbox Sync backup mirror

This tool mirrors the newest local Strongbox backup of a Strongbox Sync database
into a folder of your choice on the same Mac. Pick a folder that a sync client
such as Google Drive, Dropbox, OneDrive, or iCloud Drive uploads, or a NAS
mount or USB drive. You can then open the database read-only on Windows or in
other KeePass-compatible apps that cannot reach Strongbox Sync. Strongbox Sync
stays the primary storage.

For Google Drive, an optional upload check asks the Drive API for the file's
metadata and confirms that the upload matches the local copy. Other targets
work without it.

## Requirements

- macOS with Strongbox and a database stored in Strongbox Sync.
- An existing target folder, for example inside a cloud sync client.
- The local copy uses only zsh and tools that ship with macOS, such as `plutil`,
  `base64`, and `xmllint`.
- Python 3.10 or newer, only for the optional Google Drive upload check and
  the tests.
  No extra Python packages are needed.

## Quick start

```sh
git clone https://github.com/flowsworld/strongbox-sync-backup-mirror.git
cd strongbox-sync-backup-mirror
cp config.local.example.zsh config.local.zsh
```

Edit `config.local.zsh` and set at least these two values:

```zsh
DATABASE_NAME='Passwords.kdbx'
TARGET_DIR="$HOME/Library/CloudStorage/Dropbox/Backups"
```

`DATABASE_NAME` is the file name of the database as Strongbox shows it.
`TARGET_DIR` is any existing folder. Some folder names depend on the system
language; Google Drive's "My Drive", for example, is "Meine Ablage" in German.

Install the LaunchAgent. It runs the first sync right away:

```sh
/bin/zsh install.zsh
```

Optional, for Google Drive targets only: set up the upload check. The running
job picks it up on its next run.

```sh
./setup-google-drive.sh
```

The background job may need a macOS privacy permission. See
[macOS privacy](#macos-privacy).

## How it works

- `strongbox-source.zsh` reads the Strongbox metadata on every run and maps
  `strongbox-cloud:/<DATABASE_NAME>` to its current backup subfolder. Local or
  Google Drive databases with the same file name do not count as a source. It
  picks the newest `.bak` file by creation date. It uses no fixed UUID and never
  decrypts the database.
- `sync.zsh` compares the selected backup with the target file. If the content
  is the same, it writes nothing.
- A changed backup is copied to a temporary file in the target folder, checked,
  and renamed to `<DATABASE_NAME>`. A missing or empty source or an unclear
  mapping leaves the target copy unchanged. On each run, `sync.zsh` removes
  temporary copies (`.<DATABASE_NAME>.XXXXXXXX`) that an interrupted run left
  in the target folder.
- A per-user LaunchAgent starts at login, on watched file changes, and every
  15 minutes. launchd catches up on missed calendar runs after wake. A lock
  prevents parallel runs.

The source is the newest **local backup**. It is not necessarily the current
CloudKit state. The next run replaces any change made to the mirrored copy
with the source, so open the copy read-only.

The mapping relies on internal Strongbox metadata. If Strongbox changes that
format, the run stops with an error. It never falls back to a different
database.

The job watches the backup subfolder found at install time, the parent backup
folder, and the metadata file. launchd does not guarantee delivery of every
file event. If the database gets a new UUID, the 15-minute check finds the new
subfolder on its own; run the installer again to watch it directly. A copy can
overlap with a Strongbox write. The script checks the source and the copy
before it replaces the target, and the next scheduled run retries a failed
attempt.

## Configuration

`config.zsh` holds the defaults and is tracked in git. Your own values go into
`config.local.zsh`, which git ignores. An environment variable
`STRONGBOX_<NAME>` overrides both. Precedence, highest first:

1. Environment variable, for example `STRONGBOX_TARGET_DIR`.
2. `config.local.zsh`.
3. Defaults in `config.zsh`.

| Name | Required | Default | Meaning |
| --- | --- | --- | --- |
| `DATABASE_NAME` | yes | none | File name of the Strongbox Sync database, without a path. The copy in `TARGET_DIR` gets the same name. |
| `TARGET_DIR` | yes | none | Existing target folder, absolute path. |
| `NOTIFY` | no | `1` | `1` shows macOS notifications for errors, `0` turns them off. |
| `CLOUD_WARNING_SECONDS` | no | `1800` | Time before the upload check reports an overdue upload. Positive integer. |
| `PYTHON` | no | first of `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3` | Absolute path to Python 3.10+ for the upload check. |
| `BACKUP_ROOT` | no | `~/Library/Group Containers/group.strongbox.mac.mcguill/backups` | Strongbox backup folder, without the database UUID. |
| `PREFERENCES` | no | `~/Library/Group Containers/group.strongbox.mac.mcguill/Library/Preferences/group.strongbox.mac.mcguill.plist` | Strongbox preferences that contain the database mapping. |

`sync.zsh`, `install.zsh`, and `setup-google-drive.sh` validate the configuration and
stop with a message if `DATABASE_NAME` or `TARGET_DIR` is missing or a value is
malformed. `NOTIFY` must be `0` or `1`, `CLOUD_WARNING_SECONDS` a positive
integer, and all paths absolute. `DATABASE_NAME` must not contain a `/`.

The installer writes every value into the LaunchAgent's environment. The job
keeps the values from install time, so run `/bin/zsh install.zsh` again after
you change the configuration.

## Running and installing

A manual run replaces the target copy if the content changed:

```sh
/bin/zsh sync.zsh
```

Print the LaunchAgent configuration without installing it:

```sh
/bin/zsh install.zsh --print-plist
```

Install and run once for the current user:

```sh
/bin/zsh install.zsh
```

The job points to this checkout, so do not move the folder after installing.
If a job is already loaded, the installer removes it and waits until launchd
has unloaded it before it loads the new one.

Check the source mapping without copying a database:

```sh
/bin/zsh <<'ZSH'
source ./config.zsh
/bin/zsh ./strongbox-source.zsh watch-dir "$PREFERENCES" "$BACKUP_ROOT" "$DATABASE_NAME"
ZSH
```

`strongbox-source.zsh` answers two queries with the same three inputs.
`watch-dir` prints the current backup subfolder, even if it is still empty.
`latest-backup` prints the newest non-empty backup file. If the newest file is
empty, the query fails instead of falling back to an older backup. On success,
stdout contains only the path. On failure, stderr contains a fixed message and
the exit code is 1. The installer uses `watch-dir`, the sync uses
`latest-backup`.

## Updating

```sh
/bin/zsh update.zsh
```

The updater pulls the newest version with `git pull --ff-only` and runs
`install.zsh` from it. It stops if tracked files in the checkout have local
changes; `config.local.zsh` is not tracked and stays as it is.

## Status and errors

```sh
launchctl print "gui/$(id -u)/cloud.diesis.strongbox-sync-backup-mirror"
```

Logs and status files live in the state folder
`~/Library/Application Support/strongbox-sync-backup-mirror/`:

- `sync.log`: local copies, new errors, and recoveries.
- `launchd.log`: output of the background process.
- `last-error`: the last error, used to suppress repeated notifications.
- `cloud-status.json`: result of the last upload check, if enabled.

A new error shows a macOS notification through `osascript`. The same error
does not notify again until a run succeeds. Successful runs do not notify.

If the lock cannot be created, the run fails. A lock held by a running process
skips the run without an error. If `sync.log` is not writable, the run stops
before copying. A failed later log entry is also reported as an error. The
notification works without a writable `sync.log`; its output then goes to
`launchd.log`. Metadata errors use fixed messages without random temporary
paths, so repeated errors are recognized as the same error.

A successful run confirms the local copy only. Whether a sync client has
uploaded it shows in that client, or for Google Drive in the optional upload
check. The logs are not rotated.

## Google Drive upload check

This check is optional and only works when `TARGET_DIR` is a Google Drive for
desktop folder. Without the setup below, the sync never runs it and needs
neither Python nor a Google account.

`upload_check.py` asks the Google Drive API for `<DATABASE_NAME>` in the
configured Drive folder. It compares size and SHA-256 checksum with the local
target file, and uses MD5 if Google returns no SHA-256. The check downloads no
database content and changes no Drive files. It confirms the cloud state of the
local copy at check time. It does not confirm the CloudKit state or that a
Windows machine received the file.

### Setup

`setup-google-drive.sh` walks you through the one-time setup for a new Google Cloud
project:

```sh
./setup-google-drive.sh
```

It reads `DATABASE_NAME` from the configuration. It guides you
through enabling the Drive API, configuring the Google Auth Platform, and
creating an OAuth client of type **Desktop app**. It needs the downloaded
client JSON and the browser address of the Drive folder that holds the copy.
The sign-in opens the default browser and accepts the redirect only on
`127.0.0.1`, with PKCE and a random state check. You have five minutes to
finish the sign-in. Before saving, the script shows the signed-in account and
the chosen folder and asks you to confirm.

The setup creates `upload-check.json` in the state folder, which turns the check on.
Without that file, the sync does not run the check and does not need Python.
The setup does not install or start the LaunchAgent. An installed job starts
the check on its next run.

### Permissions and credentials

The setup requests only the `drive.metadata.readonly` scope. It covers the
metadata of all Drive files the account can access, not only the target
folder. It allows neither downloads nor changes.

The OAuth client data and refresh token are stored in the macOS keychain under
service `cloud.diesis.strongbox-sync-backup-mirror.google-drive`, account `oauth`.
They never appear in process arguments, environment variables, or logs. The
scripts access the keychain through `/usr/bin/security`. Access you grant to
that tool is not limited to this project. The downloaded client JSON also
contains credentials; keep it safe or delete it after setup. `setup.env` in
the state folder stores only the project ID and the path to the client file.

For external OAuth apps in testing mode, Google expires the refresh token after
seven days, also for listed test users. For long-term use, set the publishing
status under **Google Auth Platform > Audience** to **In production** before
you sign in. If **Publish App** is disabled, fill in the missing details under
**Branding** first. Google may ask for a home page and a privacy policy URL,
which must match the application. If you signed in while in testing mode, run
the setup again in production mode to get a new refresh token. A personal,
unverified app can still show a Google warning. If Google blocks the access,
stop the setup and read Google's message.

### Behavior

Once set up, the check runs on every sync run, also when the local content did
not change. Before the check, `sync.zsh` verifies that `PYTHON` is Python 3.10
or newer. If not, it records an `error` status with a message in
`cloud-status.json` and notifies if `NOTIFY=1`.

The check looks up the cloud file by folder ID and file name on every run, so
it also finds a file that Google Drive for desktop recreated with a new ID.
Ambiguous matches, incomplete search results, missing checksums, or an
unreachable folder count as check errors. A file that does not exist yet
counts as a pending upload.

`cloud-status.json` has one of these statuses:

- `confirmed`: size and checksum match.
- `pending`: the upload has not arrived yet.
- `overdue`: the cloud file still differs after the warning time.
- `error`: sign-in, network, API, or the local check failed.

`checked_at` and `last_confirmed_at` are Unix timestamps. With `error`, an
earlier confirmation does not confirm the current check. The warning time
counts only the time between successful checks that found a difference, at
most 15 minutes per interval. API errors pause the count; new local content or
a new target folder resets it. An overdue upload or a new check error notifies
if `NOTIFY=1`. Repeats of the same message stay silent. The check writes status
changes to `sync.log`. If the log entry or the notification fails, the next run
with the same result tries it again.

If `cloud-status.json` is corrupt or unreadable, the next run reports this once
with an `error` status and a notification, then replaces the file. The run
after that checks normally.

A cloud error does not overwrite the local sync's `last-error` and does not
block the local copy. The job exits with code 1 on cloud errors and overdue
uploads, and with code 0 when the upload is confirmed or pending. To see the
full state, look at the exit code, `last-error`, and `cloud-status.json`
together.

Each API request times out after 20 seconds. A locked keychain or denied
keychain access is reported as a cloud error. Running the setup in Terminal
does not prove that the background job can access the keychain. If you revoke
the access, run the setup again. To turn the check off, delete
`upload-check.json` from the state folder; the local copy keeps running.

### Adding a provider

The check is split into a provider-neutral core and one module per provider,
so other targets such as Dropbox or OneDrive can be added later:

- `upload_check.py` keeps the status, waiting time, notifications, and local
  checksums. It reads `upload-check.json`, for example
  `{"provider": "google-drive", "folder_id": "..."}`, and loads the module
  registered for `provider` in `PROVIDERS`.
- A provider module such as `google_drive.py` exposes
  `provider_from_config(config)`. The returned object has a stable `location`
  and a `find(name)` method that returns a `RemoteFile` with size and checksums,
  or `None` while the file is not uploaded yet. The shared types live in
  `remote.py`.
- Credentials belong in the keychain under the service
  `cloud.diesis.strongbox-sync-backup-mirror.<provider>`. Add the provider name
  to `UPLOAD_CHECK_PROVIDERS` in `launchagent.zsh`, so `uninstall.zsh --purge`
  removes them; a test checks that both lists match.

Google documentation:
[OAuth for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app),
[refresh token expiration](https://developers.google.com/identity/protocols/oauth2#expiration),
[Google Auth Platform](https://developers.google.com/workspace/guides/configure-oauth-consent),
[personal use and verification](https://support.google.com/cloud/answer/13464321),
[Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
[file metadata and checksums](https://developers.google.com/workspace/drive/api/reference/rest/v3/files).

## macOS privacy

A manual run from Terminal or another app with privacy permissions can work
while the LaunchAgent fails with `Operation not permitted (errno 1)`. In that
case, macOS privacy protection (TCC) usually blocks the background zsh process,
and the system log names `/bin/zsh` as the responsible process. The background job
then needs a privacy permission that you grant yourself in System Settings;
the installer does not set it. Full Disk Access for `/bin/zsh` works, but it
is broad. It also applies to every other script run by `/bin/zsh`. After
granting access, start the job again and check the exit code and the log. A
successful manual run does not prove that the background job works.

## Uninstall

Stop and remove the job:

```sh
/bin/zsh uninstall.zsh
```

To also delete the state folder with logs and status, and the stored
upload-check sign-in in the keychain:

```sh
/bin/zsh uninstall.zsh --purge
```

Both keep the copy in `TARGET_DIR` and your `config.local.zsh`. Delete the
checkout folder yourself afterwards if you no longer need it.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

The tests use generated files and metadata in temporary folders. They install
no job and touch no real password database. They test the source mapping and
backup selection through the source queries, copying and error handling in
`sync.zsh`, and the generated plist including the shared configuration.
The lifecycle tests run install, update, a failed reinstall, and uninstall in a
temporary home folder, with stand-ins for `launchctl` and `security`. The cloud
tests use mocked API responses and keychain access. They cover checksums,
pending uploads, network errors, recovery, ambiguous files, and the OAuth
redirect without a real Google sign-in.

## Strongbox sources

- [Backup behavior](https://strongbox.reamaze.com/kb/faqs/does-strongbox-store-backups-how-can-i-export-them)
- [Database metadata and UUID mapping](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/macbox/MacBox/DatabaseMetadata.m)
- [Backup creation and sorting](https://github.com/strongbox-password-safe/Strongbox/blob/c70fc7b021d9dfa2b18a6d7e13406e717dd5251a/StrongBox/BackupsManager.m)

## License

MIT. See [LICENSE](LICENSE).
