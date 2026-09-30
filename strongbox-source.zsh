#!/bin/zsh
# stdout: newest backup file or folder to watch. Errors: stderr and exit 1.
# Knows Strongbox metadata and backup selection; never decrypts a database.
set -u
setopt PIPE_FAIL
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() {
    print -ru2 -- "$1"
    exit 1
}

(( $# == 4 )) || fail 'Usage: strongbox-source.zsh latest-backup|watch-dir PREFERENCES BACKUP_ROOT DATABASE_NAME'
mode="$1"
preferences="$2"
backup_root="$3"
database_name="$4"
[[ "$mode" == latest-backup || "$mode" == watch-dir ]] || fail 'Unknown Strongbox source query.'
[[ "$preferences" == /* && "$backup_root" == /* ]] || fail 'The Strongbox paths must be absolute.'
archive=$(mktemp "${TMPDIR:-/tmp}/strongbox-metadata.XXXXXXXX") || exit 1
trap 'rm -f -- "$archive"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# XML represents the NSKeyedArchiver references as CF$UID dictionaries.
# plutil only processes a private temporary copy, never the app preferences.
# Tool diagnostics can contain random temporary paths. Only stable messages
# go out, so repeated errors stay recognizable.
plutil -extract databases raw -expect data -o - "$preferences" 2>/dev/null |
    base64 -D 2>/dev/null | plutil -convert xml1 -o "$archive" - >/dev/null 2>&1 ||
    fail 'Could not read the Strongbox metadata. If access was denied, check the macOS privacy permissions.'

get_reference() {
    local index="$1" key="$2" value
    # Read UID references directly from XML. Older plutil versions cannot copy
    # these special objects during extraction and abort.
    value=$(xmllint --xpath "string(/plist/dict/key[.='\$objects']/following-sibling::*[1][self::array]/*[$((index + 1))][self::dict]/key[.='$key']/following-sibling::*[1][self::dict]/key[.='CF\$UID']/following-sibling::*[1][self::integer])" "$archive" 2>/dev/null) || return 1
    [[ "$value" == <-> ]] || return 1
    print -r -- "$value"
}

get_string() {
    local index="$1" value
    value=$(plutil -extract "\$objects.$index" raw -expect string -o - "$archive" 2>/dev/null) ||
        value=$(plutil -extract "\$objects.$index.NS\\.string" raw -expect string -o - "$archive" 2>/dev/null) || return 1
    print -r -- "$value"
}

# Decodes %XX escapes exactly once into REPLY; fails on a malformed escape.
# Strongbox stores the file name percent-encoded (URLComponents.path), so
# "My Passwords.kdbx" appears as "My%20Passwords.kdbx" and a literal
# "My%20Passwords.kdbx" as "My%2520Passwords.kdbx".
percent_decode() {
    local value="$1"
    [[ "${value//\%[[:xdigit:]][[:xdigit:]]/}" != *%* ]] || return 1
    # Keep literal backslashes, then let print turn each %XX into \xXX.
    value="${value//\\/\\\\}"
    print -v REPLY -- "${value//\%/\\x}"
}

# Older plutil versions crash when extracting the whole array with UID
# references. The converted XML file can be counted without that step.
count=$(xmllint --xpath 'count(/plist/dict/key[.="$objects"]/following-sibling::*[1][self::array]/*)' "$archive" 2>/dev/null) ||
    fail 'Invalid Strongbox metadata archive.'
[[ "$count" == <-> ]] && (( count > 0 )) || fail 'Invalid Strongbox metadata archive.'
typeset -A matches
for (( index = 0; index < count; index++ )); do
    uuid_index=$(get_reference "$index" uuid) || continue
    url_index=$(get_reference "$index" fileUrl) || continue
    url_string_index=$(get_reference "$url_index" NS.relative) || continue
    database_url=$(get_string "$url_string_index") || continue
    # Local or Google Drive databases with the same name are not a source.
    database_path="${database_url%%\?*}"
    [[ "$database_path" == strongbox-cloud:/* ]] || continue
    # Accepts strongbox-cloud:/NAME and strongbox-cloud:///NAME.
    percent_decode "${${database_path#strongbox-cloud:/}#//}" || continue
    [[ "$REPLY" == "$database_name" ]] || continue
    identifier=$(get_string "$uuid_index") || fail 'The database UUID is missing.'
    [[ "$identifier" =~ '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ]] ||
        fail 'The database UUID is invalid.'
    matches[$identifier]=1
done

(( ${#matches} == 1 )) || fail 'The Strongbox Sync database cannot be matched unambiguously.'
identifier="${(k)matches}"
directory="$backup_root/$identifier"
[[ -d "$directory" && ! -L "$directory" ]] || fail 'The matched Strongbox backup folder is missing or is a link.'
if [[ "$mode" == watch-dir ]]; then
    print -r -- "$directory"
    exit 0
fi

latest=''
latest_time=-1
for candidate in "$directory"/*.bak(N.); do
    # Strongbox sorts by creation date, not modification date.
    created=$(stat -f '%.9FB' "$candidate" 2>/dev/null) || fail 'Could not check a backup.'
    if (( created >= latest_time )); then
        latest="$candidate"
        latest_time=$created
    fi
done
[[ -n "$latest" ]] || fail 'No Strongbox backup found.'
[[ -s "$latest" ]] || fail 'The newest Strongbox backup is empty.'
print -r -- "$latest"
