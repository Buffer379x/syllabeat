#!/bin/sh
# Release-Build wie im Workflow: Archiv (Release, arm64), Ad-hoc-Signatur und Prüfung, Selbsttest der gebauten App,
# DMG mit Prüfsumme in dist/. Aufruf: scripts/build-release.sh [Buildnummer]
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Version.xcconfig)
BUILD="${1:-1}"
ARCHIVE=build/release/SyllaBeat.xcarchive
rm -rf build/release dist
mkdir -p build/release dist
xcodebuild -project SyllaBeat.xcodeproj -scheme SyllaBeat -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/ReleaseData -archivePath "$ARCHIVE" ARCHS=arm64 \
    CURRENT_PROJECT_VERSION="$BUILD" archive > build/release/archive.log 2>&1 || {
    grep -E "error:" build/release/archive.log | head -20
    exit 1
}
APP=build/release/SyllaBeat.app
/usr/bin/ditto "$ARCHIVE/Products/Applications/SyllaBeat.app" "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/SyllaBeat" --self-test
DMG=$(scripts/make-dmg.sh "$APP" "$VERSION" dist | tail -1)
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
ls -lh dist
