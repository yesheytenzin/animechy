#!/usr/bin/env bash
# Animechy setup — no compile, pure Python bridge
# Installs Python deps and copies bridge to .runtime, verifies it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$DIR/.runtime"
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

# If already installed and version matches and bridge works, exit early
if [[ -x "$BRIDGE_DST" && -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" == "$VERSION" ]]; then
  if python3 "$BRIDGE_DST" '{"cmd":"ping"}' 2>/dev/null | grep -q '"ok": *true'; then
    say "bridge $VERSION already installed"
    exit 0
  fi
  warn "bridge present but failed ping — reinstalling"
fi

# Copy bridge
say "installing bridge $VERSION → $BRIDGE_DST"
install -Dm0755 "$BRIDGE_SRC" "$BRIDGE_DST"

# Ensure deps: requests, beautifulsoup4, lxml
# Try pipx > uv > pip --user > system packages via pacman check
need_install=false
if ! python3 -c "import requests, bs4, lxml" 2>/dev/null; then
  need_install=true
  say "missing Python deps — installing requests beautifulsoup4 lxml"
fi

if $need_install; then
  installed=false
  # try pipx
  if command -v pipx >/dev/null 2>&1; then
    say "trying pipx install ..."
    if pipx install requests beautifulsoup4 lxml >/dev/null 2>&1; then installed=true; fi
  fi
  # try uv
  if ! $installed && command -v uv >/dev/null 2>&1; then
    say "trying uv pip install --system ..."
    if uv pip install --system requests beautifulsoup4 lxml >/dev/null 2>&1; then installed=true; fi
  fi
  # try pip3 --user
  if ! $installed && command -v pip3 >/dev/null 2>&1; then
    say "trying pip3 install --user ..."
    if pip3 install --user requests beautifulsoup4 lxml >/dev/null 2>&1; then installed=true; fi
  fi
  # try pip (python -m pip)
  if ! $installed && python3 -m pip --version >/dev/null 2>&1; then
    say "trying python3 -m pip install --user ..."
    if python3 -m pip install --user requests beautifulsoup4 lxml >/dev/null 2>&1; then installed=true; fi
  fi
  # fallback: check if pacman can install
  if ! $installed; then
    if command -v pacman >/dev/null 2>&1; then
      warn "pip install failed — try: sudo pacman -S python-requests python-beautifulsoup4 python-lxml"
    else
      warn "could not install deps automatically — please run: pip3 install --user requests beautifulsoup4 lxml"
    fi
  fi

  # verify again
  if ! python3 -c "import requests, bs4, lxml" 2>/dev/null; then
    warn "deps still missing — bridge may fail. Install manually: pip3 install --user requests beautifulsoup4 lxml"
  else
    say "Python deps OK"
  fi
else
  say "Python deps OK (requests + bs4 + lxml present)"
fi

# Verify bridge
say "verifying bridge ..."
if ! python3 "$BRIDGE_DST" '{"cmd":"ping"}' 2>/dev/null | grep -q '"ok": *true'; then
  warn "bridge ping failed — check python deps and bridge script"
  python3 "$BRIDGE_DST" '{"cmd":"ping"}' || true
  fail "bridge verification failed"
fi

# Quick functional test (search)
say "testing search ..."
if python3 "$BRIDGE_DST" '{"cmd":"search","q":"one piece"}' 2>/dev/null | grep -q '"ok": *true'; then
  say "search OK"
else
  warn "search test failed — network or anidb.app may be blocked"
fi

printf '%s\n' "$VERSION" > "$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"

say "installed $BRIDGE_DST ($VERSION) — ready"
# Signal no shell restart needed for python bridge (fast), but keep marker for consistency
# echo "ANIMECHY_RESTART_SHELL=1"  # not needed

exit 0
