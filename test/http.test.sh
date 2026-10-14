#!/bin/sh
# http_post must always return, whichever client the firmware ships.
#
# This exists because it didn't: on a Trimui Brick, Sync now hung hard enough
# that no button worked. app.sh blocks while a child runs and Bloom draws
# nothing meanwhile, so one hung HTTP client freezes the entire UI.

APP_ROOT="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CONFIG_PATH="$TMP/userdata"; mkdir -p "$CONFIG_PATH"
export LOGS_PATH="$TMP/logs"; mkdir -p "$LOGS_PATH"
export SYS_NET="$TMP/sys/net"; mkdir -p "$SYS_NET/lo"
APP_DIR="$TMP/Syncthing.app"
cp -R "$APP_ROOT" "$APP_DIR"
# shellcheck source=/dev/null
. "$APP_DIR/bin/common.sh"
ensure_dirs

printf '<configuration><gui><address>0.0.0.0:8384</address><apikey>K</apikey></gui></configuration>\n' \
    > "$CONFIG_FILE"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi; }

echo "-- lo reports operstate 'unknown' when up, so read the flags --"
# IFF_UP is bit 0. 0x49 = UP|LOOPBACK|RUNNING; 0x8 = LOOPBACK, down.
printf '0x49\n' > "$SYS_NET/lo/flags"; printf 'unknown\n' > "$SYS_NET/lo/operstate"
check "up despite 'unknown'" "0" "$(loopback_up; echo $?)"
printf '0x8\n' > "$SYS_NET/lo/flags"
check "down when IFF_UP clear" "1" "$(loopback_up; echo $?)"
rm -f "$SYS_NET/lo/flags"
printf 'unknown\n' > "$SYS_NET/lo/operstate"
check "no flags file: 'unknown' is up" "0" "$(loopback_up; echo $?)"
printf 'down\n' > "$SYS_NET/lo/operstate"
check "no flags file: 'down' is down"  "1" "$(loopback_up; echo $?)"

echo "-- a down loopback is brought up, since the device cannot reach itself --"
mkdir -p "$SYS_NET/lo"
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
# Stand in for iproute2: record the calls, and flip operstate on link-up.
cat > "$STUBBIN/ip" <<IPSTUB
#!/bin/sh
echo "\$@" >> "$TMP/ip-calls"
case "\$1 \$2" in
    "link set") echo unknown > "$SYS_NET/lo/operstate" ;;
    "addr show") exit 1 ;;
esac
exit 0
IPSTUB
chmod +x "$STUBBIN/ip"
PATH="$STUBBIN:$PATH"

echo down > "$SYS_NET/lo/operstate"
: > "$TMP/ip-calls"
check "reports success"      "0"    "$(ensure_loopback; echo $?)"
check "brought the link up"  "0"    "$(loopback_up; echo $?)"
check "assigned an address"  "yes"  "$(grep -q '127.0.0.1/8' "$TMP/ip-calls" && echo yes || echo no)"
check "said so in the log"   "yes"  "$(grep -q 'brought the loopback' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- and left alone when it is already up --"
: > "$TMP/ip-calls"
check "no-op"       "0"  "$(ensure_loopback; echo $?)"
check "touched nothing" "0" "$(wc -l < "$TMP/ip-calls" | tr -d " ")"

echo "-- run_limited returns the command's own status --"
check "success passes through" "0"   "$(run_limited 5 true; echo $?)"
check "failure passes through" "1"   "$(run_limited 5 false; echo $?)"

echo "-- run_limited kills a command that outlives its limit --"
start="$(date +%s)"
run_limited 2 sleep 60
rc=$?
elapsed=$(( $(date +%s) - start ))
check "reports timeout"    "124" "$rc"
check "gave up quickly"    "yes" "$([ "$elapsed" -le 5 ] && echo yes || echo no)"
check "child was killed"   "no"  "$(pgrep -f 'sleep 60' >/dev/null 2>&1 && echo yes || echo no)"

echo "-- a hanging client cannot hang http_post: the Brick's failure --"
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
for c in curl wget nc; do
    printf '#!/bin/sh\nsleep 300\n' > "$STUBBIN/$c"
    chmod +x "$STUBBIN/$c"
