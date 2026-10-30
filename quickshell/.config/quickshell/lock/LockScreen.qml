// LockScreen.qml — o conteúdo de um monitor da tela de bloqueio: wallpaper (já desfocado), relógio,
// data + clima, campo de senha, notificações enquanto fora, música tocando e usuário.
// Usado pelo WlSessionLockSurface (um por monitor) e pela janela de pré-visualização.
// Todo o estado (senha digitada, PAM, tema, dados) fica em `ctl`, o Lock.qml (shell.qml e
// preview.qml), para os monitores compartilharem o que foi digitado.

import QtQuick
import QtQuick.Effects

Item {
    id: screenRoot
    required property var ctl              // o Lock.qml que controla esta tela
    required property string screenName    // nome do monitor (HDMI-A-2, ...)
    readonly property bool primary: screenName === ctl.mainScreen
    property bool shown: false
    Component.onCompleted: { shown = true; input.forceActiveFocus() }
    // tudo (papel de parede e conteúdo) aparece num fade só, quando a imagem já está pronta;
    // "pronta" inclui erro, para a tela nunca ficar sem o campo de senha por causa de um arquivo
    readonly property bool ready: shown && wall.status !== Image.Loading

    // ---- wallpaper (já desfocado) ----
    // <cena>/primary-lock-<modo>.png / secondary-lock-<modo>.png: 960x540 já com blur (tools/make_wallpapers.py);
    // a cena vem do wallpaper.json do bar (ctl.scene) e o modo do theme.json. Decodificam em poucos ms, síncronas, então o primeiro frame da
    // superfície já sai com o papel de parede; desfocar o PNG 4K aqui custava ~100 ms e entrava com um
    // pulo. Sem a versão lock (instalação antiga), cai para a imagem grande.
    Image {
        id: wall
        property bool fallback: false
        anchors.fill: parent
        source: "file://" + ctl.home + "/Pictures/Wallpapers/" + ctl.scene + "/" + (screenRoot.primary ? "primary" : "secondary")
                + (fallback ? "" : "-lock") + (ctl.dark ? "-dark" : "-light") + ".png"
        fillMode: Image.PreserveAspectCrop
        cache: false
        smooth: true
        opacity: screenRoot.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        onStatusChanged: if (status === Image.Error && !fallback) { console.warn("lock: no lock wallpaper, using the full-size one:", source); fallback = true }
        Connections { target: ctl; function onSceneChanged() { wall.fallback = false } }
    }

    // esconde o cursor; clique devolve o foco ao campo
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.BlankCursor
        onClicked: input.forceActiveFocus()
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: screenRoot.ready && !ctl.unlocking ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }

        // ---- marca ----
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 44
            spacing: 0
            Text {
                text: "B"
                color: ctl.accent
                font.family: ctl.font; font.pixelSize: 26; font.weight: Font.Medium; font.letterSpacing: 5
            }
            Text {
                text: "ARCH"
                color: ctl.dim
                font.family: ctl.font; font.pixelSize: 26; font.weight: Font.ExtraLight; font.letterSpacing: 5
            }
        }

        // ---- relógio ----
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -150
            text: Qt.formatTime(ctl.now, "HH:mm")
            color: ctl.fg
            font.family: ctl.font
            font.pixelSize: 84
            font.weight: Font.ExtraLight
            font.letterSpacing: -1
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.6; shadowColor: ctl.shadow; shadowVerticalOffset: 2 }
        }

        // ---- data e clima ----
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -72
            spacing: 10
            Text {
                text: ctl.now.toLocaleDateString(Qt.locale("en_US"), "dddd, MMMM d")
                color: ctl.dim; font.family: ctl.font; font.pixelSize: 16; font.weight: Font.Light
            }
            Text {
                visible: ctl.weatherGlyph !== ""
                text: "    " + ctl.weatherGlyph
                color: ctl.dim; font.family: ctl.iconFont; font.pixelSize: 16
            }
            Text {
                visible: ctl.weatherText !== ""
                text: ctl.weatherText
                color: ctl.dim; font.family: ctl.font; font.pixelSize: 16; font.weight: Font.Light
            }
        }

        // ---- campo de senha ----
        Rectangle {
            id: field
            width: 260; height: 44; radius: height / 2
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 70
            color: ctl.pill
            border.width: 1
            border.color: ctl.unlocking ? ctl.okColor
                        : ctl.failText !== "" ? ctl.failColor
                        : ctl.busy ? ctl.accent : ctl.outline
            Behavior on border.color { ColorAnimation { duration: 150 } }
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.5; shadowColor: ctl.shadow; shadowVerticalOffset: 2 }

            Connections {
                target: ctl
                function onShake() { shakeAnim.restart() }
            }
            SequentialAnimation {
                id: shakeAnim
                NumberAnimation { target: field; property: "anchors.horizontalCenterOffset"; to: -12; duration: 50 }
                NumberAnimation { target: field; property: "anchors.horizontalCenterOffset"; to: 12; duration: 80 }
                NumberAnimation { target: field; property: "anchors.horizontalCenterOffset"; to: -8; duration: 70 }
                NumberAnimation { target: field; property: "anchors.horizontalCenterOffset"; to: 0; duration: 60 }
            }

            Text {
                anchors.centerIn: parent
                visible: ctl.buffer === "" && !ctl.busy
                text: "Password"
                color: Qt.alpha(ctl.fg, 0.45)
                font.family: ctl.font; font.pixelSize: 14; font.weight: Font.Light
            }
            Row {
                anchors.centerIn: parent
                spacing: 5
                Repeater {
                    model: Math.min(ctl.buffer.length, 24)
                    Rectangle {
                        width: 8; height: width; radius: width / 2
                        color: ctl.fg
                    }
                }
            }

            // entrada de teclado invisível (um TextInput de verdade, para dead keys e IME)
            TextInput {
                id: input
                anchors.fill: parent
                opacity: 0
                focus: true
                echoMode: TextInput.Password
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                readOnly: ctl.busy || ctl.unlocking
                onTextChanged: if (text !== ctl.buffer) ctl.buffer = text
                onAccepted: ctl.submit()
                Keys.onEscapePressed: ctl.buffer = ""
                Connections {
                    target: ctl
                    function onBufferChanged() { if (input.text !== ctl.buffer) input.text = ctl.buffer }
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: field.bottom
            anchors.topMargin: 12
            visible: ctl.failText !== ""
            text: ctl.failText + " (" + ctl.attempts + ")"
            color: ctl.failColor
            font.family: ctl.font; font.pixelSize: 12; font.italic: true
        }

        // ---- notificações enquanto fora ----
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 130
            spacing: 8
            visible: ctl.awayCount > 0 && ctl.failText === ""
            Text { text: "󰂚"; color: ctl.dim; font.family: ctl.iconFont; font.pixelSize: 12 }
            Text {
                text: ctl.awayCount + (ctl.awayCount === 1 ? " notification" : " notifications") + " while you were away"
                color: ctl.dim; font.family: ctl.font; font.pixelSize: 12; font.weight: Font.Light
            }
        }

        // ---- música tocando ----
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 80
            spacing: 8
            visible: ctl.mediaText !== ""
            Text { text: "󰎇"; color: ctl.dim; font.family: ctl.iconFont; font.pixelSize: 12 }
            Text {
                text: ctl.mediaText
                color: ctl.dim; font.family: ctl.font; font.pixelSize: 12; font.weight: Font.Light
                elide: Text.ElideRight
                width: Math.min(implicitWidth, screenRoot.width - 120)
            }
        }

        // ---- usuário ----
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 40
            spacing: 8
            Text { text: ""; color: ctl.dim; font.family: ctl.iconFont; font.pixelSize: 11 }
            Text { text: ctl.user; color: ctl.dim; font.family: ctl.font; font.pixelSize: 11; font.weight: Font.Light }
        }
    }
}
