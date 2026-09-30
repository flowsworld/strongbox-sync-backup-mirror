#!/bin/zsh
# Downloads the newest version of this checkout and reinstalls the job with it.
# config.local.zsh is not tracked by git and stays as it is.
set -eu
setopt PIPE_FAIL
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
(( $# == 0 )) || { print -u2 'Usage: update.zsh'; exit 2; }

PROJECT_DIR="${0:A:h}"
# Checking for .git instead of asking git keeps a missing git (no Command Line
# Tools) from looking like "not a checkout"; git's own error surfaces instead.
if [[ -e "$PROJECT_DIR/.git" ]]; then
    changes=$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)
    [[ -z "$changes" ]] || {
        print -u2 'The checkout has local changes. Stash (git stash) or discard them, then run update.zsh again.'
        exit 1
    }
    git -C "$PROJECT_DIR" pull --ff-only
else
    print 'Not a git checkout, so nothing is downloaded. Reinstalling the current files.'
fi
# exec runs the install.zsh just downloaded, not a copy from before the pull.
exec /bin/zsh "$PROJECT_DIR/install.zsh"
