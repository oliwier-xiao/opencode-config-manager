.pragma library

// Reading and editing a profile, with no files and no QML in sight.
// A profile is a list of targets, one per config file; each names the top-level
// keys it owns (`manages`) and carries their values (`payload`). The editor only
// ever sees rows — one per agent — and hands back an edited profile.

// ---------------------------------------------------------------- ids

// Split on the first slash only: opencode ids are "provider/model", and an
// openrouter id like "openrouter/anthropic/claude-sonnet-4.5" nests one more.
function splitModel(id) {
  var s = String(id || "")
  var cut = s.indexOf("/")
  if (cut < 0) return { provider: "", model: s }
  return { provider: s.substr(0, cut), model: s.substr(cut + 1) }
}

function providerOf(id) { return splitModel(id).provider }

// Last segment only: openrouter's vendor prefix wastes a 22px row, and the provider has its own column.
function shortModel(id) {
  var m = splitModel(id).model
  var parts = m.split("/")
  return parts[parts.length - 1] || String(id || "")
}

// Agent names come from JSON someone else wrote, and oh-my-openagent ships one
// with a zero-width space: invisible when drawn, two agents when used as a key.
function cleanName(s) {
  return String(s || "").replace(/[​-‍﻿]/g, "")
}

function slugify(name, taken) {
  var base = cleanName(name).toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  if (!base) base = "profile"
  var seen = {}
  for (var i = 0; i < (taken || []).length; i++) seen[String(taken[i])] = true
  if (!seen[base]) return base
  for (var n = 2; n < 1000; n++) if (!seen[base + "-" + n]) return base + "-" + n
  return base + "-x"
}

// Two or three letters keep the bar icon from changing width: initials of every
// word ("Full Opus" is FO, "Full OX Alpha" FOA), or the first two of a lone word.
function autoShortName(name) {
  var words = cleanName(name).split(/[\s_-]+/).filter(function (w) { return w.length > 0 })
  if (words.length >= 2) {
    var out = ""
    for (var i = 0; i < words.length && out.length < 3; i++) out += words[i].charAt(0)
    return out.toUpperCase()
  }
  return cleanName(name).substr(0, 2).toUpperCase()
}

// ---------------------------------------------------------------- json

function isObject(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }

function clone(v) {
  if (v === null || v === undefined) return v
  return JSON.parse(JSON.stringify(v))
}

// A ceiling before anything is parsed or retained. omarchy-shell is one
// long-lived process shared by every plugin, so a file or a pipe that grows
// without bound takes the whole desktop with it, not just this panel.
function withinLimit(text, limit) {
  return String(text || "").length <= limit
}

function parseJson(text, fallback) {
  try {
    var v = JSON.parse(String(text || ""))
    return (v === null || v === undefined) ? fallback : v
  } catch (e) { return fallback }
}

// Preserve existing key order and append only new keys, so a one-model change stays a one-line diff.
function orderedAssign(original, updates) {
  var out = {}, k
  for (k in original) {
    if (updates.hasOwnProperty(k)) { if (updates[k] !== undefined) out[k] = updates[k] }
    else out[k] = original[k]
  }
  for (k in updates) {
    if (!original.hasOwnProperty(k) && updates[k] !== undefined) out[k] = updates[k]
  }
  return out
}

// ---------------------------------------------------------------- targets

function targetFor(profile, file) {
  var list = (profile && profile.targets) || []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].file === file) return list[i]
  return null
}

function payloadFor(profile, file) {
  var t = targetFor(profile, file)
  return t && isObject(t.payload) ? t.payload : null
}

// ---------------------------------------------------------------- rows

