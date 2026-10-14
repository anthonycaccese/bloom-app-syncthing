# Shared paths and helpers for the Bloom Syncthing app.
#
# Sourced by app.sh and by every script in bin/. POSIX sh only — Bloom runs
# BusyBox ash, so no arrays, no [[ ]], no process substitution.
#
# The caller must set APP_DIR to the app folder before sourcing. Bloom already
# hands app.sh an $APP_DIR; the bin/ scripts derive it from $0.

# --- Paths ------------------------------------------------------------------

# Bloom exports $CONFIG_PATH to app.sh and to everything post.sh launches at
# boot, so every script here reads it straight from the environment.
#
# $CONFIG_PATH is the per-device area, one directory per device holding every
# app's state — not to be confused with $CONFIG_DIR below, which is Syncthing's
# own config living inside it.
#
# $LOGS_PATH, $DEVICE and $PLATFORM exist in practice but are not promised, so
# each has a fallback where it is used.
CONFIG_PATH="${CONFIG_PATH:-}"
LOGS_PATH="${LOGS_PATH:-}"
DEVICE="${DEVICE:-}"
PLATFORM="${PLATFORM:-}"

SDCARD_PATH="${SDCARD_PATH:-/mnt/SDCARD}"

APP_HOME="$CONFIG_PATH/Syncthing"
# Syncthing's own config, inside our corner of Bloom's $CONFIG_PATH.
CONFIG_DIR="$APP_HOME/config"
CONFIG_FILE="$CONFIG_DIR/config.xml"
LOG_DIR="${LOGS_PATH:-$APP_HOME/logs}"
LOG_FILE="$LOG_DIR/Syncthing.log"

# "The user wants Syncthing running." Kept separate from "is it running right
# now" so a Wi-Fi drop doesn't read as the user turning it off.
ENABLED_FLAG="$APP_HOME/enabled"
API_HOST_CACHE="$APP_HOME/.api-host"

# Scratch files belong in RAM, not on the card. The Wi-Fi watcher polls every
# 15 seconds, and a card write on every poll is exactly the steady write load
# that makes an unclean shutdown corrupt a journal-less FAT32 filesystem. A
# pidfile also *should* vanish on reboot, which /tmp gives us for free.
PAK_RUN_DIR="${PAK_RUN_DIR:-/tmp}"
WATCHER_PIDFILE="$PAK_RUN_DIR/syncthing-pak-wifi-watch.pid"
IP_SCRATCH="$PAK_RUN_DIR/syncthing-pak-ip"
HTTP_SCRATCH="$PAK_RUN_DIR/syncthing-pak-http"

POST_SH="$CONFIG_PATH/post.sh"
BOOT_MARKER="# bloom-app: syncthing"

DEFAULT_GUI_ADDRESS="0.0.0.0:8384"

# Shown to every device this one pairs with. Syncthing would otherwise take
# whatever os.Hostname() returns at config creation, which is out of our hands.
st_dev="${DEVICE:-$PLATFORM}"  # both normalised above
if [ -z "$st_dev" ]; then
    st_dev="$(hostname 2>/dev/null)"
    st_dev="${st_dev#bloom_}"
fi
[ -n "$st_dev" ] || st_dev="device"
DEVICE_NAME="bloom_$st_dev"

# Hard limit on any one HTTP attempt, so the UI can never be stuck.
HTTP_TIMEOUT=12

# Only arm64 ships today, but detect so adding 32-bit arm is a Makefile line.
ARCH=arm
uname -m | grep -q 64 && ARCH=arm64
SYNCTHING="$APP_DIR/bin/$ARCH/syncthing"

# --- Environment for the syncthing binary -----------------------------------

# These firmwares have no system trust store, so syncthing's discovery, relay
# and upgrade calls need the CA bundle we ship.
export SSL_CERT_FILE="$APP_DIR/certs/ca-certificates.crt"
# Syncthing expands ~ to $HOME, and the web UI's folder picker is the only
# place that matters — so point it at the card root, where the things anyone
# would want to sync actually live (~/Saves, ~/Roms, ~/Screenshots). Syncthing
# stores nothing here; its own files are governed by --home.
export HOME="$SDCARD_PATH"

