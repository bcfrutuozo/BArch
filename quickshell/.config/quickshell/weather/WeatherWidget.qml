// WeatherWidget.qml — clima ao lado do relógio (Open-Meteo, sem chave).
// Na barra: ícone do tempo + temperatura atual.
// Clique: painel com o tempo agora, as próximas horas, os próximos dias e o nascer/pôr do sol.
// Atualiza a cada 15 min. A cidade fica em "city" (e o país em "country").

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    property string city: "Tatuí"
    property string country: "BR"
    property int refreshMinutes: 15

    // ---------- aviso de chuva ----------
    // Com chuva prevista para a próxima ~1h30 (chance >= rainThreshold), manda uma notificação
    // (uma vez por horário previsto) e mostra um guarda-chuva ao lado da temperatura.
    // Não avisa se já estiver chovendo.
    property int rainThreshold: 60
    property var rainSoon: null              // { time: "15:00", prob: 80, hourKey }
    property string lastRainKey: ""
    readonly property string rainStatePath: Quickshell.env("HOME") + "/.local/state/quickshell/rain-notified"

    function isRainCode(c) { return (c >= 51 && c <= 67) || (c >= 80 && c <= 82) || c >= 95 }

    function checkRain(d) {
        if (!d || !d.hourly || isRainCode(d.current.code)) { rainSoon = null; return }
        const now = new Date()
        let found = null
        for (const h of d.hourly) {
            const t = new Date(h.time)               // "2026-10-27T15:00": hora local
            const mins = (t - now) / 60000
            if (mins < -50 || mins > 90) continue    // hora atual até ~1h30 à frente
            if (h.rain >= rainThreshold && (isRainCode(h.code) || h.rain >= 80)) {
                found = { time: Qt.formatTime(t, "HH:mm"), prob: h.rain, hourKey: h.time, past: mins <= 0 }
                break
            }
        }
        rainSoon = found
        if (found && found.hourKey !== lastRainKey) {
            lastRainKey = found.hourKey
            Theme.writeFile(rainStatePath, found.hourKey)
            Quickshell.execDetached(["notify-send", "-a", "Weather", "-i", "weather-showers",
                "Rain Expected", (found.past ? "Rain likely within the hour" : "Rain expected around " + found.time)
                + "  ·  " + found.prob + "% chance in " + (wx && wx.place ? wx.place.split(",")[0] : "your area")])
        }
    }

    FileView {
        path: root.rainStatePath
        onLoaded: root.lastRainKey = text().trim()
    }

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property var wx: null
    property string error: ""
    readonly property bool ready: wx !== null && wx.current !== undefined

    function glyph(cp) { return String.fromCodePoint(cp) }

    // códigos WMO do Open-Meteo → ícone e descrição
    function iconFor(code, day) {
        if (code === 0 || code === 1) return day ? 0xF0599 : 0xF0594          // sunny / night
        if (code === 2) return day ? 0xF0595 : 0xF0F31                         // partly cloudy
        if (code === 3) return 0xF0590                                         // cloudy
        if (code === 45 || code === 48) return 0xF0591                         // fog
        if (code === 65 || code === 82) return 0xF0596                         // pouring
        if (code === 66 || code === 67) return 0xF067F                         // snowy rainy
        if (code >= 51 && code <= 82 && !(code >= 71 && code <= 77)) return 0xF0597  // rainy
        if ((code >= 71 && code <= 77) || code === 85 || code === 86) return 0xF0598 // snowy
        if (code === 95) return 0xF067E                                        // lightning rainy
        if (code === 96 || code === 99) return 0xF0592                         // hail
        return 0xF0590
    }
    function describe(code) {
        const d = {
            0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
            45: "Fog", 48: "Freezing fog",
            51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
            61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
            71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
            80: "Rain showers", 81: "Rain showers", 82: "Violent showers", 85: "Snow showers", 86: "Snow showers",
            95: "Thunderstorm", 96: "Thunderstorm with hail", 99: "Thunderstorm with hail"
        }
        return d[code] || "—"
    }
    function deg(t) { return Math.round(t) + "°" }
    function hhmm(iso) { return iso ? iso.slice(11, 16) : "" }
    function dayName(iso, i) {
        if (i === 0) return "Today"
        if (i === 1) return "Tomorrow"
        return new Date(iso + "T12:00").toLocaleDateString(Qt.locale("en_US"), "ddd")
    }

    function refresh() { if (!proc.running) proc.running = true }

    Process {
        id: proc
        command: ["bash", Quickshell.shellDir + "/weather/weather.sh", root.city, root.country]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text)
                    if (d.error) { root.error = d.error; return }   // mantém o último dado bom
                    root.wx = d
                    root.error = ""
                    root.checkRain(d)
                    // resumo para a tela de bloqueio (lock/lock-info.sh weather)
                    Theme.writeFile(Quickshell.env("HOME") + "/.cache/quickshell/weather-now.txt",
                        String.fromCodePoint(root.iconFor(d.current.code, d.current.day)) + "\t"
                        + Math.round(d.current.temp) + "°\t" + root.describe(d.current.code) + "\n")
                } catch (e) { root.error = "Unexpected response" }
            }
        }
    }

    Timer {
        interval: root.refreshMinutes * 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
    // sem dado ainda (ex.: sem rede ao ligar): tenta de novo em 1 min
    Timer { interval: 60000; running: !root.ready; repeat: true; onTriggered: root.refresh() }

    // ---------- na barra ----------
    visible: ready
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 4; height: 4; radius: 2
            color: Theme.accent
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.ready ? root.glyph(root.iconFor(root.wx.current.code, root.wx.current.day)) : ""
            color: popup.visible || mouse.containsMouse ? Theme.accent : Theme.fg
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.ready ? root.deg(root.wx.current.temp) : ""
            color: Theme.subtext
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
        }
        // chuva chegando: guarda-chuva em destaque
        Text {
            visible: root.rainSoon !== null
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(0xF054B)   // umbrella_outline
            color: Theme.accent
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 1
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { Popups.toggle(popup); if (Popups.isOpen(popup)) root.refresh() }
    }

    // ---------- painel ----------
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        // centralizado abaixo da ilha do relógio
        anchor.item: root.island
        anchor.rect.x: root.island.width / 2
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Bottom
        implicitWidth: 360
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: Popups.hide(popup)
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                // --- agora ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    Text {
                        text: root.ready ? root.glyph(root.iconFor(root.wx.current.code, root.wx.current.day)) : ""
                        color: Theme.accent
                        font.family: Theme.iconFont
                        font.pixelSize: 44
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: root.ready ? root.deg(root.wx.current.temp) : ""
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize + 15
                            font.bold: true
                        }
                        Text {
                            text: root.ready ? root.describe(root.wx.current.code) : ""
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize
                        }
                        Text {
                            visible: root.rainSoon !== null
                            text: root.rainSoon ? (root.rainSoon.past ? "Rain likely within the hour" : "Rain expected around " + root.rainSoon.time)
                                                  + "  ·  " + root.rainSoon.prob + "%" : ""
                            color: Theme.accent
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.ready ? root.wx.place : ""
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                        }
                    }
                }

                // sensação · umidade · vento
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        model: root.ready ? [
                            { g: 0xF050F, label: "Feels Like", value: root.deg(root.wx.current.feels) },
                            { g: 0xF058E, label: "Humidity", value: Math.round(root.wx.current.humidity) + "%" },
                            { g: 0xF059D, label: "Wind", value: Math.round(root.wx.current.wind) + " km/h" }
                        ] : []
                        ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.glyph(modelData.g) + "  " + modelData.value
                                color: Theme.fg
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize - 1
                            }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData.label
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 3
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

                // --- próximas horas (de 2 em 2) ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        model: root.ready ? root.wx.hourly.filter((h, i) => i > 0 && i % 2 === 0).slice(0, 6) : []
                        ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 3
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.hhmm(modelData.time)
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 3
                            }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.glyph(root.iconFor(modelData.code, modelData.day))
                                color: Theme.fg
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize + 4
                            }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: root.deg(modelData.temp)
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                            }
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData.rain > 0 ? modelData.rain + "%" : " "
                                color: Theme.accent
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 4
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

                // --- próximos dias ---
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    // faixa de temperatura da semana, para as barrinhas
                    readonly property real lo: root.ready ? Math.min(...root.wx.daily.map(d => d.min)) : 0
                    readonly property real hi: root.ready ? Math.max(...root.wx.daily.map(d => d.max)) : 1

                    Repeater {
                        id: days
                        model: root.ready ? root.wx.daily : []
                        RowLayout {
                            id: dayRow
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: 10

                            Text {
                                Layout.preferredWidth: 70
                                text: root.dayName(dayRow.modelData.date, dayRow.index)
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                            }
                            Text {
                                Layout.preferredWidth: 22
                                text: root.glyph(root.iconFor(dayRow.modelData.code, true))
                                color: Theme.fg
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize + 2
                            }
                            Text {
                                Layout.preferredWidth: 34
                                text: dayRow.modelData.rain > 0 ? dayRow.modelData.rain + "%" : ""
                                color: Theme.accent
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 3
                            }
                            Text {
                                Layout.preferredWidth: 30
                                horizontalAlignment: Text.AlignRight
                                text: root.deg(dayRow.modelData.min)
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                            }
                            // barrinha mínima → máxima, na escala da semana
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 4
                                readonly property real lo: dayRow.parent.lo
                                readonly property real span: Math.max(1, dayRow.parent.hi - lo)
                                Rectangle { anchors.fill: parent; radius: 2; color: Theme.track }
                                Rectangle {
                                    x: parent.width * (dayRow.modelData.min - parent.lo) / parent.span
                                    width: Math.max(4, parent.width * (dayRow.modelData.max - dayRow.modelData.min) / parent.span)
                                    height: parent.height
                                    radius: 2
                                    color: Theme.accent
                                }
                            }
                            Text {
                                Layout.preferredWidth: 30
                                text: root.deg(dayRow.modelData.max)
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                            }
                        }
                    }
                }

                // nascer / pôr do sol · status
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: root.ready && root.wx.daily.length > 0
                              ? root.glyph(0xF059C) + " " + root.hhmm(root.wx.daily[0].sunrise)
                                + "    " + root.glyph(0xF059B) + " " + root.hhmm(root.wx.daily[0].sunset)
                              : ""
                        color: Theme.dim
                        font.family: Theme.iconFont
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Text {
                        text: root.error !== "" ? root.error : "Open-Meteo"
                        color: root.error !== "" ? Theme.warn : Theme.overlay
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 3
                    }
                }
            }
        }
    }
}