done
PATH="$STUBBIN:$PATH"
HTTP_TIMEOUT=2
start="$(date +%s)"
http_post "/rest/db/scan"
rc=$?
elapsed=$(( $(date +%s) - start ))
check "http_post reports failure" "1"   "$rc"
check "and returns promptly"      "yes" "$([ "$elapsed" -le 12 ] && echo yes || echo no)"
check "log names the timeouts"    "yes" "$(grep -q 'timed out' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"
check "log names the give-up"     "yes" "$(grep -q 'every client failed' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"
check "log lists what exists"    "yes" "$(grep -q 'clients present:' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- a client's own error message reaches the log, not just an exit code --"
printf '#!/bin/sh\necho "wget: unrecognized option --post-data" >&2\nexit 1\n' > "$STUBBIN/wget"
chmod +x "$STUBBIN/wget"
printf '#!/bin/sh\nexit 127\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/nc"; chmod +x "$STUBBIN/nc"
: > "$LOG_DIR/Syncthing.app.log"
http_post "/rest/db/scan" >/dev/null 2>&1
check "log quotes the error" "yes" "$(grep -q 'unrecognized option' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- an HTTP status is judged, not swallowed --"
# curl writes the status code to stdout via -w; stand in for that.
printf '#!/bin/sh\necho 200\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
check "2xx is success" "0" "$(http_post "/rest/db/scan" >/dev/null 2>&1; echo $?)"

printf '#!/bin/sh\necho 403\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/wget"; chmod +x "$STUBBIN/wget"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/nc"; chmod +x "$STUBBIN/nc"
: > "$LOG_DIR/Syncthing.app.log"
check "403 is failure"      "1"   "$(http_post "/rest/db/scan" >/dev/null 2>&1; echo $?)"
check "and is named in log" "yes" "$(grep -q 'HTTP 403' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- it falls through a broken client to a working one, and says which --"
printf '#!/bin/sh\nexit 127\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
printf '#!/bin/sh\nsleep 300\n' > "$STUBBIN/wget"; chmod +x "$STUBBIN/wget"
printf '#!/bin/sh\ncat >/dev/null; echo "HTTP/1.0 200 OK"\n' > "$STUBBIN/nc"; chmod +x "$STUBBIN/nc"
: > "$LOG_DIR/Syncthing.app.log"
check "succeeds via nc" "0"   "$(http_post "/rest/db/scan"; echo $?)"
check "log says which"  "yes" "$(grep -q 'via nc' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- a dead loopback falls through to the device's own LAN address --"
# This is the Trimui Brick's actual behaviour: lo is down, so a call to
# 127.0.0.1 black-holes and times out rather than being refused.
ip_address() { echo "192.168.68.222"; }
cat > "$STUBBIN/curl" <<'CURL'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        *127.0.0.1*) echo "curl: (28) Connection timed out" >&2; exit 28 ;;
        *192.168.68.222*) echo 200; exit 0 ;;
    esac
done
exit 1
CURL
chmod +x "$STUBBIN/curl"
rm -f "$API_HOST_CACHE"
: > "$LOG_DIR/Syncthing.app.log"
check "succeeds anyway"      "0"   "$(http_post "/rest/db/scan" >/dev/null 2>&1; echo $?)"
check "log names the host"   "yes" "$(grep -q 'via curl at 192.168.68.222' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"
check "loopback failure kept" "yes" "$(grep -q 'curl at 127.0.0.1' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"
check "working host cached"  "192.168.68.222" "$(cat "$API_HOST_CACHE" 2>/dev/null)"

echo "-- the cached host is tried first, so later calls cost one attempt --"
: > "$LOG_DIR/Syncthing.app.log"
check "still succeeds"     "0" "$(http_post "/rest/db/scan" >/dev/null 2>&1; echo $?)"
check "no wasted attempt"  "0" "$(grep -c '127.0.0.1' "$LOG_DIR/Syncthing.app.log")"

echo "-- a stale cache does not strand us --"
echo "10.0.0.99" > "$API_HOST_CACHE"
: > "$LOG_DIR/Syncthing.app.log"
check "recovers to a live host" "0" "$(http_post "/rest/db/scan" >/dev/null 2>&1; echo $?)"
check "cache corrected"         "192.168.68.222" "$(cat "$API_HOST_CACHE" 2>/dev/null)"

echo "-- when everything fails, the log says whether loopback is even up --"
printf '#!/bin/sh\nexit 7\n' > "$STUBBIN/curl"; chmod +x "$STUBBIN/curl"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/wget"; chmod +x "$STUBBIN/wget"
printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/nc"; chmod +x "$STUBBIN/nc"
: > "$LOG_DIR/Syncthing.app.log"
http_post "/rest/db/scan" >/dev/null 2>&1
check "loopback state logged" "yes" "$(grep -q 'loopback is' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"
check "stale cache cleared"   ""    "$(cat "$API_HOST_CACHE" 2>/dev/null)"

echo "-- no API key is a clean failure, not a hang --"
printf '<configuration><gui><address>0.0.0.0:8384</address></gui></configuration>\n' > "$CONFIG_FILE"
check "reports failure" "1"   "$(http_post "/rest/db/scan"; echo $?)"
check "log explains"    "yes" "$(grep -q 'no API key' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo
[ "$fail" = 0 ] && echo "all http tests passed"
exit $fail
