import QtQuick
import QtQuick.Layouts
import qs.Commons

import "../Model.js" as Model

Item {
    id: row

    property var entry: ({})
    property bool selected: false
    readonly property string result: Model.runState(entry)
    readonly property bool failed: Model.runFailed(entry)
    readonly property bool running: entry.bucket === "running"

    signal openJob()
    signal openRepo()

    // Matches contentLayout's margins on both edges.
    implicitHeight: contentLayout.implicitHeight + Style.space(8) * 2
    width: parent ? parent.width : 0

    Rectangle {
        anchors.fill: parent
        radius: Style.space(4)
        color: {
            if (selected) return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.1);
            if (mouseArea.containsMouse) return Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04);
            return "transparent";
        }
        border.color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.3) : "transparent"
        border.width: selected ? 1 : 0

        Behavior on color { ColorAnimation { duration: 120 } }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.openJob()
    }

    ColumnLayout {
        id: contentLayout
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(3)

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Rectangle {
                width: Style.space(8); height: Style.space(8); radius: Style.space(4)
                color: {
                    if (row.failed) return Color.urgent;
                    if (row.running) return Color.accent;
                    return row.result === "success" ? Color.foreground : Color.muted;
                }

                SequentialAnimation on opacity {
                    running: row.running
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            Text {
                Layout.fillWidth: true
                text: row.entry.workflow || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                color: Color.foreground
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Text {
                text: row.result
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: {
                    if (row.failed) return Color.urgent;
                    if (row.running) return Color.accent;
                    return row.result === "success" ? Color.foreground : Color.muted;
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
                text: row.entry.repo || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.accent
                elide: Text.ElideRight
                Layout.minimumWidth: Style.space(40)
                opacity: repoMouse.containsMouse ? 1.0 : 0.9

                MouseArea {
                    id: repoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: row.openRepo()
                }
            }

            Text {
                text: row.entry.branch || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.foreground
                Layout.maximumWidth: Style.space(120)
                Layout.minimumWidth: Style.space(30)
                elide: Text.ElideRight
            }

            Text {
                visible: !!row.entry.event
                text: row.entry.event || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                color: Color.muted
            }

            Item { Layout.fillWidth: true }

            Text {
                text: Model.timeAgo(row.entry.updated || row.entry.started)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
            }
        }
    }
}
