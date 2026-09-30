# Shared settings for sync.zsh, install.zsh, and setup-google-drive.sh.
# Personal values belong in the untracked config.local.zsh, see
# config.local.example.zsh. STRONGBOX_* environment variables override both,
# for example in isolated test runs.
DATABASE_NAME=''
TARGET_DIR=''
BACKUP_ROOT="$HOME/Library/Group Containers/group.strongbox.mac.mcguill/backups"
PREFERENCES="$HOME/Library/Group Containers/group.strongbox.mac.mcguill/Library/Preferences/group.strongbox.mac.mcguill.plist"
NOTIFY=1
CLOUD_WARNING_SECONDS=1800
# The optional upload check needs Python 3.10+ without extra packages. launchd
# does not have Homebrew in PATH, so the installer stores the absolute path.
if [[ -x /opt/homebrew/bin/python3 ]]; then
    PYTHON=/opt/homebrew/bin/python3
elif [[ -x /usr/local/bin/python3 ]]; then
    PYTHON=/usr/local/bin/python3
else
    PYTHON=/usr/bin/python3
fi

# %x is the file being sourced, independent of the calling script.
LOCAL_CONFIG="${${(%):-%x}:A:h}/config.local.zsh"
if [[ -f "$LOCAL_CONFIG" ]]; then
    source "$LOCAL_CONFIG" || return 1
fi

DATABASE_NAME="${STRONGBOX_DATABASE_NAME:-$DATABASE_NAME}"
TARGET_DIR="${STRONGBOX_TARGET_DIR:-$TARGET_DIR}"
BACKUP_ROOT="${STRONGBOX_BACKUP_ROOT:-$BACKUP_ROOT}"
PREFERENCES="${STRONGBOX_PREFERENCES:-$PREFERENCES}"
# The state folder belongs to this tool alone, so uninstall.zsh --purge can
# delete it as a whole. It is not a user setting; only tests override it.
STATE_DIR="${STRONGBOX_STATE_DIR:-$HOME/Library/Application Support/strongbox-sync-backup-mirror}"
NOTIFY="${STRONGBOX_NOTIFY:-$NOTIFY}"
PYTHON="${STRONGBOX_PYTHON:-$PYTHON}"
CLOUD_WARNING_SECONDS="${STRONGBOX_CLOUD_WARNING_SECONDS:-$CLOUD_WARNING_SECONDS}"

# folder_contains PARENT CHILD succeeds if CHILD is PARENT or lies inside it,
# comparing canonical paths ("/" contains everything).
folder_contains() {
    [[ "${${2:A}%/}/" == "${${1:A}%/}/"* ]]
}

# Prints the first configuration problem, or nothing for a valid configuration.
# Checks only the form of the values; callers check whether folders exist.
config_problem() {
    if [[ ! -f "$LOCAL_CONFIG" && ( -z "$DATABASE_NAME" || -z "$TARGET_DIR" ) ]]; then
        print -r -- 'Copy config.local.example.zsh to config.local.zsh and set DATABASE_NAME and TARGET_DIR.'
    elif [[ -z "$DATABASE_NAME" || "$DATABASE_NAME" == */* ]]; then
        print -r -- 'Set DATABASE_NAME in config.local.zsh, as a file name without a path.'
    elif [[ "$TARGET_DIR" != /* ]]; then
        print -r -- 'Set TARGET_DIR in config.local.zsh to an absolute path.'
    elif [[ "$BACKUP_ROOT" != /* || "$PREFERENCES" != /* ]]; then
        print -r -- 'BACKUP_ROOT and PREFERENCES must be absolute paths.'
    elif [[ "$STATE_DIR" != /* ]]; then
        print -r -- 'STATE_DIR must be an absolute path.'
    elif [[ "$PYTHON" != /* ]]; then
        # Only the form: sync.zsh checks the version when the upload check runs.
        print -r -- 'PYTHON must be an absolute path.'
    elif folder_contains "$STATE_DIR" "$TARGET_DIR" || folder_contains "$TARGET_DIR" "$STATE_DIR"; then
        # Keeps the mirror out of the folder that uninstall.zsh --purge deletes.
        print -r -- 'STATE_DIR and TARGET_DIR must not contain each other.'
    elif [[ "$NOTIFY" != [01] ]]; then
        print -r -- 'NOTIFY must be 0 or 1.'
    elif [[ "$CLOUD_WARNING_SECONDS" != <1-> ]]; then
        print -r -- 'CLOUD_WARNING_SECONDS must be a positive integer.'
    fi
}
