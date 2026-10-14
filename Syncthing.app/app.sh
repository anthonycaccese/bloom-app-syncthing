# Syncthing for Bloom
#
# Enable/disable the Syncthing daemon, have it start after boot whenever Wi-Fi
# is up, trigger a manual rescan, and read off the web address so you can open
# the interface from another computer on the network.
#
# The daemon and the Wi-Fi watcher live in bin/; this file is only the UI.

# The app folder. Bloom calls it $APP_DIR; it was $PAK_DIR until the extension
# rename. Bloom also pre-cds into the folder, so $(pwd) is a correct fallback —
# but it masks whether Bloom exported anything at all, so record what arrived
# before the fallback hides it.
APP_DIR_FROM_ENV="${APP_DIR:-}"
APP_DIR="${APP_DIR:-$(pwd)}"
# shellcheck source=bin/common.sh
. "$APP_DIR/bin/common.sh"

RESULT_FILE="$PAK_RUN_DIR/syncthing-pak-result"
CHANGES_FILE="$PAK_RUN_DIR/syncthing-pak-changes"

# Bloom reads this script's stdout — that is how a verb's answer comes back —
# so it cannot see the app as finished while anything we started still holds
# that pipe open. Reap our own background jobs on the way out, and record
# reaching the end, so a freeze on quit can be told apart: a log with "app.sh
# exited" in it means app.sh was done and the hang is downstream of us.
on_exit() {
    # Log before reaping, not after: if the reaping is what stalls, we still
    # want the record that we got this far.
    log "app.sh exited"
    for job in $(jobs -p 2>/dev/null); do
        kill "$job" 2>/dev/null
    done
}
trap on_exit EXIT INT TERM HUP QUIT

# Render an On/Off pair with `*` on the current value, the way `form` wants it.
onoff() {
    if [ "$1" = "On" ]; then echo "Off|*On"; else echo "*Off|On"; fi
}

# The longest a task gets before we stop waiting on it. It has to exceed the
# worst case inside http_post — four clients times three addresses at a 12s
# limit each — or we would give up on a call that was still going to answer.
RUN_LIMIT=180

# Run a bin/ script behind a progress bar, so a slow start isn't a frozen
# screen. `progress` reads its bar from the lines we pipe in.
#
# The bar tracks the work rather than the clock: it climbs for the first while,
# then holds just short of full for as long as the job is still going. Filling
# to 100 on a timer and then blocking in `wait` — which is what this did — is
# worse than no bar at all, because the screen freezes at exactly the moment it
# claims to have finished.
run_with_progress() {
    label="$1"
    shift
    rm -f "$RESULT_FILE"
    (
        if "$@" >/dev/null 2>&1; then echo ok >"$RESULT_FILE"; else echo fail >"$RESULT_FILE"; fi
    ) &
    worker=$!
    (
        i=0
        while [ "$i" -lt "$RUN_LIMIT" ]; do
            [ -f "$RESULT_FILE" ] && break
            pct=$((i * 4))
            [ "$pct" -gt 95 ] && pct=95
            echo "$pct"
            i=$((i + 1))
            sleep 1
        done
        echo "100"
    ) | progress "$label"

    # No result file means we hit the limit, not that the job said no. Take the
    # worker down rather than blocking on it: its output already goes nowhere,
    # so what is left is a stall in `wait` with the bar gone from the screen.
    if [ ! -f "$RESULT_FILE" ]; then
        command -v pkill >/dev/null 2>&1 && pkill -P "$worker" 2>/dev/null
        kill "$worker" 2>/dev/null
        log "run_with_progress: gave up on '$label' after ${RUN_LIMIT}s"
        return 1
    fi
    wait "$worker"
    [ "$(cat "$RESULT_FILE" 2>/dev/null)" = "ok" ]
}

# The pairing ID other devices need. Empty until the config exists, which is
# only after Syncthing has been enabled once.
device_id() {
    [ -f "$CONFIG_FILE" ] || return 1
    "$SYNCTHING" --home="$CONFIG_DIR" device-id 2>/dev/null
}

