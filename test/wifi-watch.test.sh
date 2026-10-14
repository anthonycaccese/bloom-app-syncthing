#!/bin/sh
# Exercise the Wi-Fi gating: start when Wi-Fi comes up, stop when it drops,
# exit when "start at boot" is turned off.
SRC="$1"; STUB="$2"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"; kill "$WPID" 2>/dev/null' EXIT

export FAKE="$ROOT/fake"; mkdir -p "$FAKE"
export SYS_NET="$ROOT/sys/net"; mkdir -p "$SYS_NET/wlan0"
export CONFIG_PATH="$ROOT/userdata"; mkdir -p "$CONFIG_PATH"
export LOGS_PATH="$ROOT/logs"; mkdir -p "$LOGS_PATH"
export SYNCTHING_POLL_SECONDS=1
export PAK_RUN_DIR="$ROOT/run"; mkdir -p "$PAK_RUN_DIR"
export PATH="$STUB:$PATH"

APP="$ROOT/Syncthing.app"
cp -R "$SRC" "$APP"
cat > "$APP/bin/service-on" <<'ON'
#!/bin/sh
touch "$FAKE/running"
ON
cat > "$APP/bin/service-off" <<'OFF'
#!/bin/sh
rm -f "$FAKE/running"
[ "$1" = "--keep-flag" ] || rm -f "$CONFIG_PATH/Syncthing/enabled"
OFF
chmod +x "$APP/bin/service-on" "$APP/bin/service-off"

wifi_on()  { echo up   > "$SYS_NET/wlan0/operstate"; touch "$FAKE/wifi"; }
wifi_off() { echo down > "$SYS_NET/wlan0/operstate"; rm -f "$FAKE/wifi"; }
running()  { [ -f "$FAKE/running" ] && echo yes || echo no; }
settle()   { sleep 3; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }

# The state the watcher wakes up to at boot: enabled by the user, boot on.
mkdir -p "$CONFIG_PATH/Syncthing"
touch "$CONFIG_PATH/Syncthing/enabled"
printf '#!/bin/sh\n"%s/bin/wifi-watch" &   # bloom-app: syncthing\n' "$APP" > "$CONFIG_PATH/post.sh"

echo "== boots with Wi-Fi off: does not start Syncthing =="
wifi_off
"$APP/bin/wifi-watch" & WPID=$!
settle
check "stays stopped" "no" "$(running)"

echo "== Wi-Fi comes up later: starts it without the user coming back =="
wifi_on
settle
check "started" "yes" "$(running)"

echo "== Wi-Fi drops: stops it, but remembers the user wants it =="
wifi_off
settle
check "stopped"      "no"  "$(running)"
check "intent kept"  "yes" "$([ -f "$CONFIG_PATH/Syncthing/enabled" ] && echo yes || echo no)"

echo "== Wi-Fi returns: starts again =="
wifi_on
settle
check "restarted" "yes" "$(running)"

echo "== user disables Syncthing: watcher stops it =="
rm -f "$CONFIG_PATH/Syncthing/enabled"
settle
check "stopped" "no" "$(running)"

echo "== start at boot turned off: watcher exits =="
touch "$CONFIG_PATH/Syncthing/enabled"
grep -vF 'bloom-app: syncthing' "$CONFIG_PATH/post.sh" > "$CONFIG_PATH/post.sh.tmp"
mv "$CONFIG_PATH/post.sh.tmp" "$CONFIG_PATH/post.sh"
settle
kill -0 "$WPID" 2>/dev/null && alive=yes || alive=no
check "watcher exited"  "no" "$alive"
check "pidfile cleaned" "no" "$([ -f "$PAK_RUN_DIR/syncthing-pak-wifi-watch.pid" ] && echo yes || echo no)"

echo "== idle polling writes nothing to the card =="
# The card is FAT32 with no journal, so a write on every 15s poll is exactly
# the steady load that turns an unclean shutdown into corruption. Watch a
# quiet window where the test itself touches nothing.
wifi_on
touch "$CONFIG_PATH/Syncthing/enabled"
printf '#!/bin/sh\n"%s/bin/wifi-watch" &   # bloom-app: syncthing\n' "$APP" > "$CONFIG_PATH/post.sh"
"$APP/bin/wifi-watch" & WPID2=$!
sleep 2
stamp="$ROOT/stamp"; touch "$stamp"
sleep 4          # several poll cycles, with the test doing nothing
written="$(find "$CONFIG_PATH" -type f -newer "$stamp" 2>/dev/null)"
check "nothing written" "" "$written"
kill "$WPID2" 2>/dev/null

echo
[ "$fail" = 0 ] && echo "all watcher tests passed"
exit $fail
