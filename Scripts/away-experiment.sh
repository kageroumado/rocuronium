#!/bin/bash
# The away-window verification batch — roadmap loose ends 3, 4, 5, and 6.
#
# These four verifications need presence to genuinely read `away`, which cannot be
# simulated from the keyboard: touching anything resets the idle clock, and faking the
# reading would test the fake instead of the gate. So this script waits for the real
# thing — lock the screen (Ctrl-Cmd-Q) to trigger it deliberately, or leave the Mac for
# 15 minutes — then runs unattended and writes everything it saw to the log.
#
#   Scripts/away-experiment.sh          run in foreground (blocks until away, then runs)
#   Scripts/away-experiment.sh --arm    detach via nohup; prints the pid to disarm with
#
# Everything is ghost-rung except `activate`, whose away-gated success path is exactly
# what loose end 3 wants verified. Every step re-checks presence and bails politely if
# someone returns mid-run. Gives up after 12 hours.

set -u

R="/Applications/Rocuronium.app/Contents/Resources/rocuronium"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO/Docs/away-experiment-$(date +%Y-%m-%d).log"
WIKI_URL="https://en.wikipedia.org/wiki/Rocuronium_bromide"

if [ "${1:-}" = "--arm" ]; then
    nohup "$0" >>"$LOG" 2>&1 &
    echo "armed as pid $! — disarm with: kill $!"
    echo "results will land in $LOG"
    exit 0
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Run a rocuronium command, log the full JSON reply, and leave it in $REPLY_JSON.
run() {
    log "\$ rocuronium $*"
    REPLY_JSON="$("$R" "$@" --json 2>&1)"
    echo "$REPLY_JSON"
}

field() { echo "$REPLY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

presence_state() { "$R" status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('presence',''))" 2>/dev/null; }

# Bail out if a human came back mid-experiment. Partial results still count.
require_away() {
    local state; state="$(presence_state)"
    if [ "$state" = "present" ]; then
        log "ABORT: presence flipped to present mid-run — stopping here; partial results above stand"
        exit 0
    fi
}

log "=== away-experiment armed; polling until presence reads away (lock the screen to trigger) ==="
DEADLINE=$(( $(date +%s) + 12 * 3600 ))
while :; do
    STATE="$(presence_state)"
    if [ "$STATE" = "away" ]; then break; fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        log "gave up: presence never read away within 12 h"
        exit 1
    fi
    sleep 30
done

log "=== presence reads away — starting ==="
run status

# --- Loose end 3: activate's success path, no --confirm ------------------------------
log "--- loose end 3: activate without confirm while away ---"
run launch --app TextEdit
require_away
run activate --app TextEdit
ACTIVATE_OK="$(field ok)"
log "activate landed: $ACTIVATE_OK (frontmost read-back is in the reply above)"

# --- Loose end 6: key to a FRONTMOST dialog -----------------------------------------
# Background delivery was measured no-effect on 2026-08-09; this is the real case.
log "--- loose end 6: key escape against a frontmost save sheet ---"
require_away
run menu --app TextEdit --path "File > New"
run type --app TextEdit --text "away experiment scratch"
run shortcut --app TextEdit --keys cmd+s
sleep 1
run find --app TextEdit --role sheet
SHEET_BEFORE="$(field matches)"
run key --app TextEdit --keys escape
sleep 1
run find --app TextEdit --role sheet
log "sheet before escape: ${SHEET_BEFORE:0:60} / after: see reply above (empty matches = dismissed)"

# Cleanup: close the scratch document, discarding it.
require_away
run click --app TextEdit --label "close button"
sleep 1
run click --app TextEdit --label "Delete" --role button
run shortcut --app TextEdit --keys cmd+q

# --- Loose ends 4 + 5: WebKit scroll + read referral --------------------------------
log "--- loose ends 4+5: Safari (WebKit) read, referral, and scroll behavior ---"
require_away
run launch --app Safari
run activate --app Safari
run menu --app Safari --path "File > New Window"
sleep 1
run shortcut --app Safari --keys cmd+l
run type --app Safari --text "$WIKI_URL"
run key --app Safari --keys return
run wait --app Safari --label "References" --timeout 20
require_away

log "read: does WebKit expose text, or a silent web area with a referral?"
run read --app Safari

log "scroll to an off-screen labeled target (AXScrollToVisible on WebKit, genuinely off-screen)"
run scroll --app Safari --label "References" --dy 100

log "absolute scroll: does WebKit expose a scroll bar (attribute or role walk)?"
run scroll --app Safari --to 0
run scroll --app Safari --to 1

log "bare posted wheels on WebKit (expected honest noEffect, but unmeasured until now)"
run scroll --app Safari --dy 400

# Cleanup: close our window, quit Safari (session restore keeps prior windows).
require_away
run shortcut --app Safari --keys cmd+w
run shortcut --app Safari --keys cmd+q

log "=== done — fold these results into Docs/ROADMAP.md loose ends 3–6 ==="
run status
