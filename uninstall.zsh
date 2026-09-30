#!/bin/zsh -f
# Removes the LaunchAgent. The copy in TARGET_DIR and config.local.zsh always stay.
# --purge also deletes the state folder (logs and status) and the stored
# upload-check sign-in.
set -eu
setopt PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
case "${1:-}" in
    ''|--purge) ;;
    *) print -u2 'Usage: uninstall.zsh [--purge]'; exit 2 ;;
esac
PURGE=0
[[ "${1:-}" != --purge ]] || PURGE=1

PROJECT_DIR="${0:A:h}"
source "$PROJECT_DIR/launchagent.zsh"
PLIST=$(plist_path "$LABEL")
# The tool's own state folder (see config.zsh). Deliberately fixed: --purge
# deletes it as a whole, so it never comes from a setting or variable.
STATE_DIR="$HOME/Library/Application Support/strongbox-sync-backup-mirror"
failed=0

# The plist goes even if the job does not stop in time; otherwise the job
# would come back at the next login.
stop_job "$LABEL" || failed=1
if [[ -f "$PLIST" ]]; then
    rm -f -- "$PLIST"
    print -r -- "Removed the job $LABEL."
fi
if (( failed )); then
    print -ru2 -- 'Run uninstall.zsh again once the job has stopped.'
    exit 1
fi

if (( ! PURGE )); then
    [[ ! -e "$STATE_DIR" ]] || print -r -- "Kept $STATE_DIR."
    print -r -- 'Run uninstall.zsh --purge to delete the logs, status, and stored sign-in too.'
    exit 0
fi

# Every known provider, because upload-check.json may already be gone after
# the check was turned off. Exit code 44 means there is no (further) entry;
# anything else, such as a locked keychain, is reported.
for service in "$LABEL."${^UPLOAD_CHECK_PROVIDERS}; do
    while true; do
        "$SECURITY" delete-generic-password -s "$service" >/dev/null 2>&1 && code=0 || code=$?
        (( code == 0 )) || break
        print -r -- "Removed the keychain entry $service."
    done
    if (( code != 44 )); then
        print -ru2 -- "Could not delete the keychain entry $service. Unlock the keychain and run uninstall.zsh --purge again."
        failed=1
    fi
done

# install.zsh rejects a TARGET_DIR inside the state folder, but a hand-made
# layout must not lose the mirror. A broken config.local.zsh cannot say where
# TARGET_DIR is and does not block the purge.
if /bin/zsh -fc 'source "$1/config.zsh" && [[ -n "$TARGET_DIR" ]] && folder_contains "$2" "$TARGET_DIR"' \
    uninstall "$PROJECT_DIR" "$STATE_DIR" >/dev/null 2>&1; then
    print -ru2 -- "Kept $STATE_DIR, because TARGET_DIR lies inside it."
    failed=1
elif [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
    # Without a trailing slash, rm removes a symlink itself, not its destination.
    rm -rf -- "$STATE_DIR"
    print -r -- "Deleted $STATE_DIR."
fi
exit $failed
