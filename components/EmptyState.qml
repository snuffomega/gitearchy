import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: empty

    property string section: "attention"

    implicitHeight: col.implicitHeight

    ColumnLayout {
        id: col
        anchors.centerIn: parent
        spacing: Style.space(8)

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            text: {
                switch (section) {
                    case "attention": return "\u2713";
                    case "running": return "\u25CB";
                    case "completed": return "\u2014";
                    default: return "\u2022";
                }
            }
            font.pixelSize: Style.font.display
            color: Color.muted
            opacity: 0.5
        }

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            text: {
                switch (section) {
                    case "attention": return "Nothing needs attention";
                    case "running": return "No jobs running";
                    case "completed": return "No recent completions";
                    case "my_prs": return "No open PRs";
                    case "review": return "No reviews requested";
                    case "all": return "No open pull requests";
                    default: return "Nothing here";
                }
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            color: Color.muted
        }

        Text {
            textFormat: Text.PlainText
            Layout.alignment: Qt.AlignHCenter
            visible: section === "attention"
            text: "All clear \u2014 your repos are healthy"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            color: Color.muted
        }
    }
}