// Both shapes only write the entries you have actually overridden, so a file naming
// two agents still runs the whole roster on defaults. Listing just the file would hide
// the rest behind nothing at all — you cannot pin an agent the panel never draws. So
// the file's own keys come first, in the file's order, and the roster fills in the
// remainder as unpinned rows. An agent the roster has never heard of still shows up,
// because the file is read first and the roster only appends.
//
// These three lists are a fallback, not a source of truth. `oc-profiles detect`
// reads the real rosters off the installed software — the JSON Schema and the
// declaration files oh-my-openagent ships, and opencode's own `opencode generate`
// schema — and the panel hands them to setRoster() before drawing anything. A
// name guessed here and written into someone's config is how `scout`, which no
// opencode release ever shipped, ended up documented as a built-in.
//
// Each list is therefore what its own probe returns, order included, and not a
// tidier version of it: these are read only when a probe failed, and a fallback
// that draws a different panel than the probe would is a second failure hidden
// behind the first.
var OHMY_AGENTS = [
  "OpenCode-Builder", "atlas", "build", "explore", "hephaestus", "librarian",
  "metis", "momus", "multimodal-looker", "oracle", "plan", "prometheus",
  "sisyphus", "sisyphus-junior"
]
var OHMY_CATEGORIES = [
  "artistry", "deep", "quick", "ultrabrain",
  "unspecified-high", "unspecified-low", "visual-engineering", "writing"
]
var OPENCODE_AGENTS = [
  "build", "compaction", "explore", "general", "plan", "summary", "title"
]

// Called once per detect. A roster the probe could not read arrives empty, and
// an empty list must not blank the panel — so each half only replaces its
// fallback when detect actually found something.
// For the shell's own components. A Text of ours carries textFormat: Text.PlainText,
// but a PanelHero or a Button is somebody else's and its default is AutoText, which
// switches to rich text the moment a string looks like markup. Profile names, model
// ids and file names all reach those, and a profiles.json is a file on disk somebody
// else can write — so the markup is taken out of the string instead.
function plain(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    // Control characters do not render as anything and are a way to hide the rest
    // of a name from someone reading the panel.
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "")
}

