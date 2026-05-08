#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON_BIN="${PYTHON_BIN:-$ROOT/.venv/bin/python}"
CDP_PORT="${CDP_PORT:-9223}"
PROFILE_DIR="${CHROME_PROFILE_DIR:-$ROOT/.tmp/chrome-cdp-profile}"
VIEWPORTS="${BEACON_CDP_VIEWPORTS:-desktop mobile}"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "missing executable Python environment: $PYTHON_BIN" >&2
  echo "create it with: uv venv .venv && .venv/bin/pip install -r requirements-dev.txt" >&2
  exit 1
fi

if [ "${CHROME_BIN:-}" ]; then
  CHROME="$CHROME_BIN"
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
elif command -v google-chrome >/dev/null 2>&1; then
  CHROME="$(command -v google-chrome)"
elif command -v chromium >/dev/null 2>&1; then
  CHROME="$(command -v chromium)"
else
  echo "missing Chrome/Chromium. Set CHROME_BIN to a headless-capable browser." >&2
  exit 1
fi

mkdir -p "$PROFILE_DIR"

"$CHROME" \
  --headless=new \
  --remote-debugging-port="$CDP_PORT" \
  --user-data-dir="$PROFILE_DIR" \
  --disable-gpu \
  --no-first-run \
  --no-default-browser-check \
  about:blank >/tmp/beacon-cdp-chrome.log 2>&1 &
CHROME_PID=$!

cleanup() {
  kill "$CHROME_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

ready=0
for _ in $(seq 1 60); do
  if "$PYTHON_BIN" - <<PY >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:$CDP_PORT/json", timeout=0.5).read()
PY
  then
    ready=1
    break
  fi
  sleep 0.25
done

if [ "$ready" != "1" ]; then
  echo "Chrome did not expose CDP on port $CDP_PORT" >&2
  tail -40 /tmp/beacon-cdp-chrome.log >&2 || true
  exit 1
fi

cd "$ROOT"
for VIEWPORT in $VIEWPORTS; do
  echo "== Beacon canonical browser conformance: $VIEWPORT =="
  PYTHONUNBUFFERED=1 "$PYTHON_BIN" test_all_cdp.py --canonical --viewport "$VIEWPORT" "$@"
done
