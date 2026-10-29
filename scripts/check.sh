#!/bin/sh
# Prüfungen für SyllaBeat 0.3, lokal und im CI gleich: Formatierung, Paket-Tests, Selbsttest, App-Build, UI-Tests.
# Aufruf aus dem Repository-Ordner: scripts/check.sh   (SKIP_UI_TESTS=1 baut die App nur, ohne UI-Tests)
set -eu
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA:-build/DerivedData}"
SWIFT_FILES=$(find App InferenceService UITests Packages/SyllaBeatKit/Sources Packages/SyllaBeatKit/Tests -name '*.swift')

echo "== Formatierung (swift format lint --strict)"
# shellcheck disable=SC2086
swift format lint --strict --configuration .swift-format $SWIFT_FILES Packages/SyllaBeatKit/Package.swift

echo "== Paket-Tests"
swift test --package-path Packages/SyllaBeatKit

echo "== sbtool selftest"
swift run --package-path Packages/SyllaBeatKit --quiet sbtool selftest

ACTION=test
[ "${SKIP_UI_TESTS:-0}" = 1 ] && ACTION=build
echo "== App: xcodebuild $ACTION"
# Vollständiges Protokoll in eine Datei; angezeigt werden Fehler, Testfälle und das Ergebnis
# (auch die Meldungen fehlgeschlagener UI-Tests, die -quiet verschlucken würde).
mkdir -p build
STATUS=0
xcodebuild -project SyllaBeat.xcodeproj -scheme SyllaBeat -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" "$ACTION" > build/xcodebuild.log 2>&1 || STATUS=$?
grep -E "error:|Test Case .*(passed|failed|skipped)|\*\* (TEST|BUILD)" build/xcodebuild.log || true
[ "$STATUS" = 0 ] || exit "$STATUS"

echo "== Version"
WANTED=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Version.xcconfig)
BUILT=$(plutil -extract CFBundleShortVersionString raw "$DERIVED/Build/Products/Debug/SyllaBeat.app/Contents/Info.plist")
[ "$WANTED" = "$BUILT" ] || { echo "Version im App-Paket ($BUILT) weicht von Config/Version.xcconfig ($WANTED) ab"; exit 1; }
echo "Alle Prüfungen bestanden (Version $WANTED)."