function sameList(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

// Returns whether anything actually moved. This file is a `.pragma library`, so
// what it holds is a shared global no QML binding can depend on: a binding that
// has already run keeps the old roster until something else happens to invalidate
// it. The caller needs to know a repaint is owed, and only then.
function setRoster(roster) {
  if (!isObject(roster)) return false
  var oc = isObject(roster.opencode) ? roster.opencode : {}
  var om = isObject(roster.ohmy) ? roster.ohmy : {}
  var changed = false
  if (Array.isArray(oc.agents) && oc.agents.length && !sameList(oc.agents, OPENCODE_AGENTS)) {
    OPENCODE_AGENTS = oc.agents.slice(); changed = true
  }
  if (Array.isArray(om.agents) && om.agents.length && !sameList(om.agents, OHMY_AGENTS)) {
    OHMY_AGENTS = om.agents.slice(); changed = true
  }
  if (Array.isArray(om.categories) && om.categories.length && !sameList(om.categories, OHMY_CATEGORIES)) {
    OHMY_CATEGORIES = om.categories.slice(); changed = true
  }
  return changed
}

// Which of the two the machine actually runs, straight from `oc-profiles detect`.
// It decides what the panel is even for: under oh-my-openagent the agents are its
// agents, and opencode's own agent entries are overridden by them, so drawing both
// would offer two rows for one decision.
var SHAPE = "opencode"

function setShape(shape) {
  if (typeof shape !== "string" || !shape || shape === SHAPE) return false
  SHAPE = shape
  return true
}

function shape() { return SHAPE }

function roster() {
  return {
    opencode: { agents: OPENCODE_AGENTS.slice() },
    ohmy: { agents: OHMY_AGENTS.slice(), categories: OHMY_CATEGORIES.slice() }
  }
}

function rosterKeys(container, roster) {
  var keys = [], seen = {}, k, i
  if (isObject(container)) {
    for (k in container) if (!seen[k]) { seen[k] = true; keys.push(k) }
  }
  for (i = 0; i < roster.length; i++) {
    if (!seen[roster[i]]) { seen[roster[i]] = true; keys.push(roster[i]) }
  }
  return keys
}

// One row per editable thing, in the order the panel draws them: default model
// first, then agents, then categories; within a group, the file's own order.
function rowsFor(profile) {
  var rows = []
  var oc = payloadFor(profile, "opencode")
  var om = payloadFor(profile, "ohmy")
  var keys, i

  var underOhMy = SHAPE === "oh-my-openagent"

  if (om && underOhMy) {
    keys = rosterKeys(om.agents, OHMY_AGENTS)
    for (i = 0; i < keys.length; i++) {
      rows.push(makeRow("ohmy", "agent", cleanName(keys[i]), isObject(om.agents) ? om.agents : {}, keys[i], "AGENTS"))
    }
    keys = rosterKeys(om.categories, OHMY_CATEGORIES)
    for (i = 0; i < keys.length; i++) {
      rows.push(makeRow("ohmy", "category", cleanName(keys[i]), isObject(om.categories) ? om.categories : {}, keys[i], "CATEGORIES"))
    }
  }

  if (oc) {
    // Under oh-my-openagent these two are the bottom of the fallback chain rather
    // than the headline setting, so they come last and say what they are. The
    // opencode `agent` entries are left out entirely: oh-my-openagent supplies its
    // own build and plan, and a second row for the same agent is a trap.
    var defaultsHeading = underOhMy ? "OPENCODE BASE" : "DEFAULTS"
    rows.push(makeRow("opencode", "default", "Default model", oc, "model", defaultsHeading))
    rows.push(makeRow("opencode", "default", "Small model", oc, "small_model", defaultsHeading))
    if (!underOhMy) {
      keys = rosterKeys(oc.agent, OPENCODE_AGENTS)
      for (i = 0; i < keys.length; i++) {
        rows.push(makeRow("opencode", "agent", cleanName(keys[i]), isObject(oc.agent) ? oc.agent : {}, keys[i], "AGENTS"))
      }
    }
  }

  // A profile carrying only the half this machine does not run would draw nothing.
  // Falling back to whatever it does carry beats an empty panel.
  if (rows.length === 0 && om) {
    keys = rosterKeys(om.agents, OHMY_AGENTS)
    for (i = 0; i < keys.length; i++) {
      rows.push(makeRow("ohmy", "agent", cleanName(keys[i]), isObject(om.agents) ? om.agents : {}, keys[i], "AGENTS"))
    }
    keys = rosterKeys(om.categories, OHMY_CATEGORIES)
    for (i = 0; i < keys.length; i++) {
      rows.push(makeRow("ohmy", "category", cleanName(keys[i]), isObject(om.categories) ? om.categories : {}, keys[i], "CATEGORIES"))
    }
  }
  return rows
}

function makeRow(file, group, label, container, key, heading) {
  var value = container[key]
  return {
    file: file, group: group, key: key, label: label,
    heading: heading || (group === "category" ? "CATEGORIES" : group === "agent" ? "AGENTS" : "DEFAULTS"),
    model: readModel(value),
    variant: readVariant(value),
    fallbacks: readFallbacks(value)
  }
}

// One reader for all three shapes: "provider/model", { model, variant }, { model, fallback_models }.
function readModel(value) {
  if (typeof value === "string") return value
  if (Array.isArray(value)) return value.length > 0 ? readModel(value[0]) : ""
  if (isObject(value)) return String(value.model || "")
  return ""
}

// oh-my-openagent 4.19 renamed `variant` to `reasoning`, and when an entry carries both
// it keeps `reasoning` and reports the other as dropped. Read either, or an entry the
// plugin migrated for itself reads back with no effort at all.
function readVariant(value) {
  if (!isObject(value) || Array.isArray(value)) return ""
  return String(value.reasoning || value.variant || "")
}

// Does this file already speak the new name anywhere? oh-my-openagent migrates a whole
// file in one pass, so a single entry carrying `reasoning` says the install that wrote
// this config uses it — and no entry carrying it says nothing at all. Nothing here asks
// the plugin its version: the file is the evidence, and it stays right through whatever
// version bump comes next.
function fileUsesReasoning(profile, row) {
  var t = targetFor(profile, row.file)
  if (!t || !isObject(t.payload)) return false
  var groups = [t.payload.agents, t.payload.categories, t.payload.agent]
  for (var g = 0; g < groups.length; g++) {
    var o = groups[g]
    if (!isObject(o)) continue
    for (var k in o) {
      var v = o[k]
      if (isObject(v) && !Array.isArray(v) && v.reasoning !== undefined) return true
    }
  }
  return false
}

// The spelling to write. An entry that already chose one keeps it. One that has not
// follows the rest of its file, and a file that says nothing gets `variant` — which
// every 3.x and 4.x reads, so a config this plugin writes never needs a newer plugin.
function effortKey(value, profile, row) {
  if (isObject(value) && !Array.isArray(value)) {
    if (value.reasoning !== undefined) return "reasoning"
    if (value.variant !== undefined) return "variant"
  }
  return fileUsesReasoning(profile, row) ? "reasoning" : "variant"
}

function readFallbacks(value) {
  var list = isObject(value) ? value.fallback_models : (Array.isArray(value) ? value : null)
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var m = readModel(list[i])
    if (m) out.push({ model: m, variant: readVariant(list[i]) })
  }
  return out
}

