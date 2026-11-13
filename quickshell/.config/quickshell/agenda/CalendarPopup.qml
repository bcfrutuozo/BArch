// CalendarPopup.qml — the month under the clock (click on the date): today marked, arrows and wheel move the month, the agenda of the day below.
// One per bar (shell.qml creates it next to the island it hangs from).
pragma ComponentBehavior: Bound
import Quickshell
import QtQuick
import QtQuick.Layouts
import "../theme"

PopupWindow {
  id: calendar
  // the bar's text style (the same inline component as in shell.qml)
  component Label: Text {
    color: Theme.text
    font.family: Theme.font
    font.pixelSize: Theme.fontSize
  }
  // the clock island it opens under and the bar's SystemClock (shell.qml)
  required property Item anchorItem
  required property var sysClock
  PanelAnim { win: calendar }
  // só um painel aberto por vez na barra
  Connections {
      target: calendar
      function onVisibleChanged() { calendar.visible ? Popups.opened(calendar) : Popups.closed(calendar) }
  }
  // centralizado embaixo da ilha do relógio, popupGap abaixo dela
  anchor.item: calendar.anchorItem
  anchor.rect.x: calendar.anchorItem.width / 2
  anchor.rect.y: calendar.anchorItem.height + Theme.popupGap
  anchor.rect.width: 1
  anchor.rect.height: 1
  anchor.edges: Edges.Top
  anchor.gravity: Edges.Bottom
  implicitWidth: calBody.implicitWidth + 28
  implicitHeight: calBody.implicitHeight + 28
  color: "transparent"

  property int calYear: calendar.sysClock.date.getFullYear()
  property int calMonth: calendar.sysClock.date.getMonth()
  readonly property int firstDow: new Date(calYear, calMonth, 1).getDay()   // 0 = domingo
  readonly property int daysInMonth: new Date(calYear, calMonth + 1, 0).getDate()

  function shift(n) {
    const d = new Date(calYear, calMonth + n, 1)
    calYear = d.getFullYear()
    calMonth = d.getMonth()
  }
  function goToday() {
    calYear = calendar.sysClock.date.getFullYear()
    calMonth = calendar.sysClock.date.getMonth()
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
              && offset === calendar.sysClock.date.getDate()
              && calendar.calMonth === calendar.sysClock.date.getMonth()
              && calendar.calYear === calendar.sysClock.date.getFullYear()

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
