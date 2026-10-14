#!/bin/sh
# Drive app.sh against stubbed Bloom verbs and a fake device.
SRC="$1"
STUB="$2"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

export FAKE="$ROOT/fake"; mkdir -p "$FAKE"
export SYS_NET="$ROOT/sys/net"; mkdir -p "$SYS_NET/wlan0"
export CONFIG_PATH="$ROOT/userdata"; mkdir -p "$CONFIG_PATH"
export LOGS_PATH="$ROOT/logs"; mkdir -p "$LOGS_PATH"
export APP_DIR="$ROOT/Syncthing.app"
export TRANSCRIPT="$ROOT/transcript"
export QUEUE="$ROOT/queue"
export PATH="$STUB:$PATH"
# Keep scratch files and the watcher pidfile inside the sandbox, so a run can't
# pick up leftovers from a previous one (or from a real device's /tmp).
export PAK_RUN_DIR="$ROOT/run"; mkdir -p "$PAK_RUN_DIR"

cp -R "$SRC" "$APP_DIR"
# Stand in for the real daemon scripts — the arm64 binary can't run here.
# The config carries one real folder, because a rescan on an empty folder list
# is refused rather than attempted, and most of these cases want the normal path.
cat > "$APP_DIR/bin/service-on" <<'ON'
#!/bin/sh
touch "$FAKE/running" "$CONFIG_PATH/Syncthing/enabled"
mkdir -p "$CONFIG_PATH/Syncthing/config"
cat > "$CONFIG_PATH/Syncthing/config/config.xml" <<'XML'
<configuration>
  <folder id="saves" path="/mnt/SDCARD/Saves"></folder>
  <gui><address>0.0.0.0:8384</address><apikey>K</apikey></gui>
</configuration>
XML
ON
cat > "$APP_DIR/bin/service-off" <<'OFF'
#!/bin/sh
rm -f "$FAKE/running"
[ "$1" = "--keep-flag" ] || rm -f "$CONFIG_PATH/Syncthing/enabled"
OFF
cat > "$APP_DIR/bin/sync-now" <<'SN'
#!/bin/sh
[ -f "$FAKE/running" ] || exit 1
echo "SYNC-NOW CALLED" >> "$TRANSCRIPT"
SN
cat > "$APP_DIR/bin/recent-changes" <<'RC'
#!/bin/sh
[ -f "$FAKE/running" ] || exit 1
echo "RECENT-CHANGES CALLED" >> "$TRANSCRIPT"
printf 'Updated  saves/file.sav\n' > "$1"
RC
# The watcher is the one thing here that outlives app.sh, and its own behaviour
# is covered by wifi-watch.test.sh. Stub it, so a poll loop left running by an
# earlier case can't start the daemon back up under a later assertion.
cat > "$APP_DIR/bin/wifi-watch" <<'WW'
#!/bin/sh
echo "WATCHER STARTED" >> "$TRANSCRIPT"
WW
chmod +x "$APP_DIR/bin/service-on" "$APP_DIR/bin/service-off" \
    "$APP_DIR/bin/sync-now" "$APP_DIR/bin/recent-changes" "$APP_DIR/bin/wifi-watch"

wifi_on()  { echo up   > "$SYS_NET/wlan0/operstate"; touch "$FAKE/wifi"; }
wifi_off() { echo down > "$SYS_NET/wlan0/operstate"; rm -f "$FAKE/wifi"; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }
run_app() { : > "$TRANSCRIPT"; ( cd "$APP_DIR" && ${TEST_SH:-sh} ./app.sh >/dev/null 2>&1 ); }

# Run something with a deadline, so a hang fails the test instead of wedging it.
with_deadline() {
    limit="$1"; shift
    "$@" & wd_pid=$!
    n=0
    while [ "$n" -lt "$limit" ]; do
        kill -0 "$wd_pid" 2>/dev/null || { wait "$wd_pid"; return $?; }
        sleep 1; n=$((n + 1))
    done
    kill -9 "$wd_pid" 2>/dev/null
    return 124
}
drew() { grep -qF "$1" "$TRANSCRIPT" && echo 1 || echo 0; }
hooked() { grep -qF 'bloom-app: syncthing' "$CONFIG_PATH/post.sh" 2>/dev/null && echo 1 || echo 0; }