# An ID is eight groups of seven characters — far wider than the row. The first
# group is the short form Syncthing itself uses, and it fits, so the row shows
# that and the full string lives one press away.
show_full_device_id() {
    if [ -z "$DEVICE_ID" ]; then
        popup message "Enable Syncthing once to create its configuration"
        return
    fi
    # One unbroken 63-character string has nothing for Bloom to wrap on, so
    # break it ourselves: two groups a line, dashes kept on the ends so it still
    # reads as one string rather than eight separate values.
    BLOCK="$(echo "$DEVICE_ID" | awk -F- '{
        for (i = 1; i <= NF; i += 2) {
            line = $i
            if (i + 1 <= NF) line = line "-" $(i + 1)
            if (i + 2 <= NF) line = line "-"
            print line
        }
    }')"
    message "$BLOCK

Please use the ID above to pair with another device" title "Device ID"
}

show_status_detail() {
    case "$STATUS" in
        Running)
            message "Syncthing is Running
PID: $(service_pid)
Set Enabled to \"Off\" to stop it" title "Status"
            ;;
        Paused)
            message "Syncthing is Paused until Wi-Fi is connected" title "Status"
            ;;
        *)
            message "Syncthing is Stopped
Set Enabled to \"On\" to start it" title "Status"
            ;;
    esac
}

# The address is the one thing here that gets typed into another machine, so
# it gets a screen of its own rather than only a row that may not fit.
show_web_url() {
    case "$WEB" in
        "Not enabled")
            message "The Web GUI is only available while Syncthing is enabled and running" title "Web GUI"
            ;;
        "Not running")
            message "The Web GUI is only available while Syncthing is running" title "Web GUI"
            ;;
        "Not connected to Wi-Fi")
            message "The Web GUI is only reachable when Wi-Fi is connected" title "Web GUI"
            ;;
        *)
            message "$WEB

Please visit the address above to manage your folders" title "Web GUI"
            ;;
    esac
}

# Three logs matter when something goes wrong, and which one holds the answer
# depends on how far it got: what the app tried, what `generate` said, and what
# the daemon said. Show all three newest-first so a failed start explains
# itself on the device instead of needing the files pulled off the card.
show_log() {
    TEXT=""
    for entry in "App:$LOG_DIR/Syncthing.app.log" \
        "Setup:$LOG_DIR/Syncthing.generate.log" \
        "Syncthing:$LOG_FILE"; do
        label="${entry%%:*}"
        file="${entry#*:}"
        [ -s "$file" ] || continue
        TEXT="$TEXT
--- $label ---
$(tail -n 20 "$file" 2>/dev/null)
"
    done

    if [ -z "$TEXT" ]; then
        popup message "No logs are available yet"
        return
    fi
    message "$TEXT" title "Logs"
}

# Turning Syncthing on means all three of: the boot hook, the watcher that does
# the Wi-Fi gating, and the daemon itself. They were three separate settings
# once; in practice nobody wants a subset, and a half-applied combination is
# what produced the states the status row had to explain.
turn_on() {
    if ! boot_enable; then
        message "Syncthing could not write its startup file

Please check \"View Logs\" for details" title "Error"
        return
    fi
    if run_with_progress "Starting Syncthing..." "$APP_DIR/bin/service-on"; then
        watcher_start
        notify "Syncthing started" for 2
        return
    fi
    # Nothing is running, so leave nothing installed behind either.
    boot_disable
    if ! card_writable; then
        message "Syncthing could not start because the SD card is read-only

Please run a disk check on your SD card from a computer"
    else
        message "Syncthing failed to start
Please check \"View Logs\" for details"
    fi
}

turn_off() {
    boot_disable
    watcher_stop
    if run_with_progress "Stopping Syncthing..." "$APP_DIR/bin/service-off"; then
        notify "Syncthing stopped" for 2
    else
        message "Syncthing did not stop cleanly"
    fi
}

