#!/bin/sh
# Exercise the pure-shell helpers in common.sh against a fake config + post.sh.
set -u
APP_ROOT="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CONFIG_PATH="$TMP/userdata"
export LOGS_PATH="$TMP/logs"
export SYS_NET="$TMP/sys/net"
mkdir -p "$CONFIG_PATH" "$LOGS_PATH" "$SYS_NET/wlan0"
# Work on a copy, so the tests never touch the source tree.
APP_DIR="$TMP/Syncthing.app"
cp -R "$APP_ROOT" "$APP_DIR"
. "$APP_DIR/bin/common.sh"

fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<'XML'
<configuration version="38">
    <folder id="default" path="/mnt/SDCARD/Sync">
        <address>should-not-match</address>
    </folder>
    <options>
        <listenAddress>default</listenAddress>
    </options>
    <gui enabled="true" tls="false" debugging="false">
        <address>0.0.0.0:8384</address>
        <apikey>SECRETKEY123</apikey>
        <theme>default</theme>
    </gui>
</configuration>
XML

check "gui_address"  "0.0.0.0:8384" "$(gui_address)"
check "gui_port"     "8384"         "$(gui_port)"
check "api_key"      "SECRETKEY123" "$(api_key)"

# A user who moved the GUI to another port should be reflected everywhere.
sed -i.bak 's|0.0.0.0:8384|0.0.0.0:9999|' "$CONFIG_FILE"
check "gui_port after user change" "9999" "$(gui_port)"

# ip_address parsing, against real `ip addr` output shape.
ip_output='2: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP
    link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0
    inet6 fe80::1/64 scope link'
parsed="$(echo "$ip_output" | sed -n 's/^[[:space:]]*inet \([0-9.]*\).*/\1/p' | head -n 1)"
check "ip_address parse" "192.168.1.50" "$parsed"

# post.sh: add, be idempotent, and leave other apps alone.
printf '#!/bin/sh\n\n"/mnt/SDCARD/Tools/tg5040/Other.app/run.sh" &   # bloom-app: other\n' > "$POST_SH"
boot_enable
boot_enable
boot_enable
check "boot_enabled"        "0" "$(boot_enabled; echo $?)"
check "one marker line"     "1" "$(grep -cF "$BOOT_MARKER" "$POST_SH")"
check "other app preserved" "1" "$(grep -cF 'bloom-app: other' "$POST_SH")"

boot_disable
check "boot_enabled off"       "1" "$(boot_enabled; echo $?)"
check "other app still there"  "1" "$(grep -cF 'bloom-app: other' "$POST_SH")"
check "shebang still there"    "1" "$(grep -cF '#!/bin/sh' "$POST_SH")"

# boot_enable creates post.sh from nothing.
rm -f "$POST_SH"
boot_enable
check "post.sh created"  "1" "$(grep -cF "$BOOT_MARKER" "$POST_SH")"
check "created w/ shebang" "1" "$(grep -cF '#!/bin/sh' "$POST_SH")"

# The first-run GUI address rewrite in service-on, run in isolation.
cat > "$TMP/fresh.xml" <<'XML'
<configuration version="38">
    <folder id="x"><address>keep-me</address></folder>
    <gui enabled="true">
        <address>127.0.0.1:8384</address>
        <apikey>K</apikey>
    </gui>
</configuration>
XML
awk -v addr="0.0.0.0:8384" '
    /<gui[ >]/ { ingui = 1 }
    ingui && !done && /<address>/ {
        sub(/<address>[^<]*<\/address>/, "<address>" addr "</address>")
        done = 1
    }
    /<\/gui>/ { ingui = 0 }
    { print }
' "$TMP/fresh.xml" > "$TMP/fresh.out"
check "gui address opened"  "1" "$(grep -cF '<address>0.0.0.0:8384</address>' "$TMP/fresh.out")"
check "folder address kept" "1" "$(grep -cF '<address>keep-me</address>' "$TMP/fresh.out")"

echo
echo "-- ~ resolves to the card root, so ~/Saves works in the folder picker --"
check "HOME is the card root" "$SDCARD_PATH" "$HOME"

echo "-- the device name does not depend on the hostname --"
name_for() { env DEVICE="$1" PLATFORM="$2" CONFIG_PATH="$CONFIG_PATH" \
    APP_DIR="$APP_DIR" sh -c '. "$APP_DIR/bin/common.sh"; echo "$DEVICE_NAME"'; }
