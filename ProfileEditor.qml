import QtQuick
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model
import "lib/Catalog.js" as Catalog

// Editing one profile: a name, and a model for every agent. Edits go into a
// working copy until you save, which is what makes the bulk "every agent on
// Opus" gesture safe to offer — Discard sits right next to it. The save bar
// appears once something has changed and says how much.
Item {
  id: root

  property var profile: null                // working copy, edited in place here
  property var original: null               // what it looked like when the editor opened
  property var catalog: null
  property var catalogIndex: ({})
  property var favorites: []
  property var recents: []
  property bool showMeta: true
  property bool busy: false
  property bool isActiveProfile: false

  property bool cursorActive: false
  property int selectedIndex: 0

  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Util.alpha, not Qt.darker: on a light theme Qt.darker makes muted *more*
  // prominent than the foreground, and on all-black text the three levels collapse.
  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)

  readonly property var rows: root.profile ? Model.rowsFor(root.profile) : []
  readonly property var changes: (root.profile && root.original)
    ? Model.changedRows(root.original, root.profile) : []
  readonly property bool nameChanged: root.profile && root.original
    && (root.profile.name !== root.original.name || root.profile.shortName !== root.original.shortName)
  readonly property bool dirty: root.changes.length > 0 || root.nameChanged
  readonly property bool anyPickerOpen: agentList.anyPickerOpen || bulkPicker.popupOpen
    || nameField.activeFocus || tagField.activeFocus

  // Same rule as the list: ask for what the content needs, let the panel cap it.
  // Twenty agent rows are why this screen legitimately wants the whole cap.
  readonly property int desiredHeight:
    header.implicitHeight + Style.spacing.md
    + Math.max(Style.space(120), agentList.contentHeight)
    + Style.spacing.md + footer.implicitHeight

  readonly property var changedKeys: {
    var set = {}
    for (var i = 0; i < root.changes.length; i++) {
      set[root.changes[i].row.file + " " + root.changes[i].row.group + " " + root.changes[i].row.key] = true
    }
    return set
  }

  signal backRequested()
  signal saveRequested()
  signal discardRequested()
  signal profileEdited(var next)
  signal favoriteToggled(string modelId)
  signal fallbackRequested(int rowIndex)
  signal cursorMoved(int index)
  signal refreshCatalogRequested()

  function rowKey(row) { return row.file + " " + row.group + " " + row.key }

  // Called when the editor closes: a delegate torn down while its popup was
  // open cannot clear this itself.
  function clearPickerState() { agentList.anyPickerOpen = false }

  function applyRowModel(index, modelId) {
    if (!root.profile || index < 0 || index >= root.rows.length) return
    var next = Model.setRowModel(root.profile, root.rows[index], modelId)
    // Carrying an effort across a model change is the one place this can write
    // a config that loads and then fails: not every model offers every effort.
    var wanted = root.rows[index].file === "ohmy" ? root.rows[index].variant : ""
    if (wanted) next = Model.setRowVariant(next, root.rows[index],
                                           Catalog.nearestVariant(root.catalogIndex, modelId, wanted))
    root.profileEdited(next)
  }

  function applyRowVariant(index, variant) {
    if (!root.profile || index < 0 || index >= root.rows.length) return
    root.profileEdited(Model.setRowVariant(root.profile, root.rows[index], variant))
  }

  function removeFallback(index, fbIndex) {
    if (!root.profile || index < 0 || index >= root.rows.length) return
    var list = root.rows[index].fallbacks.slice()
    list.splice(fbIndex, 1)
    root.profileEdited(Model.setRowFallbacks(root.profile, root.rows[index], list))
  }

  function setAll(modelId) {
    if (!root.profile) return
    var index = root.catalogIndex
    root.profileEdited(Model.setAllModels(root.profile, modelId, function (id, row) {
      // Keep the row's effort, stepped down to one this model offers. Both shapes
      // have a variant field — opencode's AgentConfig included — but the two
      // opencode defaults are bare model strings and take none. A row the user
      // never set gets no effort invented for it either.
      if (row.group === "default") return ""
      if (!row.variant) return ""
      return Catalog.nearestVariant(index, id, row.variant)
    }))
  }

  // ---- Header ------------------------------------------------------------

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
        anchors.right: refreshButton.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.md
        textFormat: Text.PlainText
        text: root.profile ? "Editing “" + root.profile.name + "”" : "Editing"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      PanelActionButton {
        id: refreshButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰑐"
        tooltipText: "Re-read the model list"
        foreground: root.muted
        hoverColor: root.foreground
        onClicked: root.refreshCatalogRequested()
      }
    }

    // ---- Name, tag, default model
    Item {
      width: parent.width
      height: nameField.height

      Text {
        id: nameLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(64)
        textFormat: Text.PlainText
        text: "Name"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      TextField {
        id: nameField
        anchors.left: nameLabel.right
        anchors.right: tagLabel.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.xl
        height: Style.spacing.controlHeight
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.profile ? root.profile.name : ""
        onTextChanged: {
          if (!root.profile || text === root.profile.name) return
          var next = Model.clone(root.profile)
          next.name = text
          root.profileEdited(next)
        }
      }

      Text {
        id: tagLabel
        anchors.right: tagField.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        textFormat: Text.PlainText
        text: "Bar tag"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      TextField {
        id: tagField
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(56)
        height: Style.spacing.controlHeight
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        maximumLength: 3
        text: root.profile ? (root.profile.shortName || "") : ""
        onTextChanged: {
          if (!root.profile || text === root.profile.shortName) return
          var next = Model.clone(root.profile)
          next.shortName = text.toUpperCase()
          root.profileEdited(next)
        }
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }
  }

  // ---- Rows ---------------------------------------------------------------

  ListView {
    id: agentList
    anchors.top: header.bottom
    anchors.bottom: footer.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.spacing.md
    anchors.bottomMargin: Style.spacing.md
    clip: true
    spacing: 0
    boundsBehavior: Flickable.StopAtBounds
    model: root.rows
    currentIndex: root.selectedIndex

    highlightRangeMode: ListView.ApplyRange
    // Zero, not a margin: a non-zero begin scrolls the list on load so the
    // first row and its heading sit above the fold before anything is touched.
    preferredHighlightBegin: 0
    preferredHighlightEnd: height - Style.space(50)
    highlightMoveDuration: 0

    // A dropdown must be able to paint past the row that owns it, and a
    // clipping ListView would cut it off at the row edge.
    property bool anyPickerOpen: false

    // Model names its own sections: under oh-my-openagent the two opencode keys
    // are the bottom of a fallback chain, not the defaults, and they say so.
    function headingFor(row) {
      if (row && row.heading) return row.heading
      return row && row.group === "agent" ? "AGENTS"
           : (row && row.group === "category" ? "CATEGORIES" : "DEFAULTS")
    }

    delegate: Column {
      required property var modelData
      required property int index
      width: agentList.width
      spacing: 0

      readonly property bool startsGroup:
        index === 0 || agentList.headingFor(root.rows[index - 1]) !== agentList.headingFor(modelData)

      Item {
        width: parent.width
        height: parent.startsGroup ? Style.space(26) : 0
        visible: parent.startsGroup

        PanelSectionHeader {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.bottomMargin: Style.spacing.xs
          foreground: root.foreground
          fontFamily: root.fontFamily
          text: agentList.headingFor(modelData)
        }
      }

      AgentRow {
      width: agentList.width
      row: parent.modelData
      catalog: root.catalog
      catalogIndex: root.catalogIndex
      favorites: root.favorites
      recents: root.recents
      showMeta: root.showMeta
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      hasCursor: root.cursorActive && root.selectedIndex === parent.index
      changed: root.changedKeys[root.rowKey(parent.modelData)] === true

      onEntered: root.cursorMoved(parent.index)
      onModelPicked: function (id) { root.applyRowModel(parent.index, id) }
      onVariantPicked: function (v) { root.applyRowVariant(parent.index, v) }
      onFallbackRemoved: function (i) { root.removeFallback(parent.index, i) }
      onFallbackAddRequested: root.fallbackRequested(parent.index)
      onFavoriteToggled: function (id) { root.favoriteToggled(id) }
      onPickerOpenChanged: agentList.anyPickerOpen = pickerOpen
      }
    }
  }

  // ---- Footer -------------------------------------------------------------

  Column {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    spacing: Style.spacing.md

    PanelSeparator { width: parent.width; foreground: root.foreground }

    // Bulk. Quiet, and below the list rather than above it, because it is the
    // thing you reach for once and the rows are the thing you read every time.
    Item {
      width: parent.width
      height: bulkPicker.height

      Text {
        id: bulkLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.xs
        textFormat: Text.PlainText
        text: "Every agent on"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      ModelPicker {
        id: bulkPicker
        anchors.left: bulkLabel.right
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.lg
        catalog: root.catalog
        catalogIndex: root.catalogIndex
        favorites: root.favorites
        recents: root.recents
        showMeta: root.showMeta
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        placeholderText: "one model, every row"
        value: ""
        onChanged: function (id) { root.setAll(id); bulkPicker.value = "" }
        onFavoriteToggled: function (id) { root.favoriteToggled(id) }
      }
    }

    // The save bar. Absent until something changes, and then it says what.
    Loader {
      width: parent.width
      active: root.dirty
      sourceComponent: BorderSurface {
        width: footer.width
        implicitHeight: Style.space(40)
        radius: Style.cornerRadius
        color: Util.alpha(root.accent, 0.08)
        borderSpec: Border.flat(Util.alpha(root.accent, 0.28), Style.normalBorderWidth)

        Text {
          anchors.left: parent.left
          anchors.right: saveButtons.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xxl
          anchors.rightMargin: Style.spacing.md
          textFormat: Text.PlainText
          text: {
            var n = root.changes.length
            if (n === 0) return "Renamed"
            var body = n + (n === 1 ? " row changed" : " rows changed")
            return root.nameChanged ? body + ", renamed" : body
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Row {
          id: saveButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.lg
          spacing: Style.spacing.md

          Button {
            text: "Discard"
            fontSize: Style.font.caption
            bordered: true
            enabled: !root.busy
            foreground: root.foreground
            accent: root.accent
            onClicked: root.discardRequested()
          }

          Button {
            // Editing the running profile leaves the live config stale on save,
            // so saving re-applies; any other profile never touches it.
            text: root.isActiveProfile ? "Save and apply" : "Save"
            fontSize: Style.font.caption
            bordered: true
            selected: true
            enabled: !root.busy
            foreground: root.foreground
            accent: root.accent
            onClicked: root.saveRequested()
          }
        }
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      visible: !root.dirty
      text: "↑↓ move   esc back"
      color: root.veryMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
