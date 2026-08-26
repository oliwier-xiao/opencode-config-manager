import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/Model.js" as Model
import "lib/Catalog.js" as Catalog
import "lib/Palette.js" as Palette

// The panel: two screens, one state, every read in one place.
// Writes all go to bin/oc-profiles, which backs up, renames atomically, re-parses
// what it wrote, and rolls the whole switch back if the second file fails —
// a shell script so it can be run by hand.
Panel {
  id: root
  moduleName: "oliwier.opencode-configs"
  ipcTarget: "oliwier.opencode-configs"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color contentAccent: Color.accent

  // ---- Settings ----------------------------------------------------------
  // The shell copies a manifest's `defaults` into registry metadata and never reads
  // them back: every default must be a literal here, or the feature silently dies.
  readonly property string barLabelMode: String(setting("barLabel", "Profile name"))
  readonly property string afterSwitch: String(setting("afterSwitch", "Notify"))
  readonly property bool confirmSwitch: setting("confirmSwitch", false) === true
  readonly property bool manageOpencodeJson: setting("manageOpencodeJson", true) !== false
  readonly property bool manageOhMyOpenAgent: setting("manageOhMyOpenAgent", true) !== false
  readonly property int keepBackups: Math.max(1, Number(setting("keepBackups", 10)) || 10)
  readonly property int catalogRefreshHours: Number(setting("catalogRefreshHours", 24))
  readonly property bool showModelMeta: setting("showModelMeta", true) !== false
  readonly property string configDir: String(setting("configDir", ""))

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property var actionEnv: ({
    "OC_MANAGE_OHMY": root.manageOhMyOpenAgent ? "1" : "0",
    "OC_MANAGE_OPENCODE": root.manageOpencodeJson ? "1" : "0",
    "OC_AUTO_RELOAD": root.afterSwitch === "Restart opencode" ? "1" : "0",
    "OC_BACKUPS_KEEP": String(root.keepBackups),
    "OPENCODE_CONFIG_DIR": root.configDir
  })

  // ---- State -------------------------------------------------------------

  property var store: ({ profiles: [], state: {}, favorites: [], recents: [] })
  property var detected: null
  property var catalog: Catalog.empty()
  property var catalogIndex: ({})
  property bool busy: false
  property bool loaded: false

  property string view: "list"                 // "list" | "editor"
  property string editingId: ""
  property var draft: null
  property var draftOriginal: null

  property bool cursorActive: false
  property int selectedIndex: 0
  // Set by an action that wants the editor once the store has caught up:
  // runAction's callback fires before the re-read has landed.
  property string pendingEditorId: ""
  property var templates: []
  readonly property int templateCount: root.templates ? root.templates.length : 0

  property string errorCode: ""
  property string errorMessage: ""
  property string errorPath: ""
  property string toast: ""
  // A non-fatal thing the user should know: another config file outranks the
  // one being edited, so a switch here would appear to do nothing.
  property string notice: ""

  readonly property var profiles: (store && store.profiles) || []
  readonly property string activeProfileId: (store && store.state && store.state.activeProfileId) || ""
  readonly property bool drift: store ? store.drift === true : false
  readonly property var favorites: (store && store.favorites) || []
  readonly property var recents: (store && store.recents) || []

  readonly property var activeProfile: {
    for (var i = 0; i < root.profiles.length; i++)
      if (root.profiles[i].id === root.activeProfileId) return root.profiles[i]
    return null
  }

  // ---- What the bar reads off this panel ---------------------------------

  readonly property string activeName: activeProfile ? activeProfile.name : (activeProfileId ? activeProfileId : "")
  readonly property string activeShortName: {
    if (!activeProfile) return "——"
    var s = String(activeProfile.shortName || "")
    return s !== "" ? s : Model.autoShortName(activeProfile.name)
  }
  readonly property string activeModel: activeProfile ? Model.shortModel(Model.dominantModel(activeProfile)) : ""
  // What the running profile costs, as one of five words. The bar reads this
  // to decide whether to say anything about it at all.
  readonly property string activeTier: activeProfile
    ? Palette.profileTier(Model.rowsFor(activeProfile), root.catalogIndex) : "unknown"

  readonly property bool configBroken: errorCode === "E_PARSE" || errorCode === "E_JSONC"
  readonly property bool hasOpencode: !detected || detected.ok !== false

  readonly property string tooltipText: {
    if (root.configBroken) return root.errorMessage
    if (!root.activeProfile) return "No profile matches the live config"
    var head = root.activeProfile.name
    if (root.drift) head += ", edited"
    return head + " — " + Model.summary(root.activeProfile)
  }

  // ---- Lifecycle ---------------------------------------------------------

  onOpenedChanged: {
    if (!opened) {
      // Discard half-finished edits on close, as the shell's other panels do: the
      // panel then always opens on the list.
      root.view = "list"
      root.draft = null
      root.toast = ""
      // A dialog left armed across a close is one click from acting on a
      // profile the user has since stopped looking at.
      confirm.opened = false
      confirm.intent = ""
      confirm.subjectId = ""
      addSheet.opened = false
      return
    }
    root.cursorActive = false
    root.reload()
  }

  Component.onCompleted: {
    templatesFile.reload()
    catalogFile.reload()
    Qt.callLater(root.reload)
  }

  function reload() {
    if (!listProc.running) listProc.running = true
    if (!detectProc.running) detectProc.running = true
  }

  function refresh() {
    // An explicit refresh means "I just added a provider", so it goes past the
    // TTL rather than being told the cache is still young.
    catalogSync.force = true
    catalogFile.syncTried = false
    if (!catalogSync.running) catalogSync.running = true
    reload()
  }

  function clearError() { root.errorCode = ""; root.errorMessage = ""; root.errorPath = "" }

  function setError(code, message, path) {
    root.errorCode = String(code || "")
    root.errorMessage = String(message || "")
    root.errorPath = String(path || "")
  }

  // ---- Actions -----------------------------------------------------------

  // Every write: hand oc-profiles a verb, take one line of JSON back, then re-read.
  // Re-reading rather than patching local state keeps the panel honest about disk.
  function runAction(args, env, onDone) {
    if (root.busy) return
    root.busy = true
    root.clearError()
    actionProc.pending = onDone || null
    actionProc.environment = env ? env : root.actionEnv
    actionProc.command = [root.pluginDir + "/bin/oc-profiles"].concat(args)
    actionProc.running = true
  }

  function applyProfile(id) {
    var profile = null
    for (var i = 0; i < root.profiles.length; i++) if (root.profiles[i].id === id) profile = root.profiles[i]
    if (!profile) return
    if (id === root.activeProfileId && !root.drift) return

    runAction(["apply", id], root.actionEnv, function (res) {
      if (!res || res.ok !== true) return
      root.toast = "Now running “" + profile.name + "”."
      toastTimer.restart()
      root.announce(profile, res)
    })
  }

  function revert() {
    runAction(["revert"], root.actionEnv, function (res) {
      if (!res || res.ok !== true) return
      root.toast = "Previous config restored."
      toastTimer.restart()
    })
  }

  function saveCurrentAsProfile() {
    var name = root.uniqueName("Saved config")
    runAction(["capture", name], root.actionEnv, null)
  }

  // Same capture, but it opens the editor: "from scratch" means you are about
  // to choose the models, so the structure is taken from the live config and
  // handed straight to the bulk control.
  // A template becomes a profile, not a switch: it is saved so you can read and
  // edit it before anything on disk changes.
  function installTemplate(id) {
    var tpl = null
    for (var i = 0; i < root.templates.length; i++) if (root.templates[i].id === id) tpl = root.templates[i]
    if (!tpl) return

    var taken = []
    for (var j = 0; j < root.profiles.length; j++) taken.push(root.profiles[j].id)
    var name = root.uniqueName(tpl.name)

    var profile = {
      id: Model.slugify(name, taken),
      name: name,
      shortName: String(tpl.shortName || Model.autoShortName(name)),
      note: String(tpl.description || ""),
      targets: []
    }
    if (root.manageOhMyOpenAgent && root.detected && root.detected.shape === "oh-my-openagent"
        && tpl.ohmy) {
      profile.targets.push({ file: "ohmy", shape: "oh-my-openagent",
                             manages: Object.keys(tpl.ohmy), payload: tpl.ohmy })
    }
    if (root.manageOpencodeJson && tpl.opencode) {
      profile.targets.push({ file: "opencode", shape: "opencode",
                             manages: Object.keys(tpl.opencode), payload: tpl.opencode })
    }
    if (profile.targets.length === 0) return

    saveProfile(profile, function (res) {
      if (!res || res.ok !== true) return
      root.view = "list"
      root.selectedIndex = 0
      root.toast = "Added \u201C" + name + "\u201D. Click it to switch."
      toastTimer.restart()
    })
  }

  function newProfileFromScratch() {
    var name = root.uniqueName("New profile")
    runAction(["capture", name], root.actionEnv, function (res) {
      if (!res || res.ok !== true) return
      root.pendingEditorId = res.id
    })
  }

  function askAddProfile() {
    addSheet.title = "Add a profile"
    addSheet.choices = [
      { value: "current",
        label: "Save what is running now",
        description: "Takes a copy of your config exactly as it is, so you can come back to it." },
      { value: "template",
        label: "Start from a template",
        note: root.templateCount > 0 ? root.templateCount + " ready" : "none available",
        disabled: root.templateCount === 0,
        description: "A whole set of models chosen to suit each agent — pick the one for the provider you use." },
      { value: "scratch",
        label: "Start from scratch",
        description: "Same agents as your config has now, with every model yours to choose." }
    ]
    addSheet.opened = true
  }

  function updateActiveFromDisk() {
    if (!root.activeProfile) return
    runAction(["capture", root.activeProfile.name, root.activeProfile.id], root.actionEnv, function (res) {
      if (!res || res.ok !== true) return
      root.toast = "“" + root.activeProfile.name + "” now matches what is on disk."
      toastTimer.restart()
    })
  }

  function duplicateProfile(id) {
    var source = null
    for (var i = 0; i < root.profiles.length; i++) if (root.profiles[i].id === id) source = root.profiles[i]
    if (!source) return
    var copy = Model.clone(source)
    var taken = []
    for (var j = 0; j < root.profiles.length; j++) taken.push(root.profiles[j].id)
    copy.name = root.uniqueName(source.name + " copy")
    copy.id = Model.slugify(copy.name, taken)
    copy.shortName = Model.autoShortName(copy.name)
    saveProfile(copy, function () { root.pendingEditorId = copy.id })
  }

  function deleteProfile(id) {
    runAction(["delete", id], root.actionEnv, null)
  }

  function saveProfile(profile, onDone) {
    var env = {}
    for (var k in root.actionEnv) env[k] = root.actionEnv[k]
    // Quickshell's Process cannot write to a child's stdin, so the profile travels
    // in the environment — not argv, which every process listing on the box shows.
    env["OC_PROFILE_JSON"] = JSON.stringify(profile)
    runAction(["save"], env, onDone)
  }

  function savePrefs(favorites, recents) {
    if (root.busy) return
    var env = {}
    for (var k in root.actionEnv) env[k] = root.actionEnv[k]
    env["OC_PREFS_JSON"] = JSON.stringify({ favorites: favorites, recents: recents })
    runAction(["prefs"], env, null)
  }

  function uniqueName(base) {
    var taken = {}
    for (var i = 0; i < root.profiles.length; i++) taken[root.profiles[i].name] = true
    if (!taken[base]) return base
    for (var n = 2; n < 100; n++) if (!taken[base + " " + n]) return base + " " + n
    return base
  }

  // opencode reads its config once, at startup, so a switch may or may not reach an
  // already-open session; say which of the two happened rather than leave it to guess.
  function announce(profile, res) {
    var running = root.detected && root.detected.running ? root.detected.running.count : 0
    if (root.afterSwitch === "Nothing") return
    if (running === 0) return

    if (res.reloaded > 0) {
      notify.command = ["notify-send", "-a", "OpenCode Configs", "-t", "4000",
                        "Now running “" + profile.name + "”",
                        "Reloaded " + res.reloaded + (res.reloaded === 1 ? " session" : " sessions")
                        + " in place — your history is intact."]
    } else {
      notify.command = ["notify-send", "-a", "OpenCode Configs", "-t", "6000",
                        "Switched to “" + profile.name + "”",
                        "Run 'omarchy-restart-opencode' to load it into the "
                        + running + " session" + (running === 1 ? "" : "s") + " already open."]
    }
    notify.running = true
  }

  function reloadRunningOpencode() {
    runAction(["reload"], root.actionEnv, function (res) {
      if (!res) return
      root.toast = res.reloaded > 0
        ? "Reloaded " + res.reloaded + (res.reloaded === 1 ? " session." : " sessions.")
        : "opencode is not running."
      toastTimer.restart()
    })
  }

  // ---- Editor ------------------------------------------------------------

  function openEditor(id) {
    for (var i = 0; i < root.profiles.length; i++) {
      if (root.profiles[i].id !== id) continue
      root.editingId = id
      root.draftOriginal = Model.clone(root.profiles[i])
      root.draft = Model.clone(root.profiles[i])
      root.view = "editor"
      root.selectedIndex = 0
      root.cursorActive = false
      return
    }
  }

  function closeEditor() {
    editorView.clearPickerState()
    root.view = "list"
    root.draft = null
    root.draftOriginal = null
    root.selectedIndex = 0
    root.cursorActive = false
  }

  function saveDraft() {
    if (!root.draft) return
    var wasActive = root.draft.id === root.activeProfileId
    var id = root.draft.id
    saveProfile(root.draft, function (res) {
      if (!res || res.ok !== true) return
      // Saving the running profile leaves the on-disk config stale, so re-apply it;
      // any other profile never touches the live config.
      if (wasActive) {
        root.busy = false
        runAction(["apply", id], root.actionEnv, function (r2) {
          if (!r2 || r2.ok !== true) return
          root.toast = "Saved and applied."
          toastTimer.restart()
        })
      } else {
        root.toast = "Saved."
        toastTimer.restart()
      }
      root.closeEditor()
    })
  }

  function toggleFavorite(id) {
    var next = Catalog.toggleFavorite(root.favorites, id)
    var s = Model.clone(root.store); s.favorites = next; root.store = s
    savePrefs(next, root.recents)
  }

  function noteRecent(id) {
    var next = Catalog.pushRecent(root.recents, id)
    var s = Model.clone(root.store); s.recents = next; root.store = s
    savePrefs(root.favorites, next)
  }

  // ---- Cursor ------------------------------------------------------------

  readonly property int rowCount: root.view === "editor"
    ? (root.draft ? Model.rowsFor(root.draft).length : 0)
    : (root.view === "templates" ? root.templates.length : listView.visibleProfiles.length)

  function moveCursor(dx, dy) {
    if (dy === 0) return
    if (!root.cursorActive) { root.cursorActive = true; return }
    var n = root.rowCount
    if (n === 0) return
    root.selectedIndex = Math.max(0, Math.min(n - 1, root.selectedIndex + dy))
  }

  function activateCursor() {
    if (root.view === "editor") return
    if (root.view === "templates") {
      if (!root.cursorActive) { root.cursorActive = true; return }
      var picked = templateView.selectedTemplate()
      if (picked) root.installTemplate(picked.id)
      return
    }
    if (!root.cursorActive) { root.cursorActive = true; return }
    var p = listView.selectedProfile()
    if (p) root.applyProfile(p.id)
  }

  // ---- Panel surface -----------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // One width for both screens. A panel that changes size when you press `e`
    // reads as two different panels rather than one with two views.
    contentWidth: panel.fittedContentWidth(Style.space(580))
    contentHeight: panel.fittedContentHeight(
      root.view === "editor" ? editorView.desiredHeight
        : (root.view === "templates" ? templateView.desiredHeight : listView.desiredHeight),
      Style.space(640))

    // Animate height changes: a card that resizes while the cursor walks the list
    // would otherwise move the row out from under the pointer.
    Behavior on contentHeight {
      enabled: root.opened
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Stop driving the cursor when something inside owns the keyboard, or "j" typed
      // into the search field also walks the list underneath it.
      blocked: confirm.opened || addSheet.opened
        || (root.view === "list" && listView.searchFocused)
        || (root.view === "editor" && editorView.anyPickerOpen)

      // ConfirmDialog exposes handleKey rather than binding keys itself; without this
      // forwarding it is mouse-only and Esc does nothing.
      Keys.onPressed: function (event) {
        if (addSheet.opened) { addSheet.handleKey(event); event.accepted = true }
        else if (confirm.opened) { confirm.handleKey(event); event.accepted = true }
      }

      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.view === "editor") root.closeEditor()
        else if (root.view === "templates") { root.view = "list"; root.selectedIndex = 0 }
        else root.close()
      }
      onDeleteRequested: {
        if (root.view !== "list") return
        // The first press lights the cursor; acting on an invisible selection
        // is how you delete the wrong profile.
        if (!root.cursorActive) { root.cursorActive = true; return }
        var p = listView.selectedProfile()
        if (p) root.askDelete(p)
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (root.view === "templates") {
          if (t === "j") root.moveCursor(0, 1)
          else if (t === "k") root.moveCursor(0, -1)
          return
        }
        if (root.view === "editor") {
          if (t === "r" || t === "R") root.refresh()
          return
        }
        if (!root.cursorActive && "edx".indexOf(t.toLowerCase()) >= 0) {
          root.cursorActive = true
          return
        }
        var p = listView.selectedProfile()
        if (t === "e" || t === "E") { if (p) root.openEditor(p.id) }
        else if (t === "d" || t === "D") { if (p) root.duplicateProfile(p.id) }
        else if (t === "u" || t === "U") root.revert()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "/") listView.focusSearch()
        else if (t === "j") root.moveCursor(0, 1)
        else if (t === "k") root.moveCursor(0, -1)
      }

      ProfileList {
        id: listView
        anchors.fill: parent
        visible: root.view === "list"
        enabled: visible

        profiles: root.profiles
        activeProfileId: root.activeProfileId
        drift: root.drift
        busy: root.busy
        catalogIndex: root.catalogIndex
        shapeName: root.detected ? String(root.detected.shape || "") : ""
        backupLabel: root.backupLabel
        canUndo: root.store && root.store.state && !!root.store.state.lastBackup
        errorCode: root.errorCode
        errorMessage: root.errorMessage
        errorPath: root.errorPath
        notice: root.notice
        toast: root.toast
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex

        foreground: root.contentForeground
        accent: root.contentAccent
        fontFamily: root.contentFontFamily

        onApplyRequested: function (id) {
          if (!root.confirmSwitch) { root.applyProfile(id); return }
          for (var i = 0; i < root.profiles.length; i++) {
            if (root.profiles[i].id !== id) continue
            confirm.intent = "apply"
            confirm.subjectId = id
            confirm.message = "Switch to “" + root.profiles[i].name + "”?"
            confirm.confirmText = "Switch"
            confirm.cancelText = "Stay"
            confirm.selectedIndex = 0
            confirm.opened = true
            return
          }
        }
        onEditRequested: function (id) { root.openEditor(id) }
        onDuplicateRequested: function (id) { root.duplicateProfile(id) }
        onDeleteRequested: function (id) {
          for (var i = 0; i < root.profiles.length; i++)
            if (root.profiles[i].id === id) root.askDelete(root.profiles[i])
        }
        onSaveCurrentRequested: root.askAddProfile()
        onUpdateActiveRequested: root.updateActiveFromDisk()
        onUndoRequested: root.revert()
        onOpenFileRequested: function (path) { Quickshell.execDetached(["xdg-open", path]) }
        onCursorMoved: function (index) { root.cursorActive = true; root.selectedIndex = index }
        onDismissToast: root.toast = ""
      }

      ProfileEditor {
        id: editorView
        anchors.fill: parent
        visible: root.view === "editor"
        enabled: visible

        profile: root.draft
        original: root.draftOriginal
        catalog: root.catalog
        catalogIndex: root.catalogIndex
        favorites: root.favorites
        recents: root.recents
        showMeta: root.showModelMeta
        busy: root.busy
        isActiveProfile: root.draft && root.draft.id === root.activeProfileId
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex

        foreground: root.contentForeground
        accent: root.contentAccent
        fontFamily: root.contentFontFamily

        onBackRequested: {
          if (!editorView.dirty) { root.closeEditor(); return }
          confirm.intent = "discard"
          confirm.message = "Leave without saving?"
          confirm.confirmText = "Discard changes"
          confirm.cancelText = "Keep editing"
          confirm.selectedIndex = 0
          confirm.opened = true
        }
        onDiscardRequested: {
          root.draft = Model.clone(root.draftOriginal)
        }
        onSaveRequested: root.saveDraft()
        onProfileEdited: function (next) { root.draft = next }
        onFavoriteToggled: function (id) { root.toggleFavorite(id) }
        onCursorMoved: function (index) { root.cursorActive = true; root.selectedIndex = index }
        onRefreshCatalogRequested: root.refresh()
        onFallbackRequested: function (index) { root.addFallback(index) }
      }

      TemplateList {
        id: templateView
        anchors.fill: parent
        visible: root.view === "templates"
        enabled: visible

        templates: root.templates
        authedProviders: root.detected ? (root.detected.authedProviders || []) : []
        catalogIndex: root.catalogIndex
        shape: root.detected ? String(root.detected.shape || "") : ""
        busy: root.busy
        cursorActive: root.cursorActive
        selectedIndex: root.selectedIndex

        foreground: root.contentForeground
        accent: root.contentAccent
        fontFamily: root.contentFontFamily

        onBackRequested: { root.view = "list"; root.selectedIndex = 0; root.cursorActive = false }
        onInstallRequested: function (id) { root.installTemplate(id) }
        onCursorMoved: function (index) { root.cursorActive = true; root.selectedIndex = index }
      }

      ChoiceSheet {
        id: addSheet
        anchors.fill: parent
        z: 11
        background: Color.popups.background
        foreground: root.contentForeground
        accent: root.contentAccent
        fontFamily: root.contentFontFamily

        onCanceled: opened = false
        onChosen: function (value) {
          opened = false
          if (value === "current") root.saveCurrentAsProfile()
          else if (value === "scratch") root.newProfileFromScratch()
          else if (value === "template") root.view = "templates"
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10

        property string intent: ""
        property string subjectId: ""

        background: Color.popups.background
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily

        onConfirmed: {
          opened = false
          if (intent === "delete") root.deleteProfile(subjectId)
          else if (intent === "apply") root.applyProfile(subjectId)
          else if (intent === "discard") root.closeEditor()
          intent = ""; subjectId = ""
        }
        onCanceled: { opened = false; intent = ""; subjectId = "" }
      }
    }
  }

  function askDelete(profile) {
    confirm.intent = "delete"
    confirm.subjectId = profile.id
    confirm.message = "Delete “" + profile.name + "”?"
    confirm.confirmText = "Delete"
    confirm.cancelText = "Keep it"
    confirm.selectedIndex = 0
    confirm.opened = true
  }

  // Appends through the same picker the row uses. Kept on the panel so the row does
  // not own a second popup it shows once in twenty uses.
  function addFallback(rowIndex) {
    if (!root.draft) return
    var rows = Model.rowsFor(root.draft)
    if (rowIndex < 0 || rowIndex >= rows.length) return
    var row = rows[rowIndex]
    var list = row.fallbacks.slice()
    // Default to the profile's own most-used model, which is almost always the
    // one you want behind an agent that is on something experimental.
    var suggestion = Model.dominantModel(root.draft)
    for (var i = 0; i < list.length; i++) if (list[i].model === suggestion) suggestion = ""
    if (!suggestion) {
      for (var f = 0; f < root.favorites.length; f++) {
        var taken = false
        for (var j = 0; j < list.length; j++) if (list[j].model === root.favorites[f]) taken = true
        if (!taken && root.favorites[f] !== row.model) { suggestion = root.favorites[f]; break }
      }
    }
    if (!suggestion) return
    list.push({ model: suggestion, variant: Catalog.nearestVariant(root.catalogIndex, suggestion, "high") })
    root.draft = Model.setRowFallbacks(root.draft, row, list)
  }

  readonly property string backupLabel: {
    var ts = root.store && root.store.state ? String(root.store.state.lastBackup || "") : ""
    if (!ts) return ""
    // 2026-08-26T13-05-50Z -> 13:05
    var m = ts.match(/T(\d{2})-(\d{2})/)
    return m ? m[1] + ":" + m[2] : ""
  }

  Timer {
    id: toastTimer
    interval: 9000
    onTriggered: root.toast = ""
  }

  // ---- Processes ---------------------------------------------------------

  Process {
    id: listProc
    command: [root.pluginDir + "/bin/oc-profiles", "list"]
    environment: root.actionEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseJson(text, null)
        if (parsed && Array.isArray(parsed.profiles)) {
          root.store = parsed
          root.loaded = true
          if (root.selectedIndex >= parsed.profiles.length) root.selectedIndex = 0
          if (root.pendingEditorId !== "") {
            var wanted = root.pendingEditorId
            root.pendingEditorId = ""
            root.openEditor(wanted)
          }
        }
      }
    }
  }

  Process {
    id: detectProc
    command: [root.pluginDir + "/bin/oc-profiles", "detect"]
    environment: root.actionEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseJson(text, null)
        if (!parsed) return
        root.detected = parsed
        // A config that will not parse is the one state where nothing else in
        // the panel means anything, so it outranks every other message.
        var warnings = parsed.warnings || []
        for (var i = 0; i < warnings.length; i++) {
          var w = warnings[i]
          if (w.code === "E_PARSE" || w.code === "E_JSONC") {
            root.setError(w.code,
              w.code === "E_JSONC"
                ? root.basename(w.file) + " has comments in it, and this cannot edit it safely."
                : root.basename(w.file) + " will not parse. Nothing was changed.",
              w.file)
            return
          }
        }
        if (root.errorCode === "E_PARSE" || root.errorCode === "E_JSONC") root.clearError()

        // A `model` or `agent` key in ~/.opencode/opencode.json is loaded last and beats
        // everything this panel writes — unsaid, a switch looks like it did nothing.
        var notice = ""
        for (var w = 0; w < warnings.length; w++) {
          if (warnings[w].code === "W_HOME_OVERRIDE") {
            notice = "~/.opencode/opencode.json sets “" + warnings[w].key
                   + "”, and it is read after this one. Switching profiles will not change it."
            break
          }
          if (warnings[w].code === "W_SHADOWED" && notice === "") {
            notice = "A project config in " + warnings[w].dir + " takes precedence here."
          }
        }
        root.notice = notice
      }
    }
  }

  Process {
    id: actionProc
    property var pending: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.parseJson(text, null)
        if (res && res.ok === false) {
          root.setError(res.code, res.message, res.file || "")
        } else if (res) {
          root.clearError()
        }
        var cb = actionProc.pending
        actionProc.pending = null
        root.busy = false
        if (cb && res) cb(res)
        root.reload()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.warn("opencode-configs:", String(text).trim())
    }
    onExited: function (code) {
      // A crash before the collector settles would otherwise leave the panel
      // permanently busy with no way back except closing it.
      if (code !== 0 && code !== 2 && code !== 3) {
        root.busy = false
        actionProc.pending = null
      }
    }
  }

  Process {
    id: catalogSync
    property bool force: false
    command: [root.pluginDir + "/bin/sync-models.sh"]
    environment: ({
      "TTL": String(Math.max(1, root.catalogRefreshHours) * 3600),
      "FORCE": catalogSync.force ? "1" : "0"
    })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        catalogSync.force = false
        catalogFile.reload()
      }
    }
  }

  Process { id: notify }

  // ---- Catalog -----------------------------------------------------------

  FileView {
    id: templatesFile
    path: root.pluginDir + "/assets/templates.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var doc = Model.parseJson(text(), null)
      root.templates = (doc && Array.isArray(doc.templates)) ? doc.templates : []
    }
    onLoadFailed: root.templates = []
  }

  FileView {
    id: catalogFile
    // Honour XDG_CACHE_HOME exactly as bin/sync-models.sh does; disagreeing
    // with it meant the panel never found the file the script had just written.
    property bool syncTried: false
    path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
          + "/omarchy/oliwier.opencode-configs/models.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var c = Catalog.fromText(text())
      root.catalog = c
      root.catalogIndex = Catalog.byId(c)
    }
    onFileChanged: reload()
    onLoadFailed: {
      // Build one, once: retrying on every failure turns an offline first run into an
      // unbounded spawn loop. An explicit refresh clears the latch.
      if (catalogFile.syncTried) return
      catalogFile.syncTried = true
      if (!catalogSync.running) catalogSync.running = true
    }
  }

  // On a timer, not on panel open: the three seconds `opencode models` costs must
  // not sit between clicking the bar and seeing the list.
  Timer {
    interval: Math.max(1, root.catalogRefreshHours) * 3600 * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: catalogSync.running = true
  }

  function basename(path) {
    var s = String(path || "")
    return s.substr(s.lastIndexOf("/") + 1)
  }
}
