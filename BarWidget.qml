import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/Palette.js" as Palette

// The bar slot: which profile is running, and a way in. Panel.qml does the work;
// this file owns the icon, the label, and the open/close contract the bar routes
// summon/hide/toggle through. The label defaults to a two-letter tag, not the full
// name: a bar that changes width on every switch twitches all day.
BarWidget {
  id: root
  moduleName: "oliwier.opencode-configs"

  readonly property string labelMode: String(setting("barLabel", "Profile name"))
  readonly property var panel: panelLoader.item

  readonly property string tag: panel ? panel.activeShortName : ""
  readonly property string fullName: panel ? panel.activeName : ""
  readonly property string modelName: panel ? panel.activeModel : ""
  readonly property bool drift: panel ? panel.drift === true : false
  readonly property bool broken: panel ? panel.configBroken === true : false
  readonly property string tier: panel ? panel.activeTier : "unknown"
  readonly property bool topTier: root.tier === "top"

  // On a transparent bar the wallpaper is the backdrop: barForeground's luminance, not the bar background, decides the side.
  readonly property bool onDarkSurface:
    Palette.lumOf(root.bar ? root.bar.barForeground : Color.foreground) > 0.5

  // The silhouette stays the bar's own foreground: the mark has to read as opencode
  // first and as state second, and a frame that changes hue on every switch stops
  // being a logo. Only a config that will not parse may recolour the whole thing.
  readonly property color frameColor: root.broken
    ? (root.bar ? root.bar.urgent : Color.urgent)
    : (root.bar ? root.bar.barForeground : Color.foreground)

  // The cursor block is the one state channel. Cost is ordinal, so it grades by
  // alpha off the frame exactly like the panel's dot, and only the top of the
  // ladder earns opencode's own purple.
  readonly property color cursorColor: {
    if (root.broken) return root.bar ? root.bar.urgent : Color.urgent
    if (root.topTier) return Palette.opencodeInkOn(root.onDarkSurface)
    if (root.tier === "unknown") return Util.alpha(root.frameColor, Palette.markNeutralAlpha())
    return Util.alpha(root.frameColor, Palette.tierAlpha(root.tier))
  }

  readonly property string labelText: {
    if (root.vertical || root.labelMode === "Nothing") return ""
    if (root.labelMode === "Model") return root.modelName
    return root.tag
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = slot
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Shape contract for shell.summon/hide/toggle routing. Bar.findPanelWidget
  //      needs open/close/opened on the bar-widget root, so these delegate down.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }
  function reloadOpencode() { if (panelLoader.item) panelLoader.item.reloadRunningOpencode() }

  implicitWidth: slot.implicitWidth
  implicitHeight: slot.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "oliwier.opencode-configs"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function reload(): void { root.reloadOpencode() }
  }

  // Underline what the widget paints rather than 55% of whatever slot it
  // happens to fill, which is what the bar assumes when a widget says nothing.
  readonly property real openPanelIndicatorWidth: row.implicitWidth
  readonly property real openPanelIndicatorHeight: Style.bar.iconCanvas

  Item {
    id: slot
    // Icon-only and vertical keep the 27px slot every other icon-only module uses.
    // With a tag the 8.5 house edge padding goes outside the pair, never between icon and label.
    implicitWidth: root.vertical
      ? root.barSize
      : (root.labelText !== "" ? row.implicitWidth + Style.spaceReal(8.5) * 2
                               : Style.bar.iconSlot)
    implicitHeight: root.barSize

    Row {
      id: row
      anchors.centerIn: parent
      // Measured bug: at 6px the tag sat 12.57px from its own glyph but 11.41px from
      // the next plugin's, so the eye grouped it with the neighbour. 2 gives ~1/3 that gap.
      spacing: root.labelText !== "" ? Style.space(2) : 0

      Item {
        id: iconSlot
        anchors.verticalCenter: parent.verticalCenter
        // The canvas, not the slot: the mark paints under 10px and reserving 27
        // put most of the gap inside the widget.
        width: root.labelText !== "" ? Style.bar.iconCanvas : Style.bar.iconSlot
        height: Style.bar.iconCanvas

        OpencodeMark {
          anchors.centerIn: parent
          size: Style.bar.iconFont
          frameColor: root.frameColor
          cursorColor: root.cursorColor
        }

        // Drawn over the glyph rather than beside it: a dot that adds width
        // would nudge every widget to its left every time the config is edited.
        Rectangle {
          visible: root.drift && !root.broken
          anchors.right: parent.right
          anchors.top: parent.top
          width: Style.space(4)
          height: width
          radius: width / 2
          color: Color.accent
        }
      }

      Text {
        id: tag
        anchors.verticalCenter: parent.verticalCenter
        visible: root.labelText !== ""
        textFormat: Text.PlainText
        text: root.labelText
        // The tag stays the panel's own text colour, always. The glyph is
        // carrying the signal, and two coloured things two pixels apart compete.
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
        // Pinned so the bar never changes width on a switch: three cells for a
        // tag, a fixed cap for a model name that could be any length.
        width: root.labelMode === "Model" ? Style.space(110) : tagBox.width

        TextMetrics {
          id: tagBox
          font: tag.font
          text: "WWW"
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onEntered: if (root.bar && root.panel) root.bar.showTooltip(root, root.panel.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(root)

      onClicked: function (mouse) {
        if (root.bar) root.bar.hideTooltip(root)
        // Middle click re-reads the config and the model list without opening
        // anything — the same gesture the clock and weather widgets use.
        if (mouse.button === Qt.MiddleButton) root.refresh()
        else root.togglePanel()
      }

      // Scroll is deliberately unbound: a stray scroll over the bar must never rewrite the config.
    }
  }
}
