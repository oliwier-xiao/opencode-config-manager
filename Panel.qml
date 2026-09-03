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
  // Settings come out of shell.json, which is a file a hand can edit. A number that
  // is not one arrives as NaN, and NaN reaches a Timer interval as NaN — so both
  // ends are clamped here rather than at each use.
  function clampSetting(key, fallback, low, high) {
    var n = Number(root.setting(key, fallback))
    if (!isFinite(n)) return fallback
    return Math.min(high, Math.max(low, Math.round(n)))
  }
  readonly property int keepBackups: root.clampSetting("keepBackups", 10, 1, 200)
  readonly property int catalogRefreshHours: root.clampSetting("catalogRefreshHours", 24, 1, 8760)
  readonly property bool showModelMeta: setting("showModelMeta", true) !== false
  readonly property string configDir: String(setting("configDir", ""))

  // Byte ceilings, enforced at the far end of every pipe rather than here — a
  // process can always be made to print more than anyone expected, and the read
  // is the allocation. These count bytes on the wire; a QString of them costs
  // the shell rather more. Kept so both ends of each pipe have to agree.
  readonly property int maxCatalogBytes: 12 * 1024 * 1024
  readonly property int maxOutputBytes: 4 * 1024 * 1024

  // Qt.resolvedUrl percent-encodes: a home directory with a space in it would
  // otherwise reach Process as a literal %20, and nothing would start.
  function fromFileUrl(u) {
    var s = String(u || "").replace(/^file:\/\//, "").replace(/\/$/, "")
    try { return decodeURIComponent(s) } catch (e) { return s }
  }
  readonly property string pluginDir: root.fromFileUrl(Qt.resolvedUrl("."))
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
  // Bumped whenever Model's roster or shape moves. Model.js is a .pragma library:
  // those live in globals that no binding can watch, so this is the watchable thing.
  property int shapeGeneration: 0
  property bool catalogSyncTried: false
  // An `r` pressed while a background sync is already in flight. It cannot be
  // handed to that run — Quickshell fixes a Process's environment at spawn, so
  // its FORCE is already 0 — and dropping it is what made the panel-open sync
  // eat every refresh pressed in the seconds after opening the bar.
  property bool forcePending: false
  property bool busy: false
  property bool loaded: false

  // Both halves have to have answered once before the panel is entitled to say what
  // is running. `list` returns in about a tenth of the time `detect` takes, so
  // without this the first paint states — as fact, not as a pending read — that
  // nothing matches, and draws the profile rows against the wrong shape.
  readonly property bool ready: root.loaded && root.detected !== null

  property string view: "list"                 // "list" | "editor"
  property string editingId: ""
  property var draft: null
  property var draftOriginal: null

  property bool cursorActive: false
  property int selectedIndex: 0
  // Set by an action that wants the editor once the store has caught up:
  // runAction's callback fires before the re-read has landed.
  property string pendingEditorId: ""
  // Tried once per shell session: an empty store on first run gets the live
  // config saved as its first profile, so the panel opens on the user's own
  // setup instead of on "Custom" and a warning that nothing matches.
  property bool seedTried: false
  property var templates: []
  readonly property int templateCount: root.templates ? root.templates.length : 0

  property string errorCode: ""
  property string errorMessage: ""
  property string errorPath: ""
  property string toast: ""
  // Result of `oc-profiles doctor`, consumed exactly as the backend reports it.
  // Any shape mismatch clears this to [] and the section stays hidden — the panel
  // never validates here, it only forwards a code to `repair --fix` on click.
  property var healthIssues: []
  // A non-fatal thing the user should know: another config file outranks the
  // one being edited, so a switch here would appear to do nothing.
  property string notice: ""

  readonly property var profiles: (store && store.profiles) || []
  // Not store.state.activeProfileId: that is only the last profile switched *to*,
  // and an undo to a backup taken before any profile was active leaves it null over
  // a config that still matches a saved profile exactly. Model.resolveActiveId takes
  // oc-profiles' own answer, which is the same one it derived `drift` from.
  readonly property string activeProfileId: Model.resolveActiveId(store)
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

  readonly property bool configBroken: errorCode === "E_PARSE"
  readonly property bool hasOpencode: !detected || detected.ok !== false

  readonly property string tooltipText: {
    if (root.configBroken) return root.errorMessage
    if (!root.activeProfile) return "No profile matches the live config"
    var head = root.plain(root.activeProfile.name)
    if (root.drift) head += ", edited"
    return head + " — " + root.plain(Model.summary(root.activeProfile))
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
    // The model cache is published by a rename from sync-models.sh and nothing
    // watches it any more, so it is re-read on open rather than only on the timer.
    // The panel is constructed once per shell session; without this, a cache built
    // after the first open stays invisible for up to catalogRefreshHours.
    root.loadCatalog()
    // And a stale cache is refreshed in the background: the script exits
    // immediately as `cached` when there is nothing to do, so this costs nothing
    // when fresh — and it is the only thing that makes a new model appear
    // without pressing `r`, on a shell that restarts more often than the timer.
    root.maybeSyncCatalog()
    root.reload()
  }

  Component.onCompleted: {
    templatesFile.reload()
    root.loadCatalog()
    root.maybeSyncCatalog()
    Qt.callLater(root.reload)
  }

  function reload() {
    if (!listProc.running) listProc.running = true
    if (!detectProc.running) detectProc.running = true
    if (!doctorProc.running) doctorProc.running = true
  }

  function refresh() {
    // An explicit refresh means "I just added a provider", so it goes past the
    // TTL rather than being told the cache is still young.
    root.catalogSyncTried = false
    if (catalogSync.running) {
      root.forcePending = true
    } else {
      catalogSync.force = true
      catalogSync.running = true
    }
    reload()
  }

  // A background sync the script itself gates: a fresh cache answers `cached`
  // without touching the network or `opencode models`, so calling this on every
  // panel open only ever costs a run when the cache actually went stale. That
  // is what makes a new model appear by itself: the timer alone never fires on
  // a shell that restarts more often than catalogRefreshHours.
  function maybeSyncCatalog() {
    if (catalogSync.running) return
    catalogSync.force = false
    catalogSync.running = true
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

  // One-click fix for a doctor issue. The backend owns validation: the code and
  // the profile id (when the issue names one) are forwarded untouched, and the
  // shared actionProc path reports failures via setError. reload() follows every
  // action, so the section re-reads after each fix.
  function fixHealthIssue(issue) {
    if (!issue || !issue.code) return
    var args = ["repair", "--fix", String(issue.code)]
    var pid = (issue && (issue.profile || issue.profileId || issue.profile_id)) || ""
    if (pid) args.push("--profile", String(pid))
    args.push("--apply")
    var code = String(issue.code)
    runAction(args, root.actionEnv, function (res) {
      if (!res || res.ok !== true) return
      root.toast = "Fixed " + root.plain(code) + "."
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
    var underOhMy = root.detected && root.detected.shape === "oh-my-openagent"
    if (root.manageOhMyOpenAgent && underOhMy && tpl.ohmy) {
      profile.targets.push({ file: "ohmy", shape: "oh-my-openagent",
                             manages: Object.keys(tpl.ohmy), payload: tpl.ohmy })
    }
    if (root.manageOpencodeJson && tpl.opencode) {
      // Under oh-my-openagent its agents supersede opencode's, so a template only
      // carries the two base keys across; taking its `agent` block as well would
      // write rows this panel no longer draws, and drop any subagent of yours.
      var oc = tpl.opencode
      if (underOhMy) {
        oc = {}
        if (tpl.opencode.model) oc.model = tpl.opencode.model
        if (tpl.opencode.small_model) oc.small_model = tpl.opencode.small_model
      }
      if (Object.keys(oc).length > 0) {
        profile.targets.push({ file: "opencode", shape: "opencode",
                               manages: Object.keys(oc), payload: oc })
      }
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
        ready: root.ready
        shapeGeneration: root.shapeGeneration
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
        healthIssues: root.healthIssues
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
            confirm.message = "Switch to “" + root.plain(root.profiles[i].name) + "”?"
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
        onFixRequested: function (index) {
          if (index < 0 || index >= root.healthIssues.length) return
          root.fixHealthIssue(root.healthIssues[index])
        }
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
        manageOhMy: root.manageOhMyOpenAgent
        manageOpencode: root.manageOpencodeJson
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
    confirm.message = "Delete “" + root.plain(profile.name) + "”?"
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
        if (!Model.withinLimit(text, root.maxOutputBytes)) return
        var parsed = Model.parseJson(text, null)
        if (parsed && Array.isArray(parsed.profiles)) {
          root.store = parsed
          root.loaded = true
          if (parsed.profiles.length === 0 && !root.seedTried && !root.busy) {
            root.seedTried = true
            root.runAction(["seed"], root.actionEnv, null)
            return
          }
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
        if (!Model.withinLimit(text, root.maxOutputBytes)) return
        var parsed = Model.parseJson(text, null)
        if (!parsed) return
        root.detected = parsed
        // Detect reads the rosters off the installed software and says which of
        // the two shapes is actually running. Both have to reach Model before
        // anything draws, or the first paint is of the wrong panel.
        var rosterMoved = Model.setRoster(parsed.roster)
        var shapeMoved = Model.setShape(String(parsed.shape || "opencode"))
        // Model.js is a `.pragma library`, so those two write globals that no
        // binding depends on: every row already drawn keeps the shape it was drawn
        // with. `list` almost always lands first, so that shape is the wrong one.
        // Re-seating the store is the dependency all of them do share, and it is
        // only paid when something actually moved.
        // And a counter that IS a QML property, so a binding can depend on it. The
        // re-seat below only reaches rows drawn from the store, and only once the
        // store has arrived; anything that reads Model.roster() or Model.shape()
        // directly — every row summary in the list — had no way to know it had gone
        // stale. That is a profile reading "2 of 6 pinned" against the built-in
        // roster while holding twenty-four rows.
        if (rosterMoved || shapeMoved) root.shapeGeneration++
        if ((rosterMoved || shapeMoved) && root.loaded) root.store = Model.clone(root.store)
        // A config that will not parse is the one state where nothing else in
        // the panel means anything, so it outranks every other message.
        var warnings = parsed.warnings || []
        for (var i = 0; i < warnings.length; i++) {
          var w = warnings[i]
          if (w.code === "E_PARSE") {
            root.setError(w.code, root.basename(w.file) + " will not parse. Nothing was changed.", w.file)
            return
          }
        }
        if (root.errorCode === "E_PARSE") root.clearError()

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

  // Health, read on every reload() alongside list and detect. The `doctor` verb
  // belongs to a parallel change: when it is missing, prints usage, exits
  // non-zero, or returns anything but {ok:true, issues:[...]}, the section hides
  // entirely — no crash, no banner. Each issue keeps its backend shape
  // ({code,file,detail,fixable,fix,...}); the panel never validates it here.
  Process {
    id: doctorProc
    command: [root.pluginDir + "/bin/oc-profiles", "doctor"]
    environment: root.actionEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
        if (!parsed || parsed.ok !== true || !Array.isArray(parsed.issues)) {
          root.healthIssues = []
          return
        }
        var out = []
        for (var i = 0; i < parsed.issues.length; i++) {
          var it = parsed.issues[i]
          if (!it || typeof it.code !== "string" || it.code === "") continue
          out.push(it)
        }
        root.healthIssues = out
      }
    }
    onExited: function (code) {
      if (code !== 0) root.healthIssues = []
    }
  }

  Process {
    id: actionProc
    property var pending: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.withinLimit(text, root.maxOutputBytes) ? Model.parseJson(text, null) : null
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
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.warn("opencode-configs:", t.substring(0, 2000))
      }
    }
    onExited: function (code) {
      // A crash before the collector settles would otherwise leave the panel
      // permanently busy with no way back except closing it.
      if (code !== 0 && code !== 2 && code !== 3) {
        root.busy = false
        actionProc.pending = null
        // 124 is the timebox, 137 and 143 are the signals behind it. All three
        // arrive with nothing on stdout, so without this the panel would clear
        // itself and quietly redraw the state from before the switch — the one
        // case where doing nothing looks exactly like having done it.
        root.setError("E_KILLED",
          code === 124 || code === 137 || code === 143
            ? "That took too long and was stopped. Your config was not changed."
            : "Something went wrong and nothing was changed.", "")
        root.reload()
      }
    }
  }

  Process {
    id: catalogSync
    property bool force: false
    command: [root.pluginDir + "/bin/sync-models.sh"]
    environment: ({
      "TTL": String(root.catalogRefreshHours * 3600),
      "FORCE": catalogSync.force ? "1" : "0",
      // The reachable list is built by running `opencode models`, and which models
      // that names depends on the config folder. Every other process this panel
      // starts is told which one; leaving this one out built the picker from a
      // different opencode than the one the profile is written for.
      "OPENCODE_CONFIG_DIR": root.configDir
    })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // One status word is all this prints; anything longer is not from us.
        if (Model.withinLimit(text, 4096)) root.loadCatalog()
      }
    }
    // Honoured here rather than in refresh(), because a Process that is already
    // running cannot be told anything: its environment was read at spawn. The
    // refresh the user asked for runs now, as the forced run it was meant to be.
    onExited: {
      catalogSync.force = false
      if (!root.forcePending) return
      root.forcePending = false
      catalogSync.force = true
      catalogSync.running = true
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
      var raw = text()
      if (!Model.withinLimit(raw, root.maxCatalogBytes)) { root.templates = []; return }
      var doc = Model.parseJson(raw, null)
      root.templates = (doc && Array.isArray(doc.templates)) ? doc.templates : []
    }
    onLoadFailed: root.templates = []
  }

  // The panel never opens the cache and is not given its path. bin/read-catalog
  // decides on the descriptor it is about to read — a name checked and then opened
  // is a name that can be replaced in between — and prints at most maxCatalogBytes,
  // so a symlink, a FIFO or a bigger file never reaches this process at all.
  // omarchy-shell is one process for every plugin on the desktop; the read is the
  // allocation, and refusing after text() has returned would be too late.
  Process {
    id: catalogRead
    command: [root.pluginDir + "/bin/read-catalog"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        // Already bounded by the reader; kept so the two ceilings must agree.
        if (raw === "" || !Model.withinLimit(raw, root.maxCatalogBytes)) return
        var c = Catalog.fromText(raw)
        // A truncated or unparseable cache leaves the picker on what it already
        // has, which is more useful than an empty list.
        if (!c || !c.models || c.models.length === 0) return
        root.catalog = c
        root.catalogIndex = Catalog.byId(c)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.warn("opencode-configs:", t.substring(0, 500))
      }
    }
    onExited: function (code) {
      // Nothing to read, or something that was refused: build one, once. Retrying on
      // every failure turns an offline first run into an unbounded spawn loop.
      if (code === 0 || root.catalogSyncTried) return
      root.catalogSyncTried = true
      if (!catalogSync.running) catalogSync.running = true
    }
  }

  function loadCatalog() {
    if (catalogRead.running) return
    catalogRead.running = true
  }

  // The long arm of the refresh: the timer covers a shell left running for
  // days, maybeSyncCatalog() covers every panel open and shell start. Either
  // way the three seconds `opencode models` costs never sit between clicking
  // the bar and seeing the list — the cached list paints first, and the sync
  // re-reads the cache when it lands.
  Timer {
    // Clamped to what a Qt interval can hold. The settings slider goes to 720
    // hours, which is 2.59e9 milliseconds — past a signed 32-bit int, where it
    // wraps negative, never fires, and leaves the timer restarting itself a few
    // hundred times a second into the shell log.
    interval: Math.min(2147483647, root.catalogRefreshHours * 3600 * 1000)
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: if (!catalogSync.running) catalogSync.running = true
  }

  // ConfirmDialog's message and the bar tooltip are shell components that do
  // not set textFormat, so they default to AutoText — rich text, which will
  // fetch what a crafted string points at. Names come from a JSON file that a
  // second machine or a hand edit can write, so they are flattened first.
  function plain(s) {
    return String(s || "").replace(/[<>&]/g, " ").replace(/\s+/g, " ").trim()
  }

  function basename(path) {
    var s = String(path || "")
    return s.substr(s.lastIndexOf("/") + 1)
  }
}
