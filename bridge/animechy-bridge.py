#!/usr/bin/env python3
"""
Animechy Bridge — Python JSON IPC for anidb.app scraping
Mimics ani-cli behavior without compilation.

Usage:
  python3 animechy-bridge.py '{"cmd":"search","q":"one piece"}'
  → {"ok":true,"items":[...]}

Commands:
  ping
  search   {q, page}
  details  {id}
  episodes {id}
  streams  {id, episode, mode}  # mode: sub|dub
  homepage {page, perPage}
  suggest  {q}
  raw_search (debug)

Caching: ~/.cache/animechy/*.json
Retries with curl-impersonate fallback if cloudflare blocks.

License: GPL-3.0 (derived from pystardust/ani-cli logic)
"""
import sys
import json
import re
import time
import hashlib
import subprocess
import os
from pathlib import Path
from urllib.parse import quote_plus, urlparse

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError as e:
    print(json.dumps({"ok": False, "error": f"Missing dependency: {e}. Install: pip3 install --user requests beautifulsoup4 lxml"}))
    sys.exit(1)

BASE = "https://anidb.app"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://anidb.app/",
}

CACHE_DIR = Path.home() / ".cache" / "animechy"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

session = requests.Session()
session.headers.update(HEADERS)

ALLOWED_COVER_HOSTS = {"cdn.xlsbox.com", "anidb.app", "cdn.anidb.app"}
COVER_PATH_RE = re.compile(r"\.(jpg|jpeg|png|webp)(\?.*)?$", re.IGNORECASE)

def _sanitize_cover_url(u: str) -> str:
    if not u or not isinstance(u, str):
        return ""
    u = u.strip()
    if u.startswith("//"):
        u = "https:" + u
    try:
        p = urlparse(u)
    except Exception:
        return ""
    if p.scheme != "https":
        return ""
    host = (p.hostname or "").lower()
    if host not in ALLOWED_COVER_HOSTS:
        return ""
    # reject userinfo tricks (user:pass@host) and non-standard ports
    if p.username or p.password:
        return ""
    if p.port not in (None, 443):
        return ""
    # must be an image path; reject query tricks
    if not COVER_PATH_RE.search(p.path or ""):
        return ""
    # reconstruct to avoid userinfo / port tricks
    return f"https://{host}{p.path or '/'}" + (f"?{p.query}" if p.query else "")

def log(msg):
    print(f"[bridge] {msg}", file=sys.stderr, flush=True)

def cache_path(key: str) -> Path:
    h = hashlib.sha1(key.encode()).hexdigest()[:16]
    safe = re.sub(r'[^a-zA-Z0-9_-]', '_', key)[:40]
    return CACHE_DIR / f"{safe}_{h}.json"

def cache_get(key: str, max_age: int = 3600):
    p = cache_path(key)
    if not p.exists():
        return None
    try:
        if (time.time() - p.stat().st_mtime) > max_age:
            return None
        return json.loads(p.read_text())
    except Exception:
        return None

def cache_set(key: str, data):
    try:
        p = cache_path(key)
        p.write_text(json.dumps(data))
    except Exception:
        pass

def str_arg(req, key, default=""):
    v = req.get(key)
    if v is None:
        return default
    return str(v)

def int_arg(req, key, default=0):
    try:
        return int(req.get(key, default))
    except Exception:
        return default

def fetch_with_fallback(url, timeout=12):
    """Try requests, fallback to curl binaries (curl-impersonate if present)."""
    try:
        r = session.get(url, timeout=timeout)
        # cloudflare check
        if "Just a moment" in r.text and "cloudflare" in r.text.lower():
            raise RuntimeError("Cloudflare challenge")
        if r.status_code == 403 and "cloudflare" in r.text.lower():
            raise RuntimeError("Blocked by cloudflare")
        r.raise_for_status()
        return r.text, r
    except Exception as e:
        # try curl fallbacks
        for prog in ["curl_firefox135", "curl_chrome136", "curl_chrome116", "curl_ff117", "curl", "wget"]:
            try:
                if prog == "wget":
                    cmd = ["wget", "-qO-", "--header", f"User-Agent: {HEADERS['User-Agent']}", url]
                else:
                    cmd = [prog, "-sL", "-A", HEADERS["User-Agent"], "--max-time", str(timeout), url]
                out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=timeout+2).decode("utf-8", errors="ignore")
                if out and "Just a moment" not in out:
                    return out, None
            except Exception:
                continue
        # re-raise original
        raise e

