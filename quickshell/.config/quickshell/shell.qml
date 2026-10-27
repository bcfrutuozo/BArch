//@ pragma UseQApplication

// Barra em "ilhas" flutuantes: workspaces + janela ativa | relógio | tray + widgets + notificações + energia.
// As notificações são do próprio Quickshell (pasta notifications/), sem swaync.
// Proteção do OLED: ícones em contorno e pixel shift (as ilhas andam 1 px físico a cada 20 s).
// Cores, fontes e tamanhos vêm de theme/Theme.qml; os widgets leem de lá sozinhos.

import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell.Wayland
import "theme"
import "control"
import "bluetooth"
import "pods"
import "network"
import "sysmon"
import "clipboard"
import "audio"
import "disks"
import "media"
import "vms"
import "updates"
import "health"
import "launcher"
import "keys"
import "switcher"
import "overview"
import "agenda"
import "record"
import "minimize"
import "pin"
import "session"
import "corner"
import "notes"
import "privacy"
import "notifications"
import "replay"
import "weather"

ShellRoot {
  id: shell

  SystemClock { id: clock; precision: SystemClock.Minutes }

  // Launcher de apps (Super): qs ipc call launcher toggle
  Launcher {}
  Keybinds {}
  Switcher {}
  Overview {}
  HotCorner {}
  QuickNotes {}
  // restaurar a sessão: o singleton só existe se alguém o usar, então é "tocado" aqui
  readonly property bool sessionReady: Session.ready

  // Balões de notificação (servidor próprio, no lugar do swaync)
  NotificationPopups {}

  // ---- OLED: pixel shift ----
  // As ilhas percorrem uma grade de 25×13 pixels físicos em zigue-zague,
  // 1 pixel físico a cada 20 s (imperceptível), indo e voltando a cada ~3,6 h.
  QtObject {
    id: oled
    readonly property int rangeX: 12        // px físicos para cada lado
    readonly property int rangeY: 12        // px físicos, só para cima
    readonly property real dpr: 2           // escala do monitor no Hyprland
    readonly property int stepSeconds: 20
    property int tick: 0

    readonly property int cols: rangeX * 2 + 1
    readonly property int rows: rangeY + 1
    readonly property int cells: cols * rows
    readonly property int idx: {
      const period = 2 * cells - 2
      const t = tick % period
      return t < cells ? t : period - t
    }
    readonly property int row: Math.floor(idx / cols)
    readonly property int col: idx % cols
    readonly property real shiftX: ((row % 2 === 0 ? col : cols - 1 - col) - rangeX) / dpr
    readonly property real shiftY: -row / dpr
  }

  Timer {
    interval: oled.stepSeconds * 1000
    running: true
    repeat: true
    onTriggered: oled.tick++
  }

  // ---- Ilha: cápsula arredondada que cresce conforme o conteúdo ----
  component Island: Rectangle {
    default property alias content: row.data
    property int padding: 14
    property alias spacing: row.spacing

    implicitHeight: Theme.islandHeight
    implicitWidth: row.implicitWidth + padding * 2
    radius: height / 2
    color: Theme.base
    border.color: Theme.surface
    border.width: 1

    Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    // Clique na ilha inteira (fica atrás do conteúdo; só ativa com clickable: true)
    id: island
    property bool clickable: false
    signal clicked()
    MouseArea {
      anchors.fill: parent
      enabled: island.clickable
      onClicked: island.clicked()
    }

    RowLayout {
      id: row
      anchors.centerIn: parent
      spacing: 10
    }
  }

  component Label: Text {
    color: Theme.text
    font.family: Theme.font
    font.pixelSize: Theme.fontSize
  }

  Variants {
    // Barra só no monitor principal; se ele estiver desconectado, volta a aparecer em todos
    model: {
      const s = Quickshell.screens.filter(s => s.name === "HDMI-A-2")
      return s.length > 0 ? s : Quickshell.screens
    }

    PanelWindow {
      id: bar
      required property var modelData
      screen: modelData
      anchors { top: true; left: true; right: true }
      implicitHeight: Theme.islandHeight + Theme.gap
      color: "transparent"

      // Libera o teclado só enquanto há senha de Wi-Fi ou busca no clipboard para digitar
      WlrLayershell.keyboardFocus: (wifi.wantsKeyboard || clip.wantsKeyboard) ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

      // ================= ESQUERDA: workspaces + janela ativa =================
      Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.gap
        anchors.bottom: parent.bottom
        spacing: 8
        transform: Translate { x: oled.shiftX; y: oled.shiftY }

        Island {
          id: wsIsland
          padding: 6
          spacing: 5

          // apps abertos em cada workspace: id → [classes] (sem repetir), para os ícones
          property var apps: ({})
          function iconFor(cls) {
            const e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(cls) : null
            return Quickshell.iconPath(e && e.icon ? e.icon : (cls || "").toLowerCase(), "application-x-executable")
          }
          Process {
            id: wsAppsProc
            command: ["hyprctl", "clients", "-j"]
            running: true
            stdout: StdioCollector {
              onStreamFinished: {
                let list = []
                try { list = JSON.parse(text) } catch (e) { return }
                const m = {}
                for (const c of list) {
                  if (!c.workspace || c.workspace.id <= 0 || !c.class) continue
                  const k = c.workspace.id
                  if (!m[k]) m[k] = []
                  if (!m[k].includes(c.class)) m[k].push(c.class)
                }
                wsIsland.apps = m
              }
            }
          }
          Timer { id: wsAppsLater; interval: 120; onTriggered: wsAppsProc.running = true }
          Connections {
            target: Hyprland
            function onRawEvent(event) {
              const n = event.name
              if (n === "openwindow" || n === "closewindow" || n === "movewindow" || n === "movewindowv2"
                  || n === "windowtitle" || n === "createworkspace" || n === "destroyworkspace")
                wsAppsLater.restart()
            }
          }

          Repeater {
            model: Hyprland.workspaces

            Rectangle {
              id: ws
              required property var modelData
              readonly property var classes: wsIsland.apps[modelData.id] || []
              readonly property int maxIcons: 4
              visible: modelData.id > 0          // esconde workspaces especiais
              implicitHeight: 20
              implicitWidth: Math.max(modelData.focused ? 38 : 20, wsRow.implicitWidth + 14)
              radius: 10
              // workspace ativo em contorno (a pílula preenchida era o maior bloco fixo da barra)
              color: wsMouse.containsMouse ? Theme.surface : "transparent"
              border.width: modelData.focused ? 1.5 : 0
              border.color: Theme.accent

              Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 150 } }

              Row {
                id: wsRow
                anchors.centerIn: parent
                spacing: 4

                Label {
                  anchors.verticalCenter: parent.verticalCenter
                  text: ws.modelData.name
                  color: ws.modelData.focused ? Theme.accent : Theme.subtext
                  font.pixelSize: 11
                  font.bold: ws.modelData.focused
                }
                // ícones dos apps abertos neste workspace (até 4, depois "+n")
                Repeater {
                  model: ws.classes.slice(0, ws.maxIcons)
                  IconImage {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    implicitSize: 13
                    source: wsIsland.iconFor(modelData)
                    opacity: ws.modelData.focused ? 1 : 0.6
                  }
                }
                Label {
                  visible: ws.classes.length > ws.maxIcons
                  anchors.verticalCenter: parent.verticalCenter
                  text: "+" + (ws.classes.length - ws.maxIcons)
                  color: Theme.subtext
                  font.pixelSize: 10
                }
              }

              MouseArea {
                id: wsMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: Hyprland.dispatch('hl.dsp.focus({ workspace = "' + ws.modelData.name + '" })')
              }
            }
          }

          // Rolar o mouse sobre a ilha troca de workspace
          WheelHandler {
            onWheel: event => Hyprland.dispatch('hl.dsp.focus({ workspace = "' + (event.angleDelta.y > 0 ? "e-1" : "e+1") + '" })')
          }
        }

        Island {
          id: titleIsland
          property string title: ""
          visible: title !== ""        // sem janela focada, a ilha some

          // Pergunta o título ao Hyprland sempre que o foco ou o título muda
          Process {
            id: titleProc
            command: ["hyprctl", "activewindow", "-j"]
            running: true
            stdout: StdioCollector {
              onStreamFinished: {
                try { titleIsland.title = JSON.parse(text).title || "" }
                catch (e) { titleIsland.title = "" }
              }
            }
          }
          Connections {
            target: Hyprland
            function onRawEvent(event) {
              const n = event.name
              if (n === "activewindow" || n === "windowtitle" || n === "closewindow" || n === "workspace")
                titleProc.running = true
            }
          }

          Label {
            text: titleIsland.title
            color: Theme.subtext
            elide: Text.ElideRight
            Layout.maximumWidth: 420
          }
        }
      }

      // ================= CENTRO: relógio =================
      Island {
        id: clockIsland
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        transform: Translate { x: oled.shiftX; y: oled.shiftY }

        // Clique abre/fecha o calendário
        clickable: true
        onClicked: Popups.toggle(calendar)

        Label {
          text: Qt.formatDateTime(clock.date, "HH:mm")
          font.bold: true
          font.pixelSize: Theme.fontSize + 1
        }
        Rectangle { implicitWidth: 4; implicitHeight: 4; radius: 2; color: Theme.accent }
        Label {
          text: clock.date.toLocaleString(Qt.locale("en_US"), "ddd dd MMM")
          color: Theme.subtext
        }

        // Clima (Open-Meteo): ícone + temperatura; clique abre a previsão
        WeatherWidget { city: "Tatuí"; country: "BR" }

        // Música (aparece só quando algo está tocando ou pausado)
        MediaWidget {}
      }

      // ---- Calendário (somente consulta) ----
      PopupWindow {
        id: calendar
        PanelAnim { win: calendar }
        // só um painel aberto por vez na barra
        Connections {
            target: calendar
            function onVisibleChanged() { calendar.visible ? Popups.opened(calendar) : Popups.closed(calendar) }
        }
        // centralizado embaixo da ilha do relógio, popupGap abaixo dela
        anchor.item: clockIsland
        anchor.rect.x: clockIsland.width / 2
        anchor.rect.y: clockIsland.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Bottom
        implicitWidth: calBody.implicitWidth + 28
        implicitHeight: calBody.implicitHeight + 28
        color: "transparent"

        property int calYear: clock.date.getFullYear()
        property int calMonth: clock.date.getMonth()
        readonly property int firstDow: new Date(calYear, calMonth, 1).getDay()   // 0 = domingo
        readonly property int daysInMonth: new Date(calYear, calMonth + 1, 0).getDate()

        function shift(n) {
          const d = new Date(calYear, calMonth + n, 1)
          calYear = d.getFullYear()
          calMonth = d.getMonth()
        }
        function goToday() {
          calYear = clock.date.getFullYear()
          calMonth = clock.date.getMonth()
        }
        // Sempre abre no mês atual
        onVisibleChanged: if (visible) { goToday(); agenda.refresh() }

        Rectangle {
          anchors.fill: parent
          color: Theme.base
          border.color: Theme.surface
          border.width: 1
          radius: Theme.popupRadius

          ColumnLayout {
            id: calBody
            anchors.centerIn: parent
            spacing: 8

            // Cabeçalho: ‹ mês ano ›
            RowLayout {
              Layout.fillWidth: true
              Label {
                text: "‹"
                color: Theme.subtext
                font.pixelSize: Theme.fontSize + 6
                Layout.leftMargin: 8
                MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: calendar.shift(-1) }
              }
              Label {
                text: new Date(calendar.calYear, calendar.calMonth, 1).toLocaleDateString(Qt.locale("en_US"), "MMMM yyyy")
                font.bold: true
                font.capitalization: Font.Capitalize
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                MouseArea { anchors.fill: parent; onClicked: calendar.goToday() }   // clique no título volta para hoje
              }
              Label {
                text: "›"
                color: Theme.subtext
                font.pixelSize: Theme.fontSize + 6
                Layout.rightMargin: 8
                MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: calendar.shift(1) }
              }
            }

            // Dias da semana
            Grid {
              columns: 7
              Repeater {
                model: ["S", "M", "T", "W", "T", "F", "S"]
                Item {
                  required property string modelData
                  width: 34; height: 22
                  Label { anchors.centerIn: parent; text: parent.modelData; color: Theme.subtext; font.pixelSize: 11 }
                }
              }
            }

            // Dias (6 semanas)
            Grid {
              columns: 7
              Repeater {
                model: 42
                Rectangle {
                  id: cell
                  required property int index
                  readonly property int offset: index - calendar.firstDow + 1
                  readonly property bool inMonth: offset >= 1 && offset <= calendar.daysInMonth
                  readonly property bool isToday: inMonth
                    && offset === clock.date.getDate()
                    && calendar.calMonth === clock.date.getMonth()
                    && calendar.calYear === clock.date.getFullYear()

                  width: 34; height: 30
                  radius: 15
                  color: isToday ? Theme.accent : "transparent"

                  Label {
                    anchors.centerIn: parent
                    // fora do mês: mostra o dia do mês vizinho, apagado
                    text: new Date(calendar.calYear, calendar.calMonth, cell.offset).getDate()
                    color: cell.isToday ? Theme.crust
                         : !cell.inMonth ? Theme.overlay
                         : (cell.index % 7 === 0 || cell.index % 7 === 6) ? Theme.subtext : Theme.text
                    font.bold: cell.isToday
                  }
                  // ponto: dia com compromisso (agenda do iCloud via khal)
                  Rectangle {
                    visible: cell.inMonth && agenda.hasEvents(new Date(calendar.calYear, calendar.calMonth, cell.offset))
                    width: 4; height: 4; radius: 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    color: cell.isToday ? Theme.crust : Theme.accent
                  }
                }
              }
            }

            // Rolar o mouse troca de mês
            WheelHandler {
              onWheel: event => calendar.shift(event.angleDelta.y > 0 ? -1 : 1)
            }

            // Próximos compromissos
            Agenda {
              id: agenda
              Layout.fillWidth: true
              Layout.preferredWidth: 238
              Layout.maximumWidth: 238
            }
          }
        }
      }

      // Fecha o calendário ao clicar fora dele
      HyprlandFocusGrab {
        windows: [calendar]
        active: calendar.visible
        onCleared: Popups.hide(calendar)
      }

      // ================= DIREITA: tray + AirPods + notificações + energia =================
      Island {
        id: rightIsland
        anchors.right: parent.right
        anchors.rightMargin: Theme.gap
        anchors.bottom: parent.bottom
        transform: Translate { x: oled.shiftX; y: oled.shiftY }
        spacing: 12

        // Tray
        Repeater {
          model: SystemTray.items

          IconImage {
            id: trayIcon
            required property var modelData
            // no modo claro, troca ícones de painel claros pela versão escura do tema (Theme.trayIcon)
            source: Theme.trayIcon(modelData.icon)
            implicitSize: 16
            // apps que escolhem a cor do ícone por conta própria (e erram o contraste com a barra):
            // o ícone vira uma silhueta na cor do texto da barra, em qualquer modo
            readonly property bool forceMono: Theme.monoTrayApps.some(a =>
                ((modelData.id || "") + " " + (modelData.title || "")).toLowerCase().includes(a))
            layer.enabled: forceMono
            layer.effect: MultiEffect {
              brightness: Theme.isDark ? 1.0 : -1.0     // vira branco no escuro, preto no claro
              colorization: 1.0
              colorizationColor: Theme.fg
            }
            scale: trayMouse.containsMouse ? 1.2 : 1.0
            Behavior on scale { NumberAnimation { duration: 120 } }

            QsMenuAnchor {
              id: menuAnchor
              menu: trayIcon.modelData.menu
              anchor.window: bar
            }

            MouseArea {
              id: trayMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
              onClicked: mouse => {
                const item = trayIcon.modelData
                if (mouse.button === Qt.RightButton || item.onlyMenu) {
                  if (item.hasMenu) {
                    // abre logo abaixo do ícone
                    const pos = trayIcon.mapToItem(null, 0, trayIcon.height)
                    menuAnchor.anchor.rect.x = pos.x
                    menuAnchor.anchor.rect.y = pos.y
                    menuAnchor.open()
                  } else {
                    // Apps Wine/Proton: pede o menu direto ao app, na posição do cursor
                    Quickshell.execDetached(["bash", Quickshell.shellDir + "/sni-context-menu.sh", item.id])
                  }
                } else if (mouse.button === Qt.MiddleButton) {
                  item.secondaryActivate()
                } else {
                  item.activate()
                }
              }
            }
          }
        }

        // Monitor de recursos
        PrivacyWidget {}
        PinWidget {}
        MinimizedWidget {}
        RecordWidget {}
        ReplayWidget {}
        SysMonitor {}

        // Discos
        DiskWidget {}

        // Máquinas virtuais
        VmWidget {}

        // AirPods (some sozinho quando não há fones)
        AirPodsWidget {}

        // Volume
        VolumeWidget {}

        // Histórico da área de transferência
        ClipboardWidget { id: clip }

        // Rede: cabo e Wi-Fi em botões separados
        WiredWidget {}
        WifiWidget { id: wifi }

        // Bluetooth
        BluetoothWidget {}

        // Notificações (central + não perturbe)
        NotificationCenter {}

        // Atualizações
        HealthWidget {}
        UpdatesWidget {
          kernelScript: "/home/bcfrutuozo/.local/bin/kernel-update"
        }

        // Central de controle: modo claro/escuro, cafeína, luz noturna, não perturbe, captura
        ControlCenter { window: bar }

        // Energia
        Label {
          id: powerBtn
          text: "\uDB81\uDC25"   // nf-md-power
          color: powerMenu.visible ? Theme.red
               : powerMouse.containsMouse ? Theme.accent : Theme.text
          font.pixelSize: Theme.fontSize + 2
          Behavior on color { ColorAnimation { duration: 150 } }

          MouseArea {
            id: powerMouse
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            onClicked: Popups.toggle(powerMenu)
          }
        }
      }

      // ---- Menu de energia ----
      PopupWindow {
        id: powerMenu
        PanelAnim { win: powerMenu }
        // só um painel aberto por vez na barra
        Connections {
            target: powerMenu
            function onVisibleChanged() { powerMenu.visible ? Popups.opened(powerMenu) : Popups.closed(powerMenu) }
        }
        // canto inferior direito da ilha, popupGap abaixo dela
        anchor.item: rightIsland
        anchor.rect.x: rightIsland.width
        anchor.rect.y: rightIsland.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 190
        implicitHeight: powerCol.implicitHeight + 16
        color: "transparent"

        // Opção aguardando o segundo clique de confirmação
        property string armed: ""
        onVisibleChanged: armed = ""

        Rectangle {
          anchors.fill: parent
          color: Theme.base
          border.color: Theme.surface
          border.width: 1
          radius: Theme.popupRadius

          ColumnLayout {
            id: powerCol
            anchors.fill: parent
            anchors.margins: 8
            spacing: 2

            Repeater {
              model: [
                { key: "lock",    icon: "\uDB80\uDF3E", label: "Lock",      cmd: ["loginctl", "lock-session"], confirm: false },
                { key: "suspend", icon: "\uDB82\uDD04", label: "Suspend",   cmd: ["systemctl", "suspend"],     confirm: false },
                { key: "reboot",  icon: "\uDB81\uDF09", label: "Reboot",    cmd: ["systemctl", "reboot"],      confirm: true },
                { key: "off",     icon: "\uDB81\uDC25", label: "Shut Down", cmd: ["systemctl", "poweroff"],    confirm: true }
              ]

              Rectangle {
                id: entry
                required property var modelData
                readonly property bool isArmed: powerMenu.armed === modelData.key

                Layout.fillWidth: true
                implicitHeight: 34
                radius: 10
                color: isArmed ? Theme.red
                     : entryMouse.containsMouse ? Theme.surface : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 12
                  anchors.rightMargin: 12
                  spacing: 10

                  Label {
                    text: entry.modelData.icon
                    color: entry.isArmed ? Theme.crust : Theme.subtext
                    font.pixelSize: Theme.fontSize + 2
                  }
                  Label {
                    text: entry.isArmed ? "Confirm?" : entry.modelData.label
                    color: entry.isArmed ? Theme.crust : Theme.text
                    font.bold: entry.isArmed
                    Layout.fillWidth: true
                  }
                }

                MouseArea {
                  id: entryMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: {
                    if (entry.modelData.confirm && !entry.isArmed) {
                      powerMenu.armed = entry.modelData.key
                      return
                    }
                    Popups.hide(powerMenu)
                    Quickshell.execDetached(entry.modelData.cmd)
                  }
                }
              }
            }
          }
        }
      }

      // Fecha o menu de energia ao clicar fora dele
      HyprlandFocusGrab {
        windows: [powerMenu]
        active: powerMenu.visible
        onCleared: Popups.hide(powerMenu)
      }
    }
  }
}
