#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox -Xswiftc -gnone
APP="$PWD/../AgentsPanel.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentsPanel "$APP/Contents/MacOS/AgentsPanel"
swiftc -gnone -module-cache-path "$PWD/.build/ModuleCache" Sources/ClankerIcon.swift MakeIcon.swift -o "$PWD/.build/MakeIcon"
"$PWD/.build/MakeIcon" "$PWD/.build/AgentsPanel.iconset"
iconutil -c icns "$PWD/.build/AgentsPanel.iconset" -o "$APP/Contents/Resources/AgentsPanel.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentsPanel</string>
<key>CFBundleIdentifier</key><string>local.agentpanel.mac</string>
<key>CFBundleName</key><string>AgentsPanel</string>
<key>CFBundleDisplayName</key><string>AgentsPanel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.8</string>
<key>CFBundleVersion</key><string>11</string>
<key>CFBundleIconFile</key><string>AgentsPanel</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
