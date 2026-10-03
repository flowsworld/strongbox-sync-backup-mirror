#!/bin/zsh -f
# Local packaging only. This script never submits, installs or publishes a build.
set -eu
setopt extendedglob
umask 077

usage() {
    print -u2 'Usage: release.zsh development|direct|store VERSION BUILD [DEVELOPER_ID_IDENTITY]'
    print -u2 'VERSION is MAJOR.MINOR.PATCH; BUILD is a positive integer.'
}
(( $# >= 3 && $# <= 4 )) || { usage; exit 2; }
channel=$1
version=$2
build_number=$3
identity=${4:--}
[[ "$version" == [0-9]##.[0-9]##.[0-9]## && "$build_number" == [1-9][0-9]# ]] || {
    usage; exit 2
}
case "$channel" in
    development|store)
        (( $# == 3 )) || { usage; exit 2; }
        ;;
    direct)
        (( $# == 4 )) && [[ "$identity" != '-' && -n "$identity" ]] || {
            print -u2 'Direct builds require an explicit Developer ID Application identity.'; exit 2
        }
        # Resolve the identity before compiling. Never fall back to ad-hoc signing.
        identities=$(security find-identity -v -p codesigning)
        [[ "$identity" == 'Developer ID Application: '* || "$identity" == [0-9A-Fa-f](#c40) ]] || {
            print -u2 'Use a Developer ID Application certificate name or its SHA-1 identity.'; exit 2
        }
        if [[ "$identity" == [0-9A-Fa-f](#c40) ]]; then
            identity="${identity:u}"
        fi
        [[ "$identities" == *"$identity"* ]] || {
            print -u2 'The requested signing identity is unavailable.'; exit 1
        }
        ;;
    *) usage; exit 2 ;;
esac

app_dir=${0:A:h}
if [[ "$channel" == direct && -n "$(git -C "$app_dir" status --porcelain --untracked-files=normal)" ]]; then
    print -u2 'Direct release builds require a clean committed working tree.'; exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
release_root="$app_dir/build/releases"
release_dir="$release_root/$channel-$version-$build_number"
mkdir -p "$release_root"
release_lock="$release_dir.lock"
mkdir "$release_lock" || { print -u2 'This release is already being packaged.'; exit 1; }
staging=''
trap '[[ -z "$staging" ]] || rm -rf -- "$staging"; rmdir "$release_lock"' EXIT
trap 'exit 130' HUP INT TERM
[[ ! -e "$release_dir" && ! -L "$release_dir" ]] || {
    print -u2 'That release already exists. Choose a new build number.'; exit 1
}
typeset -a update_flags=()
typeset -a google_flags=()
if [[ -n "${DIESIS_GOOGLE_CLIENT_CONFIG:-}" ]]; then
    google_flags=(--google-client-config "$DIESIS_GOOGLE_CLIENT_CONFIG")
fi
if [[ "$channel" == direct ]]; then
    [[ -n "${DIESIS_UPDATE_FEED_URL:-}" && -n "${DIESIS_UPDATE_PUBLIC_KEY:-}" ]] || {
        print -u2 'Direct release candidates require DIESIS_UPDATE_FEED_URL and DIESIS_UPDATE_PUBLIC_KEY.'; exit 2
    }
    update_flags=(--feed-url "$DIESIS_UPDATE_FEED_URL" --public-key "$DIESIS_UPDATE_PUBLIC_KEY")
elif [[ "$channel" == store && -n "${DIESIS_STORE_URL:-}" ]]; then
    update_flags=(--store-url "$DIESIS_STORE_URL")
fi
staging=$(mktemp -d "$release_root/.package.XXXXXXXX")
app_bundle="$staging/Sync-Kopien.app"
/bin/zsh "$app_dir/build.zsh" --universal --distribution "$channel" "${update_flags[@]}" "${google_flags[@]}" --output "$app_bundle"
plist="$app_bundle/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build_number" "$plist"
plutil -replace DIESISDistributionChannel -string "$channel" "$plist"
# App payloads are readable/executable by other users after installation.
# The enclosing artifacts and build records remain private to this checkout owner.
chmod -R u=rwX,go=rX "$app_bundle"

if [[ "$channel" == direct ]]; then
    framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
    for component in "$framework/Versions/B/XPCServices/Installer.xpc" \
                     "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
        codesign --force --sign "$identity" --options runtime --timestamp "$component"
        codesign --verify --strict -R \
            'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$component"
    done
    codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements "$app_dir/entitlements-direct.plist" "$app_bundle"
    # Reject a non-Developer-ID certificate even when selected by its hash.
    codesign --verify --deep --strict -R \
        'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
        "$app_bundle"
else
    codesign --force --sign - --entitlements "$app_dir/entitlements.plist" "$app_bundle"
    codesign --verify --strict "$app_bundle"
fi
for architecture in arm64 x86_64; do
    lipo "$app_bundle/Contents/MacOS/SyncCopies" -verify_arch "$architecture"
done
xcrun vtool -show-build "$app_bundle/Contents/MacOS/SyncCopies" > "$staging/MACH_O_BUILD"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$staging/Sync-Kopien.zip"
(
    cd "$staging"
    shasum -a 256 Sync-Kopien.zip > SHA256SUMS
    git -C "$app_dir" rev-parse HEAD > SOURCE_COMMIT
    if [[ -n "$(git -C "$app_dir" status --porcelain --untracked-files=normal)" ]]; then
        print -r -- 'Working tree has changes; this is not a clean release.' > WORKTREE_DIRTY
    fi
    xcodebuild -version > TOOLCHAIN
    swift --version >> TOOLCHAIN 2>&1
)
# Atomic publication inside this checkout only. Preserve earlier release artifacts.
# The lock covers this entire build so another packager cannot reuse its version.
[[ ! -e "$release_dir" && ! -L "$release_dir" ]] || {
    print -u2 'Another build created that release while packaging.'; exit 1
}
mv -n "$staging" "$release_dir"
[[ ! -d "$staging" ]] || { print -u2 'The release destination was not moved.'; exit 1; }
staging=''
rmdir "$release_lock"
trap - EXIT
print -r -- "$release_dir"
if [[ "$channel" == direct ]]; then
    print -u2 'Signed candidate only. Notarization, stapling and Gatekeeper validation are still required.'
else
    print -u2 'Ad-hoc channel fixture. It is not a distributable signed beta or Store submission.'
fi