def fetch_json(url, timeout=12):
    try:
        r = session.get(url, timeout=timeout)
        if "Just a moment" in r.text:
            raise RuntimeError("Cloudflare challenge")
        r.raise_for_status()
        return r.json(), r
    except Exception as e:
        # fallback via curl
        for prog in ["curl_firefox135", "curl_chrome136", "curl"]:
            try:
                cmd = [prog, "-sL", "-A", HEADERS["User-Agent"], "--max-time", str(timeout), url]
                out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=timeout+2).decode()
                j = json.loads(out)
                return j, None
            except Exception:
                continue
        raise e

# ---------- SEARCH ----------
def do_search(q: str, page: int = 1):
    q = q.strip()
    if not q:
        return []
    # pagination not yet supported by anidb.app ? but we keep param
    # cache TTL increased to 24h for faster repeated searches
    cache_key = f"search:{q.lower()}:{page}"
    cached = cache_get(cache_key, max_age=86400)
    if cached is not None:
        return cached

    url = f"{BASE}/browse?q={quote_plus(q)}"
    # we don't use page param yet — anidb.app uses query only; pagination via ?page= ?
    # try with page if >1
    if page > 1:
        url = f"{BASE}/browse?q={quote_plus(q)}&page={page}"

    html, _ = fetch_with_fallback(url)
    # mimic ani-cli: split on <a href
    html_spaced = html.replace("\n", " ")
    chunks = html_spaced.split("<a href")
    items = []
    seen = set()
    for chunk in chunks:
        # reconstruct: looking for anime/[slug] and alt=
        # Use regex like ani-cli: .*anime/([a-z0-9-]+-[0-9]+)".*alt="([^"]+)".*
        m = re.search(r'anime/([a-z0-9-]+-[0-9]+)".*?alt="([^"]+)"', chunk, re.IGNORECASE)
        if not m:
            continue
        aid = m.group(1)
        title = m.group(2)
        title = title.replace("&#039;", "'").replace("&quot;", '"').replace("&amp;", "&").strip()
        if aid in seen:
            continue
        seen.add(aid)
        # Try to extract cover, year, rating from chunk
        # Look for data-src or src for cover
        cover = ""
        cm = re.search(r'(?:data-src|src)="([^"]+(?:cdn\.xlsbox\.com|anidb\.app)[^"]+\.(?:jpg|png|webp))"', chunk)
        if cm:
            cover = cm.group(1)
            if cover.startswith("//"):
                cover = "https:" + cover
        # also try poster url pattern
        if not cover:
            # broader search for poster
            cm2 = re.search(r'https://cdn\.xlsbox\.com[^"]+\.(?:jpg|png|webp)', chunk)
            if cm2:
                cover = cm2.group(0)
        # year: look for browse?year=#### or 4-digit near
        year = ""
        ym = re.search(r'/browse\?[^"]*year=(\d{4})', chunk)
        if ym:
            year = ym.group(1)
        else:
            ym2 = re.search(r'\b(19|20)\d{2}\b', chunk[:500])
            if ym2:
                year = ym2.group(0)
        # rating: look for star badge like 8.4
        rating = None
        rm = re.search(r'(\d+\.\d).*?★|★.*?(\d+\.\d)', chunk)
        cover = _sanitize_cover_url(cover)
        # fallback: not critical
        items.append({
            "id": aid,
            "title": title,
            "cover": cover,
            "year": year,
            "rating": rating,
            "stype": 1,
        })
    # fallback via BeautifulSoup if regex found nothing (maybe html changed)
    if not items:
        try:
            soup = BeautifulSoup(html, "lxml")
            for a in soup.select('a[href^="/anime/"]'):
                href = a.get("href", "")
                m = re.search(r'/anime/([a-z0-9-]+-[0-9]+)', href)
                if not m:
                    continue
                aid = m.group(1)
                if aid in seen:
                    continue
                seen.add(aid)
                title = a.get("alt") or a.get("title") or a.get_text(strip=True) or ""
                title = title.replace("&#039;", "'").replace("&quot;", '"').strip()
                if not title:
                    continue
                cover = ""
                img = a.find("img")
                if img:
                    cover = img.get("data-src") or img.get("src") or ""
                    cover = _sanitize_cover_url(cover)
                items.append({"id": aid, "title": title, "cover": cover, "year": "", "rating": None, "stype": 1})
        except Exception:
            pass

    # filter trailing trailers? ani-cli doesn't filter search trailers explicitly but we can
    # keep all but deprioritize trailers
    def is_trailer(t):
        lt = t.lower()
        return lt.startswith("trailer-") or lt.startswith("trailer ") or lt.startswith("trailer:")
    items = [i for i in items if not is_trailer(i["title"])] + [i for i in items if is_trailer(i["title"])]
    # sort by relevance: exact match > contains > others, then by title length
    ql = q.lower()
    def score(it):
        tl = it["title"].lower()
        if tl == ql:
            return 0
        if ql in tl:
            return 1
        return 2
    items.sort(key=lambda x: (score(x), len(x["title"])))
    items = items[:30]
    cache_set(cache_key, items)
    return items

