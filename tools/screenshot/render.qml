import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "app"
import "app/Model.js" as Model

// Opens the real panel on a demo snapshot and saves it as an image.
// Driven by render.sh, which sets GITEARCHY_DEMO, GITEARCHY_OUT and
// GITEARCHY_SECTION.
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 700
        implicitHeight: 1000
        color: "transparent"

        Item { id: anchorBox; x: 600; y: 0; width: 40; height: 22 }

        QtObject {
            id: demoBar
            property int dataRevision: 0
            property var hiddenRepos: ({})
            property bool hasError: false
            property bool stale: false
            property string errorMsg: ""
            property string giteaUrl: ""
            property bool hiddenSaveFailed: false
            function refresh() {}
            function close() {}
            function setHiddenRepos(list) {}
        }

        FileView {
            path: Quickshell.env("GITEARCHY_DEMO")
            onLoaded: {
                Model.parseOverview(text());
                demoBar.dataRevision++;
                panelLoader.active = true;
            }
        }

        Loader {
            id: panelLoader
            active: false
            sourceComponent: Component {
                Panel {
                    anchorItem: anchorBox
                    bar: null
                    owner: demoBar
                    open: true
                    barWidget: demoBar
                }
            }
        }

        // The theme and font settings load asynchronously; wait for them.
        Timer {
            interval: 2500
            running: true
            onTriggered: {
                panelLoader.item.updateSection(Quickshell.env("GITEARCHY_SECTION") || "all");
                grabTimer.start();
            }
        }

        // Lets the list resize to the new section's cards before the grab.
        Timer {
            id: grabTimer
            interval: 800
            onTriggered: {
                var card = panelLoader.item.contentItem[0].parent.parent;
                // Rendered at 2x for a sharp README image.
                card.grabToImage(function(result) {
                    result.saveToFile(Quickshell.env("GITEARCHY_OUT"));
                    Qt.quit();
                }, Qt.size(card.width * 2, card.height * 2));
            }
        }
    }
}