ensure_dirs() {
    mkdir -p "$APP_HOME" "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null
}

# The card is FAT32/exFAT, and Linux remounts it read-only the moment it hits
# corruption or an I/O error. Everything then fails in confusing ways —
# syncthing reports it as a config save error deep in its own log — so check
# for it directly and say so.
card_writable() {
    ensure_dirs
    cw_probe="$APP_HOME/.writable"
    if ( : >"$cw_probe" ) 2>/dev/null; then
        rm -f "$cw_probe"
        return 0
    fi
    return 1
}

log() {
    # Only the log directory — ensure_dirs would recreate the config directory
    # too, which quietly undoes a Reset that just deleted it.
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG_DIR/Syncthing.app.log" 2>/dev/null
}

# --- Service state ----------------------------------------------------------

is_running() {
    pgrep syncthing >/dev/null 2>&1
}

service_pid() {
    pgrep syncthing 2>/dev/null | sort -n | head -n 1
}

is_enabled() {
    [ -f "$ENABLED_FLAG" ]
}

# --- Wi-Fi ------------------------------------------------------------------

# Overridable so the behaviour can be exercised off-device.
SYS_NET="${SYS_NET:-/sys/class/net}"

wifi_iface() {
    for i in wlan0 wlan1; do
        [ -e "$SYS_NET/$i/operstate" ] && { echo "$i"; return 0; }
    done
    return 1
}

# Up *and* addressed. The interface reports "up" before DHCP lands, so an
# operstate check on its own will hand us a box with no usable address.
wifi_up() {
    [ -n "$(ip_address)" ]
}

ip_address() {
    ia_iface="$(wifi_iface)" || return 1

    # A down interface has no address worth asking for, and asking anyway is
    # how the menu froze after a sleep: coming back with Wi-Fi off, the query
    # to a half-initialised wlan driver never returned, and app.sh blocks
    # while it waits.
    [ "$(cat "$SYS_NET/$ia_iface/operstate" 2>/dev/null)" = "up" ] || return 1

    run_limited 3 ip addr show "$ia_iface" >"$IP_SCRATCH" 2>/dev/null
    if [ "$?" = 124 ]; then
        log "ip addr show $ia_iface did not return within 3s"
        return 1
    fi
    sed -n 's/^[[:space:]]*inet \([0-9.]*\).*/\1/p' "$IP_SCRATCH" 2>/dev/null | head -n 1
}

# Same, but give DHCP a few seconds to finish before giving up.
ip_address_wait() {
    count=0
    while [ "$count" -lt 5 ]; do
        addr="$(ip_address)"
        [ -n "$addr" ] && { echo "$addr"; return 0; }
        count=$((count + 1))
        sleep 1
    done
    return 1
}

# Bloom boots this device with the loopback interface down. That breaks far
# more than calls to 127.0.0.1: Linux routes every packet addressed to a local
# address through lo, including ones sent to the device's own LAN IP, so with
# it down the device cannot reach its own services at any address. Bringing it
# up is a no-op where it is already up, and apps run as root here.
# lo has no carrier, so the kernel reports its operstate as "unknown" once it
# is up — never "up". Read the interface flags instead, where IFF_UP is bit 0,
# and fall back to treating anything that is not "down" as up.
loopback_up() {
    lu_flags="$(cat "$SYS_NET/lo/flags" 2>/dev/null)"
    case "$lu_flags" in
        0x*) [ "$(( lu_flags & 1 ))" -eq 1 ] && return 0 || return 1 ;;
    esac
    [ "$(cat "$SYS_NET/lo/operstate" 2>/dev/null)" != "down" ]
}

ensure_loopback() {
    loopback_up && return 0

    if command -v ip >/dev/null 2>&1; then
        ip link set lo up 2>/dev/null
        # A fresh lo may have no address either; adding an existing one fails
        # harmlessly.
        ip addr show lo 2>/dev/null | grep -q '127\.0\.0\.1' ||
            ip addr add 127.0.0.1/8 dev lo 2>/dev/null
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null
    else
        log "loopback is down and neither ip nor ifconfig exists"
        return 1
    fi

    if loopback_up; then
        log "brought the loopback interface up"
        return 0
    fi
    log "could not bring the loopback interface up"
    return 1
}