# ---------- DETAILS ----------
def do_details(aid: str):
    aid = aid.strip()
    if not aid:
        raise ValueError("missing id")
    cache_key = f"details:{aid}"
    cached = cache_get(cache_key, max_age=604800)
    if cached is not None:
        return cached

    url = f"{BASE}/anime/{aid}"
    html, _ = fetch_with_fallback(url)
    soup = BeautifulSoup(html, "lxml")

    # title
    title = ""
    h1 = soup.find("h1")
    if h1:
        title = h1.get_text(strip=True)
    if not title:
        ttag = soup.find("title")
        if ttag:
            title = ttag.get_text(strip=True).split("—")[0].split("-")[0].strip()

    # description from meta or first paragraph
    desc = ""
    meta = soup.find("meta", {"name": "description"})
    if meta and meta.get("content"):
        desc = meta["content"].strip()
    if not desc:
        # try find p with muted description
        p = soup.find("p", class_=re.compile(".*muted.*"))
        if p:
            desc = p.get_text(strip=True)

    # mal_id
    mal_id = ""
    m = re.search(r'https://myanimelist\.net/anime/(\d+)', html)
    if m:
        mal_id = m.group(1)

    # year
    year = ""
    ym = re.search(r'/browse\?season=\w+&year=(\d{4})', html)
    if ym:
        year = ym.group(1)
    else:
        ym2 = soup.find("a", href=re.compile(r"/browse\?season="))
        if ym2 and ym2.get("href"):
            mm = re.search(r'year=(\d{4})', ym2["href"])
            if mm:
                year = mm.group(1)

    # genres
    genres = []
    for a in soup.select('a[href^="/genres/"]'):
        g = a.get_text(strip=True)
        if g:
            genres.append(g)
    genre_str = ", ".join(genres[:6])

    # duration
    duration = ""
    dm = re.search(r'(\d+m)', html)
    if dm:
        duration = dm.group(1)

    # rating
    rating = ""
    rm = soup.find(string=re.compile(r'★'))
    if rm:
        # find nearby number
        parent_text = rm.parent.get_text() if rm.parent else str(rm)
        rnum = re.search(r'(\d+\.\d)', parent_text)
        if rnum:
            rating = rnum.group(1)

    # cover
    cover = ""
    # og:image
    og = soup.find("meta", property="og:image")
    if og and og.get("content"):
        cover = og["content"]
    if not cover:
        img = soup.find("img", src=re.compile(r'cdn\.xlsbox\.com'))
        if img and img.get("src"):
            cover = img["src"]
            if cover.startswith("//"):
                cover = "https:" + cover
    # fallback: from background poster
    if not cover:
        mcover = re.search(r'https://cdn\.xlsbox\.com[^"\']+\.(?:jpg|png|webp)', html)
        if mcover:
            cover = mcover.group(0)
    cover = _sanitize_cover_url(cover)

    # seasons: look for Seasons header
    seasons = []
    # find h3 with Seasons
    seasons_header = None
    for h in soup.find_all(["h3", "h2"]):
        if "Seasons" in h.get_text():
            seasons_header = h
            break
    if seasons_header:
        # container is parent card
        card = seasons_header.find_parent(class_=re.compile("bg-card|rounded"))
        if card is None:
            card = seasons_header.parent
            # climb up a bit
            for _ in range(3):
                if card and card.parent:
                    card = card.parent
                    if card.find_all("a", href=re.compile(r'/anime/')):
                        break
        if card:
            for a in card.select('a[href^="/anime/"], a[href^="https://anidb.app/anime/"]'):
                href = a.get("href", "")
                mm = re.search(r'/anime/([a-z0-9-]+-[0-9]+)', href)
                if not mm:
                    continue
                sid = mm.group(1)
                # title from title attr or inner
                stitle = a.get("title") or a.get_text(strip=True) or sid
                # avoid dedup current id but keep it? include
                if sid not in [s["id"] for s in seasons]:
                    seasons.append({"id": sid, "title": stitle})
                if len(seasons) >= 20:
                    break
    # fallback regex if bs4 failed
    if not seasons and "Seasons" in html:
        # extract between Seasons and next h3/divider
        m_sec = re.search(r'Seasons.*?<div class="flex gap-3 overflow-x-auto(.*?)</div>\s*</div>', html, re.S | re.I)
        if m_sec:
            sec_html = m_sec.group(1)
            for mm in re.finditer(r'anime/([a-z0-9-]+-[0-9]+)"[^>]*title="([^"]+)"', sec_html):
                sid, stitle = mm.group(1), mm.group(2)
                if sid not in [s["id"] for s in seasons]:
                    seasons.append({"id": sid, "title": stitle.replace("&#039;", "'")})
        else:
            # broader fallback
            for mm in re.finditer(r'href="[^"]*?/anime/([a-z0-9-]+-[0-9]+)"[^>]*title="([^"]+)"', html):
                # only keep if near Seasons
                pass

    # alternative: if seasons still empty, try generic anime links near Seasons text
    if not seasons:
        try:
            idx = html.find("Seasons")
            if idx != -1:
                snippet = html[max(0, idx-0): idx+8000]
                for mm in re.finditer(r'/anime/([a-z0-9-]+-[0-9]+)', snippet):
                    sid = mm.group(1)
                    # find title near
                    ctx = snippet[max(0, mm.start()-500): mm.end()+500]
                    tm = re.search(r'title="([^"]+)"', ctx)
                    stitle = tm.group(1).replace("&#039;", "'") if tm else sid
                    if sid not in [s["id"] for s in seasons]:
                        seasons.append({"id": sid, "title": stitle})
                    if len(seasons) > 12:
                        break
        except Exception:
            pass

    # Build value object compatible with Panel expectations
    value = {
        "id": aid,
        "title": title,
        "intro": desc[:300] if desc else "",
        "description": desc,
        "year": year,
        "genre": genre_str,
        "duration": duration,
        "imdbRatingValue": rating,
        "language": "",
        "mal_id": mal_id,
        "cover": {"url": cover} if cover else "",
        "coverUrl": cover,
        "seasons": {"seasons": [{"se": i+1, "id": s["id"], "title": s["title"]} for i, s in enumerate(seasons)]} if seasons else {"seasons": []},
        "seasons_raw": seasons,
        "subjects": seasons,
        "resourceDetectors": [],
    }
    # also provide seasons flat for simple use
    value["seasons_list"] = seasons

    cache_set(cache_key, value)
    return value