// ---------------------------------------------------------------- editing

function containerFor(profile, row, create) {
  var t = targetFor(profile, row.file)
  if (!t) {
    if (!create) return null
    t = { file: row.file,
          shape: row.file === "ohmy" ? "oh-my-openagent" : "opencode",
          manages: [], payload: {} }
    if (!Array.isArray(profile.targets)) profile.targets = []
    profile.targets.push(t)
  }
  if (!isObject(t.payload)) t.payload = {}
  var p = t.payload

  function ensure(key) {
    if (!isObject(p[key])) { if (!create) return null; p[key] = {} }
    if (Array.isArray(t.manages) && t.manages.indexOf(key) < 0) t.manages.push(key)
    return p[key]
  }

  if (row.file === "opencode") {
    if (row.group === "agent") return ensure("agent")
    if (Array.isArray(t.manages) && t.manages.indexOf(row.key) < 0) t.manages.push(row.key)
    return p
  }
  if (row.group === "agent") return ensure("agents")
  if (row.group === "category") return ensure("categories")
  return p
}

// opencode.json's AgentConfig is an object — its schema has no string branch —
// so an `agent` entry is always written long, even for a lone model.
// oh-my-openagent's AgentOverrideConfigSchema (4.19+) also requires an object;
// a bare string there fails `doctor` with `expected object, received string`.
// The short string form is only legal for opencode's own top-level
// `model`/`small_model` (outside `agent`).
function longFormOnly(row) {
  return row.file === "opencode" && row.group === "agent"
}
function ohMyRequiresObject(row) {
  return row.file === "ohmy"
}

// Outside `agent`, a bare string stays one until a variant forces an object —
// except oh-my-openagent agents/categories which must be objects since 4.19
// (`expected object, received string` on `doctor`).
function setRowModel(profile, row, modelId) {
  var p = clone(profile)
  var c = containerFor(p, row, true)
  if (!c) return profile
  var value = c[row.key]
  if (isObject(value)) c[row.key] = orderedAssign(value, { model: modelId })
  else if (longFormOnly(row) || ohMyRequiresObject(row)) c[row.key] = orderedAssign(typeof value === "string" && value ? { model: value } : {}, { model: modelId })
  else c[row.key] = modelId
  return p
}

