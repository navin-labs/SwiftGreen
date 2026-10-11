#!/bin/sh
# Launch a built SwiftGreen.app and check it stays up, creates its per-install TLS
# identity and opens its TLS listener. Usage: scripts/macos-smoke.sh path/to/SwiftGreen.app
# Note: runs as the current user, so it uses (and may create) that user's SwiftGreen state.
set -eu
app="$1"
identity="$HOME/Library/Application Support/SwiftGreen/identity.p12"
log="$(mktemp -t sg-smoke)"
# Through LaunchServices, as a user launches it: run directly from a shell, the shell
# becomes the TCC-responsible process and the first Bluetooth use aborts the app.
open -n -W ${SMOKE_OPEN_ARGS:-} --stdout "$log" --stderr "$log" "$app" &
i=0
sleep 2
until pid="$(pgrep -nx -f "$app/Contents/MacOS/SwiftGreen")"; do
  i=$((i + 1)); [ "$i" -ge 15 ] && { echo "FAIL: app did not start"; exit 1; }; sleep 1
done
trap 'kill "$pid" 2>/dev/null || true' EXIT
i=0
until lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: no TLS listener after ${i}s"; tail -40 "$log"; exit 1
  fi
  sleep 1
done
sleep 5
kill -0 "$pid" || { echo "FAIL: app exited"; tail -40 "$log"; exit 1; }
test -s "$identity" || { echo "FAIL: no TLS identity at $identity"; exit 1; }
grep -q "Could not load self-signed TLS identity" "$log" && { echo "FAIL: identity did not load"; exit 1; }
lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN
echo "smoke OK: macOS $(sw_vers -productVersion) $(uname -m) ($(lipo -archs "$app/Contents/MacOS/SwiftGreen"))"
