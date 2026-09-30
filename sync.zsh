#!/bin/zsh -f
set -u
setopt PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

(( $# == 0 )) || { print -ru2 -- 'Usage: sync.zsh'; exit 2; }
PROJECT_DIR="${0:A:h}"
source "$PROJECT_DIR/config.zsh" || exit 1

LOG_FILE="$STATE_DIR/sync.log"
ERROR_FILE="$STATE_DIR/last-error"
# Exists while the notification about last-error still has to be shown.
NOTIFY_PENDING_FILE="$STATE_DIR/last-error-pending"
LOCK_FILE="$STATE_DIR/sync.lock"
TEMP_FILE=''
# Only the tests replace osascript with a stand-in.
OSASCRIPT="${STRONGBOX_OSASCRIPT:-/usr/bin/osascript}"

cleanup() {
    [[ -z "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

log() {
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# notify TITLE MESSAGE shows a macOS notification and fails if it could not.
# Its output goes to stderr, which launchd logs, so it works without sync.log.
notify() {
    "$OSASCRIPT" - "$2" "$1" <<'APPLESCRIPT' >&2
on run argv
    display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
}

# fail MESSAGE reports a new error once, then exits. A notification that could
# not be shown is tried again by the next run with the same error.
fail() {
    local message="$1" previous='' notify_now=0
    [[ ! -f "$ERROR_FILE" ]] || previous="$(<"$ERROR_FILE")"
    print -ru2 -- "$message"
    if [[ "$previous" != "$message" ]]; then
        log "ERROR: $message" || print -ru2 -- 'Could not write the log file.'
        print -r -- "$message" > "$ERROR_FILE" || print -ru2 -- 'Could not save the error state.'
        notify_now=1
    fi
    [[ ! -f "$NOTIFY_PENDING_FILE" ]] || notify_now=1
    if [[ "$NOTIFY" != 1 ]]; then
        # Like the upload check: a pending notification does not outlive NOTIFY=0.
        rm -f -- "$NOTIFY_PENDING_FILE"
    elif (( notify_now )); then
        if notify 'Strongbox backup failed' "$message"; then
            rm -f -- "$NOTIFY_PENDING_FILE"
        else
            : > "$NOTIFY_PENDING_FILE" || print -ru2 -- 'Could not save the notification state.'
        fi
    fi
    exit 1
}

recovered() {
    if [[ -f "$ERROR_FILE" ]]; then
        log 'Checked successfully again.' || fail 'Could not write the log file.'
        rm -f -- "$ERROR_FILE" "$NOTIFY_PENDING_FILE" || fail 'Could not remove the error state.'
    fi
}

# write_cloud_error MESSAGE LOG_PENDING NOTIFICATION_PENDING replaces
# cloud-status.json with an error result; the flags are JSON booleans.
write_cloud_error() {
    TEMP_FILE=$(mktemp "$STATE_DIR/.cloud-status.XXXXXXXX") || return 1
    # Without a checksum, an earlier confirmation and the waiting time cannot be
    # tied to any content, so both start again once Python works.
    cat > "$TEMP_FILE" <<JSON || return 1
{
  "status": "error",
  "message": "$1",
  "context": "",
  "local_sha256": "",
  "checked_at": $(date +%s),
  "last_confirmed_at": null,
  "pending_seconds": 0,
  "previous_mismatch_at": null,
  "log_pending": $2,
  "notification_pending": $3
}
JSON
    mv -f "$TEMP_FILE" "$STATE_DIR/cloud-status.json" || return 1
    TEMP_FILE=''
}

# Reports the upload check error without Python. The status must be current
# even without Python. Logging and notifying follow upload_check.report(): a
# change is reported once, and a failed log entry or notification is retried
# by the next run with the same result.
cloud_python_unavailable() {
    local message='Python 3.10 or newer for the upload check is missing. Check PYTHON in config.local.zsh.'
    local status_file="$STATE_DIR/cloud-status.json" key
    local -A previous
    print -ru2 -- "$message"
    if [[ -f "$status_file" ]]; then
        for key in status message log_pending notification_pending; do
            previous[$key]=$(/usr/bin/plutil -extract "$key" raw -o - "$status_file" 2>/dev/null) || previous[$key]=''
        done
    fi
    local log_pending=${previous[log_pending]:-false} notification_pending=${previous[notification_pending]:-false}
    [[ "$log_pending" == true ]] || log_pending=false
    [[ "$notification_pending" == true ]] || notification_pending=false
    if [[ "${previous[status]:-}" != error || "${previous[message]:-}" != "$message" ]]; then
        log_pending=true
        notification_pending=true
    fi
    [[ "$NOTIFY" == 1 ]] || notification_pending=false
    write_cloud_error "$message" "$log_pending" "$notification_pending" || return 1
    [[ "$log_pending" == false ]] || { log "CLOUD: $message" && log_pending=false; } ||
        print -ru2 -- 'Could not write the log file.'
    [[ "$notification_pending" == false ]] || { notify 'Strongbox upload' "$message" && notification_pending=false; }
    write_cloud_error "$message" "$log_pending" "$notification_pending"
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

# The job reads config.local.zsh on every run. Its values come from the plist,
# but an edit with a syntax error still breaks it, so such an error is logged
# and notified like any other. Without config.local.zsh (a fresh checkout) or
# with an invalid STATE_DIR, nothing is written.
config_error=$(config_problem)
if [[ -n "$config_error" ]]; then
    [[ -f "$LOCAL_CONFIG" && -z "$(state_dir_problem)" ]] && mkdir -p "$STATE_DIR" 2>/dev/null ||
        { print -ru2 -- "$config_error"; exit 1; }
    fail "$config_error"
fi
mkdir -p "$STATE_DIR" || fail 'Could not create the state directory.'
# The kernel releases the lock when this process ends, also after a crash or
# kill -9, so a stale lock file never blocks a run. The file itself stays: a
# removed and recreated file would let two runs lock different files. Only a
# lock held by a running job is a normal reason to skip this run without an error.
# flock fails the same way for a held lock and for a file it cannot open, so
# the read-write open here separates the two.
[[ ! -L "$LOCK_FILE" ]] && : <> "$LOCK_FILE" 2>/dev/null || fail 'Could not create the sync lock.'
zmodload zsh/system || fail 'Could not create the sync lock.'
zsystem flock -t 0 -f LOCK_FD "$LOCK_FILE" 2>/dev/null || exit 0
# Make sure a copy can be logged before making it.
: >> "$LOG_FILE" || fail 'Could not open the log file.'

latest=$(/bin/zsh -f "$PROJECT_DIR/strongbox-source.zsh" latest-backup "$PREFERENCES" "$BACKUP_ROOT" "$DATABASE_NAME" 2>&1) ||
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
# The source query rejects an empty backup, but it can be emptied since then.
[[ -s "$TEMP_FILE" ]] || fail 'The newest Strongbox backup is empty.'
# The temporary file and the target share a folder, so a rename replaces the target.
mv -f "$TEMP_FILE" "$target" || fail 'Could not replace the target file.'
TEMP_FILE=''
log "Copied: ${latest:t} -> $DATABASE_NAME." ||
    fail 'The copy was made, but the log file could not be written.'
recovered
check_upload
