#!/bin/sh
# Packt SyllaBeat.app in SyllaBeat-<Version>.dmg (Logik aus 0.2.0): frisches Staging per ditto (behält Verweise,
# Attribute und Signatur), Verweis auf /Applications, Bedienungsanleitung daneben, hdiutil mit Wiederholung und verify.
# Aufruf: scripts/make-dmg.sh <SyllaBeat.app> <Version> <Zielordner>
set -eu
APP="$1"
VERSION="$2"
OUT="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)/SyllaBeat"
mkdir -p "$STAGE" "$OUT"
/usr/bin/ditto "$APP" "$STAGE/SyllaBeat.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/BEDIENUNG.html" "$STAGE/Bedienungsanleitung.html"
DMG="$OUT/SyllaBeat-$VERSION.dmg"
rm -f "$DMG"
attempt=1
until /usr/bin/hdiutil create -volname "SyllaBeat $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG"; do
    # Spotlight oder XProtect halten das Abbild gelegentlich fest.
    [ "$attempt" -ge 3 ] && { echo "hdiutil konnte das DMG nicht erstellen." >&2; exit 1; }
    sleep $((5 * attempt))
    attempt=$((attempt + 1))
done
/usr/bin/hdiutil verify "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "$DMG"
