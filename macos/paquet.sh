#!/bin/zsh
# Fabrique l'app prête à télécharger : Temps.app avec ses scripts et son propre Python, zippée dans dist/.
# Rien à installer pour qui la télécharge : ni Xcode, ni Python.
#
#   ./macos/paquet.sh
#   TEMPS_PYTHON=<dossier d'un Python autonome> ./macos/paquet.sh
#
# Le Python autonome est un build « install_only » de python-build-standalone (Python 3.11 ou plus, arm64),
# relogeable, qui ne dépend que de macOS. Sans TEMPS_PYTHON, le script prend le plus récent de ceux que uv a
# installés (uv python install 3.13). L'app n'est pas notarisée : au premier lancement, macOS demande de
# l'autoriser une fois (Réglages Système > Confidentialité et sécurité > Ouvrir quand même).
set -e
ICI=${0:A:h}
RACINE=${ICI:h}
# Les scripts partent tels quels dans l'app : seule la copie publique (sans blocs privés) peut être empaquetée.
if grep -q "<pri""ve>" "$RACINE/report.py"; then
  echo "À lancer depuis la copie publique du code, pas depuis une version qui garde des blocs privés." >&2
  exit 1
fi
VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' "$ICI/build.sh")
PY=${TEMPS_PYTHON:-$(ls -d ~/.local/share/uv/python/cpython-3.1[1-9]*-macos-aarch64-none 2>/dev/null | sort -V | tail -1)}
if [ ! -x "$PY/bin/python3" ] || ! "$PY/bin/python3" -c 'import sys, tomllib, sqlite3; assert sys.version_info >= (3, 11)' 2>/dev/null; then
  echo "Python autonome 3.11 ou plus introuvable. Indiquer son dossier : TEMPS_PYTHON=<dossier> ./macos/paquet.sh" >&2
  exit 1
fi

TRAVAIL=$(mktemp -d)
APP="$TRAVAIL/Temps.app"
# 1. l'app, compilée à l'écart (l'identifiant public par défaut)
TEMPS_ID=${TEMPS_ID:-io.github.temps} TEMPS_SORTIE="$APP" "$ICI/build.sh" >/dev/null

# 2. le moteur
M="$APP/Contents/Resources/moteur"
mkdir -p "$M"
for f in biome.py claude.py recorder.py report.py rules.py server.py demo.py \
         capture.applescript mail.applescript notes.applescript things.applescript \
         rules.example.fr.toml rules.example.toml; do
  cp "$RACINE/$f" "$M/"
done

# 3. Python, sans ce dont Temps ne se sert pas (Tcl/Tk, IDLE, pip, en-têtes, tests)
P="$APP/Contents/Resources/python"
mkdir -p "$P"
rsync -a --exclude 'include/' --exclude 'share/' --exclude 'lib/pkgconfig/' --exclude 'lib/tcl*' --exclude 'lib/tk*' \
  --exclude 'lib/itcl*' --exclude 'lib/thread*' --exclude 'lib/libtcl*' --exclude 'lib/libtk*' \
  --exclude 'idlelib/' --exclude 'tkinter/' --exclude 'turtledemo/' --exclude 'ensurepip/' --exclude 'site-packages/' \
  --exclude 'test/' --exclude 'lib2to3/' --exclude 'config-*/' --exclude '_tkinter*' --exclude '__pycache__/' \
  "$PY/" "$P/"
find "$P/bin" -mindepth 1 ! -name 'python3*' -delete

# 4. signature de tout le paquet (ad hoc par défaut ; TEMPS_SIGN pour un certificat du trousseau)
codesign --force --deep --sign "${TEMPS_SIGN:--}" "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

# 5. le zip
mkdir -p "$RACINE/dist"
ZIP="$RACINE/dist/Temps-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
rm -rf "$TRAVAIL"
echo "$ZIP"
