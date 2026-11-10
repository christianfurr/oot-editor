#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build/OoT Editor.app/Contents/"{MacOS,Resources}
APP="$ROOT/build/OoT Editor.app"
xcrun swiftc -parse-as-library -O -warnings-as-errors -target arm64-apple-macosx26.0 \
  "$ROOT/OoTEditor.swift" "$ROOT/SaveWorkshop.swift" "$ROOT/SaveApply.swift" -framework SwiftUI -framework AppKit -framework WebKit -o "$APP/Contents/MacOS/OoTEditor"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/Vendor/OOT-SW2SE/editor.html" "$APP/Contents/Resources/"
cp "$ROOT/Vendor/OOT-SW2SE/LICENSE" "$APP/Contents/Resources/OOT-SW2SE-LICENSE"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.christianfurr.oot-editor</string>
<key>CFBundleName</key><string>OoT Editor</string>
<key>CFBundleExecutable</key><string>OoTEditor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
