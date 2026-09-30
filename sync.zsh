#!/bin/zsh
set -u
setopt PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

(( $# == 0 )) || { print -ru2 -- 'Usage: sync.zsh'; exit 2; }
PROJECT_DIR="${0:A:h}"
source "$PROJECT_DIR/config.zsh" || exit 1

LOG_FILE="$STATE_DIR/sync.log"
ERROR_FILE="$STATE_DIR/last-error"
LOCK_FILE="$STATE_DIR/sync.lock"
TEMP_FILE=''
LOCK_HELD=0

cleanup() {
    [[ -z "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
    (( ! LOCK_HELD )) || rm -f -- "$LOCK_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

log() {
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

fail() {
    local message="$1" previous=''
    [[ ! -f "$ERROR_FILE" ]] || previous="$(<"$ERROR_FILE")"
    print -ru2 -- "$message"
    if [[ "$previous" != "$message" ]]; then
        log "ERROR: $message" || print -ru2 -- 'Could not write the log file.'
        print -r -- "$message" > "$ERROR_FILE" || print -ru2 -- 'Could not save the error state.'
        if [[ "$NOTIFY" == 1 ]]; then
            # launchd logs stderr of the background job. The notification
            # must work even when sync.log is broken.
            /usr/bin/osascript - "$message" <<'APPLESCRIPT' >&2
on run argv
    display notification (item 1 of argv) with title "Strongbox backup failed"
end run
APPLESCRIPT
        fi
    fi
    exit 1
}

recovered() {
    if [[ -f "$ERROR_FILE" ]]; then
        log 'Checked successfully again.' || fail 'Could not write the log file.'
        rm -f -- "$ERROR_FILE" || fail 'Could not remove the error state.'
    fi
}

cloud_python_unavailable() {
    local message='Python 3.10 or newer for the upload check is missing. Check PYTHON in config.local.zsh.'
    local previous_status='' previous_message='' status_file="$STATE_DIR/cloud-status.json"
    print -ru2 -- "$message"
    if [[ -f "$status_file" ]]; then
        previous_status=$(/usr/bin/plutil -extract status raw -o - "$status_file" 2>/dev/null) || previous_status=''
        previous_message=$(/usr/bin/plutil -extract message raw -o - "$status_file" 2>/dev/null) || previous_message=''
    fi
    TEMP_FILE=$(mktemp "$STATE_DIR/.cloud-status.XXXXXXXX") || return 1
    # This error path must store a current result even without Python.
    # Without a checksum, an earlier confirmation cannot be tied to any content.
    cat > "$TEMP_FILE" <<JSON || return 1
{
  "status": "error",
  "message": "$message",
  "context": "",
  "local_sha256": "",
  "checked_at": $(date +%s),
  "last_confirmed_at": null,
  "pending_seconds": 0,
  "previous_mismatch_at": null
}
JSON
    mv -f "$TEMP_FILE" "$status_file" || return 1
    TEMP_FILE=''
    if [[ "$previous_status" != error || "$previous_message" != "$message" ]]; then
        log "CLOUD: $message" || print -ru2 -- 'Could not write the log file.'
        if [[ "$NOTIFY" == 1 ]]; then
            /usr/bin/osascript - "$message" <<'APPLESCRIPT' >&2
on run argv
    display notification (item 1 of argv) with title "Strongbox upload"
end run
APPLESCRIPT
        fi
    fi
    return 1
}

check_upload() {
    # The setup enables the check with upload-check.json, which names the
    # provider and its target but holds no secrets.
    # A cloud error changes neither the local copy nor last-error.
    [[ -f "$STATE_DIR/upload-check.json" ]] || return 0
    # A Python that is too old fails on import and would leave a stale cloud status.
    [[ "$PYTHON" == /* && -x "$PYTHON" ]] &&
        "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1 || {
        cloud_python_unavailable
        return $?
    }
    "$PYTHON" "$PROJECT_DIR/upload_check.py" --target "$TARGET_DIR/$DATABASE_NAME" \
        --state-dir "$STATE_DIR" --name "$DATABASE_NAME" \
        --warning-seconds "$CLOUD_WARNING_SECONDS" --notify "$NOTIFY"
}

# Checked before anything is written, so an invalid STATE_DIR receives no files.
# install.zsh refuses invalid settings, so this only concerns manual runs.
config_error=$(config_problem)
[[ -z "$config_error" ]] || { print -ru2 -- "$config_error"; exit 1; }
mkdir -p "$STATE_DIR" || fail 'Could not create the state directory.'
# shlock also handles lock files of crashed processes. Only a held lock is a
# normal reason to skip this run without an error. The second attempt covers
# a holder that exits between shlock and reading the lock file.
for attempt in 1 2; do
    if /usr/bin/shlock -f "$LOCK_FILE" -p $$; then
        LOCK_HELD=1
        break
    fi
    lock_pid=''
    if [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
        lock_pid=$(<"$LOCK_FILE")
    fi
    if [[ "$lock_pid" == <-> ]] && (( lock_pid > 0 )) && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0
    fi
done
(( LOCK_HELD )) || fail 'Could not create the sync lock.'
# Make sure a copy can be logged before making it.
: >> "$LOG_FILE" || fail 'Could not open the log file.'

latest=$(/bin/zsh "$PROJECT_DIR/strongbox-source.zsh" latest-backup "$PREFERENCES" "$BACKUP_ROOT" "$DATABASE_NAME" 2>&1) ||
    fail "Backup selection failed: $latest"
[[ -d "$TARGET_DIR" ]] || fail 'The target folder is missing.'
[[ "${latest:A:h}" != "${TARGET_DIR:A}" ]] || fail 'Source and target folder must not be the same.'
# An interrupted run (kill -9, power loss) leaves its temporary copy in the
# synced folder. It has the same pattern as the mktemp call below.
rm -f -- "$TARGET_DIR/.$DATABASE_NAME".????????(N.) ||
    fail 'Could not remove an orphaned temporary copy.'

target="$TARGET_DIR/$DATABASE_NAME"
[[ ! -L "$target" ]] || fail 'The target file must not be a symbolic link.'
[[ ! -e "$target" || -f "$target" ]] || fail 'The target is not a regular file.'
if [[ -f "$target" ]]; then
    cmp -s "$latest" "$target"
    result=$?
    if (( result == 0 )); then
        recovered
        check_upload
        exit $?
    elif (( result > 1 )); then
        fail 'Could not compare source and target.'
    fi
fi

before=$(stat -f '%i:%z:%m:%c:%B' "$latest") || fail 'The source is no longer available.'
TEMP_FILE=$(mktemp "$TARGET_DIR/.$DATABASE_NAME.XXXXXXXX") || fail 'Could not create the temporary target file.'
cp "$latest" "$TEMP_FILE" || fail 'Could not copy the backup.'
chmod 600 "$TEMP_FILE" || fail 'Could not set file permissions.'
after=$(stat -f '%i:%z:%m:%c:%B' "$latest") || fail 'The source was removed while copying.'
[[ "$before" == "$after" ]] || fail 'The source changed while copying.'
cmp -s "$latest" "$TEMP_FILE" || fail 'The copy does not match the source.'
# The temporary file and the target share a folder, so a rename replaces the target.
mv -f "$TEMP_FILE" "$target" || fail 'Could not replace the target file.'
TEMP_FILE=''
log "Copied: ${latest:t} -> $DATABASE_NAME." ||
    fail 'The copy was made, but the log file could not be written.'
recovered
check_upload