# --- Reading the syncthing config -------------------------------------------

# The <address> inside the <gui> block — not the <listenAddress> entries.
gui_address() {
    [ -f "$CONFIG_FILE" ] || return 1
    awk '/<gui[ >]/{ingui=1} /<\/gui>/{ingui=0} ingui' "$CONFIG_FILE" |
        sed -n 's:.*<address>\(.*\)</address>.*:\1:p' | head -n 1
}

gui_port() {
    addr="$(gui_address)"
    [ -n "$addr" ] || { echo "8384"; return; }
    echo "${addr##*:}"
}

api_key() {
    [ -f "$CONFIG_FILE" ] || return 1
    sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$CONFIG_FILE" | head -n 1
}

# What the user types into a browser on another machine.
web_url() {
    addr="$(ip_address)"
    [ -n "$addr" ] || return 1
    echo "$addr:$(gui_port)"
}

# --- Talking to the local REST API ---------------------------------------

# Run a command with a hard time limit, returning 124 if it outlives it.
#
# This matters more than it looks: app.sh blocks while a child runs, and Bloom
# draws nothing in the meantime, so a single hung HTTP client freezes the whole
# UI with no way out. BusyBox builds vary in whether they have a `timeout`
# applet and in which timeout flags their wget/nc accept, so don't rely on
# either — supervise the child ourselves.
# Poll granularity, decided once: a command that finishes immediately should
# not be padded out to a whole second, which matters now that quick calls are
# guarded too. Not every BusyBox sleep takes a fraction, so ask first.
if sleep 0.05 2>/dev/null; then
    RL_TICK=0.05
    RL_TICKS_PER_SEC=20
else
    RL_TICK=1
    RL_TICKS_PER_SEC=1
fi

# Capture output through a file, never `$(run_limited ...)`: a command
# substitution stays open until every process holding the pipe exits, so a
# descendant we could not reap would hang the caller regardless of the limit.
run_limited() {
    limit="$1"
    shift
    "$@" &
    rl_pid=$!
    rl_ticks=0
    rl_max=$((limit * RL_TICKS_PER_SEC))
    while [ "$rl_ticks" -lt "$rl_max" ]; do
        if ! kill -0 "$rl_pid" 2>/dev/null; then
            wait "$rl_pid"
            return $?
        fi
        sleep "$RL_TICK"
        rl_ticks=$((rl_ticks + 1))
    done
    # Descendants first, while they still have a parent to be found by: a
    # pipeline's members outlive the shell that started them, and one still
    # holding the output would keep a caller blocked even though we returned.
    command -v pkill >/dev/null 2>&1 && pkill -P "$rl_pid" 2>/dev/null
    kill -9 "$rl_pid" 2>/dev/null
    wait "$rl_pid" 2>/dev/null
    return 124
}

# The POST attempts, one per client. They read hp_* set by http_post; each is
# run through run_limited, so none of them can hang the app.
# No -f: it collapses every HTTP error into one exit code, which hides whether
# we were refused (403, wrong API key) or never arrived at all. Ask for the
# status instead and judge it ourselves. --noproxy stops a stray http_proxy in
# the firmware's environment from redirecting a loopback call.
_post_curl() {
    pc_code="$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 10 \
        -o /dev/null -w '%{http_code}' \
        -X POST -H "X-API-Key: $hp_key" -d '' "$hp_url")" || return 1
    case "$pc_code" in
        2*) return 0 ;;
        *)  echo "HTTP $pc_code" >&2; return 1 ;;
    esac
}

_post_wget() {
    wget -q -O /dev/null -T 10 \
        --header="X-API-Key: $hp_key" --post-data='' "$hp_url" >/dev/null
}

# Last resort, and the one that needs nothing but BusyBox. Some builds have no
# -w, so it is tried with and without.
_post_nc() {
    _nc_request | nc -w 5 "$hp_host" "$hp_port" 2>/dev/null | head -n 1 | grep -q ' 200'
}

_post_nc_plain() {
    _nc_request | nc "$hp_host" "$hp_port" 2>/dev/null | head -n 1 | grep -q ' 200'
}

