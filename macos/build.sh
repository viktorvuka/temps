#!/bin/zsh
# Compile Temps.app (barre des menus) à côté des scripts Python, qu'elle lance elle-même.
# macOS lie les accès (disque, Accessibilité, Automatisation) à la signature : avec la signature
# ad hoc par défaut, chaque recompilation les fait redemander. Pour les garder, signez avec un
# certificat de votre trousseau : TEMPS_SIGN="Apple Development: …" ./build.sh
set -e
# Identifiant de l'app ; à changer pour votre propre version : TEMPS_ID=com.example.temps ./build.sh
ID=${TEMPS_ID:-io.github.temps}
ICI=${0:A:h}
# TEMPS_SORTIE : où poser l'app (par défaut à côté des scripts, qu'elle lance)
CIBLE=${TEMPS_SORTIE:-"$ICI/../Temps.app"}
# On compile à l'écart et on ne remplace Temps.app qu'à la fin : une erreur de compilation laisse l'app en place.
APP="$(mktemp -d)/Temps.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$ICI/icon/Temps.icns" "$APP/Contents/Resources/Temps.icns"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "$ICI/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/"
# Certains outils en ligne de commande livrent un SDK où SwiftUI demande un module de macros absent :
# on essaie un petit fichier sur chaque SDK installé, du plus récent au plus ancien, et on garde le premier qui passe.
SDK=${TEMPS_SDK:-}
if [ -z "$SDK" ]; then
  ESSAI=$(mktemp -d)/essai.swift
  print 'import SwiftUI\nstruct V: View { @State var a = 0; var body: some View { Text("") } }' > "$ESSAI"
  for s in "$(xcrun --show-sdk-path)" $(ls -d "$(dirname "$(xcrun --show-sdk-path)")"/MacOSX[0-9]*.sdk | sort -V -r); do
    swiftc -sdk "$s" -typecheck -target arm64-apple-macos14 "$ESSAI" 2>/dev/null && { SDK=$s; break; }
  done
fi
swiftc -sdk "$SDK" -O -parse-as-library -target arm64-apple-macos14 "$ICI/Temps.swift" "$ICI/Window.swift" "$ICI/Settings.swift" "$ICI/Projets.swift" -o "$APP/Contents/MacOS/Temps"
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
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Lire la fenêtre et le fichier au premier plan.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign "${TEMPS_SIGN:--}" "$APP"
rm -rf "$CIBLE" && mv "$APP" "$CIBLE"
echo "$CIBLE"
