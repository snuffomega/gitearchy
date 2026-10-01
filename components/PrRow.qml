import QtQuick
import QtQuick.Layouts
import qs.Commons

import "../Model.js" as Model

Item {
    id: row

    property var entry: ({})
    property bool selected: false
    property string giteaUrl: ""

    signal openPr()
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
        onClicked: row.openPr()
    }

    ColumnLayout {
        id: contentLayout
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(4)

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Rectangle {
                width: Style.space(8); height: Style.space(8); radius: Style.space(4)
                color: {
                    switch (row.entry.status_label) {
                        case "ci_failed": return Color.urgent;
                        case "changes_requested": return Color.urgent;
                        case "review_requested": return Color.accent;
                        case "ci_running": return Color.accent;
                        case "approved_ci_passed":
                        case "approved": return Color.foreground;
                        case "ci_passed": return Color.accent;
                        case "draft": return Color.muted;
                        case "conflicted": return Color.accent;
                        default: return Color.muted;
                    }
                }

                SequentialAnimation on opacity {
                    running: row.entry.status_label === "ci_running"
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.minimumWidth: Style.space(60)
                text: row.entry.title || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.weight: row.entry.needs_attention ? Font.DemiBold : Font.Normal
                color: Color.foreground
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Rectangle {
                visible: row.entry.draft === true
                width: draftText.implicitWidth + Style.space(8)
                height: draftText.implicitHeight + Style.space(4)
                radius: Style.space(2)
                color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.15)
                Text {
                    id: draftText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "draft"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    color: Color.muted
                }
            }

            Rectangle {
                visible: row.entry.status_label === "conflicted"
                width: conflictText.implicitWidth + Style.space(8)
                height: conflictText.implicitHeight + Style.space(4)
                radius: Style.space(2)
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                Text {
                    id: conflictText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "conflicts"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    color: Color.accent
                }
            }

            Text {
                textFormat: Text.PlainText
                text: "#" + (row.entry.id || "")
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: "\u2192"
                font.pixelSize: Style.font.bodySmall
                color: Color.muted
                opacity: 0.7
            }

            Text {
                textFormat: Text.PlainText
                text: row.entry.branch || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.foreground
                Layout.maximumWidth: Style.space(120)
                Layout.minimumWidth: Style.space(30)
                elide: Text.ElideRight
            }

            Item { Layout.fillWidth: true }

            Text {
                textFormat: Text.PlainText
                text: row.entry.author || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
                elide: Text.ElideRight
                Layout.minimumWidth: Style.space(30)
            }

            Text {
                textFormat: Text.PlainText
                text: Model.timeAgo(row.entry.updated)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            visible: hasReviewInfo || hasCiInfo || !!row.entry.blocker

            property bool hasReviewInfo: row.entry.reviews && (row.entry.reviews.approved > 0 || row.entry.reviews.changes_requested > 0)
            property bool hasCiInfo: row.entry.ci && row.entry.ci.total > 0

            Row {
                spacing: Style.space(4)
                visible: parent.hasReviewInfo

                Text {
                    textFormat: Text.PlainText
                    text: {
                        var parts = [];
                        if (row.entry.reviews.approved > 0) parts.push("\u2713 " + row.entry.reviews.approved);
                        if (row.entry.reviews.changes_requested > 0) parts.push("\u2718 " + row.entry.reviews.changes_requested);
                        return parts.join("  ");
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: row.entry.reviews.changes_requested > 0 ? Color.urgent : Color.foreground
                }
            }

            Row {
                spacing: Style.space(3)
                visible: parent.hasCiInfo

                Text {
                    textFormat: Text.PlainText
                    text: {
                        if (!row.entry.ci) return "";
                        return row.entry.ci.passed + "/" + row.entry.ci.total + " checks";
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: {
                        if (!row.entry.ci) return Color.muted;
                        if (row.entry.ci.failed > 0) return Color.urgent;
                        if (row.entry.ci.pending_count > 0) return Color.accent;
                        return Color.foreground;
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                textFormat: Text.PlainText
                visible: !!row.entry.blocker
                text: row.entry.blocker || ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.italic: true
                color: Color.urgent
                Layout.maximumWidth: Style.space(200)
                Layout.minimumWidth: Style.space(40)
                elide: Text.ElideRight
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: Style.space(4)
            visible: row.entry.labels && row.entry.labels.length > 0

            Repeater {
                model: row.entry.labels || []
                Rectangle {
                    width: labelText.implicitWidth + Style.space(8)
                    height: labelText.implicitHeight + Style.space(3)
                    radius: Style.space(2)
                    color: modelData.color ? ("#" + modelData.color) : Color.popups.background
                    opacity: 0.9

                    Text {
                        id: labelText
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: modelData.name || ""
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        color: Color.foreground
                    }
                }
            }
        }
    }
}
