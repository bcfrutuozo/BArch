// VoiceWidget.qml — o microfone do controle por voz na barra: só aparece com o serviço
// barch-voice ligado. Apagado enquanto só escuta, na cor de destaque pulsando quando ouviu
// "barch" e espera a frase, fixo enquanto entende ou pergunta ao Claude, verde enquanto fala,
// vermelho quando falta algo (whisper.cpp, microfone). Ao lado, por alguns segundos, o que
// entendeu. Clique pausa e retoma a escuta; botão direito abre um painel com a última frase e a
// resposta, o idioma (lista com filtro: todos os do whisper; fora do português tudo vai ao
// Claude), pausa e desligar. Estado no singleton Voice (voice/Voice.qml).

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }
    function glyph(cp) { return String.fromCodePoint(cp) }

    visible: Voice.running
    onVisibleChanged: if (!visible) Popups.hide(popup)

    // a lista de idiomas aberta no painel: o filtro precisa do teclado (shell.qml)
    property bool chooseLang: false
    property string langFilter: ""
    readonly property bool wantsKeyboard: chooseLang && popup.visible
    readonly property var langList: {
        const q = langFilter.trim().toLowerCase()
        if (q === "") return Voice.languages
        return Voice.languages.filter(l => (l.name + " " + l.native + " " + l.code).toLowerCase().includes(q))
    }
    function pickLang(code) { Voice.setLanguage(code); chooseLang = false; langFilter = ""; langField.text = "" }
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    // a frase entendida fica visível 5 s depois de cada mudança
    property bool showHeard: false
    Timer { id: hide; interval: 5000; onTriggered: root.showHeard = false }
    Connections {
        target: Voice
        function onChangedChanged() {
            if (Voice.heard !== "" && (Voice.state === "processing" || Voice.state === "thinking" || Voice.state === "speaking" || Voice.state === "listening")) {
                root.showHeard = Voice.heard !== ""
                hide.restart()
            }
        }
    }

    readonly property color tone: Voice.degraded ? Theme.red
                                : Voice.paused ? Theme.overlay
                                : Voice.speaking ? Theme.good
                                : Voice.awake ? Theme.accent
                                : Theme.subtext

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5
        Text {
            id: mic
            anchors.verticalCenter: parent.verticalCenter
            text: Voice.paused ? root.glyph(0xF036D) : Voice.degraded ? root.glyph(0xF036D) : root.glyph(0xF036C)   // microphone_off / microphone
            color: root.tone
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
            SequentialAnimation on opacity {
                running: Voice.state === "wake" || Voice.state === "hearing" || Voice.state === "followup"; loops: Animation.Infinite
                NumberAnimation { to: Voice.state === "followup" ? 0.55 : 0.25; duration: Voice.state === "followup" ? 900 : 500 }
                NumberAnimation { to: 1; duration: Voice.state === "followup" ? 900 : 500 }
                onRunningChanged: if (!running) mic.opacity = 1
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: Voice.state === "wake" ? "listening…"
                : Voice.state === "thinking" ? "asking Claude…"
                : root.showHeard ? Voice.heard : ""
            color: Theme.subtext
            font.family: Theme.font
            font.pixelSize: Theme.fontSize - 1
            elide: Text.ElideRight
            width: Math.min(implicitWidth, 260)
        }
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) Popups.toggle(popup)
            else Voice.togglePause()
        }
    }

    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 300
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        HyprlandFocusGrab { windows: [popup]; active: popup.visible; onCleared: Popups.hide(popup) }
        onVisibleChanged: if (!visible) { root.chooseLang = false; root.langFilter = ""; langField.text = "" }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    spacing: 10
                    Text {
                        text: mic.text
                        color: root.tone
                        font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 6
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: "Voice control"
                            color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: true
                        }
                        Text {
                            text: Voice.label + (Voice.model ? "  ·  " + Voice.model.replace(/^ggml-|\.bin$/g, "") : "")
                            color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
                Repeater {
                    model: [
                        { k: "Heard", v: Voice.heard || "—" },
                        { k: "Said", v: Voice.said || "—" }
                    ]
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0
                        Text { text: parent.modelData.k; color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3 }
                        Text {
                            text: parent.modelData.v; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                            wrapMode: Text.Wrap; Layout.fillWidth: true; maximumLineCount: 3; elide: Text.ElideRight
                        }
                    }
                }
                // idioma: o atual num campo; clique abre a lista com filtro
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text { text: "Language"; color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3 }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: Theme.buttonRadius
                        color: langMouse.containsMouse ? Theme.hover : Theme.surface
                        border.width: 1
                        border.color: root.chooseLang ? Theme.accent : "transparent"
                        RowLayout {
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            spacing: 8
                            Text { text: root.glyph(0xF05CA); color: Theme.dim; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize }   // translate
                            Text {
                                text: Voice.languageLabel(Voice.language)
                                color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                            Text {
                                text: root.glyph(root.chooseLang ? 0xF0143 : 0xF0140)   // chevron_up / chevron_down
                                color: Theme.dim; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize
                            }
                        }
                        MouseArea {
                            id: langMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.chooseLang = !root.chooseLang
                                if (root.chooseLang) langField.forceActiveFocus()
                            }
                        }
                    }
                    Text {
                        visible: text !== ""
                        text: Voice.downloading !== "" ? "downloading the voice " + Voice.downloading + "…"
                            : Voice.language !== "pt" && Voice.language !== "auto" && !Voice.voiceReady ? "no voice for this language: answers go to notifications"
                            : Voice.language === "auto" ? "Portuguese uses the command table, other languages go to Claude"
                            : Voice.language !== "pt" ? "every sentence goes to Claude (the command table is Portuguese)"
                            : ""
                        color: Voice.downloading !== "" || !Voice.voiceReady ? Theme.warn : Theme.dim
                        font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                        wrapMode: Text.Wrap; Layout.fillWidth: true
                    }

                    ColumnLayout {
                        visible: root.chooseLang
                        Layout.fillWidth: true
                        spacing: 6
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: Theme.buttonRadius
                            color: Theme.surface
                            border.width: 1
                            border.color: langField.activeFocus ? Theme.accent : "transparent"
                            RowLayout {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 8
                                Text { text: root.glyph(0xF0349); color: Theme.dim; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize }   // magnify
                                TextInput {
                                    id: langField
                                    Layout.fillWidth: true
                                    color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                                    clip: true
                                    onTextChanged: root.langFilter = text
                                    Keys.onEscapePressed: { root.chooseLang = false; text = "" }
                                    Keys.onReturnPressed: if (root.langList.length > 0) root.pickLang(root.langList[0].code)
                                    Text {
                                        anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                        visible: langField.text === ""
                                        text: "Filter languages (" + Math.max(0, Voice.languages.length - 1) + ")"
                                        color: Theme.overlay; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                                    }
                                }
                            }
                        }
                        ListView {
                            id: langView
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(contentHeight, 240)
                            clip: true
                            model: root.langList
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Rectangle {
                                id: langRow
                                required property var modelData
                                readonly property bool selected: Voice.language === modelData.code
                                width: langView.width
                                implicitHeight: 30
                                radius: Theme.buttonRadius
                                color: rowMouse.containsMouse ? Theme.hover : "transparent"
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                    spacing: 8
                                    Text {
                                        text: langRow.modelData.code === "auto" ? "Automatic" : langRow.modelData.name
                                        color: langRow.selected ? Theme.accent : Theme.fg
                                        font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: langRow.selected
                                        elide: Text.ElideRight; Layout.fillWidth: true
                                    }
                                    Text {
                                        text: langRow.modelData.native
                                        color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                                        elide: Text.ElideRight; Layout.maximumWidth: 110
                                    }
                                    Text {
                                        // sem voz do Piper: a resposta vira notificação
                                        visible: langRow.modelData.code !== "auto" && !langRow.modelData.voice
                                        text: root.glyph(0xF0581)   // volume_off
                                        color: Theme.overlay; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize - 2
                                    }
                                }
                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.pickLang(langRow.modelData.code)
                                }
                            }
                        }
                    }
                }
                Text {
                    visible: !Voice.tts
                    text: "piper-tts not installed: answers go to notifications"
                    color: Theme.warn; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { label: Voice.paused ? "Resume" : "Pause", act: () => Voice.togglePause() },
                            { label: "Turn off", act: () => { Popups.hide(popup); Voice.stop() } }
                        ]
                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: 8
                            color: bm.containsMouse ? Theme.hover : "transparent"
                            border.color: Theme.border; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData.label
                                color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                            }
                            MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; onClicked: parent.modelData.act() }
                        }
                    }
                }
            }
        }
    }
}
