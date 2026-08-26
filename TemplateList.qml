import QtQuick
import qs.Commons
import qs.Ui
import "lib/Palette.js" as Palette

// Ready-made profiles: a whole config matched to a provider, so someone who has
// just connected a key does not have to pick twenty models by hand.
//
// A template you cannot reach is shown, not hidden. Not having a key yet is a
// reason to know the template exists, and the row says which key is missing.
Item {
  id: root

  property var templates: []
  property var authedProviders: []
  property var catalogIndex: ({})
  property string shape: ""
  property bool busy: false

  property bool cursorActive: false
  property int selectedIndex: 0

  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)

  signal backRequested()
  signal installRequested(string id)
  signal cursorMoved(int index)

  readonly property int desiredHeight:
    header.implicitHeight + Style.spacing.xl
    + Math.max(Style.space(80), list.contentHeight)
    + Style.spacing.xl + footer.implicitHeight

  function missingFor(tpl) {
    var need = (tpl && tpl.requires) || []
    var out = []
    for (var i = 0; i < need.length; i++) {
      if (root.authedProviders.indexOf(need[i]) < 0) out.push(need[i])
    }
    return out
  }

  readonly property bool ohmyHere: root.shape === "oh-my-openagent"

  function fillsFor(tpl) {
    if (!tpl) return ""
    if (root.ohmyHere && tpl.ohmy) {
      var a = Object.keys(tpl.ohmy.agents || {}).length
      var c = Object.keys(tpl.ohmy.categories || {}).length
      return a + (a === 1 ? " agent" : " agents") + (c > 0 ? " and " + c + " categories" : "")
    }
    if (tpl.opencode) {
      var n = Object.keys(tpl.opencode.agent || {}).length
      var bits = []
      if (tpl.opencode.model) bits.push("the default model")
      if (n > 0) bits.push(n + (n === 1 ? " agent" : " agents"))
      return bits.join(" and ")
    }
    return ""
  }

  function usableHere(tpl) {
    return root.ohmyHere ? !!(tpl && (tpl.ohmy || tpl.opencode)) : !!(tpl && tpl.opencode)
  }

  function selectedTemplate() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.templates.length) return null
    return root.templates[root.selectedIndex]
  }

  Column {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.spacing.xl

    Item {
      width: parent.width
      height: Math.max(title.implicitHeight, backButton.height)

      PanelActionButton {
        id: backButton
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅁"
        tooltipText: "Back to profiles"
        foreground: root.muted
        hoverColor: root.foreground
        onClicked: root.backRequested()
      }

      Text {
        id: title
        anchors.left: backButton.right
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.lg
        textFormat: Text.PlainText
        text: "Templates"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: {
        var base = "Each one sets a model on every agent, matched to what that agent does — the "
                 + "heavy thinking on a strong model, the file-scanning on a cheap fast one. "
        return base + (root.ohmyHere
          ? "Your config is oh-my-openagent, so they fill its agents and categories."
          : "Your config is plain opencode, so they fill its agents. The oh-my-openagent half of "
          + "each template is left alone unless you install that plugin.")
      }
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }
  }

  ListView {
    id: list
    anchors.top: header.bottom
    anchors.bottom: footer.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.spacing.xl
    anchors.bottomMargin: Style.spacing.xl
    clip: true
    spacing: Style.spacing.labelGap
    boundsBehavior: Flickable.StopAtBounds
    model: root.templates
    currentIndex: root.selectedIndex
    highlightRangeMode: ListView.ApplyRange
    // Zero, not a margin: a non-zero begin scrolls the list on load so the
    // first row and its heading sit above the fold before anything is touched.
    preferredHighlightBegin: 0
    preferredHighlightEnd: height - Style.space(40)
    highlightMoveDuration: 0

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index
      width: list.width
      implicitHeight: labels.implicitHeight + Style.spacing.xxl

      readonly property bool isCursor: root.cursorActive && root.selectedIndex === index
      readonly property var missing: root.missingFor(modelData)

      CursorSurface {
        anchors.fill: parent
        foreground: root.foreground
        accent: root.accent
        hasCursor: rowItem.isCursor
      }

      Column {
        id: labels
        anchors.left: parent.left
        anchors.right: installButton.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xxs

        Row {
          spacing: Style.spacing.md

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            readonly property string tint: modelData.vendor || ""
            width: Style.space(6)
            height: width
            radius: width / 2
            color: Palette.providerTint(tint, root.accent, Color.popups.background, root.veryMuted)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: rowItem.missing.length > 0
            text: "needs " + rowItem.missing.join(", ")
            color: root.veryMuted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "sets " + root.fillsFor(modelData)
            color: root.veryMuted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: modelData.description || ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: !!(modelData.source && modelData.source.url)
          text: modelData.source ? ("from " + modelData.source.url) : ""
          color: root.veryMuted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: installButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        text: "Add to profiles"
        fontSize: Style.font.caption
        bordered: true
        enabled: !root.busy && root.usableHere(modelData)
        foreground: root.foreground
        accent: root.accent
        onClicked: root.installRequested(modelData.id)
      }

      MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: installButton.left
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.cursorMoved(index)
      }
    }
  }

  Column {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    spacing: Style.spacing.md

    PanelSeparator { width: parent.width; foreground: root.foreground }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      // Adding is not switching: the template becomes a profile you can read
      // and edit before anything on disk changes.
      text: "Adding one saves it as a profile. Nothing changes until you switch to it."
      color: root.veryMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "↑↓ move   ⏎ add   esc back"
      color: root.veryMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
