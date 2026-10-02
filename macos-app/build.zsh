#!/bin/zsh -f
set -eu
umask 077
app_dir=${0:A:h}
app_bundle="$app_dir/build/Sync-Kopien.app"
channel=development
feed_url=''
public_key=''
store_url=''
typeset -a architecture_flags=()
while (( $# )); do
    case "$1" in
        --universal) architecture_flags=(--arch arm64 --arch x86_64); shift ;;
        --distribution|--feed-url|--public-key|--store-url)
            (( $# >= 2 )) || { print -u2 "Missing value after $1"; exit 2; }
            case "$1" in
                --distribution) channel=$2 ;;
                --feed-url) feed_url=$2 ;;
                --public-key) public_key=$2 ;;
                --store-url) store_url=$2 ;;
            esac
            shift 2 ;;
        --output)
            (( $# >= 2 )) || { print -u2 'Missing app path after --output'; exit 2; }
            app_bundle="$2"
            [[ "$app_bundle" == /* && "$app_bundle" == *.app ]] || {
                print -u2 'The output must be an absolute .app path'; exit 2
            }
            shift 2 ;;
        *) print -u2 "Unknown build argument: $1"; exit 2 ;;
    esac
done
case "$channel" in
    development|direct|store) ;;
    *) print -u2 'Distribution must be development, direct or store.'; exit 2 ;;
esac
if [[ "$channel" != direct && ( -n "$feed_url" || -n "$public_key" ) ]]; then
    print -u2 'Only direct builds may contain update feed/key settings.'; exit 2
fi
if [[ "$channel" != store && -n "$store_url" ]]; then
    print -u2 'Only Store builds may contain a Store destination.'; exit 2
fi
if [[ ( -n "$feed_url" && -z "$public_key" ) || ( -z "$feed_url" && -n "$public_key" ) ]]; then
    print -u2 'Configure the update feed URL and public key together.'; exit 2
fi
python3 - "$feed_url" "$public_key" "$store_url" <<'PYCONFIG'
import base64, sys
from urllib.parse import urlsplit
feed, key, store = sys.argv[1:]
def https_url(raw):
    value = urlsplit(raw)
    host = value.hostname or ''
    return (value.scheme == 'https' and host and not value.username and not value.password
            and not value.query and not value.fragment and host != 'localhost'
            and not host.endswith(('.invalid', '.example'))
            and host not in {'example.com', 'example.org', 'example.net'})
try:
    if feed and (not https_url(feed) or len(base64.b64decode(key, validate=True)) != 32
                 or base64.b64encode(base64.b64decode(key)).decode() != key):
        raise ValueError()
    if store and (not https_url(store) or urlsplit(store).hostname != 'apps.apple.com'):
        raise ValueError()
except (ValueError, UnicodeError):
    sys.exit('Invalid update feed, public key or Store URL configuration.')
PYCONFIG
export DIESIS_DISTRIBUTION="$channel"
scratch_path="$app_dir/.build/$channel"
# Use the installed Xcode SDK without changing the global developer selection.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Keep the direct lock outside the ordinary graph. SwiftPM otherwise fetches stale
# pins even when the current manifest has no dependency on them.
build_lock="$app_dir/build/.package-build.lock"
mkdir -p "$app_dir/build"
mkdir "$build_lock" || { print -u2 'Another channel is currently building.'; exit 1; }
owned_resolved=0
staging=''
cleanup() {
    [[ -z "$staging" ]] || rm -rf -- "$staging"
    (( owned_resolved == 0 )) || rm -f -- "$app_dir/Package.resolved"
    rmdir "$build_lock"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
if [[ "$channel" == direct && ! -e "$app_dir/Package.resolved" ]]; then
    cp "$app_dir/ThirdParty/Sparkle-Package.resolved" "$app_dir/Package.resolved"
    owned_resolved=1
fi
swift build --manifest-cache none --package-path "$app_dir" --scratch-path "$scratch_path" -c release "${architecture_flags[@]}"
binary_dir=$(swift build --manifest-cache none --package-path "$app_dir" --scratch-path "$scratch_path" -c release "${architecture_flags[@]}" --show-bin-path)
# Build into an empty private staging directory so a channel switch cannot retain helpers.
mkdir -p "${app_bundle:h}"
output_bundle=$app_bundle
staging=$(mktemp -d "${app_bundle:h}/.bundle.XXXXXXXX")
app_bundle="$staging/Sync-Kopien.app"
mkdir -p "$app_bundle/Contents/MacOS"
cp "$binary_dir/SyncCopies" "$app_bundle/Contents/MacOS/SyncCopies"
mkdir -p "$app_bundle/Contents/Resources"
cp "$app_dir/PrivacyInfo.xcprivacy" "$app_bundle/Contents/Resources/PrivacyInfo.xcprivacy"
# L10n loads the embedded bundle from the app's standard resource directory.
ditto "$binary_dir/SyncCopies_SyncCopiesCore.bundle" "$app_bundle/Contents/Resources/SyncCopies_SyncCopiesCore.bundle"
for language in en de; do
    name=$(plutil -extract appName raw -o - "$app_dir/Sources/SyncCopiesCore/Resources/$language.lproj/Localizable.strings")
    strings="$app_bundle/Contents/Resources/$language.lproj/InfoPlist.strings"
    mkdir -p "${strings:h}"
    plutil -create xml1 "$strings"
    plutil -insert CFBundleDisplayName -string "$name" "$strings"
    plutil -insert CFBundleName -string "$name" "$strings"
done
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>cloud.diesis.sync-copies</string>
  <key>CFBundleExecutable</key><string>SyncCopies</string>
  <key>CFBundleName</key><string>SyncCopies</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# Produce all icon sizes from the same approved drawing used by the menu bar.
xcrun swiftc "$app_dir/Sources/SyncCopies/AppIcon.swift" "$app_dir/scripts/GenerateIcon.swift" -o "$staging/icon-generator"
"$staging/icon-generator" "$staging/AppIcon.iconset"
iconutil -c icns "$staging/AppIcon.iconset" -o "$app_bundle/Contents/Resources/AppIcon.icns"
plist="$app_bundle/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$plist"
plutil -insert DIESISDistributionChannel -string "$channel" "$plist"
entitlements="$app_dir/entitlements.plist"
if [[ "$channel" == store && -n "$store_url" ]]; then
    plutil -insert DIESISStoreURL -string "$store_url" "$plist"
fi
if [[ "$channel" == direct ]]; then
    entitlements="$app_dir/entitlements-direct.plist"
    python3 - "$app_dir/Package.resolved" "$app_dir/ThirdParty/Sparkle-Package.resolved" <<'PYLOCK'
import json, sys
actual, expected = [json.load(open(path))['pins'] for path in sys.argv[1:]]
if actual != expected:
    sys.exit('Sparkle resolution differs from the reviewed direct dependency lock.')
PYLOCK
    # SwiftPM retains the pinned binary framework below its artifacts directory.
    typeset -a frameworks=("$scratch_path"/artifacts/**/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework(N))
    (( ${#frameworks} == 1 )) || { print -u2 'Expected one pinned Sparkle framework.'; exit 1; }
    framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
    mkdir -p "${framework:h}"
    ditto "${frameworks[1]}" "$framework"
    # Network-capable host uses the normal downloader, so this service is unnecessary.
    rm -rf -- "$framework/Versions/B/XPCServices/Downloader.xpc"
    mkdir -p "$app_bundle/Contents/Resources/ThirdParty"
    cp "$app_dir/ThirdParty/Sparkle-LICENSE.txt" "$app_bundle/Contents/Resources/ThirdParty/"
    for key in SUEnableInstallerLauncherService SUVerifyUpdateBeforeExtraction SURequireSignedFeed SUEnableAutomaticChecks; do
        plutil -insert "$key" -bool true "$plist"
    done
    for key in SUEnableDownloaderService SUAutomaticallyUpdate SUEnableSystemProfiling SUEnableJavaScript; do
        plutil -insert "$key" -bool false "$plist"
    done
    plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "$plist"
    if [[ -n "$feed_url" ]]; then
        plutil -insert SUFeedURL -string "$feed_url" "$plist"
        plutil -insert SUPublicEDKey -string "$public_key" "$plist"
    fi
    # Inside-out ad-hoc signatures are for local candidates only. Production re-signs each component.
    for component in "$framework/Versions/B/XPCServices/Installer.xpc" \
                     "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
        codesign --force --sign - --options runtime "$component"
    done
fi
codesign --force --sign - --entitlements "$entitlements" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
if [[ "$channel" != direct && "$(otool -L "$app_bundle/Contents/MacOS/SyncCopies")" == *Sparkle* ]]; then
    print -u2 'A non-direct executable unexpectedly links Sparkle.'; exit 1
fi
# Only replace a bundle after this fully packaged candidate passes verification.
previous=''
if [[ -e "$output_bundle" || -L "$output_bundle" ]]; then
    [[ -d "$output_bundle" && ! -L "$output_bundle" ]] || { print -u2 'Unsafe existing app destination.'; exit 1; }
    previous="$staging/previous.app"
    mv "$output_bundle" "$previous"
fi
if ! mv "$app_bundle" "$output_bundle"; then
    [[ -z "$previous" ]] || mv "$previous" "$output_bundle"
    exit 1
fi
print -r -- "$output_bundle"
