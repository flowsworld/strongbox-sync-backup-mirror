# LaunchAgent names and helpers, sourced by install.zsh and uninstall.zsh.
LABEL='cloud.diesis.strongbox-sync-backup-mirror'
# Upload-check providers; each keeps its sign-in in the keychain under the
# service "$LABEL.<provider>". Must list the keys of PROVIDERS in upload_check.py.
UPLOAD_CHECK_PROVIDERS=(google-drive)
# Only the tests replace these tools with stand-ins.
LAUNCHCTL="${STRONGBOX_LAUNCHCTL:-/bin/launchctl}"
SECURITY="${STRONGBOX_SECURITY:-/usr/bin/security}"
# How long to wait for a stopping job. A running sync finishes its current step
# first, and the upload check can wait on the network. Tests shorten it.
STOP_SECONDS="${STRONGBOX_STOP_SECONDS:-60}"

# plist_path LABEL prints where the user's LaunchAgent file for LABEL lives.
plist_path() {
    print -r -- "$HOME/Library/LaunchAgents/$1.plist"
}

# job_loaded LABEL succeeds while launchd knows the job.
job_loaded() {
    "$LAUNCHCTL" print "gui/$UID/$1" >/dev/null 2>&1
}

# wait_until_stopped LABEL waits up to STOP_SECONDS until launchd removed the job.
wait_until_stopped() {
    local deadline=$(( SECONDS + STOP_SECONDS ))
    while job_loaded "$1"; do
        (( SECONDS < deadline )) || return 1
        sleep 0.2
    done
}

# stop_job LABEL unloads the job, if loaded, and waits until it is gone.
stop_job() {
    job_loaded "$1" || return 0
    # bootout can return, or fail with "Operation now in progress", before
    # launchd has removed the job. What matters is that the job is gone afterwards.
    "$LAUNCHCTL" bootout "gui/$UID/$1" 2>/dev/null || true
    wait_until_stopped "$1" && return 0
    print -ru2 -- "Could not stop the job $1."
    return 1
}
