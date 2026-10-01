import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: errorState

    property string message: ""
    property string giteaUrl: ""

    implicitHeight: col.implicitHeight

    ColumnLayout {
        id: col
        anchors.centerIn: parent
        spacing: Style.space(8)

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            text: "!"
            font.pixelSize: Style.font.display
            font.weight: Font.Bold
            color: Color.urgent
            opacity: 0.5
        }

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            text: message || "Something went wrong"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            color: Color.foreground
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Style.space(300)
        }

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            visible: message.indexOf("credentials") !== -1 || message.indexOf("No credentials") !== -1
            text: "Create ~/.config/gitea-workstatus/credentials\nwith GITEA_URL and GITEA_TOKEN"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Color.muted
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 1.4
        }

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            visible: giteaUrl !== ""
            text: "Open Gitea"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Color.accent
            opacity: linkMouse.containsMouse ? 1.0 : 0.9

            MouseArea {
                id: linkMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally(giteaUrl)
            }
        }
    }
}
