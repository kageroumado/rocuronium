#!/bin/bash
# The away-window verification batch — roadmap loose ends 3, 4, 5, and 6.
#
# These verifications need presence to genuinely read `away` with the screen UNLOCKED
# (the 15-minutes-idle path). The locked regime was measured 2026-08-09 and is a
# different animal: activate cannot land (loginwindow keeps the console), background
# menus are dead on some apps and half-alive on others, and nothing frontmost exists
# for a dialog test. This script waits for the unlocked kind and runs unattended.
#
#   Scripts/away-experiment.sh          run in foreground (blocks until away, then runs)
#   Scripts/away-experiment.sh --arm    detach via nohup; prints the pid to disarm with
#
# Politeness rules learned from the first run, the hard way:
#   - activate comes FIRST, and if it does not land the script stops — every later step
#     assumes a frontmost target, and blundering on in the background navigated the
#     user's real Safari tab and then quit Safari.
#   - Apps the script did not launch are never quit; work happens in windows the script
#     opened itself, verified open before use.
# Every step re-checks presence and bails if someone returns. Gives up after 12 hours.

set -u

R="/Applications/Rocuronium.app/Contents/Resources/rocuronium"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO/Docs/away-experiment-$(date +%Y-%m-%d-%H%M).log"
WIKI_URL="https://en.wikipedia.org/wiki/Rocuronium_bromide"

if [ "${1:-}" = "--arm" ]; then
    nohup "$0" >>"$LOG" 2>&1 &
    echo "armed as pid $! — disarm with: kill $!"
    echo "results will land in $LOG (gitignored: raw replies carry session details)"
    exit 0
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

run() {
    log "\$ rocuronium $*"
    REPLY_JSON="$("$R" "$@" --json 2>&1)"
    echo "$REPLY_JSON"
}

field() { echo "$REPLY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

status_field() { "$R" status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

require_away() {
    if [ "$(status_field presence)" = "present" ]; then
        log "ABORT: presence flipped to present mid-run — partial results above stand"
        exit 0
    fi
}

window_count() { "$R" windows --app "$1" --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null; }

# The trigger is raw keyboard idle alone. The first idle-triggered attempt missed a
# real 31-minute absence and logged nothing: with the display asleep, either the lock
# flag reads true despite the password grace period, or HIDIdleTime stops climbing —
# unobservable after the fact because the loop was silent. Three countermeasures:
# hold the display awake for the script's whole lifetime (caffeinate -d; removes the
# display-sleep confound without touching Settings), trigger on idle alone and branch
# on the lock state after the fact, and heartbeat the readings so a miss is loud.
# Threshold matches the app's idleUntil constant — TEMPORARILY 60 s (2026-08-09) so
# the experiment fires in a minute; both go back to 15 min once it has run.
TRIGGER_IDLE=70
caffeinate -d -w $$ &
log "=== armed; display held awake (caffeinate -d, released on exit); waiting for >=${TRIGGER_IDLE}s keyboard idle ==="
DEADLINE=$(( $(date +%s) + 12 * 3600 ))
POLLS=0
while :; do
    IDLE="$(status_field idleSeconds)"
    LOCKED="$(status_field screenLocked)"
    POLLS=$((POLLS + 1))
    # Loud approach: every reading once idle passes half the trigger, heartbeat every 10 min.
    if [ "${IDLE:-0}" -ge $((TRIGGER_IDLE / 2)) ] || [ $((POLLS % 20)) -eq 0 ]; then
        log "poll $POLLS: idleSeconds=[$IDLE] screenLocked=[$LOCKED]"
    fi
    if [ "${IDLE:-0}" -ge "$TRIGGER_IDLE" ]; then
        if [ "$LOCKED" = "False" ]; then break; fi
        log "idle >=15 min but screen locked — the locked regime is already measured; waiting on"
    fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        log "gave up: no unlocked >=15-min-idle window within 12 h"
        exit 1
    fi
    sleep 30
done

log "=== presence reads away, screen unlocked — starting ==="
run status

# --- Loose end 3: activate without confirm while away -------------------------------
log "--- loose end 3: activate without confirm ---"
run launch --app TextEdit
TEXTEDIT_WAS_RUNNING="$(field alreadyRunning)"
require_away
run activate --app TextEdit
if [ "$(field ok)" != "True" ]; then
    log "ABORT: activate did not land even though presence is away+unlocked — that itself is"
    log "the loose-end-3 result; everything downstream assumes a frontmost target. Stopping."
    exit 0
fi
log "activate landed without confirm — loose end 3 verified"

# --- Loose end 6: key escape against a FRONTMOST save sheet -------------------------
log "--- loose end 6: key escape against a frontmost save sheet ---"
require_away
BEFORE=$(window_count TextEdit)
run menu --app TextEdit --path "File > New"
sleep 1
AFTER=$(window_count TextEdit)
log "TextEdit windows: $BEFORE before File>New, $AFTER after"
if [ "${AFTER:-0}" -le "${BEFORE:-0}" ]; then
    log "SKIP sheet test: File>New opened no window even frontmost — record and move on"
else
    run type --app TextEdit --text "away experiment scratch"
    run shortcut --app TextEdit --keys cmd+s
    sleep 1
    run find --app TextEdit --role sheet
    run key --app TextEdit --keys escape
    sleep 1
    run find --app TextEdit --role sheet
    log "sheet-after-escape above: empty matches = escape dismissed a frontmost sheet"
    require_away
    run click --app TextEdit --label "close button"
    sleep 1
    run click --app TextEdit --label "Delete" --role button
fi
if [ "$TEXTEDIT_WAS_RUNNING" != "True" ]; then
    run shortcut --app TextEdit --keys cmd+q
fi

# --- Loose ends 4 + 5: WebKit read, referral, and scroll ----------------------------
log "--- loose ends 4+5: Safari (WebKit), in a window this script opens itself ---"
require_away
run launch --app Safari
SAFARI_WAS_RUNNING="$(field alreadyRunning)"
run activate --app Safari
if [ "$(field ok)" != "True" ]; then
    log "SKIP Safari batch: activate did not land; not operating on background Safari again"
    exit 0
fi
BEFORE=$(window_count Safari)
run menu --app Safari --path "File > New Window"
sleep 1
AFTER=$(window_count Safari)
log "Safari windows: $BEFORE before New Window, $AFTER after"
if [ "${AFTER:-0}" -le "${BEFORE:-0}" ]; then
    log "SKIP Safari batch: no window of our own to work in — refusing to touch existing tabs"
    exit 0
fi
run shortcut --app Safari --keys cmd+l
run type --app Safari --text "$WIKI_URL"
run key --app Safari --keys return
run wait --app Safari --label "Pharmacology" --role heading --timeout 20
require_away

log "read: does WebKit expose page text, or a silent web area with a referral?"
run read --app Safari

log "scroll to an off-screen labeled target (AXScrollToVisible on WebKit)"
run scroll --app Safari --label "External links" --dy 100

log "absolute scroll: does WebKit expose a scroll bar (attribute or role walk)?"
run scroll --app Safari --to 1
run scroll --app Safari --to 0

log "bare posted wheels on WebKit"
run scroll --app Safari --dy 400

# Cleanup: close only the window this script opened; quit only what it launched.
require_away
run shortcut --app Safari --keys cmd+w
if [ "$SAFARI_WAS_RUNNING" != "True" ]; then
    run shortcut --app Safari --keys cmd+q
fi

log "=== done — fold these results into Docs/ROADMAP.md loose ends 3–6 ==="
run status
