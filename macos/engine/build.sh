#!/bin/zsh
# Compile « Temps Engine.app ». À ne relancer que si Engine.swift change :
# chaque recompilation fait redemander l'accès complet au disque.
set -e
# Identifiant de l'app ; à changer pour votre propre version : TEMPS_ID=com.example.temps ./build.sh
ID=${TEMPS_ID:-io.github.temps}
ICI=${0:A:h}
APP="$ICI/../../Temps Engine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ICI/../icon/Temps.icns" "$APP/Contents/Resources/Temps.icns"
swiftc -O -target arm64-apple-macos14 "$ICI/Engine.swift" -o "$APP/Contents/MacOS/Temps Engine"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Temps Engine</string>
  <key>CFBundleIdentifier</key><string>$ID.engine</string>
  <key>CFBundleExecutable</key><string>Temps Engine</string>
  <key>CFBundleIconFile</key><string>Temps</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Lire la fenêtre et le fichier au premier plan.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