# ---------- EPISODES ----------
def do_episodes(aid: str):
    aid = aid.strip()
    if not aid:
        raise ValueError("missing id")
    # extract numeric id
    num_id = aid.split("-")[-1]
    if not num_id.isdigit():
        # try to extract trailing digits
        m = re.search(r'-(\d+)$', aid)
        if m:
            num_id = m.group(1)
        else:
            raise ValueError(f"cannot extract numeric id from {aid}")
    cache_key = f"episodes:{num_id}"
    cached = cache_get(cache_key, max_age=86400)
    if cached is not None:
        return cached

    url = f"{BASE}/api/frontend/anime/{num_id}/episodes"
    data, _ = fetch_json(url)
    # handle both shapes: {"episodes":[...]} or [...]
    episodes_raw = data.get("episodes") if isinstance(data, dict) and "episodes" in data else data
    if isinstance(episodes_raw, dict):
        # maybe data itself is dict with episodes key wrongly nested?
        episodes_raw = episodes_raw.get("episodes", [])
    if not isinstance(episodes_raw, list):
        episodes_raw = []

    items = []
    for ep in episodes_raw:
        if not isinstance(ep, dict):
            continue
        eid = ep.get("id")
        number = ep.get("number")
        if eid is None or number is None:
            continue
        # filter filler? keep but mark
        items.append({
            "id": str(eid),
            "number": str(number),
            "number2": ep.get("number2"),
            "filler": ep.get("filler", False),
            "title": ep.get("title", "") or f"Episode {number}",
        })
    # sort by number numeric
    try:
        items.sort(key=lambda x: float(x["number"]))
    except Exception:
        items.sort(key=lambda x: x["number"])

    cache_set(cache_key, items)
    return items

