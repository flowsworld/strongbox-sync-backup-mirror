#!/bin/zsh -f
# Enables the job for the current user, or refreshes it after a configuration
# change or update.
set -eu
setopt PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
case "${1:-}" in
    ''|--print-plist) ;;
    *) print -u2 'Usage: install.zsh [--print-plist]'; exit 2 ;;
esac

PROJECT_DIR="${0:A:h}"
source "$PROJECT_DIR/launchagent.zsh"
TEMP_PLIST=''
# Copy of the running job's plist, so a failed reinstall can restore it.
PREVIOUS_PLIST=''
INSTALLED=0
STOPPED_CURRENT=0
MOVED_NEW=0

# A failed or interrupted reinstall restores and restarts the job that ran
# before, so the mirror does not end up without a job.
cleanup() {
    local exit_status=$?
    # A failing step in here must not skip the restore that follows it.
    setopt localoptions noerrexit
    [[ -z "$TEMP_PLIST" ]] || rm -f -- "$TEMP_PLIST"
    # Once the new plist is in place and loaded, the new job runs; keep it.
    (( MOVED_NEW )) && job_loaded "$LABEL" && INSTALLED=1
    if (( exit_status != 0 && ! INSTALLED && STOPPED_CURRENT )) && [[ -f "$PREVIOUS_PLIST" ]]; then
        if ! wait_until_stopped "$LABEL"; then
            print -ru2 -- 'The job is still stopping. Run install.zsh again once it has stopped.'
        elif mv -f -- "$PREVIOUS_PLIST" "$(plist_path "$LABEL")" &&
            "$LAUNCHCTL" bootstrap "gui/$UID" "$(plist_path "$LABEL")"; then
            print -ru2 -- 'Restarted the job, because the installation did not finish.'
        else
            print -ru2 -- 'Could not restart the job. Run install.zsh again.'
        fi
    fi
    [[ -z "$PREVIOUS_PLIST" ]] || rm -f -- "$PREVIOUS_PLIST"
}
trap cleanup EXIT
# Ctrl-C and SIGTERM exit through the EXIT trap as well.
trap 'exit 130' INT
trap 'exit 143' TERM

source "$PROJECT_DIR/config.zsh"
config_error=$(config_problem)
[[ -z "$config_error" ]] || { print -ru2 -- "$config_error"; exit 1; }
[[ -d "$TARGET_DIR" ]] || { print -u2 'Create the TARGET_DIR folder first.'; exit 1; }
SCRIPT="$PROJECT_DIR/sync.zsh"
SOURCE_DIR=$(/bin/zsh -f "$PROJECT_DIR/strongbox-source.zsh" watch-dir "$PREFERENCES" "$BACKUP_ROOT" "$DATABASE_NAME")
PLIST=$(plist_path "$LABEL")
TEMP_PLIST=$(mktemp "${TMPDIR:-/tmp}/strongbox.XXXXXXXX")
plutil -create xml1 "$TEMP_PLIST"
plutil -insert Label -string "$LABEL" "$TEMP_PLIST"
plutil -insert ProgramArguments -array "$TEMP_PLIST"
# -f: the user's ~/.zshenv must neither print into nor change the job.
plutil -insert ProgramArguments.0 -string /bin/zsh "$TEMP_PLIST"
plutil -insert ProgramArguments.1 -string -f "$TEMP_PLIST"
plutil -insert ProgramArguments.2 -string "$SCRIPT" "$TEMP_PLIST"
plutil -insert EnvironmentVariables -dictionary "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_DATABASE_NAME -string "$DATABASE_NAME" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_BACKUP_ROOT -string "$BACKUP_ROOT" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_PREFERENCES -string "$PREFERENCES" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_TARGET_DIR -string "$TARGET_DIR" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_STATE_DIR -string "$STATE_DIR" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_NOTIFY -string "$NOTIFY" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_PYTHON -string "$PYTHON" "$TEMP_PLIST"
plutil -insert EnvironmentVariables.STRONGBOX_CLOUD_WARNING_SECONDS -string "$CLOUD_WARNING_SECONDS" "$TEMP_PLIST"
plutil -insert RunAtLoad -bool YES "$TEMP_PLIST"
plutil -insert WatchPaths -array "$TEMP_PLIST"
plutil -insert WatchPaths.0 -string "$SOURCE_DIR" "$TEMP_PLIST"
plutil -insert WatchPaths.1 -string "$BACKUP_ROOT" "$TEMP_PLIST"
plutil -insert WatchPaths.2 -string "$PREFERENCES" "$TEMP_PLIST"
# launchd runs missed calendar intervals after wake.
plutil -insert StartCalendarInterval -array "$TEMP_PLIST"
for index in 0 1 2 3; do
    plutil -insert "StartCalendarInterval.$index" -dictionary "$TEMP_PLIST"
    plutil -insert "StartCalendarInterval.$index.Minute" -integer "$((index * 15))" "$TEMP_PLIST"
done
plutil -insert ThrottleInterval -integer 10 "$TEMP_PLIST"
plutil -insert StandardOutPath -string "$STATE_DIR/launchd.log" "$TEMP_PLIST"
plutil -insert StandardErrorPath -string "$STATE_DIR/launchd.log" "$TEMP_PLIST"
plutil -lint "$TEMP_PLIST" >/dev/null
if [[ "${1:-}" == --print-plist ]]; then
    cat "$TEMP_PLIST"
    exit 0
fi
mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"
if job_loaded "$LABEL"; then
    if [[ -f "$PLIST" ]]; then
        PREVIOUS_PLIST=$(mktemp "${TMPDIR:-/tmp}/strongbox-previous.XXXXXXXX")
        cp -- "$PLIST" "$PREVIOUS_PLIST"
    fi
    # Set before stopping: a stop that times out still ends the job later.
    STOPPED_CURRENT=1
    # zsh skips the EXIT trap when ERR_EXIT fires on a failing function; an
    # explicit exit runs it.
    stop_job "$LABEL" || exit $?
fi
mv -f "$TEMP_PLIST" "$PLIST"
TEMP_PLIST=''
MOVED_NEW=1
"$LAUNCHCTL" bootstrap "gui/$UID" "$PLIST"
INSTALLED=1
print 'Strongbox backup enabled. The first check starts now.'
