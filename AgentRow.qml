import QtQuick
import qs.Commons
import qs.Ui
import "lib/Catalog.js" as Catalog
import "lib/Model.js" as Model

// One agent, and what it runs on: which agent, which model, how hard it thinks.
//
// The effort control is disabled, not hidden — a control that vanishes stops the rows
// above and below lining up, and "this model has one speed" is worth being able to read.
Item {
  id: root

  property var row: null                    // Model.js row
  property var catalog: null
  property var catalogIndex: ({})
  property var favorites: []
  property var recents: []
  property bool showMeta: true
  // How wide the name column is. Every row is handed the same number so the
  // controls line up, but the editor measures it off the longest name in the
  // roster rather than reserving a fixed 140px: "atlas" was leaving two thirds
  // of that column empty between itself and its model.
  property real labelWidth: Style.space(140)
  property bool hasCursor: false
  property bool changed: false
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Util.alpha, not Qt.darker: on a light theme Qt.darker reads *more* prominent than
  // the foreground, and on an all-black-text theme all three levels collapse into one.
  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)
  // Effort on every agent and category row. opencode's own AgentConfig carries a
  // `variant` just as oh-my-openagent's entries do; only the two bare opencode
  // defaults, `model` and `small_model`, are plain strings with nowhere to put one.
  readonly property var variants: (row && row.group !== "default")
    ? Catalog.variantsFor(root.catalogIndex, row.model) : []
  readonly property bool pickerOpen: picker.popupOpen || variantPicker.popupOpen

  signal modelPicked(string modelId)
  signal variantPicked(string variant)
  // The two that open a list carry the scene rectangle of the chip that asked
  // for it, so the editor can put the list under that chip rather than in a
  // fixed place of its own — a list that opens somewhere else does not say
  // what it belongs to.
  signal fallbackAddRequested(real sceneX, real sceneY, real height)
  signal fallbackRemoved(int index)
  signal fallbackEditRequested(int index, real sceneX, real sceneY, real height)
  signal fallbackMoveRequested(int index, int delta)
  signal favoriteToggled(string modelId)
  signal entered()

  // An agent is two lines — its model, and the chain behind it — and they were
  // 4px apart while one agent was 8px from the next. At that size a 2:1 ratio
  // is no ratio: nothing said where one agent ended. The inner gap stays tight
  // and the outer one becomes generous, which is the whole of the grouping.
  implicitHeight: content.implicitHeight + Style.spacing.huge

  CursorSurface {
    anchors.fill: parent
    foreground: root.foreground
    accent: root.accent
    hasCursor: root.hasCursor
  }

  // Hover target for the panel cursor, minus the controls: moving into the dropdown
  // would otherwise count as leaving the row and drop the highlight out from under it.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onEntered: root.entered()
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.md
    spacing: Style.spacing.sm

    Item {
      width: parent.width
      height: Math.max(labels.implicitHeight, picker.implicitHeight)

      Column {
        id: labels
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.labelWidth
        spacing: Style.spacing.xxs

        Row {
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            // A row the user has touched but not saved. Three pixels of accent
            // is enough to count them without reading them.
            visible: root.changed
            text: "●"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.row ? root.row.label : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: Math.min(implicitWidth, labels.width - (root.changed ? Style.space(14) : 0))
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          text: {
            if (!root.row) return ""
            if (root.row.group === "category") return "category"
            if (root.row.file === "opencode" && root.row.group === "agent") return "opencode agent"
            return ""
          }
          color: root.veryMuted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ModelPicker {
        id: picker
        anchors.left: labels.right
        anchors.right: variantPicker.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.md
        catalog: root.catalog
        catalogIndex: root.catalogIndex
        favorites: root.favorites
        recents: root.recents
        showMeta: root.showMeta
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        value: root.row ? root.row.model : ""
        onChanged: function (id) { root.modelPicked(id) }
        onFavoriteToggled: function (id) { root.favoriteToggled(id) }
      }

      EffortDropdown {
        id: variantPicker
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(92)
        showLabel: false
        enabled: root.variants.length > 0
        opacity: enabled ? 1 : 0.45
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        // "—" is not an effort, it is the absence of one, and it has to be
        // selectable: a model that offers efforts still runs without one.
        options: {
          var out = [{ value: "", label: root.variants.length > 0 ? "—" : "n/a" }]
          for (var i = 0; i < root.variants.length; i++) out.push({ value: root.variants[i], label: root.variants[i] })
          return out
        }
        value: root.row ? root.row.variant : ""
        onChanged: function (v) { root.variantPicked(v) }
      }
    }

    // ---- Fallbacks: label on the left, one pill per line on the right. A
    // wrapping Flow put the second pill wherever the first one ended, so the
    // stack never lined up; a Column does — every pill starts at the same x,
    // under the first pill rather than under the "falls back to" text.
    Item {
      id: fallbacksLine
      width: parent.width
      height: fallbackRow.implicitHeight
      visible: root.row && root.row.file === "ohmy"

      readonly property int count: root.row ? root.row.fallbacks.length : 0
      // A reorder needs something to reorder against. Below two chips the
      // chevrons are not drawn at all — and the chip is that much narrower,
      // rather than carrying room for a move that cannot happen.
      readonly property bool reorderable: count > 1

      Row {
        id: fallbackRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.labelWidth + Style.spacing.lg
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: "falls back to"
          // Nudged down to the first pill's text baseline: a pill pads its
          // text by sm top and bottom, so the bare label needs the same.
          topPadding: Style.spacing.sm
          color: root.veryMuted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Column {
          spacing: Style.spacing.sm

          Repeater {
            model: root.row ? root.row.fallbacks : []

            BorderSurface {
              id: chipSurface
              required property var modelData
              required property int index
              implicitWidth: chip.implicitWidth + Style.spacing.lg * 2
              implicitHeight: chip.implicitHeight + Style.spacing.sm * 2
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

              HoverHandler { id: chipHover }

              Row {
                id: chip
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                // The chips stack downwards, so the two moves are up and down;
                // ‹ › pointed across a list that does not run that way. Space
                // is held for both the moment there is more than one chip, so
                // a chip never resizes under the pointer that is reaching for
                // it — the one at the end of the chain hides its own arrow
                // instead, and refuses the click that would do nothing.
                Text {
                  id: chipUp
                  textFormat: Text.PlainText
                  readonly property bool movable: chipSurface.index > 0
                  visible: fallbacksLine.reorderable
                  opacity: chipHover.hovered && movable ? 1 : 0
                  text: "󰅃"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.spacing.xs
                    enabled: chipUp.movable
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.fallbackMoveRequested(chipSurface.index, -1)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: Model.shortModel(chipSurface.modelData.model)
                       + (chipSurface.modelData.variant ? " " + chipSurface.modelData.variant : "")
                  color: chipEditHover.hovered ? root.foreground : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  HoverHandler { id: chipEditHover }
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.spacing.xs
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var p = chipSurface.mapToItem(null, 0, 0)
                      root.fallbackEditRequested(chipSurface.index, p.x, p.y, chipSurface.height)
                    }
                  }
                }

                Text {
                  id: chipDown
                  textFormat: Text.PlainText
                  readonly property bool movable: chipSurface.index < fallbacksLine.count - 1
                  visible: fallbacksLine.reorderable
                  opacity: chipHover.hovered && movable ? 1 : 0
                  text: "󰅀"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.spacing.xs
                    enabled: chipDown.movable
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.fallbackMoveRequested(chipSurface.index, 1)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "󰅖"
                  color: chipHover.hovered ? Color.urgent : root.veryMuted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.spacing.xs
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.fallbackRemoved(chipSurface.index)
                  }
                }
              }
            }
          }

          // The + is a chip-shaped empty slot at the end of the stack rather
          // than a bare icon: it lines up under the chips it extends, and on
          // an agent that has no fallbacks yet it is the only thing on the
          // line that says what the line is for.
          BorderSurface {
            id: addChip
            implicitWidth: addRow.implicitWidth + Style.spacing.lg * 2
            implicitHeight: addRow.implicitHeight + Style.spacing.sm * 2
            radius: Style.cornerRadius
            color: addHover.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
            borderSpec: Border.controlSpec(addHover.hovered ? "hover-cursor" : "normal",
                                           root.veryMuted, root.accent)

            HoverHandler { id: addHover }

            Row {
              id: addRow
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "󰐕"
                color: addHover.hovered ? root.foreground : root.veryMuted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                visible: fallbacksLine.count === 0
                text: "pick a model"
                color: addHover.hovered ? root.foreground : root.veryMuted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var p = addChip.mapToItem(null, 0, 0)
                root.fallbackAddRequested(p.x, p.y, addChip.height)
              }
            }

            PanelToolTip {
              visible: addHover.hovered && fallbacksLine.count > 0
              text: "Add another model to fall back to"
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }
  }
}
