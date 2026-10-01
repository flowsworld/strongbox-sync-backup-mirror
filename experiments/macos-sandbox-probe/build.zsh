#!/bin/zsh -f
# Builds a separate, ad-hoc signed read-only test app. Installs no background job.
set -eu
umask 077
probe_dir=${0:A:h}
probe_build="$probe_dir/build"
probe_app="$probe_build/StrongboxSandboxProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>cloud.diesis.strongbox-sandbox-probe</string>
  <key>CFBundleExecutable</key><string>StrongboxSandboxProbe</string>
  <key>CFBundleName</key><string>Strongbox Sandbox Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" "$probe_dir/Catalog.swift" "$probe_dir/main.swift" -o "$probe_build/catalog-fixture-cli"
cp "$probe_build/catalog-fixture-cli" "$probe_app/Contents/MacOS/StrongboxSandboxProbe"
codesign --force --sign - --entitlements "$probe_dir/entitlements.plist" "$probe_app"
codesign --verify --strict "$probe_app"
print -r -- "$probe_app"