echo "== turn Syncthing on, Wi-Fi up =="
wifi_on
printf 'On\nCANCEL\n' > "$QUEUE"
run_app
check "daemon started"      "1" "$([ -f "$FAKE/running" ] && echo 1 || echo 0)"
check "progress bar shown"  "1" "$(drew 'PROGRESS: Starting Syncthing...')"
check "user told"           "1" "$(drew 'NOTIFY: Syncthing started')"
# Boot hook, watcher and daemon are one setting now, not three — enabling
# installs all of them, and a half-applied combination is the bug this catches.
check "boot hook installed" "1" "$(hooked)"
check "watcher started"     "1" "$(drew 'WATCHER STARTED')"

echo "== reopening shows live state =="
printf 'CANCEL\n' > "$QUEUE"
run_app
check "enabled row starred" "1" "$(drew 'Enabled = Off|*On')"
check "status row running"  "1" "$(drew 'Status: Running')"
check "web gui row filled"  "1" "$(drew 'Web GUI: 192.168.1.50:8384')"
# device-id shells out to the arm64 binary, which can't run here, so the row
# falls back — the point is that it degrades to a placeholder instead of blank.
check "device id row"       "1" "$(drew 'Device ID: --')"

echo "== a read-only row opens a detail screen instead of saving =="
printf 'Status: Running\nCANCEL\n' > "$QUEUE"
run_app
check "status detail shown" "1" "$(drew 'Syncthing is Running')"
printf 'Web GUI: 192.168.1.50:8384\nCANCEL\n' > "$QUEUE"
run_app
check "web gui detail shown" "1" "$(drew 'MESSAGE: 192.168.1.50:8384')"

echo "== Wi-Fi down: enabled but not running is Paused, not Stopped =="
# What the watcher leaves behind when the network goes away: the daemon down,
# but the user's "on" intent still recorded. Reporting that as Stopped would
# read as though we had forgotten what they asked for.
wifi_off
rm -f "$FAKE/running"          # the watcher's `service-off --keep-flag`
printf 'CANCEL\n' > "$QUEUE"
run_app
check "enabled row still on" "1" "$(drew 'Enabled = Off|*On')"
check "status row paused"    "1" "$(drew 'Status: Paused')"
check "web gui explains"     "1" "$(drew 'Web GUI: Not connected to Wi-Fi')"
wifi_on
touch "$FAKE/running"          # ...and starts it again when Wi-Fi comes back

echo "== Rescan All =="
printf 'Rescan All\nCANCEL\n' > "$QUEUE"
run_app
check "sync-now ran"  "1" "$(drew 'SYNC-NOW CALLED')"
check "user told"     "1" "$(drew 'NOTIFY: Rescan requested')"

echo "== Recent Changes =="
printf 'Recent Changes\nCANCEL\n' > "$QUEUE"
run_app
check "recent-changes ran" "1" "$(drew 'RECENT-CHANGES CALLED')"
check "changes shown"      "1" "$(drew 'Updated  saves/file.sav')"

echo "== Rescan All with no folders yet is refused, not attempted =="
# Syncthing answers a scan of an empty folder list with the same 200 it gives a
# real one, so app.sh has to catch this before it asks.
cp "$CONFIG_PATH/Syncthing/config/config.xml" "$ROOT/config.bak"
grep -v '<folder ' "$ROOT/config.bak" > "$CONFIG_PATH/Syncthing/config/config.xml"
printf 'Rescan All\nCANCEL\n' > "$QUEUE"
run_app
check "no-folders explained" "1" "$(drew 'MESSAGE: There are no folders to scan yet. Please add them via the Web GUI')"
check "sync-now not run"     "0" "$(drew 'SYNC-NOW CALLED')"
cp "$ROOT/config.bak" "$CONFIG_PATH/Syncthing/config/config.xml"

echo "== turn Syncthing off =="
printf 'Off\nCANCEL\n' > "$QUEUE"
run_app
check "daemon stopped"    "0" "$([ -f "$FAKE/running" ] && echo 1 || echo 0)"
check "boot hook gone"    "0" "$(hooked)"
check "stop confirmed"    "1" "$(drew 'NOTIFY: Syncthing stopped')"

