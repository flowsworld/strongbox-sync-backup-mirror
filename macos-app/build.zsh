#!/bin/zsh -f
set -eu
umask 077
app_dir=${0:A:h}
app_bundle="$app_dir/build/Sync-Kopien.app"
# Use the installed Xcode SDK without changing the global developer selection.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build --package-path "$app_dir" -c release
binary_dir=$(swift build --package-path "$app_dir" -c release --show-bin-path)
mkdir -p "$app_bundle/Contents/MacOS"
cp "$binary_dir/SyncCopies" "$app_bundle/Contents/MacOS/SyncCopies"
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>cloud.diesis.sync-copies</string>
  <key>CFBundleExecutable</key><string>SyncCopies</string>
  <key>CFBundleName</key><string>Sync-Kopien</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$app_dir/entitlements.plist" "$app_bundle"
codesign --verify --strict "$app_bundle"
print -r -- "$app_bundle"
