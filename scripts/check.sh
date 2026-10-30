#!/bin/sh
# Prüfungen für SyllaBeat, lokal und im CI gleich: Formatierung, Paket-Tests, Selbsttest, App-Build, UI-Tests.
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

echo "== Hilfe im App-Bündel aktuell"
cmp -s BEDIENUNG.html App/Resources/BEDIENUNG.html || { echo "App/Resources/BEDIENUNG.html weicht von BEDIENUNG.html ab (cp BEDIENUNG.html App/Resources/)"; exit 1; }

echo "== sbtool selftest"
swift run --package-path Packages/SyllaBeatKit --quiet sbtool selftest

ACTION=test
[ "${SKIP_UI_TESTS:-0}" = 1 ] && ACTION=build
echo "== App: xcodebuild $ACTION"
# Vollständiges Protokoll in eine Datei; laufend angezeigt werden Fehler, Testfälle und das Ergebnis
# (auch die Meldungen fehlgeschlagener UI-Tests, die -quiet verschlucken würde). Ein hängender Test
# scheitert nach 3 Minuten einzeln, statt den ganzen Lauf ins Zeitlimit zu treiben.
mkdir -p build
rm -f build/xcodebuild.status
TIMEOUTS=""
[ "$ACTION" = test ] && TIMEOUTS="-test-timeouts-enabled YES -default-test-execution-time-allowance 180"
# shellcheck disable=SC2086
{ xcodebuild -project SyllaBeat.xcodeproj -scheme SyllaBeat -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" $TIMEOUTS "$ACTION" 2>&1 \
    || echo $? > build/xcodebuild.status; } \
    | tee build/xcodebuild.log | grep --line-buffered -E "error:|Test Case .*(passed|failed|skipped)|\*\* (TEST|BUILD)" || true
if [ -f build/xcodebuild.status ]; then
    # Ursache sichtbar machen (Neustart des Test-Runners, Absturz, Zeitüberschreitung, Warten auf Ruhe der App).
    echo "== xcodebuild fehlgeschlagen, Auszug aus build/xcodebuild.log"
    grep -E -i "restarting|crash|timed out|time allowance|exceeded|quiesce|idle|failed|error" build/xcodebuild.log \
        | grep -v "^Test Case .* passed" | tail -40 || true
    exit "$(cat build/xcodebuild.status)"
fi

echo "== Version"
WANTED=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Version.xcconfig)
BUILT=$(plutil -extract CFBundleShortVersionString raw "$DERIVED/Build/Products/Debug/SyllaBeat.app/Contents/Info.plist")
[ "$WANTED" = "$BUILT" ] || { echo "Version im App-Paket ($BUILT) weicht von Config/Version.xcconfig ($WANTED) ab"; exit 1; }
echo "Alle Prüfungen bestanden (Version $WANTED)."
