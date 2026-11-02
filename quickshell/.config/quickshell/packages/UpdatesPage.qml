import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// pending updates, .pacnew files, and what the repo lists still miss
Item {
    id: page

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12

            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: Store.checking ? "Checking for updates…" : Store.updates.length ? Store.updates.length + " update" + (Store.updates.length === 1 ? "" : "s") + " pending" : "Everything up to date"
                subtitle: "checkupdates (repositories) and paru -Qua (AUR). Update All is the bar's: Arch news first, then Claude's review of the AUR PKGBUILD diffs, then paru -Syu and the kernel."
                headerItems: [
                    UiButton { label: "Update All"; icon: "󰚰"; primary: true; small: true; enabledBtn: Store.updates.length > 0; onClicked: Store.updateAll() },
                    UiButton { icon: "󰑐"; small: true; tooltip: "check again"; onClicked: Store.refreshUpdates() }
                ]
                Repeater {
                    model: Store.updates
                    RowLayout {
                        id: ur
                        required property var modelData
                        spacing: 10
                        Text { Layout.preferredWidth: 260; text: ur.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Badge { visible: ur.modelData.aur; text: "AUR"; tint: Ui.yellow }
                        Text { Layout.fillWidth: true; text: ur.modelData.from + "  →  " + ur.modelData.to; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        Text { text: (Store.packages[ur.modelData.name] || { description: "" }).description; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight; Layout.preferredWidth: 360 }
                    }
                }
            }

            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: Store.pacnew.length ? Store.pacnew.length + " .pacnew / .pacsave file" + (Store.pacnew.length === 1 ? "" : "s") : "No .pacnew files"
                subtitle: "config files pacman could not replace; pacdiff merges them (terminal, sudo)"
                headerItems: [ UiButton { label: "pacdiff"; small: true; enabledBtn: Store.pacnew.length > 0; onClicked: Store.pacdiff() } ]
                Repeater {
                    model: Store.pacnew
                    Text { required property var modelData; text: modelData; color: Ui.yellow; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                }
            }

            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: Store.unsavedCount ? "Repo lists out of date (" + Store.unsavedCount + ")" : "Repo lists match the system"
                subtitle: "packages/pacman.txt and aur.txt (what a fresh install gets) against what is explicitly installed now. sync.sh regenerates them; this button does it now (then save with sync.sh)."
                headerItems: [ UiButton { label: "Update lists"; icon: "󰑐"; small: true; enabledBtn: Store.unsavedCount > 0; onClicked: Store.updateLists() } ]
                Repeater {
                    model: [
                        { label: "installed, not in pacman.txt", list: Store.unsaved.newRepo, tint: Ui.green },
                        { label: "in pacman.txt, not installed", list: Store.unsaved.goneRepo, tint: Ui.red },
                        { label: "installed, not in aur.txt", list: Store.unsaved.newAur, tint: Ui.green },
                        { label: "in aur.txt, not installed", list: Store.unsaved.goneAur, tint: Ui.red }
                    ]
                    RowLayout {
                        required property var modelData
                        visible: modelData.list.length > 0
                        spacing: 8
                        Text { Layout.preferredWidth: 220; text: modelData.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        Text { Layout.fillWidth: true; text: modelData.list.join("  "); color: modelData.tint; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap }
                    }
                }
                RowLayout {
                    spacing: 8
                    Text { text: "ignored in aur.txt (aur-ignore.txt)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; Layout.preferredWidth: 220 }
                    Text { text: Store.lists.ignore.join("  ") || "—"; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                }
            }
            Item { height: 12 }
        }
    }
}
