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
    || fallbackPicker.popupOpen
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
  // Row waiting on the fallback picker: + sets it with index -1 (append), a chip
  // click sets it with the chip index (replace in place); a dismissal clears it.
  property int pendingFallbackRow: -1
  property int pendingFallbackIndex: -1
  signal cursorMoved(int index)
  signal refreshCatalogRequested()

  function rowKey(row) { return row.file + " " + row.group + " " + row.key }

  // ---- Name column width --------------------------------------------------
  // One width for every row, so the controls line up — but measured off the
  // longest name actually in this roster instead of a fixed 140px. The roster
  // is eleven agents whose longest is "hephaestus"; reserving the old width
  // left most rows with a third of a column of nothing between the name and
  // the model. Capped at the old value so it can never come out worse, and
  // floored so a roster of very short names does not crowd the two together.
  FontMetrics {
    id: nameMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
  FontMetrics {
    id: kindMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  readonly property real labelWidth: {
    var w = 0
    for (var i = 0; i < root.rows.length; i++) {
      var r = root.rows[i]
      w = Math.max(w, nameMetrics.advanceWidth(String(r.label || "")))
      // The kind sits under the name in the same column and is often the
      // wider of the two: "opencode agent" outruns every agent name there is.
      var kind = r.group === "category"
        ? "category"
        : ((r.file === "opencode" && r.group === "agent") ? "opencode agent" : "")
      if (kind !== "") w = Math.max(w, kindMetrics.advanceWidth(kind))
    }
    // Style.space(14) is the room the unsaved-change dot takes to the left of
    // a name; without it a touched row would elide what an untouched one fits.
    return Math.min(Style.space(140), Math.max(Style.space(56), w + Style.space(14)))
  }

  // Model reset survival: model: root.rows is a fresh JS array from
  // Model.rowsFor on every profileEdited, so ListView sees a model reset and
  // drops contentY to 0. Save the viewport before the reset lands ...
  onProfileChanged: {
    if (!agentList) return
    agentList.savedY = agentList.contentY
    agentList.savedIndex = root.selectedIndex
  }

  // ... and restore after contentHeight has caught up (delegate heights shift
  // when the fallback line wraps). ContentY only: a positionViewAtIndex after
  // it fights the restore (cursor row != edited row) and reads as bouncing.
  onRowsChanged: {
    if (!agentList) return
    var y = agentList.savedY
    Qt.callLater(function() {
      if (!agentList || agentList.contentHeight <= agentList.height) return
      var maxY = Math.max(0, agentList.contentHeight - agentList.height)
      var target = Math.min(Math.max(0, y), maxY)
      if (Math.abs(agentList.contentY - target) > 1) agentList.contentY = target
    })
  }

  // Called when the editor closes: a delegate torn down while its popup was
  // open cannot clear this itself.
  function clearPickerState() {
    agentList.anyPickerOpen = false
    root.clearFallbackPicker()
  }

  function clearFallbackPicker() {
    fallbackPicker.close()
    root.pendingFallbackRow = -1
    root.pendingFallbackIndex = -1
    fallbackPicker.value = ""
  }

  // Opens the shared fallback picker under the chip that asked for it:
  // fbIndex -1 appends, >= 0 replaces. sceneX/sceneY/h are that chip's
  // rectangle, in scene coordinates.
  function openFallbackPicker(row, fbIndex, sceneX, sceneY, h) {
    if (row < 0 || row >= root.rows.length) return

    // A second click on the chip that opened the list closes it, the way the
    // model picker beside it now does. Only expressible because this picker
    // does not dismiss on an outside press: it would already be shut by the
    // time this ran, and reopening would read as a list that never closes.
    if (fallbackPicker.popupOpen
        && root.pendingFallbackRow === row
        && root.pendingFallbackIndex === fbIndex) {
      fallbackPicker.close()
      root.pendingFallbackRow = -1
      root.pendingFallbackIndex = -1
      fallbackPicker.value = ""
      return
    }

    root.pendingFallbackRow = row
    root.pendingFallbackIndex = fbIndex
    if (fbIndex >= 0 && fbIndex < root.rows[row].fallbacks.length)
      fallbackPicker.value = root.rows[row].fallbacks[fbIndex].model
    else
      fallbackPicker.value = ""

    // Below the chip when the list fits there, above it when it does not —
    // a chip near the footer would otherwise open a list running off the
    // bottom of the panel. Clamped into the editor on both axes.
    var p = root.mapFromItem(null, sceneX, sceneY)
    var lift = Style.spacing.xxs
    var below = p.y + h + lift
    var above = p.y - fallbackPicker.popupHeight - lift
    fallbackPicker.x = Math.max(0, Math.min(p.x, root.width - fallbackPicker.popupWidth))
    fallbackPicker.y = (below + fallbackPicker.popupHeight <= root.height)
      ? below
      : Math.max(0, above)
    fallbackPicker.open()
  }

  function applyRowModel(index, modelId) {
    if (!root.profile || index < 0 || index >= root.rows.length) return
    var next = Model.setRowModel(root.profile, root.rows[index], modelId)
    // Carrying an effort across a model change is the one place this can write
    // a config that loads and then fails: not every model offers every effort.
    // Every row that has an effort control gets this, not just the oh-my-openagent
    // ones — opencode's own AgentConfig carries a variant too, and an opencode
    // agent row was keeping the old model's effort on a new model that has none.
    var wanted = root.rows[index].variant
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

  function moveFallback(index, fbIndex, delta) {
    if (!root.profile || index < 0 || index >= root.rows.length) return
    var list = root.rows[index].fallbacks.slice()
    if (fbIndex < 0 || fbIndex >= list.length) return
    var to = fbIndex + delta
    if (to < 0 || to >= list.length) return
    var tmp = list[fbIndex]
    list[fbIndex] = list[to]
    list[to] = tmp
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

    highlightRangeMode: ListView.NoHighlightRange
    // NoHighlightRange: cursor is custom (CursorSurface + hasCursor), not the
    // ListView highlight. ApplyRange repositions contentY on every model reset
    // (model: root.rows is a fresh array per edit), jumping to top.
    highlightMoveDuration: 0

    // A dropdown must be able to paint past the row that owns it, and a
    // clipping ListView would cut it off at the row edge.
    property bool anyPickerOpen: false

    // Viewport saved across model resets; see onProfileChanged/onRowsChanged.
    property real savedY: 0
    property int savedIndex: -1

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
      labelWidth: root.labelWidth
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      hasCursor: root.cursorActive && root.selectedIndex === parent.index
      changed: root.changedKeys[root.rowKey(parent.modelData)] === true

      onEntered: root.cursorMoved(parent.index)
      onModelPicked: function (id) { root.applyRowModel(parent.index, id) }
      onVariantPicked: function (v) { root.applyRowVariant(parent.index, v) }
      onFallbackRemoved: function (i) { root.removeFallback(parent.index, i) }
      onFallbackMoveRequested: function (i, d) { root.moveFallback(parent.index, i, d) }
      onFallbackAddRequested: function (x, y, h) { root.openFallbackPicker(parent.index, -1, x, y, h) }
      onFallbackEditRequested: function (i, x, y, h) { root.openFallbackPicker(parent.index, i, x, y, h) }
      onFavoriteToggled: function (id) { root.favoriteToggled(id) }
      onPickerOpenChanged: agentList.anyPickerOpen = pickerOpen
      }
    }
  }

  // Light dismiss. This picker keeps CloseOnEscape only, because the chip that
  // opens it is not the popup's parent and CloseOnPressOutside would shut the
  // list on the press, leaving the click to reopen it — the same race the model
  // picker's CloseOnPressOutsideParent removes, which is not available here.
  // So the outside press is handled by hand instead. It is not propagated, so a
  // press outside only dismisses, which is exactly what the model picker beside
  // it does.
  MouseArea {
    anchors.fill: parent
    enabled: fallbackPicker.popupOpen
    visible: enabled
    onPressed: root.clearFallbackPicker()
  }

  // ---- Fallback picker ----------------------------------------------------
  // One hidden ModelPicker for every + on a fallback row and every chip click:
  // + appends {model, variant} to that row, a chip click replaces the chip in
  // place (same picker, current model ticked). It lives here — not in the
  // AgentRow delegate — so the ListView above cannot cut its popup, and so a
  // row does not carry one of these per chip. The trigger stays invisible
  // because it is only ever opened by code; openFallbackPicker() moves this
  // whole item under the chip first, and the popup follows it.
  ModelPicker {
    id: fallbackPicker
    width: popupWidth
    height: 0
    opacity: 0
    // Enabled must stay true: `enabled: false` propagates into the QQC.Popup
    // children and kills the search field + list interaction (popup opens but
    // nothing is clickable). The trigger is neutralised by triggerHeight 0
    // instead: zero-height, invisible, intercepts no mouse, popup still
    // positions fine. Not rowHeight — that one also sizes the popup's search
    // field and result rows, and zeroing it stacked every model on one line.
    enabled: true
    triggerHeight: 0
    dismissOnOutsidePress: false
    catalog: root.catalog
    catalogIndex: root.catalogIndex
    favorites: root.favorites
    recents: root.recents
    showMeta: root.showMeta
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    // It opens in a fixed place under the header rather than beside the chip
    // that summoned it, so it has to say out loud which agent it is about to
    // change — otherwise the row you clicked is off behind the popup.
    placeholderText: {
      if (root.pendingFallbackRow < 0 || root.pendingFallbackRow >= root.rows.length)
        return "Pick a fallback model"
      var name = root.rows[root.pendingFallbackRow].label
      return root.pendingFallbackIndex >= 0
        ? "Replace a fallback behind " + name
        : "Add a fallback behind " + name
    }
    value: ""
    onChanged: function (id) {
      var r = root.pendingFallbackRow
      var f = root.pendingFallbackIndex
      root.pendingFallbackRow = -1
      root.pendingFallbackIndex = -1
      fallbackPicker.value = ""
      if (!id || r < 0 || r >= root.rows.length) return
      // A chain that falls back to what it is already running is a chain that
      // does nothing: the model it just failed on is the model it retries.
      if (root.rows[r].model === id) return
      var list = root.rows[r].fallbacks.slice()
      if (f >= 0 && f < list.length) {
        if (list[f].model === id) return
        for (var d = 0; d < list.length; d++) if (d !== f && list[d].model === id) return
        list[f] = { model: id, variant: Catalog.nearestVariant(root.catalogIndex, id, list[f].variant || "high") }
      } else {
        for (var i = 0; i < list.length; i++) if (list[i].model === id) return
        list.push({ model: id, variant: Catalog.nearestVariant(root.catalogIndex, id, "high") })
      }
      root.profileEdited(Model.setRowFallbacks(root.profile, root.rows[r], list))
    }
    onFavoriteToggled: function (id) { root.favoriteToggled(id) }
    onPopupOpenChanged: {
      // A pick commits synchronously right after close() and clears the row
      // itself; only a dismissal still has it set when this fires.
      if (!fallbackPicker.popupOpen && root.pendingFallbackRow >= 0) {
        var r = root.pendingFallbackRow
        var f = root.pendingFallbackIndex
        Qt.callLater(function () {
          if (root.pendingFallbackRow === r && root.pendingFallbackIndex === f) {
            root.pendingFallbackRow = -1
            root.pendingFallbackIndex = -1
            fallbackPicker.value = ""
          }
        })
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
