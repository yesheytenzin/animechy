# Animechy — Omarchy Quattro Anime Bar Plugin

> **Credit:** [ani-cli](https://github.com/pystardust/ani-cli) by [pystardust](https://github.com/pystardust) (GPL-3.0) — scraping logic for `anidb.app`

Quickshell bar widget for anime — click **ア** → search → pick season/episode (sub/dub) → stream in `mpv`. No Rust/compile, pure Python bridge. No manual prerequisites — fresh Omarchy already includes `mpv`+`python`; `requests`/`beautifulsoup4`/`lxml` auto-install on first click via `animechy-setup.sh` (`pipx`/`uv`/`pip --user`).

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/animechy.git --enable
```

The `animechy-setup.sh` auto-runs on first click (copies bridge to `~/.cache/animechy/`, installs `requests`+`bs4`+`lxml`, verifies `ping`+`search`). Click **ア** in the top bar to browse. Nothing is ever written inside the plugin dir, so the shell never restarts/blinks.

## Update

```bash
omarchy plugin update tenzin.animechy
```

## Remove

```bash
omarchy plugin remove tenzin.animechy
```

---

## Usage

1. Click **ア** in bar (center)
2. **Discover** shows 24 shuffled trending titles — tap any
3. **Search**: type + Enter, pick suggestion or genre chip (All, Action, Adventure… Supernatural)
4. **Details**: pick **Sub/Dub**, **Season** (if multiple), **Episode** `E1…` (filler dimmed), **Quality** `1080p→360p`, hit **▶ Play**
5. `mpv --force-window=immediate --cache=yes` opens; panel auto-closes. **Back** returns to Discover; **↻ Refresh** reloads current view; `Esc` closes panel.
6. Recent searches appear as chips below search bar (persisted to `~/.local/state/animechy/hists`, max 10).

## Features

- Bar widget `ア` with `BarWidget.qml` + `Panel.qml` (`KeyboardPanel`)
- Live suggestions (≥2 chars, 380 ms debounce) + genre cache (10 min)
- Episode grid with light-grey outline card (`Flickable`+`Flow`), `ScrollBar.AsNeeded`
- Streams via `anidb.app` → `embed_url` → `master.m3u8` → qualities sorted `1080p,720p…`
- Parallel bridge IPC (queued `bridgeProc` + dedicated `streamsProc` for instant `E1` streams)
- Caching in `~/.cache/animechy/` — search 24h (`86400`), details 7d (`604800`), episodes 2h, streams 2h
- Sub/Dub toggle with `sub→dub` fallback if first mode empty

## Manual setup

```bash
cd ~/.config/omarchy/plugins/tenzin.animechy
bash animechy-setup.sh
python3 ~/.cache/animechy/animechy-bridge.py '{"cmd":"search","q":"one piece"}' | jq
python3 ~/.cache/animechy/animechy-bridge.py '{"cmd":"episodes","id":"one-piece-3880"}' | jq '.items | length'
python3 ~/.cache/animechy/animechy-bridge.py '{"cmd":"streams","id":"one-piece-3880","episode":"1","mode":"sub"}' | jq
```

## Bridge API

`python3 bridge/animechy-bridge.py '{"cmd":"…",…}'` → `{ok:true,…}` or `{ok:false,error}`

| cmd | params | returns |
|-----|--------|---------|
| `ping` | — | `{pong:true}` |
| `search` | `{q, page}` | `{items:[{id,title,cover,year,rating}]}` |
| `details` | `{id}` | `{value:{title,intro,description,year,genre,cover,coverUrl,seasons_list[],mal_id}}` |
| `episodes` | `{id}` | `{items:[{id,number,filler}]}` |
| `streams` | `{id,episode,mode}` | `{items:[{resolution,quality,url,resourceLink,bandwidth}]}` |
| `homepage` | `{page,perPage}` | `{items:[...]}` |
| `suggest` | `{q}` | `{suggestions:[{name,id,cover}]}` |

## How it works

```
Panel.qml ──JSON──> animechy-bridge.py ──HTTP──> anidb.app
   │                     │                         ├── /browse?q=            → search (regex anime/([a-z0-9-]+-[0-9]+)".*alt="([^"]+)")
   │                     │                         ├── /anime/<id>           → details + Seasons (<h3>Seasons</h3>)
   │                     │                         ├── /api/frontend/anime/<num>/episodes → episodes
   │                     │                         └── /api/frontend/episode/<epId>/languages → embed_url (jpn/eng) → jwplayer file:'…master.m3u8' → #EXT-X-STREAM-INF:RESOLUTION
   └─ mpv ←──────────────┘
```

## Troubleshooting

- **Bridge not ready** → click again, `animechy-setup.sh` reruns; check `python3 -c "import requests,bs4,lxml"` and `mpv --version`
- **Blocked by cloudflare** → `pip install curl-impersonate` (bridge tries `curl_firefox135` fallback)
- **No streams** → toggles Sub/Dub automatically; try different episode; check `~/.cache/animechy/` m3u8
- **Panel not showing** → `omarchy plugin list --json | jq '.[] | select(.id=="tenzin.animechy")'` → `enabled:true`; `omarchy-shell shell rescanPlugins`; log out/in
- **Lint** → `qmllint BarWidget.qml Panel.qml` → 0

## Development

```bash
# Edit bridge, test without restarting shell
python3 ~/.config/omarchy/plugins/tenzin.animechy/bridge/animechy-bridge.py '{"cmd":"search","q":"naruto"}' | jq
# Edit Panel.qml, then
omarchy-shell shell rescanPlugins
# Check bar placement
cat ~/.config/omarchy/shell.json | jq '.bar.layout.center'
```

## Credits & License

- **Source:** [pystardust/ani-cli](https://github.com/pystardust/ani-cli) (GPL-3.0)
- **UI:** Forked from `tenzin.omamovie` bar-widget/Panel pattern
- **License:** **GPL-3.0**

See `LICENSE` (http://www.gnu.org/licenses/).
