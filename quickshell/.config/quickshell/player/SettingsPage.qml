import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io

// where the music comes from, what the player keeps, the shortcuts
Item {
    id: page
    property bool mprisHere: false
    Process { id: mprisCheck; command: ["sh", "-c", "[ -e /etc/mpv/scripts/mpris.so ] || [ -e /usr/lib/mpv-mpris/mpris.so ]"]; running: true; onExited: (code, status) => page.mprisHere = code === 0 }
    property int clearArmed: 0

    component Row: RowLayout {
        property string label: ""
        property string value: ""
        property color tint: Ui.text
        Layout.fillWidth: true
        spacing: 10
        Text { text: parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; Layout.preferredWidth: 150 }
        Text { Layout.fillWidth: true; text: parent.value; color: parent.tint; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
    }
    component Key: RowLayout {
        property string keys: ""
        property string does: ""
        spacing: 8
        Rectangle { implicitWidth: kt.implicitWidth + 12; implicitHeight: 20; radius: 4; color: Ui.sunken; border.width: 1; border.color: Ui.surface; Text { id: kt; anchors.centerIn: parent; text: parent.parent.keys; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 } }
        Text { text: parent.does; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
    }

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 16; anchors.rightMargin: 16
        contentHeight: col.implicitHeight + 20
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: col
            width: parent.width
            spacing: 12
            Card {
                title: "Library"
                subtitle: "the catalog the pipeline on the NAS keeps of /music (server/music/catalog.py); the albums it delivers show up here by themselves"
                headerItems: [
                    UiButton { icon: "󰑓"; label: "Reload"; small: true; tooltip: "ask the NAS whether anything changed"; enabledBtn: !Store.loading; onClicked: Store.fetchCatalog() },
                    UiButton { icon: "󰑐"; label: "Rescan on the NAS"; small: true; tooltip: "the pipeline reads the album folders whose files changed (it does this every 15 min anyway)"; onClicked: Store.refreshCatalog(false) },
                    UiButton { icon: "󰑐"; label: "Full rescan"; small: true; tooltip: "every album read again (some minutes on the NAS; the catalog grows as it goes)"; onClicked: Store.refreshCatalog(true) }
                ]
                Row { label: "albums · tracks"; value: Store.albumCount + " · " + Store.trackCount + " · " + Store.hours(Store.totalLength) }
                Row { label: "artists · genres"; value: Store.artists.length + " · " + Store.genres.length }
                Row { label: "catalog"; value: "version " + Store.version + (Store.scanned ? ", read " + Store.when(Store.scanned) : "") + (Store.scanning ? " · the NAS is reading it now" : "") + (Store.loading ? " · downloading" : "") }
                Row { label: "pipeline API"; value: Store.configured ? Store.url + (Store.reachable ? "" : "  (not reachable)") : "not configured: run barch music install"; tint: Store.configured && Store.reachable ? Ui.text : Ui.red }
                Row { label: "audio from"; value: Store.mounted ? "the NAS share, " + Store.mount : "the API (the share is not mounted: " + Store.mount + ")"; tint: Store.mounted ? Ui.green : Ui.yellow }
                Row { label: "cache"; value: Store.cacheDir + "/catalog.json (+ lyrics/)" }
            }
            Card {
                title: "Playback"
                subtitle: "mpv started by the app (mpv.sh), audio only, gapless, driven over its IPC socket; the bar's media island and playerctl see it through mpv-mpris"
                Row { label: "mpv"; value: Player.ready ? "connected · " + Player.sock : "starting…"; tint: Player.ready ? Ui.green : Ui.yellow }
                Row { label: "MPRIS"; value: page.mprisHere ? "mpv-mpris loaded: the media island, playerctl and voice commands work" : "mpv-mpris is not installed: sudo pacman -S mpv-mpris (then reopen the player)"; tint: page.mprisHere ? Ui.green : Ui.yellow }
                Row { label: "now"; value: Player.hasTrack ? Player.current.title + " · " + Player.current.artist + " · " + Player.current.bits + "-bit " + (Player.current.rate / 1000) + " kHz" : "nothing playing" }
                Row { label: "volume · shuffle · repeat"; value: Math.round(Player.volume) + "% · " + (Player.shuffle ? "on" : "off") + " · " + Player.repeat }
            }
            Card {
                title: "Plex & Tautulli"
                subtitle: "what plays here is reported to Plex as a Plex client's timeline, through the pipeline on the NAS (the token stays there): Plex counts the play, Now Playing shows it, Tautulli writes it in its history as the player \"BArch Player\" on this machine"
                headerItems: [
                    UiSwitch { checked: Player.plexOn; onToggled: v => Store.edit(s => { s.plex = v }) }
                ]
                Row { label: "last report"; value: Player.plexOn ? (Player.plexStatus || "nothing reported yet") : "off"; tint: Player.plexBad ? Ui.yellow : Ui.text }
                Row { label: "this machine"; value: Player.device + " · client barch-player-" + Player.device }
                Row { label: "check"; value: "barch player plex (the last report, the sessions Plex shows)" }
            }
            Card {
                title: "What the player keeps"
                subtitle: Store.stateDir + "/state.json: likes, play counts, the history, playlists, the last queue (in the daily backup with the rest of ~/.local/state)"
                headerItems: [
                    UiButton {
                        danger: true; small: true; icon: "󰆴"
                        label: page.clearArmed ? "Click again to clear the history" : "Clear history"
                        tooltip: "forgets every play and play count; likes and playlists stay"
                        onClicked: { if (page.clearArmed) { Store.edit(s => { s.history = []; s.plays = {}; s.lastPlayed = {} }); page.clearArmed = 0; Store.say("history cleared") } else { page.clearArmed = 1; disarm.restart() } }
                        Timer { id: disarm; interval: 4000; onTriggered: page.clearArmed = 0 }
                    }
                ]
                Row { label: "liked tracks"; value: Object.keys(Store.state.likes || {}).length }
                Row { label: "plays"; value: (Store.state.history || []).length + " in the history · " + Object.keys(Store.state.plays || {}).length + " tracks played" }
                Row { label: "playlists"; value: Store.playlists.length + " (" + Store.playlists.filter(p => p.smart).length + " smart)" }
            }
            Card {
                title: "Window"
                subtitle: "the music does not depend on the window: closed (the X, Ctrl+W, Super+W), it keeps playing and a button next to the bar's tray brings it back (middle click pauses, right click quits)"
                headerItems: [
                    UiButton { danger: true; small: true; icon: "󰗼"; label: "Quit the player"; tooltip: "stops the music and ends the process (Ctrl+Q)"; onClicked: Qt.quit() }
                ]
                RowLayout {
                    spacing: 10
                    UiSwitch { checked: Store.state.closeHides !== false; onToggled: v => Store.edit(s => { s.closeHides = v }) }
                    Text { text: "Closing the window keeps the music playing"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: "(with nothing playing it quits; a closed window with nothing playing for a minute quits too)"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                }
            }
            Card {
                title: "Keyboard"
                GridLayout {
                    columns: 3
                    columnSpacing: 24; rowSpacing: 6
                    Key { keys: "Space"; does: "play / pause" }
                    Key { keys: "N · P"; does: "next · previous" }
                    Key { keys: "← →"; does: "seek 5 s" }
                    Key { keys: "S · R"; does: "shuffle · repeat" }
                    Key { keys: "+ −"; does: "volume 5 %" }
                    Key { keys: "M"; does: "mute" }
                    Key { keys: "L"; does: "like the track playing" }
                    Key { keys: "/ · Ctrl+F"; does: "search" }
                    Key { keys: "Q"; does: "the queue" }
                    Key { keys: "Y"; does: "lyrics" }
                    Key { keys: "V · E"; does: "visualizer · equalizer" }
                    Key { keys: "Esc"; does: "back / close the album" }
                    Key { keys: "Ctrl+W"; does: "close the window, the music goes on" }
                    Key { keys: "Ctrl+Q"; does: "quit (stops the music)" }
                }
            }
            Card {
                title: "From a shell"
                Text { text: "barch player [browse] [albums|artists|tracks|genres|queue|favorites|recent|lyrics|stats|viz|eq|settings]\nbarch player play|pause|toggle|next|prev|stop|status · volume <0-100> · seek <±s> · like\nbarch player album \"Artist/Album\" · queue \"Artist/Album\" · search \"text\"\nplayerctl -p mpv play-pause  (with mpv-mpris)"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
            }
        }
    }
}
