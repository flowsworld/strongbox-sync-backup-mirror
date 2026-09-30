#!/usr/bin/env bash
#
# Guides you once through the Google Cloud setup for the optional upload check.
# You work in the browser; this script says what to do and stores the result.
# It neither installs nor starts the LaunchAgent.

set -euo pipefail

if [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; RED=""
fi

TOTAL_STAGES=4
STAGE_INDEX=0

# clear_screen keeps only the current stage visible. No-op when piped.
clear_screen() { [[ -t 1 ]] && tput clear || true; }

# stage "Name" starts the next stage and shows progress.
stage() {
  clear_screen
  STAGE_INDEX=$((STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' "$BOLD" "$BLUE" "$STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
fail() { printf '  %s%s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

open_url() {
  printf '  %s↗ opening%s %s\n' "$GREEN" "$RESET" "$1"
  open "$1" >/dev/null 2>&1 || say "Could not open the browser. Open the address manually."
}

pause() {
  printf '  %s%s%s ' "$DIM" "$1" "$RESET"
  read -r _ || true
}

# saved KEY prints the value stored in ENV_FILE by an earlier run, if any.
saved() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^${1}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# ask KEY "Prompt" reads a visible value into $KEY. Enter keeps the saved value.
ask() {
  local key="$1" prompt="$2" current input=""
  current=$(saved "$key")
  if [[ -n "$current" ]]; then
    printf '  %s%s%s %s[Enter keeps %s]%s ' "$BOLD" "$prompt" "$RESET" "$DIM" "$current" "$RESET"
  else
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
  fi
  read -r input || true
  [[ -z "$input" ]] && input="$current"
  printf -v "$key" '%s' "$input"
}

# remember KEY VALUE stores a non-secret value for the next run.
remember() {
  local tmp
  touch "$ENV_FILE"
  tmp=$(mktemp "$ENV_FILE.XXXXXXXX")
  grep -vE "^${1}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# config NAME prints a value from config.zsh, including config.local.zsh.
config() {
  /bin/zsh -c 'source "$1/config.zsh" && print -r -- "${(P)2}"' setup "$PROJECT_DIR" "$1"
}

PROJECT_DIR=$(cd "$(dirname "$0")" && pwd)
problem=$(/bin/zsh -c 'source "$1/config.zsh" && config_problem' setup "$PROJECT_DIR")
[[ -z "$problem" ]] || fail "$problem"
STATE_DIR=$(config STATE_DIR)
PYTHON=$(config PYTHON)
DATABASE_NAME=$(config DATABASE_NAME)
[[ "$PYTHON" == /* && -x "$PYTHON" ]] || fail "Python 3.10+ is missing. Set PYTHON in config.local.zsh to an absolute path."
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || fail "The upload check needs Python 3.10 or newer."
umask 077
mkdir -p "$STATE_DIR"
ENV_FILE="$STATE_DIR/setup.env"

clear_screen
printf '\n%s%s  Strongbox: set up the upload check%s\n\n' "$BOLD" "$BLUE" "$RESET"
say "You work in the browser. This script tells you what to do and stores what you copy back."
say "Stop at any time with Ctrl-C. A later run offers the values already entered."
pause "Press Enter to start."

stage "Google Cloud project and Drive API"
open_url "https://console.cloud.google.com/projectcreate"
step "Create a project, for example strongbox-upload-check. An existing project works too."
step "Copy the project ID, not the project number."
ask GOOGLE_PROJECT_ID "Project ID:"
[[ "$GOOGLE_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "Invalid project ID. Run the setup again."
remember GOOGLE_PROJECT_ID "$GOOGLE_PROJECT_ID"
open_url "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=$GOOGLE_PROJECT_ID"
step "Enable the Google Drive API."
pause "Drive API enabled? Press Enter to continue."

stage "Google sign-in"
open_url "https://console.cloud.google.com/auth/branding?project=$GOOGLE_PROJECT_ID"
step "If not set up yet: Get Started. App name Strongbox Upload Check, your support and contact address."
step "Choose External as the audience for a personal Google account. Review Google's terms and create the configuration."
pause "Branding set up? Press Enter to continue."
open_url "https://console.cloud.google.com/auth/scopes?project=$GOOGLE_PROJECT_ID"
step "Data Access > Add or Remove Scopes: add only https://www.googleapis.com/auth/drive.metadata.readonly and save."
say "This allows reading metadata of all Drive files. It allows neither downloads nor changes."
pause "Scope saved? Press Enter to continue."
open_url "https://console.cloud.google.com/auth/audience?project=$GOOGLE_PROJECT_ID"
step "For a first test: add your Drive account under Test users."
say "In testing mode the sign-in expires after seven days, even for test users."
say "For permanent use, choose Publish App before signing in, so the status is In production."
say "If Publish App is disabled, complete the missing details under Branding. Google may ask for"
say "home page and privacy policy URLs that must match the application."
say "After a sign-in in testing mode, run this setup again in production mode to get a new refresh token."
say "Publishing does not publish code or share Drive files. Google may warn about an unverified app."
say "If Google blocks the access, stop here and check Google's message."
pause "Audience configured? Press Enter to continue."

stage "Download the OAuth client"
open_url "https://console.cloud.google.com/auth/clients?project=$GOOGLE_PROJECT_ID"
step "Create client > Application type: Desktop app. Name: Strongbox Upload Check."
step "Create the client and download its JSON file. This file contains credentials."
ask GOOGLE_CLIENT_JSON "Full path to the JSON file, without quotes:"
case "$GOOGLE_CLIENT_JSON" in
  \~/*) GOOGLE_CLIENT_JSON="$HOME/${GOOGLE_CLIENT_JSON#\~/}" ;;
esac
[[ -f "$GOOGLE_CLIENT_JSON" ]] || fail "JSON file not found."
remember GOOGLE_CLIENT_JSON "$GOOGLE_CLIENT_JSON"

stage "Drive folder and sign-in"
open_url "https://drive.google.com/drive/my-drive"
step "Switch to the Google account that the Drive app syncs, and open the folder that holds $DATABASE_NAME."
step "Copy the address of the open folder from the address bar."
ask GOOGLE_FOLDER_URL "Drive folder address:"
say "The sign-in now opens your browser. Choose the Drive account and grant only read access to metadata."
say "Afterwards the script shows the account and folder. Check both before confirming with yes."
say "Client data and refresh token go into the macOS keychain. The folder ID goes into upload-check.json."
"$PYTHON" "$PROJECT_DIR/google_drive_setup.py" --client-json "$GOOGLE_CLIENT_JSON" \
  --folder-url "$GOOGLE_FOLDER_URL" --state-dir "$STATE_DIR" --name "$DATABASE_NAME"

clear_screen
printf '\n%s%s  ✓ Upload check set up%s\n\n' "$BOLD" "$GREEN" "$RESET"
say "Keep the downloaded client JSON safe, or delete it from Downloads yourself."
say "An installed job starts the upload check on its next run."
printf '\n'