# ---------- STREAMS ----------
def do_streams(aid: str, episode: str, mode: str = "sub"):
    aid = aid.strip()
    episode = str(episode).strip()
    mode = mode.strip().lower()
    if not aid or not episode:
        raise ValueError("missing id or episode")
    lang = "jpn" if mode in ("sub", "jpn", "ja", "japanese") else "eng"

    # find ep_id
    episodes = do_episodes(aid)
    ep_id = None
    for ep in episodes:
        if str(ep.get("number")) == str(episode):
            ep_id = ep.get("id")
            break
    if not ep_id:
        # try float compare
        try:
            ep_id = next((e["id"] for e in episodes if float(e["number"]) == float(episode)), None)
        except Exception:
            pass
    if not ep_id:
        raise ValueError(f"Episode {episode} not found for {aid} (available: {[e['number'] for e in episodes[:5]]})")

    cache_key = f"streams:{ep_id}:{lang}"
    cached = cache_get(cache_key, max_age=7200)
    if cached is not None:
        return cached

    # languages api
    url = f"{BASE}/api/frontend/episode/{ep_id}/languages"
    data, _ = fetch_json(url)
    # data shape: {"languages":[...]}
    langs = data.get("languages") if isinstance(data, dict) else data
    if isinstance(langs, dict):
        langs = langs.get("languages", [])
    if not isinstance(langs, list):
        langs = []

    embed_url = None
    for item in langs:
        if not isinstance(item, dict):
            continue
        code = item.get("code", "").lower()
        if code == lang:
            embed_url = item.get("embed_url", "").replace("\\/", "/")
            break
        # fallback: match jpn/eng
        if lang == "jpn" and code in ("jpn", "ja", "jpn_sub"):
            embed_url = item.get("embed_url", "").replace("\\/", "/")
            break
        if lang == "eng" and code in ("eng", "en", "dub"):
            embed_url = item.get("embed_url", "").replace("\\/", "/")
            break
    if not embed_url:
        # try any
        for item in langs:
            eu = item.get("embed_url", "").replace("\\/", "/")
            if eu:
                embed_url = eu
                break
    if not embed_url:
        raise ValueError(f"No embed url for lang {lang} ep {episode}")

    # fetch embed page
    embed_html, _ = fetch_with_fallback(embed_url)
    # extract master m3u8
    # ani-cli: sed -nE "s|.*file: '([^']*)'.*|\1|p"
    m = re.search(r"file:\s*'([^']+\.m3u8)'", embed_html)
    if not m:
        # try double quotes
        m = re.search(r'file:\s*"([^"]+\.m3u8)"', embed_html)
    if not m:
        # try generic m3u8
        m = re.search(r'(https?://[^"\']+\.m3u8)', embed_html)
    if not m:
        raise ValueError("No m3u8 found in embed page")
    master_url = m.group(1)

    # fetch master
    master_text, _ = fetch_with_fallback(master_url)
    # parse qualities — like ani-cli but more robust
    streams = []
    # split on STREAM-INF
    # Use regex to capture resolution and url
    # Example:
    # #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1261457,RESOLUTION=1920x1080...
    # https://...
    lines = master_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("#EXT-X-STREAM-INF"):
            # parse params
            res_m = re.search(r'RESOLUTION=(\d+)x(\d+)', line)
            bw_m = re.search(r'BANDWIDTH=(\d+)', line)
            height = int(res_m.group(2)) if res_m else 0
            width = int(res_m.group(1)) if res_m else 0
            bw = int(bw_m.group(1)) if bw_m else 0
            # next line is url
            url_line = ""
            if i+1 < len(lines):
                nxt = lines[i+1].strip()
                if nxt and not nxt.startswith("#"):
                    url_line = nxt
                    i += 1
            # Skip iframe streams
            if "I-FRAME" in line:
                i += 1
                continue
            if url_line:
                # quality label like 1080p
                qual = f"{height}p" if height else "unknown"
                # handle relative url
                if url_line.startswith("/"):
                    # resolve against master_url base
                    from urllib.parse import urljoin
                    url_line = urljoin(master_url, url_line)
                streams.append({
                    "resolution": height,
                    "width": width,
                    "bandwidth": bw,
                    "quality": qual,
                    "url": url_line,
                    "resourceLink": url_line,
                    "link": url_line,
                    "resourceId": ep_id,
                    "size": bw,  # for compatibility
                    "codecName": "h264",
                })
        i += 1

    # Fallback: if no streams parsed but master has direct urls
    if not streams:
        # try find all https m3u8 lines
        for line in lines:
            line = line.strip()
            if line.startswith("http") and ".m3u8" in line:
                if "iframes" in line.lower():
                    continue
                streams.append({
                    "resolution": 0,
                    "quality": "auto",
                    "url": line,
                    "resourceLink": line,
                    "link": line,
                    "resourceId": ep_id,
                })

    # Sort descending by resolution/bandwidth like ani-cli: sort -g -r
    streams.sort(key=lambda x: (x.get("resolution", 0), x.get("bandwidth", 0)), reverse=True)

    # If still empty, return master itself as one stream
    if not streams and master_url:
        streams = [{
            "resolution": 0,
            "quality": "auto",
            "url": master_url,
            "resourceLink": master_url,
            "link": master_url,
            "resourceId": ep_id,
        }]

    cache_set(cache_key, streams)
    return streams

