// Renders OpencodeMark in every state it can reach, on a dark and a light bar, so a
// change to the mark or to the colour rules can be looked at without restarting the
// shell. Run it from the repository root:
//
//   qml6 mark-preview.qml                 # opens a window
//   QT_QPA_PLATFORM=offscreen qml6 mark-preview.qml   # writes docs/mark-states.png
//
// Not part of the plugin: dev-sync.sh keeps it out of the installed folder.
import QtQuick
import "lib/Palette.js" as Palette

Window {
  id: win
  visible: true
  width: 760
  height: 300
  color: "#0b0b0f"

  readonly property var states: [
    { label: "free", tier: "free" },
    { label: "light", tier: "light" },
    { label: "standard", tier: "standard" },
    { label: "unknown", tier: "unknown" },
    { label: "TOP", tier: "top" },
    { label: "broken", tier: "broken" }
  ]

  component Band: Item {
    id: band
    property color surface: "#181825"
    property color fg: "#cdd6f4"
    property color urgent: "#f38ba8"
    property string title: ""
    readonly property bool onDark: Palette.lumOf(fg) > 0.5

    implicitWidth: 720
    implicitHeight: 118

    Rectangle { anchors.fill: parent; color: band.surface }

    Column {
      anchors.centerIn: parent
      spacing: 10

      Text {
        textFormat: Text.PlainText
        text: band.title
        color: band.fg
        font.pixelSize: 12
        font.family: "monospace"
      }

      Row {
        spacing: 26

        Repeater {
          model: win.states

          Column {
            id: cell
            spacing: 6
            readonly property string tier: modelData.tier
            readonly property color frameColor: tier === "broken" ? band.urgent : band.fg
            readonly property color cursorColor: {
              if (tier === "broken") return band.urgent
              if (tier === "top") return Palette.opencodeInkOn(band.onDark)
              var a = tier === "unknown" ? Palette.markNeutralAlpha() : Palette.tierAlpha(tier)
              return Qt.rgba(band.fg.r, band.fg.g, band.fg.b, a)
            }

            Row {
              spacing: 14
              anchors.horizontalCenter: parent.horizontalCenter

              OpencodeMark {
                size: 16
                anchors.verticalCenter: parent.verticalCenter
                frameColor: cell.frameColor
                cursorColor: cell.cursorColor
              }

              OpencodeMark {
                size: 48
                anchors.verticalCenter: parent.verticalCenter
                frameColor: cell.frameColor
                cursorColor: cell.cursorColor
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: modelData.label
              color: band.fg
              font.pixelSize: 10
              font.family: "monospace"
            }
          }
        }
      }
    }
  }

  Column {
    id: sheet
    anchors.centerIn: parent
    spacing: 22

    Band {
      title: "DARK   bar foreground #cdd6f4"
      surface: "#181825"
      fg: "#cdd6f4"
    }

    Band {
      title: "LIGHT  bar foreground #4c4f69"
      surface: "#eff1f5"
      fg: "#4c4f69"
    }
  }

  Timer {
    interval: 700
    running: Qt.platform.pluginName === "offscreen"
    onTriggered: sheet.grabToImage(function (result) {
      result.saveToFile("docs/mark-states.png")
      Qt.quit()
    })
  }
}