_nc_request() {
    printf 'POST %s HTTP/1.0\r\nHost: %s:%s\r\nX-API-Key: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
        "$hp_path" "$hp_host" "$hp_port" "$hp_key"
}

# Addresses to reach our own GUI on, best first.
#
# 127.0.0.1 is the obvious one, but some firmwares leave the loopback
# interface down, and a dead lo black-holes traffic rather than refusing it —
# so a loopback call times out instead of failing fast. The GUI listens on
# 0.0.0.0, so the device's own LAN address reaches it just as well. Whichever
# answered last time is remembered and tried first.
api_hosts() {
    ah_cached="$(cat "$API_HOST_CACHE" 2>/dev/null)"
    ah_lan="$(ip_address)"
    for ah in "$ah_cached" "127.0.0.1" "$ah_lan"; do
        [ -n "$ah" ] || continue
        case " $ah_seen " in *" $ah "*) continue ;; esac
        ah_seen="$ah_seen $ah"
        echo "$ah"
    done
    ah_seen=""
}

# POST to a /rest path. Which HTTP client a firmware ships varies, so try them
# in order and log which one answered — that is the only way to find out what
# is actually on a given device.
http_post() {
    hp_path="$1"
    hp_key="$(api_key)"
    if [ -z "$hp_key" ]; then
        log "http_post: no API key in $CONFIG_FILE"
        return 1
    fi
    hp_port="$(gui_port)"
    ensure_loopback

    hp_have=""
    for hp_bin in curl wget nc; do
        command -v "$hp_bin" >/dev/null 2>&1 && hp_have="$hp_have $hp_bin"
    done
    if [ -z "$hp_have" ]; then
        log "http_post: none of curl, wget or nc exist on this firmware"
        return 1
    fi
    log "http_post: $hp_path on port $hp_port, clients present:$hp_have"

    hp_err="$HTTP_SCRATCH"
    # Client-major: a dead address costs one fast connect timeout per client
    # rather than a slow client's full budget before the good address is tried.
    for hp_try in curl wget nc nc_plain; do
        command -v "${hp_try%%_*}" >/dev/null 2>&1 || continue
        for hp_host in $(api_hosts); do
            hp_url="http://$hp_host:$hp_port$hp_path"
            rm -f "$hp_err"
            run_limited "$HTTP_TIMEOUT" "_post_$hp_try" >"$hp_err" 2>&1
            hp_rc=$?
            case "$hp_rc" in
                0)
                    log "http_post: $hp_path via $hp_try at $hp_host"
                    echo "$hp_host" >"$API_HOST_CACHE" 2>/dev/null
                    rm -f "$hp_err"
                    return 0
                    ;;
                124) log "http_post: $hp_try at $hp_host timed out after ${HTTP_TIMEOUT}s" ;;
                *)   log "http_post: $hp_try at $hp_host exit $hp_rc: $(head -n 2 "$hp_err" 2>/dev/null | tr '\n' ' ')" ;;
            esac
        done
    done
    rm -f "$hp_err"
    rm -f "$API_HOST_CACHE"

    if loopback_up; then hp_lo="up"; else hp_lo="down"; fi
    log "http_post: every client failed for $hp_path (loopback is $hp_lo)"
    return 1
}

# The GET half. Kept separate from http_post rather than folded into it: the
# POST path is load-bearing and well-tested, and the two differ in more than a
# method — a GET has a body we care about, which has to land in a file rather
# than be thrown away. nc is not in the list because it isn't on this firmware
# and reassembling a response body out of raw headers is not worth it for a
# client that doesn't exist. BusyBox wget only hangs on POSTs, so it can stay
# as the fallback here.
_get_curl() {
    gc_code="$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 10 \
        -o "$hg_out" -w '%{http_code}' -H "X-API-Key: $hg_key" "$hg_url")" || return 1
    case "$gc_code" in
        2*) return 0 ;;
        *)  echo "HTTP $gc_code" >&2; return 1 ;;
    esac
}

_get_wget() {
    wget -q -O "$hg_out" -T 10 --header="X-API-Key: $hg_key" "$hg_url" >/dev/null
}

