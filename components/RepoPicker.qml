import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.Commons
import qs.Ui as Ui

import "../Model.js" as Model

// Chooses which repositories appear in the bar and panel. Toggling only
// changes visibility: hidden repositories keep sending notifications.
Item {
    id: picker

    property var hidden: ({})
    property int dataRev: 0
    property bool saveFailed: false
    property int selectedIndex: 0
    property alias query: search.text

    // Emits the complete new hidden list; the owner persists it.
    signal hiddenListChanged(var list)

    readonly property var rows: {
        void dataRev;
        return Model.pickerRows(hidden, query);
    }
    readonly property int shownCount: {
        void dataRev;
        var all = Model.pickerRows(hidden, "");
        return all.filter(function(r) { return r.shown; }).length;
    }
    readonly property int totalCount: { void dataRev; return Model.knownRepos().length; }

    implicitHeight: col.implicitHeight

    onRowsChanged: selectedIndex = Math.max(0, Math.min(selectedIndex, rows.length - 1))

    function toggleRow(row) {
        if (!row) return;
        hiddenListChanged(Model.updateHidden(hidden, [row.repo], row.shown));
    }

    // Applies to the rows matching the current search.
    function setAllShown(show) {
        hiddenListChanged(Model.updateHidden(hidden, rows.map(function(r) { return r.repo; }), !show));
    }

    function focusSearch() { search.forceActiveFocus(); }

    // Keys routed from the panel while the picker is showing. Returns true
    // when handled.
    function handleKey(event) {
        switch (event.key) {
        case Qt.Key_J:
        case Qt.Key_Down:
            selectedIndex = Math.min(selectedIndex + 1, rows.length - 1);
            return true;
        case Qt.Key_K:
        case Qt.Key_Up:
            selectedIndex = Math.max(selectedIndex - 1, 0);
            return true;
        case Qt.Key_Space:
        case Qt.Key_Return:
        case Qt.Key_Enter:
            toggleRow(rows[selectedIndex]);
            return true;
        case Qt.Key_Slash:
            focusSearch();
            return true;
        }
        return false;
    }

    signal leaveSearch()

    ColumnLayout {
        id: col
        anchors.fill: parent
        spacing: Style.space(8)

        Ui.TextField {
            id: search
            Layout.fillWidth: true
            placeholderText: "Filter repositories"
            Keys.onEscapePressed: function(event) {
                if (search.text !== "") search.text = "";
                else picker.leaveSearch();
                event.accepted = true;
            }
            Keys.onDownPressed: function(event) {
                picker.leaveSearch();
                event.accepted = true;
            }
            onAccepted: picker.leaveSearch()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(12)

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: picker.shownCount + " of " + picker.totalCount + " shown in the bar · all still notify"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.foreground
                elide: Text.ElideRight
            }

            Repeater {
                model: [
                    { label: "Show all", show: true },
                    { label: "Hide all", show: false }
                ]
                Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.underline: linkMouse.containsMouse
                    color: Color.accent

                    MouseArea {
                        id: linkMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.setAllShown(modelData.show)
                    }
                }
            }
        }

        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: picker.saveFailed
            text: "This bar cannot save settings; the choice lasts until the shell restarts."
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Color.urgent
        }

        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: picker.rows.length === 0
            text: picker.totalCount === 0 ? "No repositories collected yet" : "No repositories match"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            color: Color.foreground
        }

        ListView {
            id: rowList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, Style.space(560))
            visible: picker.rows.length > 0
            model: picker.rows
            currentIndex: picker.selectedIndex
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                width: Style.space(4)
            }

            delegate: Ui.Toggle {
                width: rowList.width
                label: modelData.repo
                description: modelData.active ? "Active now" : ""
                checked: modelData.shown
                hasCursor: index === picker.selectedIndex
                onClicked: {
                    picker.selectedIndex = index;
                    picker.toggleRow(modelData);
                }
            }
        }
    }
}
