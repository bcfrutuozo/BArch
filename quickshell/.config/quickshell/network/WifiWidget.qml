// WifiWidget.qml — Wi-Fi na barra do Quickshell
// Na barra: ícone desenhado com o nível do sinal (some se não houver placa Wi-Fi).
// Clique: painel com liga/desliga do Wi-Fi, a rede conectada (com os dados da conexão
// e o botão de desconectar) e a lista de redes disponíveis, com campo de senha.
// Depende do iwd (por wifi.py, nesta pasta: D-Bus pelo busctl), do net-info.sh e do wl-clipboard.

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); os painéis se alinham a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property bool hideWhenNoDevice: true

    // ---------- estado ----------
    property string device: ""
    property bool radioOn: true
    property var networks: []        // [{ ssid, signal, secure, active }]
    property var savedWifi: []       // redes já salvas no iwd (/var/lib/iwd)
    property string pendingSsid: ""  // rede aguardando senha
    property string statusText: ""
    property var details: []         // entradas "wifi" do net-info.sh
    property bool showDetails: true

    readonly property var activeWifi: networks.find(n => n.active) || null
    readonly property var others: networks.filter(n => !n.active)

    // A barra libera o teclado enquanto o campo de senha está aberto
    readonly property bool wantsKeyboard: pendingSsid !== ""

    // ---------- utilidades ----------
    function glyph(cp) { return String.fromCodePoint(cp) }
    function level(sig) { return sig >= 75 ? 4 : sig >= 50 ? 3 : sig >= 25 ? 2 : 1 }

    function copy(label, value) {
        Quickshell.execDetached(["wl-copy", value])
        statusText = label + " copied"
        statusClear.restart()
    }

    readonly property var wifiCmd: ["python3", "-I", Quickshell.shellDir + "/network/wifi.py"]

    function refresh() { if (!statusProc.running) statusProc.running = true }
    function refreshDetails() { infoProc.running = true }

    function rescan() {
        statusText = "Scanning…"
        rescanProc.running = true
    }

    function connectTo(ssid, password) {
        statusText = "Connecting to " + ssid + "…"
        const cmd = root.wifiCmd.concat(["connect", ssid])
        if (password) cmd.push(password)
        connectProc.command = cmd
        connectProc.running = true
    }

    function run(cmd, msg) {
        statusText = msg
        actionProc.command = cmd
        actionProc.running = true
    }

    // ---------- processos ----------
    // wifi.py status: { device, radio, networks: [{ ssid, signal, secure, active, known }], saved }
    Process {
        id: statusProc
        command: root.wifiCmd.concat(["status"])
        stdout: StdioCollector {
            onStreamFinished: {
                let st
                try { st = JSON.parse(text) } catch (e) { root.device = ""; return }
                root.device = st.device || ""
                root.radioOn = st.radio === true
                root.savedWifi = st.saved || []
                // a new array recreates every row of the list, and the password field with it (it lost
                // the focus at each refresh): keep the list while a password is being typed, and replace
                // it only when something in it changed
                if (root.pendingSsid !== "") return
                const list = (st.networks || []).map(n => ({
                    ssid: n.ssid, signal: n.signal, secure: n.secure, active: n.active
                }))
                if (JSON.stringify(list) === JSON.stringify(root.networks)) return
                const wasActive = root.activeWifi ? root.activeWifi.ssid : ""
                root.networks = list
                const nowActive = root.activeWifi ? root.activeWifi.ssid : ""
                if (wasActive !== nowActive && popup.visible) root.refreshDetails()
            }
        }
    }

    Process {
        id: infoProc
        command: ["bash", Quickshell.shellDir + "/network/net-info.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.details = JSON.parse(text).filter(c => c.type === "wifi") }
                catch (e) { root.details = [] }
            }
        }
    }

    Process {
        id: rescanProc
        command: root.wifiCmd.concat(["scan"])
        onExited: rescanDelay.restart()
    }

    Timer {
        id: rescanDelay
        interval: 2500
        onTriggered: { root.statusText = ""; root.refresh() }
    }

    Process {
        id: connectProc
        stderr: StdioCollector { id: connErr }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.statusText = "Connected"
                root.pendingSsid = ""
                statusClear.restart()
            } else {
                root.statusText = connErr.text.trim() || "Connection failed"
            }
            root.refresh()
            root.refreshDetails()
        }
    }

    // liga/desliga o rádio e desconectar
    Process {
        id: actionProc
        onExited: { root.statusText = ""; root.refresh(); root.refreshDetails() }
    }

    Timer { id: statusClear; interval: 2000; onTriggered: root.statusText = "" }

    // atualiza a cada 10 s (e a cada 3 s com o painel aberto)
    Timer {
        interval: popup.visible ? 3000 : 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---------- na barra ----------
    visible: !hideWhenNoDevice || device !== ""
    implicitWidth: barIcons.implicitWidth
    implicitHeight: barIcons.implicitHeight

    Item {
        id: barIcons
        anchors.centerIn: parent
        implicitWidth: wifiIcon.implicitWidth
        implicitHeight: wifiIcon.implicitHeight

        // ligado: arcos com o nível do sinal (todos apagados se não conectado)
        WifiIcon {
            id: wifiIcon
            visible: root.radioOn
            anchors.centerIn: parent
            size: Theme.fontSize + 2
            level: root.activeWifi ? root.level(root.activeWifi.signal) : 0
            on: popup.visible || barMouse.containsMouse ? Theme.accent : Theme.fg
            off: Theme.overlay
        }

        // desligado: ícone de Wi-Fi riscado
        Text {
            visible: !root.radioOn
            anchors.centerIn: parent
            text: root.glyph(0xF092E)   // nf-md-wifi_strength_off_outline
            color: Theme.overlay
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
        }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            Popups.toggle(popup)
            if (Popups.isOpen(popup)) {
                if (root.radioOn) root.rescan()
                root.refreshDetails()
            }
        }
    }

    // ---------- painel ----------
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        // só um painel aberto por vez na barra
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        // ponto de ancoragem: canto inferior direito da ilha, popupGap abaixo dela;
        // o painel cresce para a esquerda e para baixo a partir dali
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 340
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        // fecha ao clicar fora e permite digitar a senha
        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: { Popups.hide(popup); root.pendingSsid = "" }
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
                anchors.margins: 14
                spacing: 8

                // --- cabeçalho: título, nova busca e liga/desliga ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        text: "Wi-Fi"
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }
                    Text {
                        visible: root.radioOn
                        text: root.glyph(0xF0450)   // refresh
                        color: scanMouse.containsMouse ? Theme.accent : Theme.dim
                        font.family: Theme.iconFont
                        font.pixelSize: Theme.fontSize
                        MouseArea {
                            id: scanMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.rescan()
                        }
                    }

                    // interruptor em contorno
                    Rectangle {
                        implicitWidth: 34
                        implicitHeight: 18
                        radius: 9
                        color: "transparent"
                        border.width: 1.5
                        border.color: root.radioOn ? Theme.accent : Theme.overlay

                        Rectangle {
                            width: 10; height: 10; radius: 5
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.radioOn ? parent.width - width - 4 : 4
                            color: root.radioOn ? Theme.accent : Theme.overlay
                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.run(root.wifiCmd.concat(["radio", root.radioOn ? "off" : "on"]),
                                                root.radioOn ? "Turning Wi-Fi off…" : "Turning Wi-Fi on…")
                        }
                    }
                }

                Text {
                    visible: !root.radioOn
                    text: "Wi-Fi is off"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }

                // --- rede conectada ---
                Rectangle {
                    visible: root.radioOn && root.activeWifi !== null
                    Layout.fillWidth: true
                    implicitHeight: current.implicitHeight + 20
                    radius: Theme.cardRadius
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.accent

                    ColumnLayout {
                        id: current
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            WifiIcon {
                                size: Theme.fontSize + 4
                                level: root.activeWifi ? root.level(root.activeWifi.signal) : 0
                                on: Theme.accent
                                off: Theme.overlay
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: root.activeWifi ? root.activeWifi.ssid : ""
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: "Connected" + (root.activeWifi ? "  ·  " + root.activeWifi.signal + "%" : "")
                                    color: Theme.good
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 2
                                }
                            }

                            // mostrar/ocultar dados
                            Text {
                                text: root.showDetails ? root.glyph(0xF0143) : root.glyph(0xF0140)
                                color: detMouse.containsMouse ? Theme.accent : Theme.dim
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize + 2
                                MouseArea {
                                    id: detMouse
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.showDetails = !root.showDetails
                                        if (root.showDetails) root.refreshDetails()
                                    }
                                }
                            }
                        }

                        // dados da conexão
                        ColumnLayout {
                            visible: root.showDetails
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                visible: root.details.length === 0
                                Layout.leftMargin: 8
                                text: infoProc.running ? "Loading…" : "No address yet"
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                            }

                            Repeater {
                                model: root.details

                                ColumnLayout {
                                    id: conn
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 0

                                    DetailRow {
                                        widget: root
                                        label: "IPv4"
                                        value: conn.modelData.ipv4 ? conn.modelData.ipv4 + "/" + conn.modelData.prefix : ""
                                        copyValue: conn.modelData.ipv4
                                    }
                                    DetailRow { widget: root; label: "Netmask"; value: conn.modelData.mask }
                                    DetailRow { widget: root; label: "Gateway"; value: conn.modelData.gateway }
                                    DetailRow { widget: root; label: "DNS"; value: conn.modelData.dns }
                                    DetailRow { widget: root; label: "IPv6"; value: conn.modelData.ipv6 }
                                    DetailRow { widget: root; label: "MAC"; value: conn.modelData.mac }
                                    DetailRow { widget: root; label: "Interface"; value: conn.modelData.iface }
                                }
                            }

                            DetailRow {
                                widget: root
                                label: "Public IP"
                                value: root.details.length > 0 ? root.details[0].external : ""
                            }
                        }

                        // desconectar
                        Rectangle {
                            Layout.alignment: Qt.AlignRight
                            implicitWidth: discText.implicitWidth + 20
                            implicitHeight: 26
                            radius: Theme.buttonRadius
                            color: discMouse.containsMouse ? Theme.hover : "transparent"
                            border.width: 1
                            border.color: Theme.border

                            Text {
                                id: discText
                                anchors.centerIn: parent
                                text: "Disconnect"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                            }
                            MouseArea {
                                id: discMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.run(root.wifiCmd.concat(["disconnect"]), "Disconnecting…")
                            }
                        }
                    }
                }

                // --- redes disponíveis ---
                Text {
                    visible: root.radioOn && root.others.length > 0
                    Layout.topMargin: 4
                    text: "Available Networks"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }

                Text {
                    visible: root.radioOn && root.networks.length === 0
                    text: rescanProc.running ? "Scanning…" : "No networks found"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }

                ListView {
                    visible: root.radioOn
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 320)
                    clip: true
                    spacing: 2
                    model: root.others

                    delegate: ColumnLayout {
                        id: item
                        required property var modelData
                        width: ListView.view.width
                        spacing: 4

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 34
                            radius: Theme.buttonRadius
                            color: rowMouse.containsMouse ? Theme.hover : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 10

                                WifiIcon {
                                    size: Theme.fontSize + 1
                                    level: root.level(item.modelData.signal)
                                    on: Theme.fg
                                    off: Theme.overlay
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: item.modelData.ssid
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: item.modelData.signal + "%"
                                    color: Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 2
                                }
                                Text {
                                    visible: item.modelData.secure
                                    text: root.glyph(0xF0341)   // nf-md-lock_outline
                                    color: Theme.dim
                                    font.family: Theme.iconFont
                                    font.pixelSize: Theme.fontSize - 1
                                }
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const n = item.modelData
                                    if (n.secure && !root.savedWifi.includes(n.ssid))
                                        root.pendingSsid = n.ssid
                                    else
                                        root.connectTo(n.ssid, "")
                                }
                            }
                        }

                        // campo de senha, só na rede escolhida
                        TextField {
                            id: pw
                            visible: root.pendingSsid === item.modelData.ssid
                            Layout.fillWidth: true
                            placeholderText: "Password for " + item.modelData.ssid
                            placeholderTextColor: Theme.dim
                            color: Theme.fg
                            echoMode: TextInput.Password
                            font.family: Theme.font
                            leftPadding: 12
                            rightPadding: 12
                            background: Rectangle {
                                radius: Theme.buttonRadius
                                color: Theme.hover
                                border.color: pw.activeFocus ? Theme.accent : "transparent"
                            }
                            onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
                            onAccepted: root.connectTo(item.modelData.ssid, text)
                            Keys.onEscapePressed: root.pendingSsid = ""
                        }
                    }
                }

                // --- status ---
                Text {
                    visible: root.statusText !== ""
                    Layout.fillWidth: true
                    text: root.statusText
                    wrapMode: Text.Wrap
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }
    }
}
