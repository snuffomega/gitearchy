import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

import "Model.js" as Model

Ui.BarWidget {
    id: root

    property int refreshIntervalSec: setting("refreshIntervalSec", 180)
    property string giteaUrl: setting("giteaUrl", "")
    property int maxStaleHours: setting("maxStaleHours", 6)
    property bool notifyOnFailure: setting("notifyOnFailure", true)
    property bool notifyOnReviewRequest: setting("notifyOnReviewRequest", true)
    property string mutedRepos: setting("mutedRepos", "")
    // Repositories kept out of the bar and panel; notifications ignore it.
    // hiddenOverride shows a picker change at once and until the shell
    // hands back the saved settings.
    property var hiddenOverride: null
    property var hiddenRepos: hiddenOverride !== null
        ? hiddenOverride : Model.hiddenSet(setting("hiddenRepos", []), mutedRepos)
    property bool hiddenSaveFailed: false

    property string stateDir: {
        var xdg = Quickshell.env("XDG_STATE_HOME")
        return (xdg || Quickshell.env("HOME") + "/.local/state") + "/omarchy/gitea-workstatus"
    }
    property string stateFile: stateDir + "/overview.json"
    property string errorFile: stateDir + "/last-error.json"

    property var barSummary: ({ total: 0, attention: 0, running: 0, failed: 0, review: 0, ready: 0, healthy: true })
    property bool panelOpen: false
    readonly property bool opened: panelOpen
    property bool stale: false
    property bool hasError: false
    property string errorMsg: ""
    property string collectorError: ""
    property string collectionBaselineTs: ""
    // Bumped whenever the snapshot or the display settings change, so an open
    // panel repopulates on either.
    property int dataRevision: 0
    property string lastContent: ""

    implicitWidth: barRow.implicitWidth + Style.space(16)
    implicitHeight: Style.bar.sizeHorizontal

    function open() { panelOpen = true; }
    function close() {
        panelOpen = false;
        // The panel may be unloaded before its own onOpenChanged runs.
        if (bar && typeof bar.releasePopout === "function") bar.releasePopout(root);
    }
    function toggle() { panelOpen ? close() : open(); }
    function refresh() {
        var meta = Model.getMeta();
        collectionBaselineTs = meta ? String(meta.collected_at || "") : "";
        collector.running = true;
    }
    function next() {}

    Component.onCompleted: refresh()

    onSettingsChanged: {
        hiddenOverride = null;
        hiddenSaveFailed = false;
    }

    // Persist the picker's hidden list into this widget's shell.json entry.
    // The legacy mutedRepos value is folded in, so it is cleared on save.
    function setHiddenRepos(list) {
        hiddenOverride = Model.repoSet(list);
        var next = {};
        for (var key in settings) next[key] = settings[key];
        next.hiddenRepos = list;
        next.mutedRepos = "";
        var api = bar ? bar.shell : null;
        if (!api || typeof api.updateEntryInline !== "function") {
            hiddenSaveFailed = true;
            return;
        }
        // false only means nothing changed; a real save re-delivers settings.
        api.updateEntryInline(moduleName || "io.github.snuffomega.gitearchy", next);
    }

    onHiddenReposChanged: {
        barSummary = Model.getBarSummary(hiddenRepos);
        dataRevision++;
    }

    function processData(content) {
        if (!content || content.trim() === "") {
            hasError = true;
            errorMsg = "No status data yet";
            return;
        }

        var parsed;
        try { parsed = JSON.parse(content); } catch(e) {
            hasError = true;
            errorMsg = "Corrupt status data";
            return;
        }

        if (parsed.error) {
            hasError = true;
            errorMsg = parsed.error;
            return;
        }

        if (settleTimer.running && parsed.meta && String(parsed.meta.collected_at || "") !== collectionBaselineTs) {
            settleTimer.stop();
        }
        hasError = collectorError !== "";
        errorMsg = collectorError;

        // Settle polling and file-watch echoes re-deliver identical content.
        if (content === lastContent) return;
        lastContent = content;

        Model.parseOverview(content);
        barSummary = Model.getBarSummary(hiddenRepos);
        dataRevision++;

        var meta = Model.getMeta();
        stale = meta && meta.stale === true;

        // Model.js decides per repository whether stale data may notify.
        var notes = Model.getNewNotifications(notifyOnFailure, notifyOnReviewRequest);
        for (var i = 0; i < notes.length; i++) {
            sendNotification(notes[i].message);
        }
    }

    function processError(content) {
        if (!content || content.trim() === "") return;
        try {
            var parsed = JSON.parse(content);
            collectorError = String(parsed.error || "").trim();
        } catch(e) {
            collectorError = "Collector error details are corrupt";
        }
        if (collectorError !== "") {
            settleTimer.stop();
            hasError = true;
            errorMsg = collectorError;
        }
    }

    // Detached so several notes from one refresh are all delivered; a shared
    // Process ignores running = true while the previous send is still alive.
    function sendNotification(body) {
        Quickshell.execDetached(["notify-send", "--app-name=Gitea", "Gitea", body]);
    }

    FileView {
        id: fileReader
        path: root.stateFile
        watchChanges: true
        printErrors: false
        onLoaded: root.processData(text())
        onFileChanged: reload()
    }

    FileView {
        id: errorReader
        path: root.errorFile
        watchChanges: true
        printErrors: false
        onLoaded: root.processError(text())
        onFileChanged: reload()
        onLoadFailed: {
            root.collectorError = "";
            fileReader.reload();
        }
    }

    Process {
        id: collector
        command: ["bash", Qt.resolvedUrl("bin/gitea-collect").toString().replace("file://", "")]
        environment: ({
            GITEA_WS_MAX_STALE_HOURS: root.maxStaleHours.toString()
        })
        stdout: StdioCollector { id: collectorStdout }
        stderr: StdioCollector { id: collectorStderr }
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.hasError = true;
                var detail = String(collectorStderr.text || "").trim();
                root.collectorError = detail || "Collector failed (exit " + exitCode + ")";
                root.errorMsg = root.collectorError;
            } else if (String(collectorStdout.text || "").indexOf("Another collector is running") !== -1) {
                settleTimer.remaining = 120;
                settleTimer.restart();
            } else {
                root.collectorError = "";
                fileReader.reload();
                errorReader.reload();
            }
        }
    }

    Timer {
        id: settleTimer
        property int remaining: 0
        interval: 500
        repeat: true
        onTriggered: {
            fileReader.reload();
            errorReader.reload();
            remaining--;
            if (remaining <= 0) stop();
        }
    }

    Timer {
        interval: root.refreshIntervalSec * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) root.toggle();
            else if (mouse.button === Qt.RightButton) root.refresh();
        }
        cursorShape: Qt.PointingHandCursor

        RowLayout {
            id: barRow
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
                text: "\u2387"
                font.family: Style.font.family
                font.pixelSize: Style.space(14)
                color: {
                    if (root.hasError) return Color.muted;
                    if (root.barSummary.attention > 0 || root.barSummary.failed > 0) return Color.urgent;
                    if (root.barSummary.running > 0) return Color.accent;
                    if (root.barSummary.review > 0) return Color.accent;
                    return Color.foreground;
                }
                opacity: root.stale ? 0.5 : 1.0

                SequentialAnimation on opacity {
                    running: root.barSummary.running > 0 && !root.stale
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.4; duration: 800; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
                }
            }

            Row {
                spacing: Style.space(4)
                visible: !root.hasError && root.barSummary.total > 0

                Row {
                    spacing: Style.space(2)
                    visible: root.barSummary.failed > 0
                    Text {
                        text: "\u2718"
                        font.pixelSize: Style.space(10)
                        color: Color.urgent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.barSummary.failed
                        font.family: Style.font.family
                        font.pixelSize: Style.space(11)
                        font.weight: Font.DemiBold
                        color: Color.urgent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    spacing: Style.space(2)
                    visible: root.barSummary.review > 0
                    Text {
                        text: "\u25CF"
                        font.pixelSize: Style.space(8)
                        color: Color.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.barSummary.review
                        font.family: Style.font.family
                        font.pixelSize: Style.space(11)
                        font.weight: Font.DemiBold
                        color: Color.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    spacing: Style.space(2)
                    visible: root.barSummary.running > 0
                    Text {
                        text: "\u25E6"
                        font.pixelSize: Style.space(10)
                        color: Color.accent
                        anchors.verticalCenter: parent.verticalCenter

                        SequentialAnimation on opacity {
                            running: true
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 600 }
                            NumberAnimation { to: 1.0; duration: 600 }
                        }
                    }
                    Text {
                        text: root.barSummary.running
                        font.family: Style.font.family
                        font.pixelSize: Style.space(11)
                        color: Color.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    spacing: Style.space(2)
                    visible: root.barSummary.ready > 0 && root.barSummary.attention === 0
                    Text {
                        text: "\u2714"
                        font.pixelSize: Style.space(10)
                        color: Color.foreground
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.barSummary.ready
                        font.family: Style.font.family
                        font.pixelSize: Style.space(11)
                        color: Color.foreground
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            Text {
                visible: root.hasError
                text: "!"
                font.family: Style.font.family
                font.pixelSize: Style.space(11)
                font.weight: Font.Bold
                color: Color.muted
            }
        }
    }

    Loader {
        id: panelLoader
        active: root.panelOpen
        sourceComponent: Component {
            Panel {
                anchorItem: root
                bar: root.bar
                owner: root
                open: root.panelOpen
                barWidget: root
            }
        }
    }
}
