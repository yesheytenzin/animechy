import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.animechy"

    visible: true
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property string setupScript: Qt.resolvedUrl("animechy-setup.sh").toString().replace(/^file:\/\//, "")
    readonly property string pendingOpenMarker: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/animechy/.pending-open"
    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool userClickedInstall: false

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.setupOutput = "";
        setupProc.command = ["bash", root.setupScript];
        setupProc.running = true;
        installNotifyTimer.restart();
    }

    function injectPanel() {
        var target = panelLoader.item;
        if (!target) return;
        if ("bar" in target) target.bar = root.bar;
        if ("settings" in target) target.settings = root.settings;
        if ("anchorItem" in target) target.anchorItem = button;
        if ("hostWidget" in target) target.hostWidget = root;
    }

    function togglePanel() {
        // Debug notify to confirm click
        notify("Animechy — Clicked", "bridgeReady=" + root.bridgeReady + " loader=" + panelLoader.status + " opened=" + root.opened, "low");
        if (panelLoader.status === Loader.Error) {
            notify("Animechy — Panel Load Error", "Failed to load Panel.qml — check logs", "critical");
            return;
        }
        if (!panelLoader.item) {
            notify("Animechy — Panel Not Ready", "Loader status=" + panelLoader.status, "critical");
            return;
        }
        if (!root.bridgeReady) {
            root.userClickedInstall = true;
            touchProc.command = ["touch", root.pendingOpenMarker];
            touchProc.running = true;
            root.ensureBridge();
            // Still try to open panel even while installing, so user sees UI
        }
        if (panelLoader.item && panelLoader.item.toggle) {
            panelLoader.item.toggle();
        } else if (panelLoader.item && panelLoader.item.openFromHotkey) {
            // fallback
            if (root.opened) panelLoader.item.close();
            else panelLoader.item.openFromHotkey();
        } else {
            notify("Animechy — No toggle", "Panel item has no toggle/open", "critical");
        }
    }

    function consumePendingOpen() {
        markerProc.out = "";
        markerProc.command = ["bash", "-c", "m=\"$1\"; [ -f \"$m\" ] && rm -f \"$m\" && echo OPEN", "_", root.pendingOpenMarker];
        markerProc.running = true;
    }
    function open() {
        if (panelLoader.item && panelLoader.item.openFromHotkey)
            panelLoader.item.openFromHotkey();
    }
    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
            panelLoader.item.closeForPopoutSwitch();
    }

    function notify(title, body, urgency) {
        var u = urgency || "normal";
        var t = title || "Animechy";
        var b = body || "";
        notifyProc.command = ["notify-send", "-a", "Animechy", "-u", u, "-i", "video-display", t, b];
        notifyProc.running = true;
    }

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Process {
        id: setupProc
        property string setupOutput: ""
        property string errorOutput: ""
        stdout: SplitParser {
            onRead: function(data) { setupProc.setupOutput += data + "\n" }
        }
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onExited: function(exitCode) {
            installNotifyTimer.stop();
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge setup failed";
                notify("Animechy — Setup failed", root.bridgeError, "critical");
                return;
            }
            var out = setupProc.setupOutput;
            var isFresh = out.indexOf("already installed") === -1 && (out.indexOf("installed") !== -1 || out.indexOf("ready") !== -1);
            if (isFresh) {
                notify("Animechy — Ready", "Bridge ready — click ア to browse anime", "normal");
            }
            var restartScheduled = out.indexOf("ANIMECHY_RESTART_SHELL=1") !== -1;
            if (restartScheduled) {
                return;
            }
            if (root.userClickedInstall) {
                root.userClickedInstall = false;
                touchProc.command = ["rm", "-f", root.pendingOpenMarker];
                touchProc.running = true;
                Qt.callLater(root.togglePanel);
            }
        }
    }

    Process {
        id: markerProc
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { markerProc.out += data }
        }
        onExited: function(exitCode) {
            if (markerProc.out.indexOf("OPEN") !== -1)
                Qt.callLater(root.togglePanel);
        }
    }

    Process {
        id: touchProc
    }

    Process {
        id: notifyProc
    }

    Timer {
        id: installNotifyTimer
        interval: 600
        repeat: false
        onTriggered: {
            if (root.installing && !root.bridgeReady) {
                notify("Animechy", "Setting up bridge…", "normal");
            }
        }
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("Animechy Panel failed to load:", source, "error:", panelLoader.sourceComponent ? "" : "component null");
                root.notify("Animechy — Loader Error", "Panel.qml failed to load (status Error)", "critical");
            } else if (status === Loader.Ready) {
                console.log("Animechy Panel loaded OK");
            }
        }
        onLoaded: {
            console.log("Animechy Panel onLoaded");
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // ▶ play triangle — distinct from OmaMovie's  film, universally rendered
        text: "ア"
        slotSize: Style.bar.statusSlot
        tooltipText: root.installing ? "Animechy • installing bridge …" :
                     (root.bridgeReady ? "Animechy • search & watch anime in mpv (sub/dub)" :
                      (root.bridgeError || "Animechy • bridge not ready; click to retry"))
        onPressed: root.togglePanel()
    }

    Component.onCompleted: {
        root.consumePendingOpen();
        root.ensureBridge();
    }
}