# Folders are the user's to add from the Web GUI, and a fresh install has none.
# Syncthing answers a scan request for an empty folder list with the same 200
# it gives a real one, so this is the only place the difference can be caught.
folder_count() {
    [ -f "$CONFIG_FILE" ] || { echo 0; return; }
    # Not a plain grep for "<folder ": the config always carries a <defaults>
    # block holding a template folder, so a match count is never zero however
    # little is shared. Skip that block, and count only entries with a real id.
    fc="$(awk '
        /<defaults>/    { in_defaults = 1 }
        /<\/defaults>/  { in_defaults = 0; next }
        in_defaults     { next }
        $0 ~ /<folder / && $0 !~ /id=""/ { n++ }
        END { print n + 0 }
    ' "$CONFIG_FILE" 2>/dev/null)"
    echo "${fc:-0}"
}

# What Syncthing has actually done to the files, which is the question the log
# never answers — the log is about the daemon, this is about the folders.
show_changes() {
    if [ "$STATUS" = "Paused" ]; then
        popup message "Syncthing is paused because Wi-Fi isn't connected. Please connect to Wi-Fi to see recent changes"
        return
    fi
    if ! is_running; then
        popup message "Syncthing is disabled. Please set Enabled to \"On\" to see recent changes"
        return
    fi
    rm -f "$CHANGES_FILE"
    if ! run_with_progress "Checking recent changes..." "$APP_DIR/bin/recent-changes" "$CHANGES_FILE"; then
        popup message "Could not reach Syncthing to read recent changes. Please check the log for details"
        return
    fi
    # Syncthing keeps its event log in memory, so this is empty after a restart
    # even on a folder with a long history. Say so, rather than implying the
    # folders themselves have been idle.
    if [ ! -s "$CHANGES_FILE" ]; then
        popup message "No changes since Syncthing last started"
        return
    fi
    message "$(cat "$CHANGES_FILE")" title "Recent Changes"
}

do_sync_now() {
    if [ "$STATUS" = "Paused" ]; then
        popup message "Syncthing is paused because Wi-Fi isn't connected. Please connect to Wi-Fi to run a rescan"
        return
    fi
    if ! is_running; then
        popup message "Syncthing is disabled. Please set Enabled to \"On\" to run a rescan"
        return
    fi
    if [ "$(folder_count)" -eq 0 ]; then
        popup message "There are no folders to scan yet. Please add them via the Web GUI"
        return
    fi
    if run_with_progress "Asking Syncthing to rescan..." "$APP_DIR/bin/sync-now"; then
        notify "Rescan requested" for 2
    else
        popup message "Could not reach Syncthing to request a rescan. Please check the log for details"
    fi
}

do_reset() {
    if ! confirm "Doing this will stop Syncthing and reset its configuration.  When you re-enable Syncthing it will generate a new Device ID and you'll need to set up your shared folders again (your actual files won't be affected)." title "Reset Configuration?" action "RESET" cancel "KEEP"; then
        return
    fi
    # A reset leaves Syncthing off, so take the boot hook with it — otherwise
    # the toggle reads Off with a watcher still installed behind it.
    boot_disable
    watcher_stop
    "$APP_DIR/bin/service-off" >/dev/null 2>&1
    rm -rf "$CONFIG_DIR"
    notify "Syncthing configuration reset" for 3
}

# Nothing works on a read-only card, and every symptom of it is misleading, so
# say it plainly once on the way in rather than letting it surface as a failed
# start or a config error buried in syncthing's log.
warn_if_read_only() {
    card_writable && return 0
    message "Your SD card is currently read-only.

Syncthing cannot store its configuration or sync anything until this is fixed. Sometimes Linux can remount an SD card as read-only when it finds errors on it.

Please try mounting the card on your computer and run a disk check on it (First Aid on macOS, or chkdsk on Windows), then try again." title "Error"
    return 1
}

# --- Main screen ------------------------------------------------------------

ensure_dirs
log "app.sh started"
# Everything below roots itself at Bloom's $CONFIG_PATH, so record what Bloom
# exported. "View Logs" can read it back on the device.
log "env: config=${CONFIG_PATH:-unset} app=$APP_DIR logs=${LOGS_PATH:-unset} platform=${PLATFORM:-unset} device=${DEVICE:-unset}"
# The app folder has a $(pwd) fallback, so only this says whether Bloom set it.
log "exported by bloom: APP_DIR=${APP_DIR_FROM_ENV:-unset} BLOOM=${BLOOM:-unset}"
warn_if_read_only

