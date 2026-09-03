import QtQuick
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model
import "lib/Palette.js" as Palette

// The panel's first screen: every profile you keep, and which one is running.
//
// A click switches; there is no Apply button. What keeps that safe is the backup
// taken on the way past and the Undo sitting under the list.
Item {
  id: root

  property var profiles: []
  property var catalogIndex: ({})
  property string activeProfileId: ""
  // False until both `list` and `detect` have answered once. Everything this screen
  // says about the running config is a claim about disk, and before the second half
  // lands the panel does not yet know enough to make one.
  property bool ready: true
  // Model.js keeps the roster and the shape in globals a binding cannot watch, so
  // the panel counts the moves and every summary below reads the count. Without it
  // a row keeps whatever it was first drawn with, which before detect answers is
  // the built-in four-agent roster.
  property int shapeGeneration: 0
  property bool drift: false
  property bool busy: false
  property string shapeName: ""
  property string backupLabel: ""
  property bool canUndo: false

  property string errorCode: ""
  property string errorMessage: ""
  property string errorPath: ""
  property string toast: ""
  property string notice: ""

  property bool cursorActive: false
  property int selectedIndex: 0
  property string query: ""

  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Util.alpha, not Qt.darker: on a light theme Qt.darker makes muted *more*
  // prominent than the foreground, and on all-black text all three levels collapse.
  readonly property color muted: Util.alpha(foreground, 0.66)
  readonly property color veryMuted: Util.alpha(foreground, 0.45)

  readonly property var visibleProfiles: {
    var q = String(root.query || "").toLowerCase()
    if (!q) return root.profiles
    var out = []
    for (var i = 0; i < root.profiles.length; i++) {
      var p = root.profiles[i]
      if (String(p.name || "").toLowerCase().indexOf(q) >= 0
          || String(p.id || "").toLowerCase().indexOf(q) >= 0
          || Model.summary(p).toLowerCase().indexOf(q) >= 0) out.push(p)
    }
    return out
  }

  readonly property var activeProfile: {
    for (var i = 0; i < root.profiles.length; i++)
      if (root.profiles[i].id === root.activeProfileId) return root.profiles[i]
    return null
  }

  // A search field for four profiles is furniture. It arrives when the list is
  // long enough that scanning it stops being instant.
  readonly property bool searchable: root.profiles.length >= 8

  readonly property string activeTier: activeProfile
    ? Palette.profileTier(Model.rowsFor(activeProfile), root.catalogIndex) : "unknown"

  // The height this screen wants: a fixed one leaves empty card under a short list, which reads as a failed load.
  readonly property int desiredHeight:
    header.implicitHeight + Style.spacing.xl
    + Math.max(Style.space(60), list.contentHeight)
    + Style.spacing.xl + footer.implicitHeight

  signal applyRequested(string id)
  signal editRequested(string id)
  signal deleteRequested(string id)
  signal duplicateRequested(string id)
  signal saveCurrentRequested()
  signal updateActiveRequested()
  signal undoRequested()
  signal openFileRequested(string path)
  signal cursorMoved(int index)
  signal dismissToast()

  function selectedProfile() {
    var list = root.visibleProfiles
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  // ---- Header ------------------------------------------------------------

  Column {
    id: header
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.spacing.xl

    PanelHero {
      width: parent.width
      foreground: root.foreground
      fontFamily: root.fontFamily
      // PanelHero is the shell's, so its Text is not ours to set PlainText on.
      // Everything reaching it is neutralised on the way instead.
      title: Model.plain(root.activeProfile ? root.activeProfile.name
           : (root.activeProfileId ? root.activeProfileId
           : (root.ready ? "Custom" : "Opencode")))
      meta: {
        if (root.errorCode !== "") return "CONFIG NOT READ"
        // "Nothing matches" is a finding, not a default. Until the reads are in,
        // say what is actually happening instead of asserting the worst case.
        if (!root.ready) return "READING WHAT IS ON DISK"
        if (!root.activeProfile) return "NO PROFILE MATCHES WHAT IS ON DISK"
        root.shapeGeneration    // same dependency: the count is read off the roster
        return Model.plain(Model.summary(root.activeProfile).toUpperCase())
      }
      detail: root.shapeName

      // The same mark as the bar, mounted from the same file, so the two can never
      // drift apart. The cursor carries the same cost band the row dots use.
      iconComponent: Component {
        OpencodeMark {
          size: Style.font.display
          frameColor: root.errorCode !== "" ? Color.urgent : root.foreground
          cursorColor: {
            if (root.errorCode !== "") return Color.urgent
            if (root.activeTier === "top") return Palette.opencodeInk(Color.popups.background)
            if (root.activeTier === "unknown") return Util.alpha(root.foreground, Palette.markNeutralAlpha())
            return Util.alpha(root.foreground, Palette.tierAlpha(root.activeTier))
          }
        }
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    // ---- The one strip that changes: an error, a fresh switch, or drift — never two at once.
    Loader {
      width: parent.width
      // The drift strip waits for `ready` for the same reason the heading does: before
      // detect lands it would be describing a config the panel has not finished reading.
      active: root.errorCode !== "" || root.toast !== "" || root.notice !== ""
              || (root.drift && root.ready)
      // Column skips invisible children; without this the strip's two gaps stay behind as a hole.
      visible: active
      height: active ? implicitHeight : 0
      sourceComponent: root.errorCode !== "" ? errorStrip
                     : (root.toast !== "" ? toastStrip
                     : (root.notice !== "" ? noticeStrip : driftStrip))
    }

    Component {
      id: errorStrip
      BorderSurface {
        width: header.width
        implicitHeight: errCol.implicitHeight + Style.spacing.xxl * 2
        radius: Style.cornerRadius
        color: Util.alpha(Color.urgent, 0.10)
        borderSpec: Border.flat(Util.alpha(Color.urgent, 0.35), Style.normalBorderWidth)

        Column {
          id: errCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xxl
          anchors.rightMargin: Style.spacing.xxl
          spacing: Style.spacing.lg

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.errorMessage
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.errorPath !== ""
            text: "Open the file"
            fontSize: Style.font.caption
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: root.openFileRequested(root.errorPath)
          }
        }
      }
    }

    Component {
      id: noticeStrip
      BorderSurface {
        width: header.width
        implicitHeight: noticeText.implicitHeight + Style.spacing.xxl * 2
        radius: Style.cornerRadius
        color: Util.alpha(root.foreground, 0.05)
        borderSpec: Border.flat(Util.alpha(Color.urgent, 0.30), Style.normalBorderWidth)

        Text {
          id: noticeText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xxl
          anchors.rightMargin: Style.spacing.xxl
          textFormat: Text.PlainText
          text: root.notice
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }

    Component {
      id: toastStrip
      BorderSurface {
        width: header.width
        implicitHeight: Style.space(38)
        radius: Style.cornerRadius
        color: Util.alpha(root.accent, 0.10)
        borderSpec: Border.flat(Util.alpha(root.accent, 0.30), Style.normalBorderWidth)

        Text {
          anchors.left: parent.left
          anchors.right: undoButton.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xxl
          anchors.rightMargin: Style.spacing.md
          textFormat: Text.PlainText
          text: root.toast
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Button {
          id: undoButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.lg
          text: "Undo"
          fontSize: Style.font.caption
          bordered: true
          enabled: !root.busy
          foreground: root.foreground
          accent: root.accent
          onClicked: root.undoRequested()
        }
      }
    }

    Component {
      id: driftStrip
      BorderSurface {
        width: header.width
        implicitHeight: driftCol.implicitHeight + Style.spacing.xxl * 2
        radius: Style.cornerRadius
        color: Util.alpha(root.foreground, 0.05)
        borderSpec: Border.flat(Util.alpha(root.foreground, 0.18), Style.normalBorderWidth)

        Column {
          id: driftCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.xxl
          anchors.rightMargin: Style.spacing.xxl
          spacing: Style.spacing.lg

          Text {
            width: parent.width
            textFormat: Text.PlainText
            // Drift is almost always a hand edit, so offer to keep it rather than warn.
            text: root.activeProfile
              ? "Your config has been edited since you switched to “" + root.activeProfile.name + "”."
              : "Your config does not match any saved profile."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.spacing.lg

            Button {
              visible: root.activeProfile !== null
              text: "Update “" + (root.activeProfile ? root.activeProfile.name : "") + "”"
              fontSize: Style.font.caption
              bordered: true
              enabled: !root.busy
              foreground: root.foreground
              accent: root.accent
              onClicked: root.updateActiveRequested()
            }

            Button {
              text: "Save as a new profile"
              fontSize: Style.font.caption
              bordered: true
              enabled: !root.busy
              foreground: root.foreground
              accent: root.accent
              onClicked: root.saveCurrentRequested()
            }
          }
        }
      }
    }

    Item {
      width: parent.width
      height: Math.max(sectionHeader.implicitHeight, Style.space(16))

      PanelSectionHeader {
        id: sectionHeader
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "PROFILES"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.query !== ""
          ? root.visibleProfiles.length + " of " + root.profiles.length
          : String(root.profiles.length)
        color: root.veryMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    TextField {
      id: searchField
      width: parent.width
      visible: root.searchable
      height: visible ? Style.spacing.controlHeight : 0
      placeholderText: "Search profiles"
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      onTextChanged: root.query = text
    }
  }

  function focusSearch() { if (root.searchable) searchField.forceActiveFocus() }
  readonly property bool searchFocused: searchField.activeFocus

  // ---- List ---------------------------------------------------------------

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
    model: root.visibleProfiles
    currentIndex: root.selectedIndex

    // Keeps the keyboard cursor on screen when it walks past the fold.
    highlightRangeMode: ListView.ApplyRange
    // Zero, not a margin: a non-zero begin scrolls the list on load so the
    // first row and its heading sit above the fold before anything is touched.
    preferredHighlightBegin: 0
    preferredHighlightEnd: height - Style.space(40)
    highlightMoveDuration: 0

    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(60)
      spacing: Style.spacing.md
      visible: root.visibleProfiles.length === 0

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.profiles.length === 0
          ? "No profiles yet."
          : "No profile matches “" + root.query + "”."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        visible: root.profiles.length === 0
        text: "Your current config is a good first one."
        color: root.veryMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index
      width: list.width
      implicitHeight: rowLabels.implicitHeight + Style.spacing.xxl

      readonly property bool isActive: modelData.id === root.activeProfileId
      readonly property bool isCursor: root.cursorActive && root.selectedIndex === index

      CursorSurface {
        anchors.fill: parent
        foreground: root.foreground
        accent: root.accent
        hasCursor: rowItem.isCursor
        current: rowItem.isActive
      }

      // The three pixels that say which one is running. A dot would move with
      // the text; a bar stays put and reads down the list at a glance.
      Rectangle {
        id: stateBar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(6)
        anchors.bottomMargin: Style.space(6)
        anchors.leftMargin: Style.space(2)
        width: Style.space(3)
        radius: width / 2
        // Running is still the accent, at full strength. The rest carry the tint of
        // the provider they are mostly on — the same hue the model picker gives that
        // provider — so a list of a dozen profiles groups by eye instead of reading
        // as one grey column. A profile on no single provider gets the muted
        // fallback, which is what the bar looked like before any of this.
        // Counted off rowsFor, which reads the shape out of a .pragma library global —
        // so this needs the same dependency the summary beside it has. Without it the
        // bar keeps the answer it was drawn with, and before detect answers that is
        // six opencode rows rather than the twenty-four the profile holds: a profile
        // whose base model is on one provider and whose agents are on another takes
        // the base model's colour and never lets go of it.
        readonly property string provider: {
          root.shapeGeneration
          return Palette.dominantProvider(Model.rowsFor(modelData))
        }
        color: rowItem.isActive
          ? root.accent
          : Palette.providerTint(provider, root.accent, Color.popups.background, root.veryMuted)
        opacity: rowItem.isActive ? (root.drift ? 0.45 : 1) : 0.7

        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }

      Column {
        id: rowLabels
        anchors.left: stateBar.right
        anchors.right: actions.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xxs

        Row {
          spacing: Style.spacing.md

          // Cost as one dot: ordinal, so one hue at graded strength — a palette
          // would read as unrelated kinds. Only the top band earns the brand colour.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            readonly property string tier:
              Palette.profileTier(Model.rowsFor(modelData), root.catalogIndex)
            visible: tier !== "unknown"
            width: Style.space(5)
            height: width
            radius: width / 2
            color: tier === "top"
              ? Palette.opencodeInk(Color.popups.background)
              : Util.alpha(root.foreground, Palette.tierAlpha(tier))
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: rowItem.isActive
            elide: Text.ElideRight
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: rowItem.isActive
            text: root.drift ? "in use, edited" : "in use"
            color: root.veryMuted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          // The header above already refuses to guess before the reads are in; the
          // rows under it were asserting a count off the built-in roster, which is
          // four agents wide. That is where "2 of 6 pinned" came from on a profile
          // that has twenty-four rows the moment detect answers.
          text: {
            root.shapeGeneration    // a dependency, so this re-reads when the roster moves
            return root.ready ? Model.summary(modelData) : "reading what is on disk"
          }
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Actions appear on the row you are pointing at. Four buttons on every
      // row turns a list you scan into a list you have to parse.
      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xs
        opacity: rowItem.isCursor ? 1 : 0
        visible: opacity > 0

        Behavior on opacity { NumberAnimation { duration: 60 } }

        PanelActionButton {
          iconText: "󰏫"
          tooltipText: "Edit this profile"
          foreground: root.muted
          hoverColor: root.foreground
          enabled: !root.busy
          onClicked: root.editRequested(modelData.id)
        }

        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Duplicate"
          foreground: root.muted
          hoverColor: root.foreground
          enabled: !root.busy
          onClicked: root.duplicateRequested(modelData.id)
        }

        PanelActionButton {
          iconText: "󰆴"
          tooltipText: "Delete"
          foreground: root.muted
          hoverColor: Color.urgent
          enabled: !root.busy
          onClicked: root.deleteRequested(modelData.id)
        }
      }

      MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: actions.left
        hoverEnabled: true
        cursorShape: rowItem.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
        onEntered: root.cursorMoved(index)
        onClicked: {
          if (root.busy) return
          if (rowItem.isActive) root.editRequested(modelData.id)
          else root.applyRequested(modelData.id)
        }
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

    Button {
      width: parent.width
      leftAlign: true
      iconText: "󰐕"
      text: "Add a profile"
      fontSize: Style.font.bodySmall
      enabled: !root.busy
      foreground: root.foreground
      accent: root.accent
      onClicked: root.saveCurrentRequested()
    }

    Item {
      width: parent.width
      height: undoRow.implicitHeight
      visible: root.canUndo

      Button {
        id: undoRow
        anchors.left: parent.left
        anchors.right: backupStamp.left
        anchors.rightMargin: Style.spacing.md
        leftAlign: true
        iconText: "󰕌"
        text: "Restore the previous config"
        fontSize: Style.font.bodySmall
        enabled: !root.busy
        foreground: root.foreground
        accent: root.accent
        onClicked: root.undoRequested()
      }

      Text {
        id: backupStamp
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.controlPaddingX
        textFormat: Text.PlainText
        text: root.backupLabel
        color: root.veryMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: root.searchable
        ? "↑↓ select   ⏎ switch   e edit   x delete   / search"
        : "↑↓ select   ⏎ switch   e edit   x delete   u undo"
      color: root.veryMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
