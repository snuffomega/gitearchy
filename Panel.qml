import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui as Ui

import "Model.js" as Model
import "components"

Ui.PopupCard {
    id: panel

    property var barWidget: null
    property string activeSection: "attention"
    property string repoFilter: ""
    property int selectedIndex: 0
    property bool isRefreshing: false
    // Showing the repository picker instead of the work lists.
    property bool pickerOpen: false
    // Key hints start collapsed on every open; never remembered (#14).
    property bool hintsOpen: false
    property int dataRev: barWidget ? barWidget.dataRevision : 0
    // Display choices live here and on the bar widget, never in Model.js,
    // so each panel opens unfocused and monitors do not share a focus.
    readonly property var view: ({
        hidden: barWidget ? barWidget.hiddenRepos : ({}),
        focus: repoFilter
    })

    // Wide enough for a card's repo, branch, author, and age on one line;
    // fittedContentWidth keeps it on narrow screens.
    contentWidth: fittedContentWidth(Style.space(540))
    // fittedContentHeight adds the card's own padding and border, then
    // clamps to the cap and the screen's available height.
    contentHeight: fittedContentHeight(contentCol.implicitHeight, Style.space(900))

    Component.onCompleted: {
        contentCol.forceActiveFocus();
        updateSection("attention");
    }

    function updateSection(section) {
        activeSection = section;
        selectedIndex = 0;
        populateList();
    }

    function setRepoFilter(repo) {
        repoFilter = repo;
        selectedIndex = 0;
        populateList();
    }

    function populateList() {
        // A focused repository that has since been hidden or gone quiet
        // would leave every section empty with no chip to clear it.
        if (repoFilter && Model.visibleRepos(view.hidden).indexOf(repoFilter) === -1) {
            repoFilter = "";
        }
        listModel.clear();
        var itemType = (activeSection === "running" || activeSection === "completed") ? "job" : "pr";
        var items = Model.sectionItems(activeSection, view);
        for (var i = 0; i < items.length; i++) {
            listModel.append({ itemData: JSON.stringify(items[i]), itemType: itemType });
        }
        selectedIndex = Math.max(0, Math.min(selectedIndex, listModel.count - 1));
    }

    function openSelected() {
        if (selectedIndex < 0 || selectedIndex >= listModel.count) return;
        var item = JSON.parse(listModel.get(selectedIndex).itemData);
        if (item.url) Qt.openUrlExternally(item.url);
    }

    function openRepo(repo) {
        var meta = Model.getMeta();
        if (meta && meta.gitea_url && repo) {
            Qt.openUrlExternally(meta.gitea_url + "/" + repo);
        }
    }

    onDataRevChanged: populateList()

    function setPickerOpen(open) {
        pickerOpen = open;
        contentCol.forceActiveFocus();
        if (!open) populateList();
    }

    property var sectionOrder: ["attention", "running", "completed", "my_prs", "review", "all"]

    function cycleSectionNext() {
        var idx = sectionOrder.indexOf(activeSection);
        updateSection(sectionOrder[(idx + 1) % sectionOrder.length]);
    }
    function cycleSectionPrev() {
        var idx = sectionOrder.indexOf(activeSection);
        updateSection(sectionOrder[(idx - 1 + sectionOrder.length) % sectionOrder.length]);
    }

    function badgeCount(section) {
        void dataRev;
        return Model.sectionItems(section, view).length;
    }

    Item {
        visible: false

        Timer {
            id: refreshTimer
            interval: 2000
            onTriggered: isRefreshing = false
        }

        ListModel { id: listModel }
    }

    ColumnLayout {
        id: contentCol
        anchors.fill: parent
        spacing: Style.space(8)
        focus: true

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Question) {
                panel.hintsOpen = !panel.hintsOpen;
                event.accepted = true;
                return;
            }
            if (panel.pickerOpen) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_S) {
                    panel.setPickerOpen(false);
                    event.accepted = true;
                } else if (repoPicker.handleKey(event)) {
                    event.accepted = true;
                }
                return;
            }
            switch (event.key) {
            case Qt.Key_S:
                panel.setPickerOpen(true);
                event.accepted = true; break;
            case Qt.Key_J:
            case Qt.Key_Down:
                panel.selectedIndex = Math.min(panel.selectedIndex + 1, listModel.count - 1);
                event.accepted = true; break;
            case Qt.Key_K:
            case Qt.Key_Up:
                panel.selectedIndex = Math.max(panel.selectedIndex - 1, 0);
                event.accepted = true; break;
            case Qt.Key_G:
                if (event.modifiers & Qt.ShiftModifier) panel.selectedIndex = listModel.count - 1;
                else panel.selectedIndex = 0;
                event.accepted = true; break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                panel.openSelected();
                event.accepted = true; break;
            case Qt.Key_H:
            case Qt.Key_Left:
                panel.cycleSectionPrev();
                event.accepted = true; break;
            case Qt.Key_L:
            case Qt.Key_Right:
                panel.cycleSectionNext();
                event.accepted = true; break;
            case Qt.Key_R:
                if (panel.barWidget) panel.barWidget.refresh();
                panel.isRefreshing = true;
                refreshTimer.restart();
                event.accepted = true; break;
            case Qt.Key_Escape:
                panel.close();
                event.accepted = true; break;
            case Qt.Key_Tab:
                event.accepted = true; break;
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
                textFormat: Text.PlainText
                text: "Gitea"
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.weight: Font.DemiBold
                color: Color.foreground
            }

            Text {
                textFormat: Text.PlainText
                text: {
                    void panel.dataRev;
                    var meta = Model.getMeta();
                    return meta ? meta.username : "";
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                color: Color.muted
                visible: text !== ""
            }

            Item { Layout.fillWidth: true }

            Text {
                textFormat: Text.PlainText
                text: panel.pickerOpen ? "Done" : "Repos"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.underline: pickerToggleMouse.containsMouse
                color: Color.accent

                MouseArea {
                    id: pickerToggleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.setPickerOpen(!panel.pickerOpen)
                }
            }

            Text {
                textFormat: Text.PlainText
                visible: barWidget && barWidget.stale
                text: "stale"
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.accent
                opacity: 0.8
            }

            Text {
                textFormat: Text.PlainText
                text: isRefreshing ? "refreshing\u2026" : ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
                visible: isRefreshing

                SequentialAnimation on opacity {
                    running: isRefreshing
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 500 }
                    NumberAnimation { to: 1.0; duration: 500 }
                }
            }

            Text {
                textFormat: Text.PlainText
                text: {
                    void panel.dataRev;
                    var meta = Model.getMeta();
                    return meta ? Model.timeAgo(meta.collected_at) : "";
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.muted
            }

            Text {
                textFormat: Text.PlainText
                text: {
                    void panel.dataRev;
                    var meta = Model.getMeta();
                    if (meta && meta.repo_failed > 0) return meta.repo_failed + " repo(s) unreachable";
                    return "";
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.accent
                visible: text !== ""
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Color.popups.border
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: !panel.pickerOpen && (!barWidget || !barWidget.hasError)

            SummaryBadge {
                label: "Attention"
                count: panel.badgeCount("attention")
                accent: Color.urgent
                active: activeSection === "attention"
                onClicked: updateSection("attention")
            }
            SummaryBadge {
                label: "Running"
                count: panel.badgeCount("running")
                accent: Color.accent
                active: activeSection === "running"
                onClicked: updateSection("running")
            }
            SummaryBadge {
                label: "Completed"
                count: panel.badgeCount("completed")
                accent: Color.muted
                active: activeSection === "completed"
                onClicked: updateSection("completed")
            }
            SummaryBadge {
                label: "My PRs"
                count: panel.badgeCount("my_prs")
                accent: Color.accent
                active: activeSection === "my_prs"
                onClicked: updateSection("my_prs")
            }
            SummaryBadge {
                label: "Review"
                count: panel.badgeCount("review")
                accent: Color.accent
                active: activeSection === "review"
                onClicked: updateSection("review")
            }
            SummaryBadge {
                label: "All"
                count: panel.badgeCount("all")
                accent: Color.foreground
                active: activeSection === "all"
                onClicked: updateSection("all")
            }

            Item { Layout.fillWidth: true }
        }

        RepoFilter {
            id: repoFilterBar
            Layout.fillWidth: true
            repos: { void panel.dataRev; return Model.visibleRepos(panel.view.hidden); }
            currentFilter: panel.repoFilter
            onFilterChanged: function(repo) { panel.setRepoFilter(repo) }
            visible: !panel.pickerOpen && repos.length > 1
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Color.popups.border
            visible: !panel.pickerOpen && listModel.count > 0
        }

        RepoPicker {
            id: repoPicker
            Layout.fillWidth: true
            visible: panel.pickerOpen
            hidden: barWidget ? barWidget.hiddenRepos : ({})
            dataRev: panel.dataRev
            saveFailed: barWidget ? barWidget.hiddenSaveFailed : false
            onHiddenListChanged: function(list) { if (panel.barWidget) panel.barWidget.setHiddenRepos(list) }
            onLeaveSearch: contentCol.forceActiveFocus()
        }

        ErrorState {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !panel.pickerOpen && barWidget && barWidget.hasError
            message: barWidget ? barWidget.errorMsg : "Unknown error"
            giteaUrl: barWidget ? barWidget.giteaUrl : ""
        }

        EmptyState {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !panel.pickerOpen && (!barWidget || (!barWidget.hasError && listModel.count === 0))
            section: activeSection
        }

        ListView {
            id: itemList
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Sized from the real card heights, so a lone card is never
            // clipped; past about five cards the list scrolls.
            Layout.preferredHeight: visible ? Math.min(contentHeight, Style.space(430)) : 0
            visible: !panel.pickerOpen && listModel.count > 0 && !(barWidget && barWidget.hasError)
            model: listModel
            currentIndex: panel.selectedIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                width: Style.space(4)
            }

            delegate: Loader {
                width: itemList.width
                property var parsedData: JSON.parse(itemData)
                property bool isSelected: index === panel.selectedIndex

                sourceComponent: itemType === "pr" ? prRowComponent : jobRowComponent

                Component {
                    id: prRowComponent
                    PrRow {
                        entry: parsedData
                        selected: isSelected
                        giteaUrl: {
                            void panel.dataRev;
                            var meta = Model.getMeta();
                            return meta ? meta.gitea_url : "";
                        }
                        onOpenPr: Qt.openUrlExternally(entry.url)
                        onOpenRepo: panel.openRepo(entry.repo)
                    }
                }

                Component {
                    id: jobRowComponent
                    JobRow {
                        entry: parsedData
                        selected: isSelected
                        onOpenJob: Qt.openUrlExternally(entry.url)
                        onOpenRepo: panel.openRepo(entry.repo)
                    }
                }
            }
        }

        Item {
            id: hintsBar
            Layout.fillWidth: true
            implicitHeight: Math.max(hintsRow.implicitHeight, hintsToggle.implicitHeight)

            // Centered on the panel, but pushed left of the toggle when it
            // would overlap (#14).
            Row {
                id: hintsRow
                visible: panel.hintsOpen
                spacing: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min((hintsBar.width - width) / 2,
                                        hintsToggle.x - Style.space(12) - width))

                Repeater {
                    model: !panel.hintsOpen ? [] : panel.pickerOpen ? [
                        { key: "j/k", action: "navigate" },
                        { key: "space", action: "show/hide" },
                        { key: "/", action: "filter" },
                        { key: "esc", action: "back" }
                    ] : [
                        { key: "j/k", action: "navigate" },
                        { key: "h/l", action: "sections" },
                        { key: "\u21B5", action: "open" },
                        { key: "s", action: "repos" },
                        { key: "r", action: "refresh" }
                    ]
                    Row {
                        spacing: Style.space(3)
                        Text {
                            textFormat: Text.PlainText
                            text: modelData.key
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            color: Color.foreground
                            opacity: 0.85
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: modelData.action
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            color: Color.muted
                        }
                    }
                }
            }

            Text {
                id: hintsToggle
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: (panel.hintsOpen ? "\u203A" : "\u2039") + " keys"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.underline: hintsToggleMouse.containsMouse
                color: Color.muted

                MouseArea {
                    id: hintsToggleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.hintsOpen = !panel.hintsOpen
                }
            }
        }
    }
}
