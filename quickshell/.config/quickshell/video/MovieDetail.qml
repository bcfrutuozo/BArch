import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One movie (video.py movie): the file and what is in it, the checklist, the profile (4K / 1080p),
// what the PT-BR pipeline did, and the actions: Search now, Releases (interactive), Radarr's page.
Rectangle {
    id: d
    color: Ui.base
    readonly property var m: Store.movie

    Flickable {
        anchors.fill: parent
        anchors.margins: 14
        contentHeight: col.implicitHeight
        clip: true
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: col
            width: parent.width
            spacing: 10
            Text { visible: !d.m; text: "Reading Radarr…"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            RowLayout {
                visible: !!d.m
                Layout.fillWidth: true
                spacing: 12
                Poster { source: d.m ? d.m.poster : ""; title: d.m ? d.m.title : ""; Layout.preferredWidth: 92; Layout.preferredHeight: 138 }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text { Layout.fillWidth: true; text: d.m ? d.m.title + " (" + d.m.year + ")" : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; wrapMode: Text.WordWrap }
                    Text { Layout.fillWidth: true; text: d.m ? "original: " + (d.m.original || "?") + " · " + d.m.profile + (d.m.monitored ? "" : " · not monitored") : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap }
                    Checks { check: d.m ? d.m.check : null; visible: !!d.m && d.m.has_file }
                    RowLayout {
                        spacing: 4
                        Text { text: "Profile"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { small: true; label: "4K"; primary: !!d.m && d.m.profile === "BArch 4K"; onClicked: Store.setProfile("movie", d.m.id, "4k") }
                        UiButton { small: true; label: "1080p"; primary: !!d.m && d.m.profile === "BArch 1080p"; onClicked: Store.setProfile("movie", d.m.id, "1080p") }
                    }
                }
            }
            Text { visible: !!d.m && d.m.overview !== ""; Layout.fillWidth: true; text: d.m ? d.m.overview : ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap }

            Card {
                visible: !!d.m
                title: d.m && d.m.has_file ? "File" : "No file yet"
                subtitle: d.m && d.m.has_file ? d.m.quality + " · " + Store.gb(d.m.size_gb) : d.m && d.m.queue ? "downloading " + d.m.queue.progress + " % (" + d.m.queue.timeleft + ")" : "Radarr is looking for a release that fits " + (d.m ? d.m.profile : "")
                Text { visible: !!d.m && d.m.has_file; Layout.fillWidth: true; text: d.m ? d.m.file : ""; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WrapAnywhere }
                ColumnLayout {
                    visible: !!d.m && !!d.m.media
                    Layout.fillWidth: true
                    spacing: 2
                    Repeater {
                        model: d.m && d.m.media ? [
                            ["video", [d.m.media.resolution, d.m.media.codec, d.m.media.hdr].filter(x => x).join(" · ") + (d.m.media.bitrate ? " · " + Math.round(d.m.media.bitrate / 1e6) + " Mb/s" : "")],
                            ["audio", d.m.media.audio + " · " + d.m.media.audio_codec + (d.m.media.channels ? " " + d.m.media.channels : "")],
                            ["subtitles", d.m.media.subs || "none"],
                            ["runtime", d.m.media.runtime]] : []
                        RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.preferredWidth: 64; text: modelData[0]; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { Layout.fillWidth: true; text: modelData[1] || "?"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap }
                        }
                    }
                }
            }

            Card {
                visible: !!d.m
                title: "PT-BR dub"
                subtitle: !d.m ? "" : d.m.dub === "" ? (d.m.check && d.m.check.por_audio ? "the file already has PT-BR audio" : "no job yet (the pipeline takes the movie once Radarr imports a file)")
                        : d.m.dub + (d.m.dub_reason ? ": " + d.m.dub_reason : "")
                headerItems: [
                    Badge { visible: !!d.m && d.m.dub !== ""; text: d.m ? d.m.dub : ""; tint: Store.dubTint(d.m ? d.m.dub : "") },
                    UiButton { visible: !!d.m && d.m.dub !== ""; small: true; label: "Open"; onClicked: { Store.openDub("m" + d.m.id); Store.navigate("dub") } }
                ]
            }

            RowLayout {
                visible: !!d.m
                spacing: 6
                UiButton { label: "Search now"; icon: "󰍉"; tooltip: "Radarr searches every indexer and grabs the best release that fits"; onClicked: Store.searchNow({ kind: "movie", id: d.m.id, label: d.m.title }) }
                UiButton { label: "Releases"; icon: "󰒺"; primary: true; tooltip: "every release the indexers have, ranked, to pick one by hand"; onClicked: Store.findReleases({ kind: "movie", id: d.m.id, label: d.m.title }) }
                UiButton { label: "Radarr"; icon: "󰏌"; small: true; onClicked: Store.openUrl("https://radarr.frutuozo.com.br/movie/" + d.m.tmdb) }
                UiButton { visible: !!d.m && d.m.imdb !== ""; label: "IMDb"; icon: "󰏌"; small: true; onClicked: Store.openUrl("https://www.imdb.com/title/" + d.m.imdb) }
            }
            ReleasesView { Layout.fillWidth: true; visible: Store.relTarget !== null && Store.relTarget.kind === "movie" }
        }
    }
}
