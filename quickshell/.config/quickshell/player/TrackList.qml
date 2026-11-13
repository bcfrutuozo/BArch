pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the rows of tracks every page shows. `tracks` is an array of Store tracks (or { header: true, label } rows
// for a group title); a click plays the list from that row (`activated` when the page wants something else).
// Editable lists (a playlist, the queue) can be reordered by dragging the handle and get a remove button.
Item {
    id: list
    property var tracks: []
    property bool showAlbum: true
    property bool showArtist: true
    property bool showNumber: false        // disc.position instead of the row number
    property bool showGenre: false
    property bool showYear: false
    property bool editable: false          // drag to reorder, remove
    property bool queueMode: false         // the current row is the queue index, not the key
    property string sortCol: ""
    property bool sortDesc: false
    property bool sortable: false
    property string empty: "Nothing here."
    signal activated(int index)
    signal reorder(int from, int to)
    signal remove(int index)
    signal sortBy(string col)
    property var menu: null                // the window's RowMenu
    function menuItems(t, i) { return menu ? menu.trackItems([t.key], list.editable ? [{ label: "Remove", icon: "󰆴", danger: true, action: () => list.remove(i) }] : []) : [] }

    readonly property var playable: tracks.filter(t => !t.header)
    function playFrom(i) {
        if (queueMode) { Player.jumpTo(i); return }
        const t = tracks[i]
        if (!t || t.header) return
        Player.playList(playable, playable.indexOf(t))
    }
    function isCurrent(i, t) { return queueMode ? i === Player.index : (t.key === Player.currentKey && Player.hasTrack) }

    readonly property int rowH: 36
    readonly property int numW: 44
    readonly property int lenW: 56
    readonly property int playsW: 44
    readonly property int likeW: 32
    readonly property int yearW: 52

    component Head: Item {
        id: entry
        property string col: ""
        property string label: ""
        property int align: Text.AlignLeft
        implicitHeight: 24
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: entry.label + (list.sortCol === entry.col && entry.col ? (list.sortDesc ? " 󰅀" : " 󰅃") : "")
            horizontalAlignment: entry.align
            color: list.sortCol === entry.col && entry.col ? Ui.accent : Ui.overlay
            font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; font.bold: true
            elide: Text.ElideRight
        }
        MouseArea { anchors.fill: parent; enabled: list.sortable && parent.col !== ""; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: list.sortBy(parent.col) }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 10; Layout.rightMargin: 22
            spacing: 10
            Head { Layout.preferredWidth: list.numW; col: list.showNumber ? "n" : ""; label: "#"; align: Text.AlignRight }
            Head { Layout.fillWidth: true; col: "title"; label: "Title" }
            Head { visible: list.showAlbum; Layout.preferredWidth: Math.round(list.width * 0.24); col: "album"; label: "Album" }
            Head { visible: list.showGenre; Layout.preferredWidth: 110; col: "genre"; label: "Genre" }
            Head { visible: list.showYear; Layout.preferredWidth: list.yearW; col: "year"; label: "Year" }
            Head { Layout.preferredWidth: list.playsW; col: "plays"; label: "Plays"; align: Text.AlignRight }
            Head { Layout.preferredWidth: list.lenW; col: "length"; label: "Time"; align: Text.AlignRight }
            Item { Layout.preferredWidth: list.likeW + (list.editable ? 28 : 0) }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Ui.surface }
        Text {
            visible: list.tracks.length === 0
            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 30
            text: list.empty; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: list.tracks
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            currentIndex: -1
            property int dragFrom: -1
            property int dragTo: -1
            moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 120 } }

            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool header: !!modelData.header
                readonly property bool current: !header && list.isCurrent(index, modelData)
                width: ListView.view.width
                height: header ? 30 : list.rowH

                // a group title
                Text {
                    visible: row.header
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 10; bottomMargin: 4 }
                    text: row.modelData.label || ""
                    color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true
                }

                Rectangle {
                    visible: !row.header
                    anchors.fill: parent
                    anchors.rightMargin: 12
                    radius: Ui.radius
                    color: row.current ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.14) : (hover.containsMouse ? Ui.faint : "transparent")
                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) list.playFrom(row.index) }
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) { const p = mapToItem(null, mouse.x, mouse.y); if (list.menu) list.menu.show(p.x, p.y, list.menuItems(row.modelData, row.index)) }
                            else list.playFrom(row.index)
                        }
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10; anchors.rightMargin: 10
                        spacing: 10
                        // number, or the playing mark
                        Item {
                            Layout.preferredWidth: list.numW
                            Layout.fillHeight: true
                            Text {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                visible: !(row.current && Player.playing) || hover.containsMouse
                                text: hover.containsMouse ? (row.current && Player.playing ? "󰏤" : "󰐊") : (list.showNumber ? row.modelData.n : String(row.index + 1))
                                color: hover.containsMouse || row.current ? Ui.accent : Ui.overlay
                                font.family: hover.containsMouse ? Ui.iconFont : Ui.monoFont; font.pixelSize: Ui.fontSize - 1
                            }
                            // three bars while it plays
                            Row {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                visible: row.current && Player.playing && !hover.containsMouse
                                spacing: 2
                                Repeater {
                                    model: 3
                                    Rectangle {
                                        id: bar
                                        required property int index
                                        width: 3; radius: 1; color: Ui.accent
                                        anchors.bottom: parent.bottom
                                        height: 6
                                        SequentialAnimation on height {
                                            running: row.current && Player.playing
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 14; duration: 300 + bar.index * 110; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 5; duration: 300 + bar.index * 110; easing.type: Easing.InOutSine }
                                        }
                                    }
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: row.modelData.title || ""
                                color: row.current ? Ui.accent : (row.modelData.error ? Ui.red : Ui.text)
                                font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: list.showArtist && text !== ""
                                text: row.modelData.artist || ""
                                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
                            }
                        }
                        Text {
                            visible: list.showAlbum
                            Layout.preferredWidth: Math.round(list.width * 0.24)
                            text: row.modelData.album || ""
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Store.goAlbum(row.modelData.albumKey) }
                        }
                        Text { visible: list.showGenre; Layout.preferredWidth: 110; text: row.modelData.genre || ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { visible: list.showYear; Layout.preferredWidth: list.yearW; text: row.modelData.year || ""; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        Text {
                            Layout.preferredWidth: list.playsW
                            horizontalAlignment: Text.AlignRight
                            text: Store.plays(row.modelData.key) || ""
                            color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                        }
                        Text {
                            Layout.preferredWidth: list.lenW
                            horizontalAlignment: Text.AlignRight
                            text: Store.time(row.modelData.length)
                            color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                        }
                        IconButton {
                            Layout.preferredWidth: list.likeW
                            size: 26; glyphSize: Ui.fontSize + 1
                            readonly property bool on: Store.liked(row.modelData.key)
                            icon: on ? "󰋑" : "󰋕"
                            active: on
                            tint: hover.containsMouse ? Ui.subtext : "transparent"
                            tooltip: on ? "Unlike" : "Like"
                            onClicked: Store.toggleLike(row.modelData.key)
                        }
                        // drag handle (editable lists)
                        Item {
                            visible: list.editable
                            Layout.preferredWidth: 24
                            Layout.fillHeight: true
                            Text { anchors.centerIn: parent; text: "󰇙"; color: dragArea.containsMouse || dragArea.pressed ? Ui.text : Ui.overlay; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 2 }
                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.SizeVerCursor
                                preventStealing: true
                                property real startY: 0
                                onPressed: mouse => { view.dragFrom = row.index; view.dragTo = row.index; startY = mouse.y }
                                onPositionChanged: mouse => {
                                    if (!pressed || view.dragFrom < 0) return
                                    const y = row.y + mouse.y
                                    const to = Math.max(0, Math.min(list.tracks.length - 1, Math.floor(y / list.rowH)))
                                    if (to !== view.dragTo) view.dragTo = to
                                }
                                onReleased: {
                                    if (view.dragFrom >= 0 && view.dragTo >= 0 && view.dragTo !== view.dragFrom) list.reorder(view.dragFrom, view.dragTo)
                                    view.dragFrom = -1; view.dragTo = -1
                                }
                            }
                        }
                    }
                    // where a dragged row would land
                    Rectangle {
                        visible: view.dragFrom >= 0 && view.dragTo === row.index && view.dragTo !== view.dragFrom
                        anchors { left: parent.left; right: parent.right }
                        y: view.dragTo > view.dragFrom ? parent.height - 1 : 0
                        height: 2
                        color: Ui.accent
                    }
                }
            }
        }
    }
}
