// PolkitDialog.qml — o agente de autenticação polkit da sessão (no lugar do hyprpolkitagent,
// aposentado em 2026-10-28): quando um app pede privilégios (pkexec, GNOME Disks, systemctl
// pela interface...), o polkitd chama este agente e o diálogo aparece no monitor principal,
// com o tema do bar. Enter envia a senha, Esc cancela. Uma falha reabre o campo com o erro.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Polkit
import "../theme"

Scope {
    id: root

    property string error: ""
    readonly property var flow: agent.flow
    readonly property bool canAnswer: flow !== null && flow.isResponseRequired && !flow.isCompleted

    PolkitAgent {
        id: agent
        path: "/org/barch/PolkitAgent"
        onAuthenticationRequestStarted: root.open()
        onIsActiveChanged: if (!isActive) win.visible = false
        onFlowChanged: if (flow) root.open()
    }
    function open() {
        root.error = ""
        field.text = ""
        win.visible = true
        field.forceActiveFocus()
    }
    function submit() {
        if (!root.canAnswer || field.text === "") return
        root.error = ""
        root.flow.submit(field.text)
        field.text = ""
    }
    function cancel() {
        if (root.flow && !root.flow.isCompleted) root.flow.cancelAuthenticationRequest()
        win.visible = false
    }
    Connections {
        target: root.flow
        ignoreUnknownSignals: true
        function onIsResponseRequiredChanged() { if (root.flow.isResponseRequired) { field.text = ""; field.forceActiveFocus() } }
        function onFailedChanged() { if (root.flow.failed) root.error = "Authentication failed" }
        function onSupplementaryMessageChanged() {
            if (root.flow.supplementaryMessage !== "" && root.flow.supplementaryIsError) root.error = root.flow.supplementaryMessage
        }
        function onIsCompletedChanged() { if (root.flow.isCompleted) win.visible = false }
    }

    PanelWindow {
        id: win
        visible: false
        screen: Quickshell.screens.find(s => s.name === "HDMI-A-2") || Quickshell.screens[0]
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "barch-polkit"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // fundo escurecido; clicar fora não fecha (é um pedido de senha), Esc cancela
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.35) }

        Rectangle {
            id: card
            width: 440
            height: col.implicitHeight + 44
            anchors.centerIn: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: col
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                spacing: 10

                RowLayout {
                    spacing: 12
                    Text { text: "󰌾"; color: Theme.accent; font.family: Theme.iconFont; font.pixelSize: 22 }   // nf-md-lock
                    Text {
                        text: "Authentication required"
                        color: Theme.text; font.family: Theme.font; font.pixelSize: Theme.fontSize + 2; font.bold: true
                        Layout.fillWidth: true
                    }
                }
                Text {
                    text: root.flow ? root.flow.message : ""
                    color: Theme.text; font.family: Theme.font; font.pixelSize: Theme.fontSize
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                Text {
                    text: (root.flow ? root.flow.actionId : "") + "   ·   " + Quickshell.env("USER")
                    color: Theme.subtext; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }

                // campo de senha
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 38
                    radius: 10
                    color: Theme.surface
                    border.width: 1
                    border.color: root.error !== "" ? Theme.red : field.activeFocus ? Theme.accent : "transparent"
                    opacity: root.canAnswer ? 1 : 0.5

                    TextInput {
                        id: field
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.text; font.family: Theme.font; font.pixelSize: Theme.fontSize
                        echoMode: root.flow && root.flow.responseVisible ? TextInput.Normal : TextInput.Password
                        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                        readOnly: !root.canAnswer
                        clip: true
                        onAccepted: root.submit()
                        Keys.onEscapePressed: root.cancel()
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: field.text === ""
                            text: root.canAnswer ? (root.flow.inputPrompt || "Password:").replace(/:\s*$/, "") : "Checking…"
                            color: Theme.overlay; font.family: Theme.font; font.pixelSize: Theme.fontSize
                        }
                    }
                }
                Text {
                    visible: root.error !== ""
                    text: root.error
                    color: Theme.red; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.topMargin: 6
                    Layout.alignment: Qt.AlignRight
                    spacing: 8
                    component Button: Rectangle {
                        property string label
                        property bool primary: false
                        signal clicked()
                        implicitWidth: lbl.implicitWidth + 28
                        implicitHeight: 32
                        radius: 10
                        color: primary ? Theme.accent : mouse.containsMouse ? Theme.surface : "transparent"
                        border.width: primary ? 0 : 1
                        border.color: Theme.border
                        Text {
                            id: lbl
                            anchors.centerIn: parent
                            text: parent.label
                            color: parent.primary ? Theme.crust : Theme.text
                            font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: parent.primary
                        }
                        MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() }
                    }
                    Button { label: "Cancel"; onClicked: root.cancel() }
                    Button { label: "Authenticate"; primary: true; onClicked: root.submit() }
                }
            }
        }
    }
}