check "DEVICE wins"          "bloom_brick"  "$(name_for brick tg5040)"
check "PLATFORM when no DEVICE" "bloom_tg5040" "$(name_for "" tg5040)"
check "never a bare bloom_"  "yes" "$(n=$(name_for "" ""); [ "$n" != "bloom_" ] && echo yes || echo no)"

echo "-- the device name is written into a real generated config --"
cat > "$TMP/dev.xml" <<'XML'
<configuration version="52">
    <device id="ABC" name="some-hostname.local" compression="metadata">
        <address>dynamic</address>
    </device>
    <defaults>
        <device id="" compression="metadata"><address>dynamic</address></device>
    </defaults>
</configuration>
XML
awk -v nm="bloom_brick" '
    !done && /<device / && /name="/ { sub(/name="[^"]*"/, "name=\"" nm "\""); done = 1 }
    { print }
' "$TMP/dev.xml" > "$TMP/dev.out"
check "our device renamed"   "1" "$(grep -c 'name="bloom_brick"' "$TMP/dev.out")"
check "hostname gone"        "0" "$(grep -c 'some-hostname' "$TMP/dev.out")"
check "defaults untouched"   "1" "$(grep -c '<device id="" compression' "$TMP/dev.out")"

echo "-- a down interface is never queried, which is what froze the menu --"
cat > "$TMP/ip" <<'IPSTUB'
#!/bin/sh
echo called >> "$TMP_MARK"
echo "    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0"
IPSTUB
chmod +x "$TMP/ip"
PATH="$TMP:$PATH"
export TMP_MARK="$TMP/ip-called"

: > "$TMP_MARK"
echo down > "$SYS_NET/wlan0/operstate"
check "no address reported"  ""   "$(ip_address)"
check "ip was never run"     "0"  "$(wc -l < "$TMP_MARK" | tr -d " ")"
check "wifi_up says no"      "1"  "$(wifi_up; echo $?)"

: > "$TMP_MARK"
echo up > "$SYS_NET/wlan0/operstate"
check "address when up"      "192.168.1.50" "$(ip_address)"
check "wifi_up says yes"     "0"            "$(wifi_up; echo $?)"

echo "-- and a wedged interface times out instead of hanging the app --"
printf '#!/bin/sh\nsleep 300\n' > "$TMP/ip"; chmod +x "$TMP/ip"
start="$(date +%s)"
addr="$(ip_address)"
elapsed=$(( $(date +%s) - start ))
check "no address"        ""    "$addr"
check "gave up quickly"   "yes" "$([ "$elapsed" -le 6 ] && echo yes || echo no)"
check "logged the stall"  "yes" "$(grep -q 'did not return within' "$LOG_DIR/Syncthing.app.log" && echo yes || echo no)"

echo "-- boot_enable reports what actually happened --"
# It used to return 0 whenever the append failed, because the status it handed
# back was `sync`'s. Only reading the line back catches a card that took the
# write and dropped it.
BE="$TMP/boot-enable"
mkdir -p "$BE/ud" "$BE/logs"
printf '#!/bin/sh\n\n' > "$BE/ud/post.sh"
chmod -w "$BE/ud/post.sh"
check "unwritable post.sh fails" "1" \
    "$(APP_DIR="$APP_DIR" CONFIG_PATH="$BE/ud" LOGS_PATH="$BE/logs" sh -c \
        '. "$APP_DIR/bin/common.sh"; boot_enable; echo $?')"
check "and says so in the log" "yes" \
    "$(grep -q 'boot_enable:' "$BE/logs/Syncthing.app.log" && echo yes || echo no)"
chmod +w "$BE/ud/post.sh"
check "writable post.sh succeeds" "0" \
    "$(APP_DIR="$APP_DIR" CONFIG_PATH="$BE/ud" LOGS_PATH="$BE/logs" sh -c \
        '. "$APP_DIR/bin/common.sh"; boot_enable; echo $?')"

echo "-- and refuses to write anything when Bloom did not set CONFIG_PATH --"
# Without the guard, post.sh would resolve to /post.sh at the filesystem root.
check "no CONFIG_PATH fails" "1" \
    "$(env -u CONFIG_PATH APP_DIR="$APP_DIR" LOGS_PATH="$BE/logs" sh -c \
        '. "$APP_DIR/bin/common.sh"; boot_enable; echo $?')"
check "and says why"         "yes" \
    "$(grep -q 'CONFIG_PATH not set' "$BE/logs/Syncthing.app.log" && echo yes || echo no)"

echo
[ "$fail" = 0 ] && echo "all helper tests passed"
exit $fail