# Which row the cursor sits on when the menu is redrawn. `form` takes it as
# `at`, and matches a row label — but three of the button rows carry their
# value in the label ("Status: Running" becomes "Status: Paused"), so a label
# would stop matching at exactly the moment the state changed. An all-digit
# value is a 0-based row index instead, which is what the numbers below are.
LAST=""

while true; do
    # Intent, not reality: this row is what the user asked for, and the status
    # row below is what is actually happening. They differ while paused.
    if is_enabled; then RUN="On"; else RUN="Off"; fi

    URL="$(web_url 2>/dev/null)"
    DEVICE_ID="$(device_id)"

    # Three states, not two. The watcher stops the daemon when the network goes
    # away and starts it again when it comes back, leaving the user's "on"
    # intent recorded — so "Stopped" would read as though we had forgotten it.
    # A URL means we have an address, which is the same question as whether
    # Wi-Fi is up, and asking it twice costs another `ip addr`.
    if is_running; then
        STATUS="Running"
    elif is_enabled && [ -z "$URL" ]; then
        STATUS="Paused"
    else
        STATUS="Stopped"
    fi

    set -- "Enabled = $(onoff "$RUN") :: Runs in the background when Wi-Fi is connected"
    # The three read-only lines are button rows, not `Label = value` rows: only
    # buttons act on A, so this is what keeps SAVE meaning the toggle above and
    # nothing else. The cost is that their text lives in the label, which is
    # why they read `Label: value` rather than lining up in a value column.
    set -- "$@" "Status: $STATUS"
    # An address is only worth printing when something is listening at it: an
    # unreachable URL reads as a working one and sends the user to a browser
    # for nothing. Every other case says which of the two things is missing.
    if [ "$STATUS" = "Running" ] && [ -n "$URL" ]; then
        WEB="$URL"
    elif [ "$STATUS" != "Stopped" ]; then
        WEB="Not connected to Wi-Fi"
    elif is_enabled; then
        WEB="Not running"
    else
        WEB="Not enabled"
    fi
    set -- "$@" "Web GUI: $WEB"
    if [ -n "$DEVICE_ID" ]; then
        set -- "$@" "Device ID: ${DEVICE_ID%%-*}"
    else
        set -- "$@" "Device ID: --"
    fi
    set -- "$@" "Recent Changes" "Rescan All" "View Logs" "Reset Configuration"

    OUT="$(form "$@" title "Syncthing" at "$LAST")"

    # One line per menu interaction, which is a handful per session — the cost
    # is nothing and it splits the two ways a freeze on quit can happen. If
    # this appears without "app.sh exited" after it, the menu returned and we
    # stalled on the way out. If it never appears, the menu itself never
    # returned and app.sh is still waiting on Bloom.
    #
    # It records what came back, not just that something did: a save reports
    # the toggle's value, a button its label, a cancel nothing. That is enough
    # to tell a deliberate press from the keypress that launched the app
    # landing on a form that has only just been drawn.
    log "menu returned: ${OUT:-(cancelled)}"

    # B, or a button row. Buttons come back as their own label and never
    # produce a value line, so they can't be confused with a save.
    case "$OUT" in
        "")
            break
            ;;
        "Status: "*)
            LAST=1
            show_status_detail
            continue
            ;;
        "Web GUI: "*)
            LAST=2
            show_web_url
            continue
            ;;
        "Device ID: "*)
            LAST=3
            show_full_device_id
            continue
            ;;
        "Recent Changes")
            LAST=4
            show_changes
            continue
            ;;
        "Rescan All")
            LAST=5
            do_sync_now
            continue
            ;;
        "View Logs")
            LAST=6
            show_log
            continue
            ;;
        "Reset Configuration")
            LAST=7
            do_reset
            continue
            ;;
    esac

    # A save: the one option row's chosen value. It is the value that comes
    # back, not a row label, so there is nothing here to feed to `at` — but a
    # save can only have come from the one row that has values, so the cursor
    # belongs on Enabled either way.
    LAST=0
    NEW_RUN="$(echo "$OUT" | sed -n 1p)"

    if [ "$NEW_RUN" != "$RUN" ]; then
        if [ "$NEW_RUN" = "On" ]; then turn_on; else turn_off; fi
    fi
done
