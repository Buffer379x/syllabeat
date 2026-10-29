#!/bin/sh
# Vorübergehende Fehlersuche auf dem CI-Runner: Jeder Medienzugriff und jede Test-Suite läuft einzeln mit Zeitlimit.
# Das Ergebnis erscheint als Annotation „Diagnose“ im Lauf.
cd "$(dirname "$0")/.."
PKG=Packages/SyllaBeatKit
OUT="${RUNNER_TEMP:-/tmp}/diagnose.txt"
: > "$OUT"
limited() { # <Sekunden> <Befehl …>: gibt Status aus, 124 bei Zeitüberschreitung
    LIMIT=$1; shift
    "$@" > "${RUNNER_TEMP:-/tmp}/step.log" 2>&1 &
    PID=$!; T=0
    while kill -0 $PID 2>/dev/null; do
        sleep 2; T=$((T + 2))
        if [ $T -ge "$LIMIT" ]; then pkill -TERM -P $PID; kill $PID; sleep 1; return 124; fi
    done
    wait $PID
}
echo "Kerne: $(sysctl -n hw.ncpu), VM: $(sysctl -n kern.hv_vmm_present)" >> "$OUT"
swift build --package-path $PKG --build-tests > /dev/null 2>&1
for f in tests/Fixtures/media/*.mov tests/Fixtures/media/*.mkv; do
    SYLLABEAT_TRACE=1 limited 60 $PKG/.build/debug/sbtool probe "$f"
    S=$?
    echo "probe $(basename "$f"): Status $S, letzter Schritt: $(grep '\[probe\]' "${RUNNER_TEMP:-/tmp}/step.log" | tail -1)" >> "$OUT"
done
for suite in RationalTests MigrationTests GoldenCompileTests EditCommandTests JobCenterTests MediaCommandTests \
    AnalysisMergeTests SceneIndexTests InstallTests InferenceProtocolTests FileTests MetadataTests SceneTests; do
    limited 180 swift test --package-path $PKG --skip-build --filter "$suite"
    S=$?
    echo "suite $suite: Status $S $(grep -E 'Test run with' "${RUNNER_TEMP:-/tmp}/step.log" | tail -1 | tr -d '\r')" >> "$OUT"
done
cat "$OUT"
echo "::notice title=Diagnose::$(sed 's/%/%25/g' "$OUT" | awk '{printf "%s%%0A", $0}')"
