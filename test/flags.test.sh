#!/bin/sh
# Every flag we pass to syncthing must exist in the version we ship.
#
# This exists because it didn't: we shipped `generate --no-default-folder`,
# a flag syncthing v2 removed, and only found out from a device log. The
# flags are read out of bin/service-on rather than restated here, so this
# can't drift from what we actually run.
#
# The shipped binary is linux/arm64 and can't run on a build machine, so we
# download the host's build of the same version — the CLI surface is
# identical across platforms.

APP="$1"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
CACHE="$TEST_DIR/.cache"

VERSION="$(sed -n 's/^SYNCTHING_VERSION ?= *//p' "$REPO_DIR/Makefile")"
[ -n "$VERSION" ] || { echo "FAIL could not read SYNCTHING_VERSION from Makefile"; exit 1; }

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  ASSET="syncthing-macos-arm64-$VERSION.zip" ;;
    Darwin-x86_64) ASSET="syncthing-macos-amd64-$VERSION.zip" ;;
    Linux-x86_64)  ASSET="syncthing-linux-amd64-$VERSION.tar.gz" ;;
    Linux-aarch64) ASSET="syncthing-linux-arm64-$VERSION.tar.gz" ;;
    *) echo "SKIP no syncthing build for $(uname -s)-$(uname -m)"; exit 0 ;;
esac

DIR="${ASSET%.zip}"; DIR="${DIR%.tar.gz}"
ST="$CACHE/$DIR/syncthing"
if [ ! -x "$ST" ]; then
    mkdir -p "$CACHE"
    echo "     fetching $ASSET"
    curl -sSLf -o "$CACHE/$ASSET" \
        "https://github.com/syncthing/syncthing/releases/download/$VERSION/$ASSET" || {
        echo "FAIL could not download $ASSET"; exit 1; }
    case "$ASSET" in
        *.zip)    (cd "$CACHE" && unzip -oq "$ASSET") ;;
        *.tar.gz) (cd "$CACHE" && tar -xzf "$ASSET") ;;
    esac
    chmod +x "$ST" 2>/dev/null
    xattr -d com.apple.quarantine "$ST" 2>/dev/null
fi
[ -x "$ST" ] || { echo "FAIL no syncthing binary at $ST"; exit 1; }

fail=0

# Pull the flags straight out of the invocations in bin/service-on, so the
# test checks what we actually run.
flags_for() { # $1 = subcommand as it appears after "$SYNCTHING"
    grep -A2 "SYNCTHING\" $1" "$APP/bin/service-on" |
        tr ' ' '\n' | sed -n 's/^\(--[a-z-]*\).*/\1/p' | sort -u
}

check_subcommand() {
    sub="$1"
    help="$("$ST" "$sub" --help 2>&1)"
    found=0
    for flag in $(flags_for "$sub"); do
        found=$((found + 1))
        if echo "$help" | grep -q -- "$flag"; then
            echo "ok   $sub $flag"
        else
            echo "FAIL $sub $flag is not a flag in $VERSION"
            fail=1
        fi
    done
    if [ "$found" = 0 ]; then
        echo "FAIL found no flags for '$sub' in bin/service-on — has it been renamed?"
        fail=1
    fi
}

echo "     syncthing $VERSION"
check_subcommand generate
check_subcommand serve

# app.sh reads the device ID with --home; make sure that still exists too.
if "$ST" device-id --help 2>&1 | grep -q -- "--home"; then
    echo "ok   device-id --home"
else
    echo "FAIL device-id --home is not a flag in $VERSION"
    fail=1
fi

echo
[ "$fail" = 0 ] && echo "all flag tests passed"
exit $fail
