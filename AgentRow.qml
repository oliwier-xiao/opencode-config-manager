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
  signal fallbackAddRequested()
  signal fallbackRemoved(int index)
  signal favoriteToggled(string modelId)
  signal entered()

  implicitHeight: content.implicitHeight + Style.spacing.lg

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
        width: Style.space(140)
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

      Dropdown {
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

    // ---- Fallbacks: one line per agent. A row each would double the editor's height
    // to show what is almost always a single model.
    Item {
      width: parent.width
      height: fallbackRow.implicitHeight
      visible: root.row && root.row.file === "ohmy"

      Row {
        id: fallbackRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(140) + Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "falls back to"
          color: root.veryMuted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.row ? root.row.fallbacks : []

          BorderSurface {
            required property var modelData
            required property int index
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: chip.implicitWidth + Style.spacing.lg * 2
            implicitHeight: chip.implicitHeight + Style.spacing.sm * 2
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

            Row {
              id: chip
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Model.shortModel(modelData.model)
                     + (modelData.variant ? " " + modelData.variant : "")
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "󰅖"
                color: chipHover.hovered ? Color.urgent : root.veryMuted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                HoverHandler { id: chipHover }
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.fallbackRemoved(index)
                }
              }
            }
          }
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰐕"
          tooltipText: "Add a fallback model"
          fontSize: Style.font.bodySmall
          foreground: root.veryMuted
          hoverColor: root.foreground
          onClicked: root.fallbackAddRequested()
        }
      }
    }
  }
}