# GET a /rest path, writing the response body to a file.
http_get() {
    hg_path="$1"
    hg_out="$2"
    hg_key="$(api_key)"
    if [ -z "$hg_key" ]; then
        log "http_get: no API key in $CONFIG_FILE"
        return 1
    fi
    hg_port="$(gui_port)"
    ensure_loopback

    for hg_try in curl wget; do
        command -v "$hg_try" >/dev/null 2>&1 || continue
        for hg_host in $(api_hosts); do
            hg_url="http://$hg_host:$hg_port$hg_path"
            : >"$hg_out"
            run_limited "$HTTP_TIMEOUT" "_get_$hg_try" >"$HTTP_SCRATCH" 2>&1
            hg_rc=$?
            case "$hg_rc" in
                0)
                    log "http_get: $hg_path via $hg_try at $hg_host"
                    echo "$hg_host" >"$API_HOST_CACHE" 2>/dev/null
                    rm -f "$HTTP_SCRATCH"
                    return 0
                    ;;
                124) log "http_get: $hg_try at $hg_host timed out after ${HTTP_TIMEOUT}s" ;;
                *)   log "http_get: $hg_try at $hg_host exit $hg_rc: $(head -n 2 "$HTTP_SCRATCH" 2>/dev/null | tr '\n' ' ')" ;;
            esac
        done
    done
    rm -f "$HTTP_SCRATCH"
    log "http_get: every client failed for $hg_path"
    return 1
}

# --- Start at boot ----------------------------------------------------------

# post.sh is shared with every other app, so we only ever add or remove our own
# marked line and never rewrite the file blind.
boot_enabled() {
    [ -f "$POST_SH" ] && grep -qF "$BOOT_MARKER" "$POST_SH"
}

boot_enable() {
    if [ -z "$CONFIG_PATH" ]; then
        log "boot_enable: CONFIG_PATH not set by Bloom"
        return 1
    fi
    mkdir -p "$CONFIG_PATH" 2>/dev/null
    if [ ! -f "$POST_SH" ] && ! printf '#!/bin/sh\n\n' 2>/dev/null >"$POST_SH"; then
        log "boot_enable: could not create $POST_SH"
        return 1
    fi
    boot_enabled && return 0
    echo "\"$APP_DIR/bin/wifi-watch\" &   $BOOT_MARKER" 2>/dev/null >>"$POST_SH"
    chmod +x "$POST_SH" 2>/dev/null
    sync
    # Read it back rather than trusting the append. A read-only card fails the
    # write without failing the command that made it, so the status of the
    # `echo` above says nothing — only the file does.
    if ! boot_enabled; then
        log "boot_enable: wrote to $POST_SH but the line is not there"
        return 1
    fi
    return 0
}

boot_disable() {
    [ -f "$POST_SH" ] || return 0
    grep -vF "$BOOT_MARKER" "$POST_SH" >"$POST_SH.tmp" 2>/dev/null &&
        mv "$POST_SH.tmp" "$POST_SH"
    chmod +x "$POST_SH" 2>/dev/null
    sync
}

# --- The Wi-Fi watcher ------------------------------------------------------

watcher_running() {
    [ -f "$WATCHER_PIDFILE" ] || return 1
    pid="$(cat "$WATCHER_PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q wifi-watch
}

watcher_start() {
    watcher_running && return 0
    # setsid where it exists, so the watcher is not merely backgrounded but in
    # its own session, holding none of our descriptors. Closing stdin matters
    # as much as stdout: an inherited descriptor of any kind keeps whoever is
    # reading the other end waiting.
    if command -v setsid >/dev/null 2>&1; then
        setsid "$APP_DIR/bin/wifi-watch" </dev/null >/dev/null 2>&1 &
    else
        ( "$APP_DIR/bin/wifi-watch" </dev/null >/dev/null 2>&1 & ) &
    fi
    return 0
}

watcher_stop() {
    watcher_running || { rm -f "$WATCHER_PIDFILE"; return 0; }
    kill "$(cat "$WATCHER_PIDFILE" 2>/dev/null)" >/dev/null 2>&1
    rm -f "$WATCHER_PIDFILE"
    return 0
}