# ---------- HOMEPAGE ----------
def do_homepage(page: int = 1, per_page: int = 24, tab: str = "2"):
    cache_key = f"homepage:{page}:{per_page}"
    cached = cache_get(cache_key, max_age=3600)
    if cached is not None:
        return cached
    # Trending via /browse?sort=order_popular
    url = f"{BASE}/browse?sort=order_popular&page={page}"
    html, _ = fetch_with_fallback(url)
    html_spaced = html.replace("\n", " ")
    chunks = html_spaced.split("<a href")
    items = []
    seen = set()
    for chunk in chunks:
        m = re.search(r'anime/([a-z0-9-]+-[0-9]+)".*?alt="([^"]+)"', chunk, re.IGNORECASE)
        if not m:
            continue
        aid = m.group(1)
        title = m.group(2).replace("&#039;", "'").replace("&quot;", '"').strip()
        if aid in seen:
            continue
        seen.add(aid)
        cover = ""
        cm = re.search(r'(?:data-src|src)="([^"]+(?:cdn\.xlsbox\.com|anidb\.app)[^"]+\.(?:jpg|png|webp))"', chunk)
        if cm:
            cover = cm.group(1)
        if not cover:
            cm2 = re.search(r'https://cdn\.xlsbox\.com[^"]+\.(?:jpg|png|webp)', chunk)
            if cm2:
                cover = cm2.group(0)
        cover = _sanitize_cover_url(cover)
        items.append({"id": aid, "title": title, "cover": cover, "year": "", "rating": None})
        if len(items) >= per_page * 2:
            break
    # dedupe and shuffle-like: take first per_page
    items = items[:per_page]
    # fallback if empty — use search for popular terms
    if not items:
        try:
            items = do_search("a", 1)[:per_page]
        except Exception:
            pass
    cache_set(cache_key, items)
    return items

