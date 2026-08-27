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

// One row per editable thing, in the order the panel draws them: default model
// first, then agents, then categories; within a group, the file's own order.
function rowsFor(profile) {
  var rows = []
  var oc = payloadFor(profile, "opencode")
  var om = payloadFor(profile, "ohmy")

  if (oc) {
    if (oc.model !== undefined) rows.push(makeRow("opencode", "default", "Default model", oc, "model"))
    if (oc.small_model !== undefined) rows.push(makeRow("opencode", "default", "Small model", oc, "small_model"))
    if (isObject(oc.agent)) {
      for (var a in oc.agent) rows.push(makeRow("opencode", "agent", cleanName(a), oc.agent, a))
    }
  }
  if (om) {
    if (isObject(om.agents)) {
      for (var b in om.agents) rows.push(makeRow("ohmy", "agent", cleanName(b), om.agents, b))
    }
    if (isObject(om.categories)) {
      for (var c in om.categories) rows.push(makeRow("ohmy", "category", cleanName(c), om.categories, c))
    }
  }
  return rows
}

function makeRow(file, group, label, container, key) {
  var value = container[key]
  return {
    file: file, group: group, key: key, label: label,
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

function readVariant(value) {
  return (isObject(value) && !Array.isArray(value)) ? String(value.variant || "") : ""
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

// A bare string stays one until a variant forces an object — promoting every
// entry on the first edit would rewrite half the file to change one model.
function setRowModel(profile, row, modelId) {
  var p = clone(profile)
  var c = containerFor(p, row, true)
  if (!c) return profile
  var value = c[row.key]
  if (isObject(value)) c[row.key] = orderedAssign(value, { model: modelId })
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
  value = orderedAssign(value, { variant: variant || undefined })
  if (!variant) delete value.variant
  // An object whose only key is `model` is a string with extra punctuation.
  if (Object.keys(value).length === 1 && value.model !== undefined) c[row.key] = value.model
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
  var list = []
  for (var i = 0; i < (fallbacks || []).length; i++) {
    var f = fallbacks[i]
    if (!f || !f.model) continue
    var entry = { model: f.model }
    if (f.variant) entry.variant = f.variant
    list.push(entry)
  }
  value = orderedAssign(value, { fallback_models: list.length > 0 ? list : undefined })
  if (list.length === 0) delete value.fallback_models
  if (Object.keys(value).length === 1 && value.model !== undefined) c[row.key] = value.model
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
function summary(profile) {
  var rows = rowsFor(profile)
  var pinned = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].model) pinned++
  if (pinned === 0) return "nothing pinned"

  var models = distinctModels(profile)
  var head = pinned + (pinned === 1 ? " entry" : " entries")
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