function setRowVariant(profile, row, variant) {
  var p = clone(profile)
  var c = containerFor(p, row, true)
  if (!c) return profile
  var value = c[row.key]
  if (typeof value === "string") value = { model: value }
  if (!isObject(value)) value = { model: "" }
  var vKey = effortKey(value, p, row)
  var vOther = vKey === "reasoning" ? "variant" : "reasoning"
  var vPatch = {}
  vPatch[vKey] = variant || undefined
  value = orderedAssign(value, vPatch)
  // Never leave both spellings on one entry — that is the conflict oh-my-openagent
  // resolves by dropping one of them behind the user's back.
  delete value[vOther]
  if (!variant) delete value[vKey]
  // An object whose only key is `model` collapses to a string — unless the
  // file demands the long form (opencode agent) or the schema requires an
  // object (oh-my-openagent since 4.19).
  if (!longFormOnly(row) && !ohMyRequiresObject(row) && Object.keys(value).length === 1 && value.model !== undefined) c[row.key] = value.model
  else if (longFormOnly(row) && Object.keys(value).length === 0) delete c[row.key]
  else if (ohMyRequiresObject(row) && Object.keys(value).length === 0) c[row.key] = { model: value.model || "" }
  else c[row.key] = value
  return p
}

function setRowFallbacks(profile, row, fallbacks) {
  var p = clone(profile)
  var c = containerFor(p, row, true)
  if (!c) return profile
  var value = c[row.key]
  if (typeof value === "string") value = { model: value }
  if (!isObject(value)) value = { model: "" }
  var fKey = effortKey(value, p, row)
  var list = []
  for (var i = 0; i < (fallbacks || []).length; i++) {
    var f = fallbacks[i]
    if (!f || !f.model) continue
    var entry = { model: f.model }
    if (f.variant) entry[fKey] = f.variant
    list.push(entry)
  }
  value = orderedAssign(value, { fallback_models: list.length > 0 ? list : undefined })
  if (list.length === 0) delete value.fallback_models
  if (!longFormOnly(row) && !ohMyRequiresObject(row) && Object.keys(value).length === 1 && value.model !== undefined) c[row.key] = value.model
  else if (longFormOnly(row) && Object.keys(value).length === 0) delete c[row.key]
  else if (ohMyRequiresObject(row) && Object.keys(value).length === 0) c[row.key] = { model: value.model || "" }
  else c[row.key] = value
  return p
}

// One model everywhere — the control most profiles are built with. `variantFor`
// is passed in: an effort a model does not offer fails on the first request.
function setAllModels(profile, modelId, variantFor) {
  var p = clone(profile)
  var rows = rowsFor(p)
  for (var i = 0; i < rows.length; i++) {
    p = setRowModel(p, rows[i], modelId)
    var v = variantFor ? variantFor(modelId, rows[i]) : ""
    p = setRowVariant(p, rows[i], v)
  }
  return p
}

// ---------------------------------------------------------------- summary

function dominantModel(profile) {
  var rows = rowsFor(profile), counts = {}, best = "", bestN = 0
  for (var i = 0; i < rows.length; i++) {
    var m = rows[i].model
    if (!m) continue
    counts[m] = (counts[m] || 0) + 1
    if (counts[m] > bestN) { bestN = counts[m]; best = m }
  }
  return best
}

function isUniform(profile) {
  var rows = rowsFor(profile), seen = ""
  for (var i = 0; i < rows.length; i++) {
    if (!rows[i].model) continue
    if (!seen) seen = rows[i].model
    else if (rows[i].model !== seen) return false
  }
  return seen !== ""
}

function distinctModels(profile) {
  var rows = rowsFor(profile), seen = {}, out = []
  for (var i = 0; i < rows.length; i++) {
    var m = rows[i].model
    if (!m || seen[m]) continue
    seen[m] = true; out.push(m)
  }
  return out
}

function agentCount(profile) {
  var rows = rowsFor(profile), n = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].group === "agent") n++
  return n
}