echo "== Rescan All while stopped is refused, not attempted =="
printf 'Rescan All\nCANCEL\n' > "$QUEUE"
run_app
check "refused politely" "1" "$(drew 'MESSAGE: Syncthing is disabled. Please set Enabled to "On" to run a rescan')"
check "sync-now not run"  "0" "$(drew 'SYNC-NOW CALLED')"

echo "== Recent Changes while stopped is refused too =="
printf 'Recent Changes\nCANCEL\n' > "$QUEUE"
run_app
check "refused politely"       "1" "$(drew 'MESSAGE: Syncthing is disabled. Please set Enabled to "On" to see recent changes')"
check "recent-changes not run" "0" "$(drew 'RECENT-CHANGES CALLED')"

echo "== Reset asks first, and KEEP means no =="
printf 'On\nReset Configuration\nNO\nCANCEL\n' > "$QUEUE"
run_app
check "asked first"       "1" "$(drew 'CONFIRM: Doing this will stop Syncthing')"
check "config kept on No" "1" "$([ -f "$CONFIG_PATH/Syncthing/config/config.xml" ] && echo 1 || echo 0)"
check "daemon still up"   "1" "$([ -f "$FAKE/running" ] && echo 1 || echo 0)"

echo "== Reset on RESET wipes config and stops the daemon =="
printf 'Reset Configuration\nYES\nCANCEL\n' > "$QUEUE"
run_app
check "config wiped"     "0" "$([ -d "$CONFIG_PATH/Syncthing/config" ] && echo 1 || echo 0)"
check "daemon stopped"   "0" "$([ -f "$FAKE/running" ] && echo 1 || echo 0)"
# A reset leaves Syncthing off, so the boot hook has to go with it — otherwise
# the toggle reads Off with a watcher still installed behind it.
check "boot hook gone"   "0" "$(hooked)"
check "user told"        "1" "$(drew 'NOTIFY: Syncthing configuration reset')"

echo "== quitting closes the answer channel, so Bloom sees the app finish =="
# Bloom reads app.sh's stdout to get a verb's answer, and that pipe stays open
# for as long as any background child we left behind holds it. If one does, the
# reader below never reaches EOF — which is what a freeze on quit looks like.
wifi_on
printf 'On\nCANCEL\n' > "$QUEUE"; run_app          # leaves a daemon running
drain() { ( cd "$APP_DIR" && ${TEST_SH:-sh} ./app.sh 2>/dev/null | cat >/dev/null ); }
printf 'CANCEL\n' > "$QUEUE"
with_deadline 15 drain
check "stdout reached EOF" "0" "$?"

echo "== and the app records reaching the end =="
printf 'CANCEL\n' > "$QUEUE"
run_app
applog="$LOGS_PATH/Syncthing.app.log"
check "logged the start" "yes" "$(grep -q 'app.sh started' "$applog" && echo yes || echo no)"
check "logged the menu"  "yes" "$(grep -q 'menu returned:' "$applog" && echo yes || echo no)"
check "logged the exit"  "yes" "$(grep -q 'app.sh exited' "$applog" && echo yes || echo no)"

echo "== a read-only card says so, instead of failing obscurely =="
# Recreate what the device hit: the card remounted read-only, which surfaced
# only as a syncthing config-save error.
RO="$ROOT/readonly"
mkdir -p "$RO/Syncthing"
chmod -w "$RO" "$RO/Syncthing"
OLD_UD="$CONFIG_PATH"
export CONFIG_PATH="$RO"
printf 'CANCEL\n' > "$QUEUE"
run_app
check "warned on entry"    "1" "$(drew 'MESSAGE: Your SD card is currently read-only.')"
check "told how to fix it" "1" "$(grep -qF 'disk check' "$TRANSCRIPT" && echo 1 || echo 0)"
chmod +w "$RO" "$RO/Syncthing"
export CONFIG_PATH="$OLD_UD"

echo
[ "$fail" = 0 ] && echo "all app tests passed"
exit $fail
