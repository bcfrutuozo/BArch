// PowerMenu.qml — the power menu (the bar's last button): reload Hyprland, lock, suspend, reboot and shut down, the last two with a second click.
// One per bar (shell.qml creates it next to the island it hangs from).
pragma ComponentBehavior: Bound
import Quickshell
import QtQuick
import QtQuick.Layouts
import "../theme"

PopupWindow {
  id: powerMenu
  // the bar's text style (the same inline component as in shell.qml)
  component Label: Text {
    color: Theme.text
    font.family: Theme.font
    font.pixelSize: Theme.fontSize
  }
  // the bar's right island it opens under (shell.qml)
  required property Item anchorItem
  PanelAnim { win: powerMenu }
  // só um painel aberto por vez na barra
  Connections {
      target: powerMenu
      function onVisibleChanged() { powerMenu.visible ? Popups.opened(powerMenu) : Popups.closed(powerMenu) }
  }
  // canto inferior direito da ilha, popupGap abaixo dela
  anchor.item: powerMenu.anchorItem
  anchor.rect.x: powerMenu.anchorItem.width
  anchor.rect.y: powerMenu.anchorItem.height + Theme.popupGap
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
          { key: "reload",  icon: "\uDB81\uDC50", label: "Reload Hyprland", cmd: ["hyprctl", "reload"], confirm: false },
          { key: "lock",    icon: "\uDB80\uDF3E", label: "Lock",      cmd: ["loginctl", "lock-session"], confirm: false },
          // -i: a clicked Suspend is the user's decision, so sleep inhibitors (a Claude session
          // wrapped in systemd-inhibit, a backup) do not refuse it; idle suspend (hypridle) still respects them
          { key: "suspend", icon: "\uDB82\uDD04", label: "Suspend",   cmd: ["systemctl", "suspend", "-i"], confirm: false },
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
