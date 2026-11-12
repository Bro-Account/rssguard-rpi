#!/bin/bash
# Smoke test for the released RSSGuard build.
#
# Runs in a CI container that deliberately contains ONLY runtime packages
# (no build tools, no dev headers) — the same situation as a stock Raspberry
# Pi OS system. The binary must start, stay alive, and produce no dynamic
# loader errors. This catches problems a successful compile cannot: missing
# runtime libraries or incompatible library symbol versions.
set -u

TARBALL="${1:?usage: smoke-test.sh <tarball>}"

echo "== Unpacking ${TARBALL} to /usr/local =="
rm -rf /usr/local/bin/rssguard /usr/local/lib/librssguard.so /usr/local/share/rssguard
tar -xzf "$TARBALL" -C /usr/local
ldconfig

# Layout assertion: the installed files must sit where the app expects them.
LAYOUT_OK=true
for INSTALLED_FILE in /usr/local/bin/rssguard /usr/local/lib/librssguard.so; do
  if [ ! -e "$INSTALLED_FILE" ]; then
    echo "FAIL: expected installed file missing: ${INSTALLED_FILE}"
    LAYOUT_OK=false
  fi
done
if [ ! -x /usr/local/bin/rssguard ]; then
  echo "FAIL: /usr/local/bin/rssguard is not executable"
  LAYOUT_OK=false
fi
if [ "$LAYOUT_OK" = false ]; then
  echo "FAIL: install layout does not match what RSSGuard expects"
  exit 1
fi
echo "✓ Layout check passed: binary and library in place under /usr/local"

echo "== Launching RSSGuard under Xvfb on a clean system =="
# The CI container runs as root; Chromium (inside Qt WebEngine) refuses the
# sandbox there, so disable it for this test environment only.
xvfb-run -a --server-args="-screen 0 1280x1024x24" bash -c '
  export QTWEBENGINE_DISABLE_SANDBOX=1
  export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox"
  /usr/local/bin/rssguard > /tmp/rssguard-stdout.log 2> /tmp/rssguard-stderr.log &
  APP_PID=$!
  sleep 15
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: rssguard exited before the smoke-test timeout"
    exit 1
  fi
  if command -v import >/dev/null 2>&1; then
    import -window root /tmp/rssguard-smoke.png 2>/dev/null || echo "(screenshot unavailable)"
  elif command -v magick >/dev/null 2>&1; then
    magick import -window root /tmp/rssguard-smoke.png 2>/dev/null || echo "(screenshot unavailable)"
  fi
  kill "$APP_PID" 2>/dev/null
'
RESULT=$?

echo "== RSSGuard stderr =="
cat /tmp/rssguard-stderr.log 2>/dev/null || true

if [ "$RESULT" -ne 0 ]; then
  echo "FAIL: smoke test did not pass (exit ${RESULT})"
  exit "$RESULT"
fi

if grep -qi "error while loading shared libraries" /tmp/rssguard-stderr.log 2>/dev/null; then
  echo "FAIL: dynamic loader reported a missing library"
  exit 1
fi

if grep -qiE "version .+ not found" /tmp/rssguard-stderr.log 2>/dev/null; then
  echo "FAIL: binary requires a library symbol version that stock Debian 13 does not provide"
  exit 1
fi

if [ -s /tmp/rssguard-smoke.png ]; then
  echo "✓ Screenshot captured: $(du -h /tmp/rssguard-smoke.png | cut -f1)"
else
  echo "(no screenshot captured)"
fi

echo "✓ Smoke test passed: RSSGuard started, rendered, and stayed alive"
