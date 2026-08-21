#!/usr/bin/env bash
# Animechy setup — no compile, pure Python bridge
# Installs Python deps and copies bridge to ~/.cache/animechy, verifies it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CRITICAL: never write inside the plugin dir — omarchy watches it with
# inotifywait -r and any write triggers a full shell plugin reload (screen blink).
RUNTIME="${XDG_CACHE_HOME:-$HOME/.cache}/animechy"
BRIDGE_SRC="$DIR/bridge/animechy-bridge.py"
BRIDGE_DST="$RUNTIME/animechy-bridge.py"
VERSION="$(jq -er '.version' "$DIR/manifest.json" 2>/dev/null || echo "1.0.0")"
VERSION_FILE="$RUNTIME/version"

say()  { printf '\033[1;36m[animechy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[animechy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[animechy]\033[0m %s\n' "$*"; exit 1; }

command -v mpv >/dev/null 2>&1 || warn "mpv not found — install with: omarchy pkg add mpv (or sudo pacman -S mpv)"
command -v python3 >/dev/null 2>&1 || fail "python3 not found — install python"

mkdir -p "$RUNTIME"

VENV="$RUNTIME/venv"
VENV_PY="$VENV/bin/python"
VENV_PIP="$VENV/bin/pip"
WRAPPER="$RUNTIME/animechy-bridge"
REQ_TXT="$DIR/bridge/requirements.txt"

# If already installed with matching version and isolated venv intact, exit early (no network/ping needed)
if [[ -x "$BRIDGE_DST" && -x "$VENV_PY" && -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" == "$VERSION" ]]; then
  if "$VENV_PY" -c "import requests, bs4, lxml" 2>/dev/null; then
    say "bridge $VERSION already installed (isolated venv)"
    exit 0
  fi
  warn "venv present but deps missing — reinstalling"
fi

# Copy bridge
say "installing bridge $VERSION → $BRIDGE_DST"
install -Dm0755 "$BRIDGE_SRC" "$BRIDGE_DST"

# --- Isolated venv (never mutates user/system site-packages) ---
# Previous versions used pipx / uv --system / pip --user which mutated global env.
# Now we create $RUNTIME/venv and pip install --require-hashes pinned deps there.
say "setting up isolated venv → $VENV"
if ! python3 -m venv "$VENV" 2>/dev/null; then
  warn "python3 -m venv failed — is python-venv installed? try: sudo pacman -S python"
  # fallback: check if system already has deps via pacman
  if python3 -c "import requests, bs4, lxml" 2>/dev/null; then
    warn "using system python deps as fallback (venv unavailable)"
    # create wrapper that uses system python3
    cat > "$WRAPPER" <<EOS
#!/usr/bin/env bash
exec python3 "$BRIDGE_DST" "\$@"
EOS
    chmod +x "$WRAPPER"
  else
    warn "no venv and no system deps — bridge will fail. Install: sudo pacman -S python-requests python-beautifulsoup4 python-lxml"
    cat > "$WRAPPER" <<EOS
#!/usr/bin/env bash
exec python3 "$BRIDGE_DST" "\$@"
EOS
    chmod +x "$WRAPPER"
  fi
else
  # venv created; install pinned hashed deps there
  say "installing pinned deps into venv (no --user/--system, --require-hashes) ..."
  if [[ -f "$REQ_TXT" ]]; then
    if ! "$VENV_PIP" install --require-hashes -r "$REQ_TXT" >/dev/null 2>&1; then
      warn "pip install --require-hashes failed — trying without hashes"
      if ! "$VENV_PIP" install -r "$REQ_TXT" >/dev/null 2>&1; then
        warn "venv pip install failed — network or hash mismatch. Bridge may still work if system deps exist."
      fi
    fi
  else
    warn "bridge/requirements.txt missing — installing unpinned (should not happen)"
    "$VENV_PIP" install requests beautifulsoup4 lxml soupsieve 2>/dev/null || true
  fi
  if "$VENV_PY" -c "import requests, bs4, lxml" 2>/dev/null; then
    say "Python deps OK (isolated venv)"
  else
    warn "venv deps still missing — try: sudo pacman -S python-requests python-beautifulsoup4 python-lxml as fallback"
  fi
  # wrapper that always uses venv python
  cat > "$WRAPPER" <<EOS
#!/usr/bin/env bash
exec "$VENV_PY" "$BRIDGE_DST" "\$@"
EOS
  chmod +x "$WRAPPER"
fi

# Verify bridge via isolated wrapper (non-fatal — still write version to avoid restart loop)
say "verifying bridge ..."
BRIDGE_CMD=("$WRAPPER")
if [[ ! -x "$WRAPPER" ]]; then
  BRIDGE_CMD=(python3 "$BRIDGE_DST")
fi
if ! "${BRIDGE_CMD[@]}" '{"cmd":"ping"}' 2>/dev/null | grep -q '"ok": *true'; then
  warn "bridge ping failed — check venv deps and bridge script; continuing anyway"
  "${BRIDGE_CMD[@]}" '{"cmd":"ping"}' || true
else
  say "bridge ping OK (via ${BRIDGE_CMD[0]})"
fi

# Quick functional test (search) — best-effort, no fail
say "testing search ..."
if "${BRIDGE_CMD[@]}" '{"cmd":"search","q":"one piece"}' 2>/dev/null | grep -q '"ok": *true'; then
  say "search OK"
else
  warn "search test failed — network or anidb.app may be blocked (expected on offline fresh install)"
fi

mkdir -p "$(dirname "$VERSION_FILE")"
printf '%s\n' "$VERSION" > "$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"

say "installed $BRIDGE_DST ($VERSION) — ready"
# Fresh install finished: ask the host to restart the Omarchy shell exactly ONCE.
# BarWidget.qml parses this marker and runs omarchy-restart-shell; the
# "already installed" early-exit above never prints it, so no restart loop.
echo "ANIMECHY_RESTART_SHELL=1"

exit 0
