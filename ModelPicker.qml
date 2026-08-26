import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "lib/Catalog.js" as Catalog
import "lib/Palette.js" as Palette

// Pick a model out of every model your opencode can reach. A fork of the shell's
// SearchableDropdown, which suits six options — not the 400 reachable here (6000 across all
// providers): this ranks matches rather than filtering, shows price and context, floats
// favourites/recents, searches unreachable models. Trigger/focus/escape match the shared control.
Item {
  id: root

  // ---- Data
  property var catalog: null                 // Catalog.js document
  property var catalogIndex: ({})            // id -> model, built once by the panel
  property string value: ""
  property var favorites: []
  property var recents: []
  property bool showMeta: true

  // ---- Chrome
  property string placeholderText: "Pick a model"
  property string label: ""
  property bool showLabel: false
  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupWidth: Style.space(460)
  property int visibleRows: 11

  readonly property var popupBorderSpec:
    Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
  // Util.alpha, not Qt.darker: on a light theme Qt.darker makes muted louder than the
  // foreground, and on an all-black-text theme all three levels collapse into one.
  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)

  // Lets the host panel suspend its key handling, so "j" typed here does not move its cursor too.
  readonly property bool popupOpen: popup.opened
  property bool hasCursor: false

  signal changed(string modelId)
  signal favoriteToggled(string modelId)
  signal hovered(bool isHovered)

  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }

  // ---- Derived ------------------------------------------------------------

  readonly property bool knowsReachable: root.catalog && root.catalog.reachableCount > 0
  property string scope: "reachable"          // "reachable" | "all"
  readonly property string effectiveScope: root.knowsReachable ? root.scope : "all"
  property string query: ""

  readonly property var currentModel: Catalog.lookup(root.catalog, root.catalogIndex, root.value)

  readonly property var result: Catalog.search(root.catalog, root.query, {
    scope: root.effectiveScope,
    limit: 200,
    favorites: root.favorites,
    recents: root.recents,
    current: root.value
  })

  // Headings only while the list is unqueried. Once you are typing, rank is the
  // organising principle and a heading just pushes the answer further down.
  readonly property var rows: Catalog.withGroups(root.result, root.query === "")

  function commit(id) {
    if (!id) return
    root.value = id
    // Close first: changed() swaps the editor's model synchronously and destroys this delegate,
    // and close() on a destroyed item never reports back — the panel's keyboard stays blocked.
    popup.close()
    root.changed(id)
  }

  implicitWidth: Style.space(300)
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  Column {
    anchors.fill: parent
    spacing: Style.spacing.labelGap

    Text {
      visible: root.showLabel && root.label !== ""
      text: root.label
      textFormat: Text.PlainText
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    // ---- Trigger ----------------------------------------------------------

    BorderSurface {
      id: trigger
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius
      activeFocusOnTab: true

      readonly property bool _focused: trigger.activeFocus
      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      color: Style.controlFill(_focused, _hot, root.foreground, root.accent)
      borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"),
                                     root.foreground, root.accent)

      HoverHandler { id: triggerHover; onHoveredChanged: root.hovered(hovered) }

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          root.toggle(); event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          popup.close(); event.accepted = true
        }
      }

      // Which vendor this row points at, without opening the picker. Hue rotates off the theme
      // accent so it survives a theme swap; filled/hollow alternate so hue is not load-bearing.
      Rectangle {
        id: triggerMark
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
        width: Style.space(7)
        height: width
        radius: width / 2
        visible: root.value !== ""
        readonly property string provider: root.currentModel ? root.currentModel.provider : ""
        readonly property color tint:
          Palette.providerTint(provider, root.accent, root.background, root.veryMuted)
        readonly property bool filled: Palette.providerFilled(provider)
        color: filled ? tint : "transparent"
        border.color: filled ? "transparent" : tint
        border.width: filled ? 0 : Math.max(1, Style.space(2))
      }

      Text {
        id: triggerLabel
        anchors.left: triggerMark.visible ? triggerMark.right : parent.left
        anchors.right: triggerMeta.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: triggerMark.visible
          ? Style.spacing.lg
          : trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.md
        // Never AutoText: these strings come out of a JSON file, and AutoText
        // would fetch whatever a crafted one pointed at.
        textFormat: Text.PlainText
        text: root.value ? root.value : root.placeholderText
        color: root.value
          ? ((root.currentModel && root.currentModel.unknown && root.catalog
              && root.catalog.models.length > 0) ? Color.urgent : root.foreground)
          : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideLeft   // the model name is the end of the id, so keep it
      }

      Text {
        id: triggerMeta
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        textFormat: Text.PlainText
        visible: root.showMeta && text !== ""
        text: root.value ? Catalog.formatPrice(root.currentModel) : ""
        color: root.veryMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: "󰅀"
        color: Util.alpha(root.foreground, 0.75)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { trigger.forceActiveFocus(); root.toggle() }
      }

      // ---- Popup ----------------------------------------------------------

      QQC.Popup {
        id: popup
        // Wider than the trigger, and pulled back left so it stays inside the
        // panel when the trigger sits against the right edge.
        width: root.popupWidth
        x: Math.min(0, trigger.width - width)
        y: trigger.height + Style.spacing.xxs
        implicitHeight: header.height + 1 + listArea.preferredHeight + footer.height
        padding: Style.spacing.hairline
        leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
        rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
        topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
        bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
        focus: true

        background: BorderSurface {
          color: root.background
          borderSpec: root.popupBorderSpec
          radius: Style.cornerRadius
        }

        onOpened: {
          searchField.text = ""
          root.query = ""
          resultList.currentIndex = firstSelectableIndex()
          Qt.callLater(function () { searchField.forceActiveFocus() })
        }
        onClosed: { searchField.text = ""; root.query = "" }

        function firstSelectableIndex() {
          for (var i = 0; i < root.rows.length; i++) if (!root.rows[i].header) return i
          return -1
        }

        function step(delta) {
          var i = resultList.currentIndex
          for (var n = 0; n < root.rows.length; n++) {
            i += delta
            if (i < 0) return -1
            if (i >= root.rows.length) return resultList.currentIndex
            if (!root.rows[i].header) return i
          }
          return resultList.currentIndex
        }

        function activate() {
          var i = resultList.currentIndex
          if (i < 0 || i >= root.rows.length) return
          var row = root.rows[i]
          if (row.header) return
          root.commit(row.id)
        }

        function favoriteCurrent() {
          var i = resultList.currentIndex
          if (i < 0 || i >= root.rows.length) return
          var row = root.rows[i]
          if (row.header) return
          root.favoriteToggled(row.id)
        }

        contentItem: Column {
          spacing: 0

          // ---- Search + scope
          Item {
            id: header
            width: parent.width
            height: root.rowHeight + Style.spacing.controlPaddingX

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.right: scopeToggle.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              height: root.rowHeight
              placeholderText: root.effectiveScope === "reachable"
                ? "Search " + (root.catalog ? root.catalog.reachableCount : 0) + " models you can use"
                : "Search " + (root.catalog ? root.catalog.totalCount : 0) + " models"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              onTextChanged: {
                root.query = text
                resultList.currentIndex = popup.firstSelectableIndex()
                resultList.positionViewAtBeginning()
              }

              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) {
                  // One escape clears the filter, the next closes the popup —
                  // so a mistyped query costs one key, not the whole popup.
                  if (searchField.text !== "") searchField.text = ""
                  else popup.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  var n = popup.step(1)
                  if (n >= 0) { resultList.currentIndex = n; resultList.forceActiveFocus() }
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (resultList.currentIndex >= 0) popup.activate()
                  // A model id is just a string in JSON: one the catalog missed is still committable.
                  else if (searchField.text.indexOf("/") > 0) root.commit(searchField.text.trim())
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.scope = root.scope === "reachable" ? "all" : "reachable"
                  event.accepted = true
                } else if (event.text === "*") {
                  // The footer advertises "*", but the popup opens focused here, not in the
                  // list — without this the key just typed an asterisk into the filter.
                  popup.favoriteCurrent()
                  event.accepted = true
                }
              }
            }

            Button {
              id: scopeToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.spacing.md
              height: root.rowHeight
              text: root.effectiveScope === "reachable" ? "Yours" : "All"
      enabled: root.knowsReachable
      opacity: enabled ? 1 : 0.45
              tooltipText: root.scope === "reachable"
                ? "Showing the models this opencode can reach. Tab for every model models.dev knows."
                : "Showing every model models.dev knows, reachable or not. Tab to go back to yours."
              fontSize: Style.font.caption
              foreground: root.foreground
              accent: root.accent
              bordered: true
              onClicked: root.scope = root.scope === "reachable" ? "all" : "reachable"
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.10) }

          // ---- Results
          Item {
            id: listArea
            width: parent.width
            readonly property int preferredHeight:
              Math.max(Style.space(120), Math.min(resultList.contentHeight + Style.spacing.md,
                                                  root.visibleRows * (root.rowHeight + Style.spacing.xxs)))
            height: preferredHeight

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.md
              visible: root.rows.length === 0
              width: parent.width - Style.space(40)

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: root.query === ""
                  ? "The model list is empty."
                  : "No model matches “" + root.query + "”."
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                visible: root.knowsReachable && root.scope === "reachable"
                text: "Tab searches every model, not just the ones you can reach."
                color: root.veryMuted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.query.indexOf("/") > 0
                text: "Use “" + root.query + "” anyway"
                fontSize: Style.font.caption
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.commit(root.query.trim())
              }
            }

            ListView {
              id: resultList
              anchors.fill: parent
              anchors.margins: Style.spacing.xxs
              spacing: Style.spacing.xxs
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.rows
              currentIndex: -1
              keyNavigationEnabled: false
              highlightMoveDuration: 0
              // 200 rows max, all the same height — recycling keeps even a 6000-model catalog cheap.
              reuseItems: true

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) { popup.close(); event.accepted = true }
                else if (event.key === Qt.Key_Down || event.text === "j") {
                  var d = popup.step(1); if (d >= 0) resultList.currentIndex = d
                  event.accepted = true
                } else if (event.key === Qt.Key_Up || event.text === "k") {
                  var u = popup.step(-1)
                  if (u < 0) searchField.forceActiveFocus(); else resultList.currentIndex = u
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  popup.activate(); event.accepted = true
                } else if (event.text === "*") {
                  popup.favoriteCurrent(); event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.scope = root.scope === "reachable" ? "all" : "reachable"
                  event.accepted = true
                } else if (event.text && event.text.length === 1 && event.text >= " ") {
                  // Printable keys belong to the filter; otherwise list focus eats the first letter.
                  searchField.text += event.text
                  searchField.forceActiveFocus()
                  event.accepted = true
                }
              }

              delegate: Loader {
                required property var modelData
                required property int index
                width: resultList.width
                sourceComponent: modelData && modelData.header ? headerRow : modelRow

                Component {
                  id: headerRow
                  Item {
                    width: resultList.width
                    height: Style.space(22)
                    Text {
                      anchors.left: parent.left
                      anchors.bottom: parent.bottom
                      anchors.leftMargin: Style.spacing.controlPaddingX
                      anchors.bottomMargin: Style.spacing.xs
                      textFormat: Text.PlainText
                      text: String(modelData.header || "").toUpperCase()
                      color: root.veryMuted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.2
                    }
                  }
                }

                Component {
                  id: modelRow
                  CursorSurface {
                    width: resultList.width
                    height: root.rowHeight
                    foreground: root.foreground
                    accent: root.accent
                    hasCursor: index === resultList.currentIndex
                    current: modelData.current === true

                    // Star first: the only thing in the row you press rather than read,
                    // and it stays put while names change length under the cursor.
                    Text {
                      id: star
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.spacing.md
                      text: modelData.favorite ? "󰓎" : "󰓒"
                      color: modelData.favorite ? root.accent
                           : (index === resultList.currentIndex ? root.muted : "transparent")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.spacing.xs
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.favoriteToggled(modelData.id)
                      }
                    }

                    // The same mark as the trigger. Scanning four hundred rows
                    // for "the Anthropic one" is the thing this accelerates.
                    Rectangle {
                      id: rowMark
                      anchors.left: star.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.spacing.lg
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      readonly property color tint: Palette.providerTint(
                        modelData.model.provider, root.accent, root.background, root.veryMuted)
                      readonly property bool filled: Palette.providerFilled(modelData.model.provider)
                      color: filled ? tint : "transparent"
                      border.color: filled ? "transparent" : tint
                      border.width: filled ? 0 : Math.max(1, Style.space(2))
                      opacity: modelData.model.reachable ? 1 : 0.5
                    }

                    Text {
                      id: name
                      anchors.left: rowMark.right
                      anchors.right: meta.left
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.spacing.lg
                      anchors.rightMargin: Style.spacing.lg
                      textFormat: Text.PlainText
                      text: modelData.model.name || modelData.model.modelId
                      color: modelData.model.reachable ? root.foreground : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Row {
                      id: meta
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.rightMargin: Style.spacing.controlPaddingX
                      spacing: Style.spacing.lg

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.showMeta && text !== ""
                        textFormat: Text.PlainText
                        text: Catalog.formatContext(modelData.model.context)
                        color: root.veryMuted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.showMeta && text !== ""
                        textFormat: Text.PlainText
                        text: Catalog.formatPrice(modelData.model)
                        color: modelData.model.free ? root.accent : root.veryMuted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      // One badge, never two. The second one is never why
                      // anybody picked a model.
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text !== "" && !root.showMeta
                        textFormat: Text.PlainText
                        text: Catalog.badgeFor(modelData.model)
                        color: root.veryMuted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.current === true
                        text: "󰄬"
                        color: root.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      anchors.leftMargin: star.width + rowMark.width + Style.spacing.lg * 2
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: resultList.currentIndex = index
                      onClicked: root.commit(modelData.id)
                    }
                  }
                }
              }
            }
          }

          // ---- Footer: what is not on screen, and how to move
          Item {
            id: footer
            width: parent.width
            height: Style.space(24)

            Rectangle {
              anchors.top: parent.top
              width: parent.width
              height: 1
              color: Util.alpha(root.foreground, 0.10)
            }

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              textFormat: Text.PlainText
              // A list that silently stops at two hundred reads as though that
              // is all there is. Saying the number turns a dead end into a hint.
              text: root.result.truncated
                ? "+" + (root.result.total - root.result.shown) + " more — keep typing"
                : (root.result.total + (root.result.total === 1 ? " model" : " models"))
              color: root.veryMuted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.spacing.controlPaddingX
              textFormat: Text.PlainText
              text: "⏎ pick   * star   ⇥ scope"
              color: root.veryMuted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