// The line under a profile's name: one model if uniform, else the two or three
// it actually uses — "mostly opus" is the thing you switch profiles over.
// Which profile the panel should call the running one.
//
// The store remembers the id of the last profile that was *switched to*, but a
// config can arrive at a saved profile without a switch: an undo to a backup taken
// before any profile was active, a hand edit that lands back on one, a capture made
// elsewhere. oc-profiles answers that separately in `matches`. Reading only the
// stored id is how a config that matches "Saved config" byte for byte gets reported
// as matching nothing at all, under a heading that says "Custom".
//
// A stored id that still names a profile wins, drifted or not: it is what the user
// last asked for, and calling it something else because the file has since been
// edited would hide the edit rather than show it.
function resolveActiveId(store) {
  if (!isObject(store)) return ""
  var profiles = Array.isArray(store.profiles) ? store.profiles : []
  var i, j

  // oc-profiles works this out already, over the same store and the same live
  // fingerprints, and it is the half that also decides `drift`. Taking its answer
  // keeps the heading and the drift strip from disagreeing. The rules below stand
  // in when the field is missing: a store read by an older binary, or by hand.
  var given = String(store.effectiveProfileId || "")
  if (given) {
    for (i = 0; i < profiles.length; i++)
      if (profiles[i] && profiles[i].id === given) return given
  }

  var stored = String((isObject(store.state) && store.state.activeProfileId) || "")
  if (stored) {
    for (i = 0; i < profiles.length; i++)
      if (profiles[i] && profiles[i].id === stored) return stored
  }

  // Only ids the store still carries: `matches` is computed against the same file
  // this was read from, but a name that no longer resolves is worse than none.
  var matches = Array.isArray(store.matches) ? store.matches : []
  for (i = 0; i < matches.length; i++) {
    var id = String(matches[i] || "")
    if (!id) continue
    for (j = 0; j < profiles.length; j++)
      if (profiles[j] && profiles[j].id === id) return id
  }
  return ""
}

function summary(profile) {
  var rows = rowsFor(profile)
  var pinned = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].model) pinned++
  if (pinned === 0) return "nothing pinned"

  var models = distinctModels(profile)
  var head = pinned + " of " + rows.length + " pinned"
  if (models.length === 1) return head + " · " + shortModel(models[0])
  var names = []
  for (var j = 0; j < Math.min(3, models.length); j++) names.push(shortModel(models[j]))
  var tail = names.join(", ")
  if (models.length > 3) tail += " +" + (models.length - 3)
  return head + " · " + tail
}

// ---------------------------------------------------------------- diffing

// Comparing rows rather than JSON, so a reformat or a reordered file is not a
// change — only a different answer for some agent is.
function changedRows(before, after) {
  var a = rowsFor(before), b = rowsFor(after), out = []
  var index = {}
  for (var i = 0; i < a.length; i++) index[a[i].file + "\u0000" + a[i].group + "\u0000" + a[i].key] = a[i]
  for (var j = 0; j < b.length; j++) {
    var row = b[j]
    var was = index[row.file + "\u0000" + row.group + "\u0000" + row.key]
    if (!was) { out.push({ row: row, from: "", to: row.model }); continue }
    if (was.model !== row.model || was.variant !== row.variant
        || JSON.stringify(was.fallbacks) !== JSON.stringify(row.fallbacks)) {
      out.push({ row: row, from: was.model, to: row.model,
                 fromVariant: was.variant, toVariant: row.variant })
    }
  }
  return out
}

function sameProfile(a, b) {
  return JSON.stringify(stripVolatile(a)) === JSON.stringify(stripVolatile(b))
}

function stripVolatile(p) {
  var c = clone(p) || {}
  delete c.updatedAt
  delete c.createdAt
  var t = c.targets || []
  for (var i = 0; i < t.length; i++) delete t[i].fingerprint
  return c
}
