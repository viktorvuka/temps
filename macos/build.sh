#!/bin/zsh
# Compile Temps.app (barre des menus) à côté des scripts Python, qu'elle lance elle-même.
# macOS lie les accès (disque, Accessibilité, Automatisation) à la signature : avec la signature
# ad hoc par défaut, chaque recompilation les fait redemander. Pour les garder, signez avec un
# certificat de votre trousseau : TEMPS_SIGN="Apple Development: …" ./build.sh
set -e
# Identifiant de l'app ; à changer pour votre propre version : TEMPS_ID=com.example.temps ./build.sh
ID=${TEMPS_ID:-io.github.temps}
ICI=${0:A:h}
APP="$ICI/../Temps.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$ICI/icon/Temps.icns" "$APP/Contents/Resources/Temps.icns"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "$ICI/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/"
swiftc -O -parse-as-library -target arm64-apple-macos14 "$ICI/Temps.swift" "$ICI/Window.swift" -o "$APP/Contents/MacOS/Temps"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Temps</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string><string>en</string></array>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>Temps</string>
  <key>CFBundleIconFile</key><string>Temps</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Lire la fenêtre et le fichier au premier plan.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign "${TEMPS_SIGN:--}" "$APP"
echo "$APP"
