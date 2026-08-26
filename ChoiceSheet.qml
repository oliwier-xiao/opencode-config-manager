import QtQuick
import qs.Commons
import qs.Ui

// A modal that asks which one, rather than whether.
//
// ConfirmDialog covers yes/no. "Add a profile" is not that shape: the three
// answers are unlike each other and two of them need a line of explanation, so
// they get rows rather than a button strip. The scrim and keyboard idiom are
// ConfirmDialog's on purpose — same kind of interruption, same feel.
Item {
  id: root

  property bool opened: false
  property string title: ""
  // [{ value, label, description, disabled, note }]
  property var choices: []
  property string cancelText: "Cancel"

  property color background: Color.popups.background
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property color scrim: Util.alpha(Color.background, 0.7)
  property string fontFamily: Style.font.family

  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)

  property int selectedIndex: 0
  readonly property int cancelIndex: choices.length

  signal canceled()
  signal chosen(string value)

  function pick(index) {
    if (index === cancelIndex) { root.canceled(); return }
    if (index < 0 || index >= choices.length) return
    if (choices[index].disabled === true) return
    root.chosen(String(choices[index].value))
  }

  // Reopened on a different question, so the previous answer must not carry over.
  onOpenedChanged: if (opened) selectedIndex = 0
  // ...and a new set of answers is a new question even if `opened` never dipped.
  onChoicesChanged: selectedIndex = 0

  function handleKey(event) {
    if (!root.opened) return false
    var count = root.cancelIndex + 1
    if (event.key === Qt.Key_Escape) { root.canceled(); return true }
    if (event.key === Qt.Key_Up) {
      root.selectedIndex = (root.selectedIndex + count - 1) % count; return true
    }
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
      root.selectedIndex = (root.selectedIndex + 1) % count; return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.pick(root.selectedIndex); return true
    }
    return false
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.scrim
    MouseArea { anchors.fill: parent; onClicked: root.canceled() }
  }

  BorderSurface {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(40), Style.space(420))
    implicitHeight: card.implicitHeight + Style.spacing.huge * 2
    radius: Style.cornerRadius
    color: root.background
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)

    // Swallows clicks so the scrim underneath does not dismiss the sheet.
    MouseArea { anchors.fill: parent }

    Column {
      id: card
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.huge
      anchors.rightMargin: Style.spacing.huge
      spacing: Style.spacing.xl

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.choices

          CursorSurface {
            required property var modelData
            required property int index
            width: parent.width
            implicitHeight: rowCol.implicitHeight + Style.spacing.xxl
            foreground: root.foreground
            accent: root.accent
            hasCursor: root.selectedIndex === index
            opacity: modelData.disabled === true ? 0.45 : 1

            Column {
              id: rowCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              spacing: Style.spacing.xxs

              Row {
                spacing: Style.spacing.md

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: modelData.note || ""
                  color: root.veryMuted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: text !== ""
                text: modelData.description || ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: modelData.disabled === true ? Qt.ArrowCursor : Qt.PointingHandCursor
              onEntered: root.selectedIndex = index
              onClicked: root.pick(index)
            }
          }
        }
      }

      Item {
        width: parent.width
        height: cancelButton.height

        Button {
          id: cancelButton
          anchors.right: parent.right
          text: root.cancelText
          fontSize: Style.font.caption
          bordered: true
          foreground: root.foreground
          accent: root.accent
          hasCursor: root.selectedIndex === root.cancelIndex
          onClicked: root.canceled()
        }
      }
    }
  }
}
