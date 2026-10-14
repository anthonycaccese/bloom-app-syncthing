#!/bin/sh
# Run every off-device test.
#
# The app can't be executed on a build machine — the syncthing binary is
# arm64 and Bloom's verbs only exist on the handheld. So these tests stub
# both: test/stubs/ stands in for Bloom's verbs and for the bits of the
# system we read (the process table, `ip`, /sys/class/net), and the tests
# drive the real app.sh and bin/ scripts against them.

set -e
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
APP="$REPO_DIR/Syncthing.app"
STUBS="$TEST_DIR/stubs"

# dash is the closest thing to the BusyBox ash Bloom actually runs.
SH=sh
command -v dash >/dev/null 2>&1 && SH=dash

chmod +x "$STUBS"/* 2>/dev/null || true

for t in helpers http app wifi-watch; do
    echo "### $t"
    TEST_SH="$SH" "$SH" "$TEST_DIR/$t.test.sh" "$APP" "$STUBS"
    echo
done

# Checking our syncthing flags against the real binary needs a download.
if [ -n "$SKIP_NETWORK_TESTS" ]; then
    echo "### flags (skipped: SKIP_NETWORK_TESTS is set)"
else
    echo "### flags"
    "$SH" "$TEST_DIR/flags.test.sh" "$APP"
fi
echo

echo "all tests passed"