def do_suggest(q: str):
    q = q.strip()
    if len(q) < 2:
        return []
    # reuse search cache: search and take titles
    try:
        items = do_search(q, 1)
        return [{"name": it["title"], "id": it["id"], "cover": it["cover"]} for it in items[:8]]
    except Exception:
        return []

# ---------- MAIN DISPATCH ----------
def run(cmd: str, req: dict):
    if cmd == "ping":
        return {"pong": True}
    elif cmd == "search":
        q = str_arg(req, "q")
        page = int_arg(req, "page", 1) or 1
        items = do_search(q, page)
        return {"items": items}
    elif cmd == "details":
        aid = str_arg(req, "id")
        if not aid:
            raise ValueError("missing id")
        val = do_details(aid)
        return {"value": val}
    elif cmd == "episodes":
        aid = str_arg(req, "id")
        items = do_episodes(aid)
        return {"items": items, "value": {"episodes": items}}
    elif cmd == "streams" or cmd == "resources":
        aid = str_arg(req, "id")
        episode = str_arg(req, "episode", str_arg(req, "ep", "1"))
        mode = str_arg(req, "mode", str_arg(req, "lang", "sub"))
        # also accept season/episode params like OmaMovie
        if not episode or episode == "0":
            episode = str(int_arg(req, "episode", 1) or 1)
            if episode == "0":
                episode = "1"
        streams = do_streams(aid, episode, mode)
        return {"items": streams, "value": {"list": streams}}
    elif cmd == "homepage" or cmd == "home" or cmd == "discover":
        page = int_arg(req, "page", 1) or 1
        per_page = int_arg(req, "perPage", int_arg(req, "per_page", 24))
        items = do_homepage(page, per_page)
        return {"items": items, "rawCount": len(items)}
    elif cmd == "suggest":
        q = str_arg(req, "q")
        sugg = do_suggest(q)
        return {"suggestions": sugg}
    elif cmd == "captions":
        # not supported for anidb — return empty
        return {"options": []}
    else:
        raise ValueError(f"unknown command: {cmd}")

def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    # also allow stdin if no arg
    if raw == "{}" and not sys.stdin.isatty():
        try:
            raw = sys.stdin.read().strip() or "{}"
        except Exception:
            pass
    try:
        req = json.loads(raw)
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"bad request json: {e}", "raw": raw[:200]}))
        return

    cmd = req.get("cmd", "")
    if not cmd:
        # try to infer from keys
        if "q" in req:
            cmd = "search"
        else:
            print(json.dumps({"ok": False, "error": "missing cmd"}))
            return

    try:
        data = run(cmd, req)
        resp = {"ok": True}
        resp.update(data)
        print(json.dumps(resp, ensure_ascii=False))
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        print(json.dumps({"ok": False, "error": str(e), "trace": tb}, ensure_ascii=False), file=sys.stdout)
        log(f"error {cmd}: {e}\n{tb}")

if __name__ == "__main__":
    main()
