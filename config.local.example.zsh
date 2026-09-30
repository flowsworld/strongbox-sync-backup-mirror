# Template for your own settings. Copy it to config.local.zsh in the same
# directory and adjust it. config.local.zsh is not tracked by git.

# File name of the Strongbox Sync database, as shown in Strongbox.
DATABASE_NAME='Passwords.kdbx'

# Existing folder that receives the copy, for example a folder synced by
# Google Drive, Dropbox, OneDrive, or iCloud Drive, a NAS mount, or a USB drive.
# Folder names such as "My Drive" depend on the system language.
TARGET_DIR="$HOME/Library/CloudStorage/Dropbox/Backups"
# TARGET_DIR="$HOME/Library/CloudStorage/GoogleDrive-name@example.com/My Drive/Backups"

# Optional. Defaults are in config.zsh.
# NOTIFY=0
# CLOUD_WARNING_SECONDS=3600
# PYTHON=/opt/homebrew/bin/python3
# BACKUP_ROOT="$HOME/Library/Group Containers/group.strongbox.mac.mcguill/backups"
# PREFERENCES="$HOME/Library/Group Containers/group.strongbox.mac.mcguill/Library/Preferences/group.strongbox.mac.mcguill.plist"
