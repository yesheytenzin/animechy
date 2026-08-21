import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root
    readonly property string bridge: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/animechy/animechy-bridge.py"
    readonly property string bridgeWrapper: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/animechy/animechy-bridge"
    // ---------------- state ----------------
    property string view: "home"
    // home | grid | details
    property var details: null
    property string currentId: ""
    property string currentTitle: ""
    property var seasons: [] // list of {id, title}
    property int curSeasonIdx: 0
    property var episodes: [] // list of {id, number}
    property string curEp: "1"
    property string mode: "sub" // sub | dub
    property var streams: []
    property int selStream: -1
    property bool busy: false
    property string busyLabel: ""
    property string statusText: "Search anime — try \"One Piece\" or pick a genre"
    property string query: ""
    property var results: []
    property bool playing: false
    property bool homeLoading: false
    property int suggestGen: 0
    property int searchGen: 0
    property int detailGen: 0
    property int resourceGen: 0
    property int episodeGen: 0
    property var searchHistory: [] // recent searches [ "one piece", "naruto" ]
    readonly property int maxHistory: 10
    property string selectedGenre: ""
    property int genreGen: 0
    Component.onCompleted: loadHistory()
    property var genreCache: ({
    })
    property var genreCacheTime: ({
    })
    readonly property var genres: ["All", "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Romance", "Slice of Life", "Sci-Fi", "Mystery", "Sports", "Supernatural"]
    // ---------------- bridge IPC (serialized) ----------------
    property var pending: []
    property var cbChain: null
    // local helper for episode count
    property int _episodeCount: 0

    function sanitize(s) {
        if (!s)
            return "";

        return String(s).replace(/<[^>]*>/g, "");
    }

    function sanitizeDetails(d) {
        if (!d)
            return null;

        var out = {
        };
        for (var k in d) {
            var v = d[k];
            if (typeof v === "string")
                out[k] = root.sanitize(v);
            else if (Array.isArray(v))
                out[k] = v.map(function(x) {
                return typeof x === "string" ? root.sanitize(x) : x;
            });
            else
                out[k] = v;
        }
        return out;
    }

    function sanitizeStreams(arr) {
        if (!Array.isArray(arr))
            return [];

        return arr.map(function(s) {
            var out = {
            };
            for (var k in s) {
                var v = s[k];
                if (typeof v === "string")
                    out[k] = root.sanitize(v);
                else
                    out[k] = v;
            }
            return out;
        });
    }

    function request(cmd, params, cb) {
        params = params || {
        };
        if (bridgeProc.running) {
            root.pending.push({
                "cmd": cmd,
                "params": params,
                "cb": cb
            });
            return ;
        }
        root._start(cmd, params, cb);
    }

    function _bridgeCmd(json) {
        // isolated venv wrapper (setup.sh creates $XDG_CACHE_HOME/animechy/animechy-bridge)
        // fall back to python3+bridge.py if wrapper not yet present (very early boot)
        var w = root.bridgeWrapper;
        var b = root.bridge;
        // Use bash to try wrapper first; avoids QML file-existence check
        return ["/bin/bash", "-c", "if [[ -x \"" + w + "\" ]]; then exec \"" + w + "\" \"$1\"; else exec python3 \"" + b + "\" \"$1\"; fi", "_", json];
    }
    function _start(cmd, params, cb) {
        bridgeProc.collected = "";
        root.cbChain = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = cmd;
        bridgeProc.command = root._bridgeCmd(JSON.stringify(req));
        bridgeProc.running = true;
    }

    // ---------------- helpers ----------------
    function _isAllowedCoverUrl(u) {
        if (!u || typeof u !== "string") return false;
        u = u.trim();
        if (u.startsWith("//")) u = "https:" + u;
        var m = u.match(/^https:\/\/([^\/]+)(\/.*)?$/);
        if (!m) return false;
        var host = m[1].toLowerCase();
        if (host !== "cdn.xlsbox.com" && host !== "anidb.app" && host !== "cdn.anidb.app") return false;
        if (!/\.(jpg|jpeg|png|webp)(\?.*)?$/i.test(m[2] || "")) return false;
        return true;
    }
    function _sanitizeCoverUrl(u) {
        if (!_isAllowedCoverUrl(u)) return "";
        if (u.trim().startsWith("//")) return "https:" + u.trim();
        return u.trim();
    }
    function coverUrlOf(obj) {
        if (!obj) return "";
        var raw = "";
        var c = obj.cover;
        if (c && typeof c === "object") raw = c.url || "";
        else if (typeof c === "string") raw = c;
        else raw = obj.coverUrl || "";
        return _sanitizeCoverUrl(raw);
    }

    // ---------------- actions ----------------
    function doSearch() {
        var q = searchField.text.trim();
        if (!q)
            return ;

        root.query = q;
        root.selectedGenre = "";
        root.busy = true;
        root.busyLabel = "Searching …";
        root.statusText = "";
        root.searchGen++;
        root.genreGen++;
        var gen = root.searchGen;
        request("search", {
            "q": q,
            "page": 1
        }, function(resp, code) {
            if (gen !== root.searchGen)
                return ;

            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Search failed";
                return ;
            }
            root.results = resp.items || [];
            resultModel.clear();
            for (var i = 0; i < root.results.length; i++) {
                var r = root.results[i];
                resultModel.append({
                    "id": root.sanitize(r.id),
                    "title": root.sanitize(r.title),
                    "year": root.sanitize(r.year || ""),
                    "rating": root.sanitize(r.rating ? String(r.rating) : "-"),
                    "cover": root.sanitize(r.cover || ""),
                    "coverPath": root.sanitize(r.cover || ""),
                    "duration": root.sanitize(r.duration || "")
                });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " results for “" + q + "”";
            addToHistory(q);
        });
    }

    function debounceSuggest() {
        suggestTimer.restart();
    }

    // ---------- search history (in-memory + file via Process) ----------
    function loadHistory() {
        // use $HOME so fresh installs with different usernames work; not watched by plugin watcher
        historyLoadProc.command = ["bash", "-c", "cat \"$HOME/.local/state/animechy/hists\" 2>/dev/null || cat \"${XDG_STATE_HOME:-$HOME/.local/state}/animechy/hists\" 2>/dev/null || true"];
        historyLoadProc.running = true;
    }

    function saveHistory() {
        var payload = JSON.stringify(root.searchHistory);
        var b64 = Qt.btoa(payload);
        historySaveProc.command = ["bash", "-c", "mkdir -p \"$HOME/.local/state/animechy\" && echo '" + b64 + "' | base64 -d > \"$HOME/.local/state/animechy/hists\""];
        historySaveProc.running = true;
    }

    function addToHistory(q) {
        if (!q) return;
        q = String(q).trim();
        if (!q) return;
        var idx = root.searchHistory.indexOf(q);
        if (idx >= 0)
            root.searchHistory.splice(idx, 1);
        root.searchHistory.unshift(q);
        if (root.searchHistory.length > root.maxHistory)
            root.searchHistory = root.searchHistory.slice(0, root.maxHistory);
        // trigger binding update (assign new array reference)
        root.searchHistory = root.searchHistory.slice();
        saveHistory();
    }

    // ----------------------------------------

    function openDetails(idx, fromHome) {
        var model = fromHome ? homeModel : resultModel;
        if (idx < 0 || idx >= model.count)
            return ;

        var it = model.get(idx);
        root.currentId = root.sanitize(it.id);
        root.currentTitle = root.sanitize(it.title);
        root.details = null;
        root.seasons = [];
        root.episodes = [];
        root.streams = [];
        root.selStream = -1;
        root.curEp = "1";
        root.detailGen++;
        var gen = root.detailGen;
        root.busy = true;
        root.busyLabel = "Loading details & episodes …";
        root.statusText = "Loading “" + it.title + "” …";
        root.view = "details";
        detailPoster.source = _sanitizeCoverUrl(it.cover || "");
        // fetch details and episodes in parallel — episodes start immediately
        root.loadEpisodes(it.id, gen);
        request("details", {
            "id": it.id
        }, function(resp, code) {
            if (gen !== root.detailGen) return ;
            if (!resp || !resp.ok) {
                root.busy = false;
                root.statusText = (resp && resp.error) || "Details failed";
                return ;
            }
            root.details = root.sanitizeDetails(resp.value);
            var rawSeasons = (resp.value && resp.value.seasons_list) || (resp.value && resp.value.seasons && resp.value.seasons.seasons) || [];
            var normSeasons = [];
            for (var s = 0; s < rawSeasons.length; s++) {
                var ss = rawSeasons[s];
                if (ss.id && ss.title)
                    normSeasons.push({ "id": root.sanitize(ss.id), "title": root.sanitize(ss.title) });
                else if (ss.id)
                    normSeasons.push({ "id": root.sanitize(ss.id), "title": root.sanitize(ss.id) });
            }
            root.seasons = normSeasons;
            root.curSeasonIdx = 0;
            var cover = root.coverUrlOf(root.details);
            if (cover)
                detailPoster.source = cover;
            // if episodes not yet loaded, fetch them; otherwise keep already-loaded episodes
            // (speculative loadEpisodes already started in parallel)
            if (root.episodes.length === 0) {
                root.loadEpisodes(root.currentId, gen);
            }
        });
    }

    function loadEpisodes(aid, gen) {
        root.episodeGen++;
        var eGen = root.episodeGen;
        root.busy = true;
        root.busyLabel = "Loading episodes …";
        request("episodes", {
            "id": aid
        }, function(resp, code) {
            if (eGen !== root.episodeGen)
                return ;

            if (gen !== undefined && gen !== root.detailGen)
                return ;

            if (!resp || !resp.ok) {
                root.busy = false;
                root.statusText = (resp && resp.error) || "No episodes";
                return ;
            }
            var eps = resp.items || [];
            root.episodes = eps;
            // expose to QML for repeater needing count
            root._episodeCount = eps.length;
            // default episode
            if (eps.length > 0) {
                root.curEp = eps[0].number;
                root.statusText = eps.length + " episodes — pick one";
                root.loadStreams(aid, eps[0].number, root.mode);
            } else {
                root.busy = false;
                root.statusText = "No episodes found";
            }
        });
    }

    // helper to reload episodes when season changed
    function selectSeason(idx) {
        if (idx < 0 || idx >= root.seasons.length)
            return ;

        root.curSeasonIdx = idx;
        var s = root.seasons[idx];
        root.currentId = s.id;
        root.currentTitle = s.title;
        root.details = null;
        root.episodes = [];
        root.streams = [];
        root.selStream = -1;
        root.busy = true;
        root.busyLabel = "Loading season …";
        root.detailGen++;
        var gen = root.detailGen;
        request("details", {
            "id": s.id
        }, function(resp) {
            if (gen !== root.detailGen)
                return ;

            if (resp && resp.ok) {
                root.details = root.sanitizeDetails(resp.value);
                var cover = root.coverUrlOf(root.details);
                if (cover)
                    detailPoster.source = cover;

            }
            // load episodes for this season id
            root.loadEpisodes(s.id, gen);
        });
    }

    function loadStreams(aid, ep, mode, _fallbackTried) {
        root.busy = true;
        root.busyLabel = "Loading streams …";
        streamsProc.gen++;
        var gen = streamsProc.gen;
        var effMode = mode || root.mode;
        var req = { cmd: "streams", id: aid, episode: String(ep), mode: effMode };
        streamsProc.collected = "";
        streamsProc.cbChain = function(resp, code) {
            if (gen !== streamsProc.gen) return;
            var items = (resp && resp.ok && resp.items) ? resp.items : [];
            if (items.length === 0 && !_fallbackTried) {
                var other = (effMode === "sub") ? "dub" : "sub";
                root.busyLabel = "No " + effMode + " streams — trying " + other + " …";
                loadStreams(aid, ep, other, true);
                return;
            }
            root.busy = false;
            root.streams = root.sanitizeStreams(items);
            root.selStream = root.streams.length > 0 ? 0 : -1;
            if (root.streams.length === 0) {
                root.statusText = "No streams for E" + ep + " (" + effMode + ")" + (_fallbackTried ? " — tried sub & dub" : "");
            } else {
                if (_fallbackTried && effMode !== (mode || root.mode)) {
                    root.mode = effMode;
                    root.statusText = root.streams.length + " streams (" + effMode + ") — pick quality & Play (auto-switched)";
                } else {
                    root.statusText = root.streams.length + " streams — pick quality & Play";
                }
                root.curEp = String(ep);
            }
        };
        streamsProc.command = root._bridgeCmd(JSON.stringify(req));
        streamsProc.running = true;
    }

    function selectStream(i) {
        root.selStream = i;
    }

    function playExternal() {
        if (root.selStream < 0 || root.streams.length === 0)
            return ;

        var s = root.streams[root.selStream];
        var link = s.resourceLink || s.link || s.url || "";
        if (!link) {
            root.statusText = "Stream has no URL";
            return ;
        }
        // launch mpv immediately
        root._launch(["mpv", "--force-window=immediate", "--no-terminal", "--cache=yes", "--demuxer-max-bytes=50M"], link);
    }

    function _launch(args, link) {
        args.push(link);
        mpvProc.command = args;
        mpvProc.running = true;
        root.playing = true;
        root.statusText = "Playing in mpv • close player to stop";
        Qt.callLater(function() {
            root.close();
        });
    }

    function prefetchDetails(id) {
        if (!id || bridgeProc.running || root.pending.length > 0 || prefetchProc.running)
            return ;

        var req = JSON.stringify({
            "cmd": "details",
            "id": id
        });
        prefetchProc.collected = "";
        prefetchProc.command = root._bridgeCmd(req);
        prefetchProc.running = true;
    }

    function loadHome(force) {
        if (root.homeLoading)
            return ;

        if (!force && homeModel.count > 0) {
            root.view = "home";
            return ;
        }
        root.homeLoading = true;
        root.busy = true;
        root.busyLabel = "Loading home …";
        request("homepage", {
            "page": 1,
            "perPage": 24
        }, function(resp) {
            root.homeLoading = false;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Could not load home";
                root.view = "home";
                return ;
            }
            var items = resp.items || [];
            // shuffle for variety
            for (var i = items.length - 1; i > 0; i--) {
                var j = Math.floor(Math.random() * (i + 1));
                var tmp = items[i];
                items[i] = items[j];
                items[j] = tmp;
            }
            homeModel.clear();
            for (var k = 0; k < items.length && k < 24; k++) {
                var r = items[k];
                homeModel.append({
                    "id": root.sanitize(r.id),
                    "title": root.sanitize(r.title),
                    "year": root.sanitize(r.year || ""),
                    "rating": root.sanitize(r.rating ? String(r.rating) : "-"),
                    "cover": root.sanitize(r.cover || ""),
                    "coverPath": root.sanitize(r.cover || ""),
                    "duration": root.sanitize(r.duration || "")
                });
            }
            root.view = "home";
            root.statusText = homeModel.count ? "Discover • " + homeModel.count + " titles" : "Search anime above";
        });
    }

    function goHome() {
        if (homeModel.count === 0)
            root.loadHome(false);
        else
            root.view = "home";
        root.selectedGenre = "";
        if (root.view === "home" && homeModel.count)
            root.statusText = "Discover • " + homeModel.count + " titles";
        else
            root.statusText = "Search anime — try \"One Piece\" or pick a genre";
    }

    function searchByGenre(genre, force) {
        if (genre === "All" || genre === "") {
            root.selectedGenre = "";
            root.loadHome(true);
            return ;
        }
        root.selectedGenre = genre;
        var now = Date.now();
        var cached = root.genreCache[genre];
        var cachedAt = root.genreCacheTime[genre] || 0;
        var fresh = cached && (now - cachedAt < 600000) && !force;
        if (fresh) {
            root.results = cached;
            resultModel.clear();
            for (var ci = 0; ci < cached.length; ci++) {
                var cr = cached[ci];
                resultModel.append({
                    "id": root.sanitize(cr.id),
                    "title": root.sanitize(cr.title),
                    "year": root.sanitize(cr.year || ""),
                    "rating": root.sanitize(cr.rating ? String(cr.rating) : "-"),
                    "cover": root.sanitize(cr.cover || ""),
                    "coverPath": root.sanitize(cr.cover || ""),
                    "duration": root.sanitize(cr.duration || "")
                });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " " + genre + " titles";
            root.busy = false;
            return ;
        }
        root.busy = true;
        root.busyLabel = "Loading " + genre + " …";
        root.statusText = "";
        root.genreGen++;
        var gen = root.genreGen;
        request("search", {
            "q": genre,
            "page": 1
        }, function(resp, code) {
            if (gen !== root.genreGen)
                return ;

            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Search failed";
                return ;
            }
            root.results = resp.items || [];
            var nc = {
            };
            for (var k in root.genreCache) nc[k] = root.genreCache[k]
            nc[genre] = root.results.slice();
            root.genreCache = nc;
            var nt = {
            };
            for (var k2 in root.genreCacheTime) nt[k2] = root.genreCacheTime[k2]
            nt[genre] = Date.now();
            root.genreCacheTime = nt;
            resultModel.clear();
            for (var i = 0; i < root.results.length; i++) {
                var r = root.results[i];
                resultModel.append({
                    "id": root.sanitize(r.id),
                    "title": root.sanitize(r.title),
                    "year": root.sanitize(r.year || ""),
                    "rating": root.sanitize(r.rating ? String(r.rating) : "-"),
                    "cover": root.sanitize(r.cover || ""),
                    "coverPath": root.sanitize(r.cover || ""),
                    "duration": root.sanitize(r.duration || "")
                });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " " + genre + " titles";
        });
    }

    function refreshCurrent() {
        if (root.view === "home") {
            root.loadHome(true);
        } else if (root.view === "grid") {
            if (root.selectedGenre)
                root.searchByGenre(root.selectedGenre, true);
            else
                root.doSearch();
        } else if (root.view === "details" && root.currentId) {
            root.detailGen++;
            var gen = root.detailGen;
            root.busy = true;
            root.busyLabel = "Refreshing …";
            request("details", {
                "id": root.currentId
            }, function(resp) {
                if (gen !== root.detailGen)
                    return ;

                if (resp && resp.ok) {
                    root.details = root.sanitizeDetails(resp.value);
                    var cover = root.coverUrlOf(root.details);
                    if (cover)
                        detailPoster.source = cover;

                }
                root.loadEpisodes(root.currentId, gen);
            });
        } else {
            root.loadHome(true);
        }
    }

    // ---------------- open/close wiring ----------------
    function openFromHotkey() {
        if (homeModel.count === 0 && !root.homeLoading)
            root.loadHome(false);

        root.controller.show();
        Qt.callLater(function() {
            if (root.opened)
                searchField.forceActiveFocus();

        });
    }

    function close() {
        root.controller.hide();
    }

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.openFromHotkey();
    }

    function closeForPopoutSwitch() {
        root.close();
    }

    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction);

        return false;
    }

    moduleName: "tenzin.animechy"
    implicitWidth: 820
    implicitHeight: 580

    Process {
        id: bridgeProc

        property string collected: ""

        onExited: function(code, status) {
            var cb = root.cbChain;
            root.cbChain = null;
            var resp = null;
            try {
                resp = JSON.parse(bridgeProc.collected);
            } catch (e) {
            }
            if (cb)
                cb(resp, code);

            if (root.pending.length > 0) {
                var next = root.pending.shift();
                root._start(next.cmd, next.params, next.cb);
            }
        }

        stdout: SplitParser {
            onRead: function(data) {
                bridgeProc.collected += data;
            }
        }

    }

    Process {
        id: mpvProc

        onExited: function() {
            root.playing = false;
            root.statusText = "Player closed";
        }
    }

    Process {
        id: prefetchProc

        property string collected: ""

        onExited: function(code) {
            try {
                JSON.parse(prefetchProc.collected);
            } catch (e) {
            }
        }

        stdout: SplitParser {
            onRead: function(data) {
                prefetchProc.collected += data;
            }
        }

    }

    Process {
        id: streamsProc
        property string collected: ""
        property var cbChain: null
        property int gen: 0
        onExited: function(code, status) {
            var cb = streamsProc.cbChain;
            streamsProc.cbChain = null;
            var resp = null;
            try { resp = JSON.parse(streamsProc.collected); } catch(e){}
            streamsProc.collected = "";
            if (cb) cb(resp, code);
        }
        stdout: SplitParser { onRead: function(data){ streamsProc.collected += data } }
    }

    Process {
        id: historyLoadProc
        property string collected: ""
        onExited: function(code) {
            var raw = historyLoadProc.collected.trim();
            historyLoadProc.collected = "";
            if (!raw) return;
            try {
                var arr = JSON.parse(raw);
                if (Array.isArray(arr)) {
                    if (arr.length > root.maxHistory) arr = arr.slice(0, root.maxHistory);
                    root.searchHistory = arr;
                }
            } catch (e) {}
        }
        stdout: SplitParser { onRead: function(data){ historyLoadProc.collected += data } }
    }
    Process { id: historySaveProc }

    // ---------------- UI ----------------
    ListModel {
        id: resultModel
    }

    ListModel {
        id: homeModel
    }

    Timer {
        id: suggestTimer

        interval: 380
        repeat: false
        onTriggered: {
            var q = searchField.text.trim();
            if (q.length < 2) {
                suggestionModel.clear();
                return ;
            }
            root.suggestGen++;
            var gen = root.suggestGen;
            request("suggest", {
                "q": q
            }, function(resp) {
                if (gen !== root.suggestGen)
                    return ;

                suggestionModel.clear();
                var list = (resp && resp.ok && resp.suggestions) ? resp.suggestions : [];
                for (var i = 0; i < list.length && i < 8; i++) suggestionModel.append({
                    "name": root.sanitize(list[i].name)
                })
            });
        }
    }

    ListModel {
        id: suggestionModel
    }

    KeyboardPanel {
        id: panel

        readonly property bool isSmallScreen: panel.screenW > 0 && panel.screenW < 1366
        readonly property bool isLargeScreen: panel.screenW >= 1920
        readonly property real uiScale: Math.min(1.4, Math.max(0.9, panel.screenW / 1920))

        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: true
        margin: Style.gapsOut
        gap: Style.gapsOut
        contentWidth: isSmallScreen ? panel.fittedContentWidth(panel.screenW * 0.74) : isLargeScreen ? panel.fittedContentWidth(panel.screenW * 0.67) : panel.fittedContentWidth(panel.screenW * 0.71)
        contentHeight: isSmallScreen ? panel.fittedContentHeight(panel.screenH * 0.86, panel.screenH * 0.94) : isLargeScreen ? panel.fittedContentHeight(panel.screenH * 0.84, panel.screenH * 0.9) : panel.fittedContentHeight(panel.screenH * 0.82, panel.screenH * 0.9)

        ColumnLayout {
            id: mainColumn

            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            // header
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: 8

                        Text {
                            text: "ア"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                            color: Color.accent
                        }

                        Text {
                            text: "Animechy"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                            font.bold: true
                            color: Color.foreground
                        }

                        Rectangle {
                            width: 1
                            height: 18
                            color: Color.foreground
                            opacity: 0.12
                            Layout.leftMargin: 4
                            Layout.rightMargin: 4
                        }

                        Text {
                            text: root.view === "details" ? "Details" : root.view === "grid" ? "Results" : "Discover"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            color: Qt.darker(Color.foreground, 1.25)
                            font.capitalization: Font.AllUppercase
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        RowLayout {
                            spacing: 6
                            visible: root.busy || root.playing

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: Color.accent
                                opacity: 0.9
                                visible: root.busy

                                SequentialAnimation on opacity {
                                    running: root.busy
                                    loops: Animation.Infinite

                                    NumberAnimation {
                                        from: 0.4
                                        to: 1
                                        duration: 700
                                    }

                                    NumberAnimation {
                                        from: 1
                                        to: 0.4
                                        duration: 700
                                    }

                                }

                            }

                            Text {
                                textFormat: Text.PlainText
                                text: root.busy ? root.busyLabel : "Playing"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Color.accent
                            }

                        }

                    }

                    Text {
                        textFormat: Text.PlainText
                        text: root.statusText
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption - 1
                        color: Qt.darker(Color.foreground, 1.35)
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        maximumLineCount: 1
                    }

                }

                Button {
                    text: "\u21bb"
                    tooltipText: "Refresh"
                    fontSize: Style.font.body
                    horizontalPadding: 10
                    verticalPadding: 5
                    onClicked: root.refreshCurrent()
                }

                Button {
                    text: "✕"
                    tooltipText: "Close"
                    fontSize: Style.font.body
                    horizontalPadding: 12
                    verticalPadding: 6
                    onClicked: root.close()
                }

            }

            PanelSeparator {
                Layout.fillWidth: true
                opacity: 0.5
            }

            // search
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                TextField {
                    id: searchField

                    Layout.fillWidth: true
                    placeholderText: "Search anime … (e.g. Naruto, One Piece, Demon Slayer)"
                    onAccepted: root.doSearch()
                    onTextChanged: if (text.length >= 2) root.debounceSuggest()
                    Keys.onEscapePressed: {
                        if (searchField.hasFocus) {
                            clear();
                            suggestionModel.clear();
                        } else {
                            root.close();
                        }
                    }
                }

                Button {
                    text: "Search"
                    iconText: "\uf002"
                    selected: true
                    onClicked: root.doSearch()
                }

                Button {
                    text: "Home"
                    iconText: "\uf015"
                    onClicked: root.goHome()
                }

            }

            // recent searches chips (below search bar, not inside it)
            Flow {
                id: historyFlow
                Layout.fillWidth: true
                spacing: 4
                visible: root.searchHistory.length > 0
                Repeater {
                    model: root.searchHistory
                    Button {
                        text: modelData
                        fontSize: Style.font.caption - 1
                        selected: root.query === modelData
                        onClicked: {
                            searchField.text = modelData;
                            root.doSearch();
                        }
                    }
                }
            }

            // suggestions
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Layout.preferredHeight: suggestionModel.count ? Math.min(suggestionModel.count, 2) * 28 + 6 : 0
                visible: suggestionModel.count > 0

                Repeater {
                    model: suggestionModel

                    Button {
                        text: model.name
                        fontSize: Style.font.caption
                        horizontalPadding: 10
                        verticalPadding: 4
                        onClicked: {
                            searchField.text = model.name;
                            root.doSearch();
                        }
                    }

                }

            }

            // genre selector — visible for home + grid
            Flow {
                Layout.fillWidth: true
                visible: root.view === "home" || root.view === "grid"
                spacing: 6

                Repeater {
                    model: root.genres

                    Button {
                        text: modelData
                        fontSize: Style.font.caption
                        horizontalPadding: 10
                        verticalPadding: 4
                        enabled: !root.busy && !root.homeLoading
                        selected: root.selectedGenre === modelData || (modelData === "All" && root.selectedGenre === "")
                        onClicked: root.searchByGenre(modelData)
                    }

                }

            }

            // body
            Item {
                id: body

                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: Math.round(Math.min(Math.max(300, panel.screenH * 0.52), panel.screenH * 0.6))
                clip: true

                // ---- home (discover) ----
                Item {
                    anchors.fill: parent
                    visible: root.view === "home"

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: root.homeLoading ? "Discover …" : (homeModel.count ? "Discover • tap any title" : "Discover")
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                font.bold: true
                                color: Color.accent
                            }

                        }

                        GridView {
                            id: homeGrid

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            cacheBuffer: 400
                            flickableDirection: Flickable.VerticalFlick
                            boundsBehavior: Flickable.StopAtBounds
                            maximumFlickVelocity: 4000
                            reuseItems: true
                            visible: !root.homeLoading
                            model: homeModel
                            cellWidth: Math.round(168 * panel.uiScale)
                            cellHeight: Math.round(236 * panel.uiScale)

                            delegate: Item {
                                id: homeDelegate

                                property bool hovered: homeMouse.containsMouse

                                width: homeGrid.cellWidth
                                height: homeGrid.cellHeight

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    spacing: 5

                                    Rectangle {
                                        width: parent.width
                                        height: parent.height * 0.74
                                        radius: Style.cornerRadius
                                        color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                                        border.width: homeDelegate.hovered ? 1 : 0
                                        border.color: homeDelegate.hovered ? Color.accent : "transparent"
                                        clip: true

                                        Image {
                                            anchors.fill: parent
                                            source: root._sanitizeCoverUrl(model.cover || model.coverPath || "")
                                            fillMode: Image.PreserveAspectCrop
                                            visible: source !== ""
                                            asynchronous: true
                                            cache: true
                                        }

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            height: 22
                                            color: "#66000000"
                                            visible: model.rating && model.rating !== "-"

                                            Text {
                                                anchors.centerIn: parent
                                                textFormat: Text.PlainText
                                                text: "★ " + model.rating
                                                font.family: Style.font.family
                                                font.pixelSize: 10
                                                color: "white"
                                                font.bold: true
                                            }

                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: !model.cover && !model.coverPath
                                            text: "ア"
                                            font.family: Style.font.family
                                            font.pixelSize: 30
                                            color: Qt.darker(Color.foreground, 1.3)
                                        }

                                    }

                                    Text {
                                        width: parent.width
                                        textFormat: Text.PlainText
                                        text: model.title
                                        elide: Text.ElideRight
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        color: Color.foreground
                                        maximumLineCount: 1
                                    }

                                    Text {
                                        textFormat: Text.PlainText
                                        text: (model.year ? model.year : "—") + "  ★ " + model.rating
                                        elide: Text.ElideRight
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption - 2
                                        color: Qt.darker(Color.foreground, 1.5)
                                    }

                                }

                                MouseArea {
                                    id: homeMouse

                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    enabled: !root.busy && !root.homeLoading
                                    onEntered: homeHoverTimer.restart()
                                    onExited: homeHoverTimer.stop()
                                    onClicked: {
                                        if (!root.busy && !root.homeLoading)
                                            root.openDetails(index, true);

                                    }

                                    Timer {
                                        id: homeHoverTimer

                                        interval: 380
                                        repeat: false
                                        onTriggered: root.prefetchDetails(model.id)
                                    }

                                }

                            }

                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.homeLoading
                            text: "Loading highlights …"
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            color: Qt.darker(Color.foreground, 1.5)
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !root.homeLoading && homeModel.count === 0
                            text: "No highlights yet — try Search above."
                            horizontalAlignment: Text.AlignHCenter
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Qt.darker(Color.foreground, 1.4)
                        }

                    }

                }

                // ---- results grid ----
                GridView {
                    id: grid

                    anchors.fill: parent
                    visible: root.view === "grid"
                    model: resultModel
                    clip: true
                    cacheBuffer: 600
                    flickableDirection: Flickable.VerticalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    maximumFlickVelocity: 4000
                    reuseItems: true
                    cellWidth: Math.round(168 * panel.uiScale)
                    cellHeight: Math.round(236 * panel.uiScale)

                    delegate: Item {
                        id: gridDelegate

                        property bool hovered: gridMouse.containsMouse

                        width: grid.cellWidth
                        height: grid.cellHeight

                        Column {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 5

                            Rectangle {
                                width: parent.width
                                height: parent.height * 0.74
                                radius: Style.cornerRadius
                                color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                                border.width: gridDelegate.hovered ? 1 : 0
                                border.color: gridDelegate.hovered ? Color.accent : "transparent"
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: root._sanitizeCoverUrl(model.cover || model.coverPath || "")
                                    fillMode: Image.PreserveAspectCrop
                                    visible: source !== ""
                                    asynchronous: true
                                    cache: true
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 22
                                    radius: 0
                                    visible: model.rating && model.rating !== "-"
                                    color: "#66000000"

                                    Text {
                                        anchors.centerIn: parent
                                        textFormat: Text.PlainText
                                        text: "★ " + model.rating
                                        font.family: Style.font.family
                                        font.pixelSize: 10
                                        color: "white"
                                        font.bold: true
                                    }

                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: !model.cover && !model.coverPath
                                    text: "ア"
                                    font.family: Style.font.family
                                    font.pixelSize: 30
                                    color: Qt.darker(Color.foreground, 1.3)
                                }

                                Behavior on border.width {
                                    NumberAnimation {
                                        duration: 100
                                    }

                                }

                            }

                            Text {
                                width: parent.width
                                textFormat: Text.PlainText
                                text: model.title
                                elide: Text.ElideRight
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Color.foreground
                                maximumLineCount: 1
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: (model.year ? model.year : "—") + "  ★ " + model.rating
                                elide: Text.ElideRight
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption - 2
                                color: Qt.darker(Color.foreground, 1.5)
                            }

                        }

                        MouseArea {
                            id: gridMouse

                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            enabled: !root.busy
                            onEntered: {
                                if (!root.busy) {
                                    hoverTimer.restart();
                                }
                            }
                            onExited: hoverTimer.stop()
                            onClicked: {
                                if (!root.busy)
                                    root.openDetails(index, false);

                            }

                            Timer {
                                id: hoverTimer

                                interval: 380
                                repeat: false
                                onTriggered: root.prefetchDetails(model.id)
                            }

                        }

                    }

                }

                // ---- details ----
                Item {
                    anchors.fill: parent
                    visible: root.view === "details"

                    RowLayout {
                        anchors.fill: parent
                        spacing: 14

                        // poster
                        Rectangle {
                            Layout.preferredWidth: Math.round(170 * panel.uiScale)
                            Layout.fillHeight: true
                            radius: Style.cornerRadius
                            color: Qt.darker(Color.foreground, 2.2)
                            clip: true

                            Image {
                                id: detailPoster

                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                source: ""
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: detailPoster.source === ""
                                text: "ア"
                                font.family: Style.font.family
                                font.pixelSize: 40
                                color: Qt.darker(Color.foreground, 1.3)
                            }

                        }

                        // info column
                        ColumnLayout {
                            id: detailsContent

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: root.currentTitle
                                    elide: Text.ElideRight
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.title
                                    font.bold: true
                                    color: Color.foreground
                                }

                                Button {
                                    text: "← Back"
                                    fontSize: Style.font.caption
                                    onClicked: root.goHome()
                                }

                            }

                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: {
                                    if (!root.details)
                                        return "";

                                    var parts = [];
                                    var year = root.details.year ? String(root.details.year) : "";
                                    if (year)
                                        parts.push(year);

                                    if (root.details.genre)
                                        parts.push(root.details.genre);

                                    if (root.details.duration)
                                        parts.push(root.details.duration);

                                    if (root.details.imdbRatingValue)
                                        parts.push("★ " + root.details.imdbRatingValue);

                                    return parts.join("  •  ");
                                }
                                wrapMode: Text.WordWrap
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Qt.darker(Color.foreground, 1.4)
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 48
                                textFormat: Text.PlainText
                                text: (root.details && (root.details.intro || root.details.description || "")) || ""
                                wrapMode: Text.WordWrap
                                elide: Text.ElideRight
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Qt.darker(Color.foreground, 1.4)
                            }

                            // sub/dub toggle
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    text: "Audio:"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Qt.darker(Color.foreground, 1.2)
                                    font.bold: true
                                }

                                Button {
                                    text: "Sub"
                                    fontSize: Style.font.caption
                                    selected: root.mode === "sub"
                                    onClicked: {
                                        if (root.mode !== "sub") {
                                            root.mode = "sub";
                                            if (root.curEp)
                                                root.loadStreams(root.currentId, root.curEp, "sub");

                                        }
                                    }
                                }

                                Button {
                                    text: "Dub"
                                    fontSize: Style.font.caption
                                    selected: root.mode === "dub"
                                    onClicked: {
                                        if (root.mode !== "dub") {
                                            root.mode = "dub";
                                            if (root.curEp)
                                                root.loadStreams(root.currentId, root.curEp, "dub");

                                        }
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: root.episodes.length ? root.episodes.length + " episodes" : ""
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption - 1
                                    color: Qt.darker(Color.foreground, 1.4)
                                }

                            }

                            // seasons
                            Flow {
                                Layout.fillWidth: true
                                visible: root.seasons.length > 1
                                spacing: 6

                                Repeater {
                                    model: root.seasons

                                    Button {
                                        text: "S" + (index + 1)
                                        tooltipText: modelData.title
                                        fontSize: Style.font.caption
                                        selected: index === root.curSeasonIdx
                                        onClicked: root.selectSeason(index)
                                    }

                                }

                            }

                            // episodes — light grey fill + outline enclosing all episodes
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 110
                                visible: root.episodes.length > 0
                                radius: Style.cornerRadius
                                color: Util.alpha(Color.foreground, 0.07)
                                border.width: 1
                                border.color: Util.alpha(Color.foreground, 0.18)
                                clip: true

                                Flickable {
                                    id: epFlick

                                    anchors.fill: parent
                                    anchors.margins: 6
                                    clip: true
                                    contentWidth: width
                                    contentHeight: episodeFlow.implicitHeight
                                    boundsBehavior: Flickable.StopAtBounds
                                    flickableDirection: Flickable.VerticalFlick

                                    Flow {
                                        id: episodeFlow

                                        width: epFlick.width
                                        spacing: 6

                                        Repeater {
                                            id: episodeRepeater

                                            model: root._episodeCount

                                            Button {
                                                property var epObj: (index < root.episodes.length) ? root.episodes[index] : null
                                                property string epNum: epObj ? epObj.number : String(index + 1)
                                                property bool isFiller: epObj ? epObj.filler : false

                                                text: "E" + epNum
                                                fontSize: Style.font.caption
                                                selected: epNum === root.curEp
                                                opacity: isFiller ? 0.6 : 1
                                                onClicked: {
                                                    root.curEp = epNum;
                                                    root.loadStreams(root.currentId, epNum, root.mode);
                                                }
                                            }

                                        }

                                    }

                                    ScrollBar.vertical: ScrollBar {
                                        policy: ScrollBar.AsNeeded
                                    }

                                }

                            }

                            PanelSeparator {
                                Layout.fillWidth: true
                            }

                            // streams
                            Text {
                                Layout.fillWidth: true
                                text: "Streams" + (root.curEp ? " — E" + root.curEp + " (" + root.mode + ")" : "")
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                color: Color.accent
                            }

                            ListView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                spacing: 4
                                cacheBuffer: 200
                                boundsBehavior: Flickable.StopAtBounds
                                maximumFlickVelocity: 3500
                                reuseItems: true
                                model: root.streams

                                Text {
                                    anchors.centerIn: parent
                                    visible: root.streams.length === 0 && !root.busy
                                    text: {
                                        if (!root.episodes.length) return "No streams";
                                        if (root.curEp) return "No streams for E" + root.curEp + " — tap episode again to retry";
                                        return "Select an episode to load streams";
                                    }
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Qt.darker(Color.foreground, 1.5)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: root.streams.length === 0 && root.busy && root.curEp
                                    text: "Loading streams for E" + root.curEp + " …"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: Color.accent
                                }

                                delegate: Button {
                                    width: parent ? parent.width : 0
                                    text: {
                                        var q = modelData.quality || (modelData.resolution ? modelData.resolution + "p" : "Stream");
                                        var bw = modelData.bandwidth ? Math.round(modelData.bandwidth / 1000) + " kbps" : "";
                                        return q + (bw ? "  •  " + bw : "") + (modelData.codecName ? "  •  " + String(modelData.codecName).toUpperCase() : "");
                                    }
                                    leftAlign: true
                                    selected: index === root.selStream
                                    fontSize: Style.font.caption
                                    onClicked: root.selectStream(index)
                                }

                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Layout.bottomMargin: 6

                                Text {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: root.statusText
                                    elide: Text.ElideRight
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption - 2
                                    color: Qt.darker(Color.foreground, 1.4)
                                }

                                Button {
                                    text: "▶ Play"
                                    selected: true
                                    enabled: root.selStream >= 0 && !root.playing
                                    onClicked: {
                                        root.playExternal();
                                    }
                                }

                            }

                        }

                    }

                }

            }

        }

    }

}
