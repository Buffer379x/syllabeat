#!/bin/sh
# Führt einen Befehl im CI aus und begrenzt seine Laufzeit. Bei Fehler oder Zeitüberschreitung landet das Ende
# des Protokolls als Annotation im Lauf (ohne Anmeldung lesbar). Aufruf: scripts/ci-run.sh <Sekunden> <Befehl …>
set -u
LIMIT="$1"
shift
LOG="${RUNNER_TEMP:-/tmp}/ci-run.log"
# Über ein Pseudo-Terminal, damit die Testausgabe sofort (ungepuffert) im Protokoll landet.
script -q "$LOG" "$@" > /dev/null 2>&1 &
PID=$!
ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ "$ELAPSED" -ge "$LIMIT" ]; then
        echo "Zeitlimit $LIMIT s überschritten, Abbruch."
        pkill -TERM -P "$PID" 2>/dev/null
        kill "$PID" 2>/dev/null
        sleep 2
        STATUS=124
        break
    fi
done
[ "${STATUS:-}" = 124 ] || { wait "$PID"; STATUS=$?; }
cat "$LOG"
if [ "$STATUS" != 0 ]; then
    TAIL=$(tr -d '\r' < "$LOG" | grep -v "^\[\|Fetch\|working copy\|Working copy" | tail -60 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
    echo "::error title=Prüfung fehlgeschlagen (Status $STATUS)::$TAIL"
fi
exit "$STATUS"
