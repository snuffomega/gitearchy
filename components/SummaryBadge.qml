import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: badge

    property string label: ""
    property int count: 0
    property color accent: Color.muted
    property bool active: false

    signal clicked()

    implicitWidth: badgeRow.implicitWidth + Style.space(12)
    implicitHeight: Style.space(24)

    Rectangle {
        anchors.fill: parent
        radius: Style.space(3)
        color: {
            if (active) return Qt.rgba(accent.r, accent.g, accent.b, 0.15);
            if (mouseArea.containsMouse) return Qt.rgba(accent.r, accent.g, accent.b, 0.08);
            return "transparent";
        }
        border.color: active ? Qt.rgba(accent.r, accent.g, accent.b, 0.3) : "transparent"
        border.width: active ? 1 : 0

        Behavior on color { ColorAnimation { duration: 100 } }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: badge.clicked()
    }

    RowLayout {
        id: badgeRow
        anchors.centerIn: parent
        spacing: Style.space(4)

        Text {
            text: badge.count.toString()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.weight: badge.active ? Font.DemiBold : Font.Normal
            color: badge.count > 0 ? badge.accent : Color.muted
        }

        Text {
            text: badge.label
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: badge.active ? Color.foreground : Color.muted
        }
    }
}
