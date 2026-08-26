.pragma library

// The model list: searching it, ranking it, and saying what a model is in one
// row. Built by bin/sync-models.sh from the models your opencode can reach plus
// models.dev metadata. Reachable models rank first everywhere: ranking a model
// you cannot call above one you can is worse than a shorter list.

// ---------------------------------------------------------------- shaping

function empty() {
  return { generated: 0, providers: [], models: [], reachableCount: 0, totalCount: 0 }
}

function fromText(text) {
  try {
    var c = JSON.parse(String(text || ""))
    if (!c || !Array.isArray(c.models)) return empty()
    return c
  } catch (e) { return empty() }
}

function byId(catalog) {
  var map = {}
  var list = (catalog && catalog.models) || []
  for (var i = 0; i < list.length; i++) map[list[i].id] = list[i]
  return map
}

// An id the catalog never heard of was still typed by the user: synthesize a model so the row shows it instead of an empty trigger.
function lookup(catalog, index, id) {
  if (!id) return null
  var hit = index ? index[id] : null
  if (hit) return hit
  var parts = String(id).split("/")
  return { id: id, provider: parts[0] || "", providerName: parts[0] || "",
           modelId: parts.slice(1).join("/"), name: parts[parts.length - 1] || id,
           context: 0, inputCost: null, outputCost: null, variants: [],
           reasoning: false, vision: false, free: false, reachable: false, unknown: true }
}

// The efforts a model actually offers; empty disables the variant control, because an unsupported effort loads fine and then fails on the first request.
function variantsFor(index, id) {
  var m = index ? index[id] : null
  return (m && Array.isArray(m.variants)) ? m.variants : []
}

// Best effort at or below what was asked: a shorter ladder steps down quietly rather than writing "xhigh" to a model that stops at "high".
function nearestVariant(index, id, wanted) {
  var vs = variantsFor(index, id)
  if (vs.length === 0) return ""
  if (!wanted) return ""
  if (vs.indexOf(wanted) >= 0) return wanted
  var ladder = ["max", "xhigh", "high", "medium", "low"]
  var from = ladder.indexOf(wanted)
  if (from < 0) return vs[vs.length - 1]
  for (var i = from; i < ladder.length; i++) if (vs.indexOf(ladder[i]) >= 0) return ladder[i]
  for (var j = from - 1; j >= 0; j--) if (vs.indexOf(ladder[j]) >= 0) return ladder[j]
  return vs[vs.length - 1]
}

// ---------------------------------------------------------------- formatting

// 1048576 is a number you have to stop and count the digits of. 1M is not.
function formatContext(n) {
  var v = Number(n) || 0
  if (v <= 0) return ""
  if (v >= 1000000) {
    var m = v / 1048576
    if (Math.abs(m - Math.round(m)) < 0.06) return Math.round(m) + "M"
    return (v / 1000000).toFixed(1).replace(/\.0$/, "") + "M"
  }
  if (v >= 1000) return Math.round(v / 1000) + "K"
  return String(v)
}

// Dollars per million tokens, in and out — the two numbers that decide whether
// a profile is one you leave on. Free is worth saying as a word.
function formatPrice(model) {
  if (!model) return ""
  var i = model.inputCost, o = model.outputCost
  if (i === null || i === undefined || o === null || o === undefined) return ""
  if (Number(i) === 0 && Number(o) === 0) return "free"
  return "$" + trimNum(i) + " / $" + trimNum(o)
}

function trimNum(n) {
  var v = Number(n)
  if (!isFinite(v)) return String(n)
  if (v === Math.round(v)) return String(Math.round(v))
  if (v < 1) return v.toFixed(2).replace(/0$/, "").replace(/\.$/, "")
  return v.toFixed(2).replace(/0$/, "").replace(/\.$/, "")
}

// At most one badge per row. Two is a row you read instead of scan, and the
// third one is never the reason anybody picked a model.
function badgeFor(model) {
  if (!model) return ""
  if (model.unknown) return ""
  if (model.free) return "free"
  if (model.vision) return "vision"
  if (model.reasoning) return "thinks"
  return ""
}

function metaLine(model, showMeta) {
  if (!model || !showMeta) return ""
  var parts = []
  var ctx = formatContext(model.context)
  if (ctx) parts.push(ctx)
  var price = formatPrice(model)
  if (price) parts.push(price)
  return parts.join("  ")
}

// ---------------------------------------------------------------- search

// Prefix beats word-start beats substring, and a model-id hit beats a provider-name
// hit: "opus" must not rank six providers' catalogues above Claude Opus.
function score(model, query) {
  if (!query) return model.reachable ? 100 : 50
  var hay = model.search || ""
  var id = String(model.id || "").toLowerCase()
  var name = String(model.name || "").toLowerCase()
  var short = String(model.modelId || "").toLowerCase()

  var s = -1
  if (short.indexOf(query) === 0 || name.indexOf(query) === 0) s = 1000
  else if (id.indexOf(query) === 0) s = 900
  else if (short.indexOf("/" + query) >= 0 || (" " + name).indexOf(" " + query) >= 0) s = 800
  else if (short.indexOf(query) >= 0) s = 700
  else if (name.indexOf(query) >= 0) s = 650
  else if (id.indexOf(query) >= 0) s = 600
  else if (hay.indexOf(query) >= 0) s = 400
  else return -1

  // A shorter name containing the query is more likely to be the thing meant:
  // "gpt" should reach "GPT-5" before "GPT-5 Codex Mini (preview)".
  s -= Math.min(80, short.length)
  if (model.reachable) s += 500
  return s
}

// Multi-word queries are ANDed: "opus max" finds the model whose haystack has
// both, which is how people actually narrow a list of six thousand.
function scoreQuery(model, terms) {
  if (terms.length === 0) return model.reachable ? 100 : 50
  var total = 0
  for (var i = 0; i < terms.length; i++) {
    var s = score(model, terms[i])
    if (s < 0) return -1
    total += s
  }
  return total / terms.length
}

function terms(query) {
  return String(query || "").toLowerCase().split(/\s+/).filter(function (t) { return t.length > 0 })
}

// The list the picker renders. `scope` is "reachable" (callable today) or "all"
// (whole catalog); `limit` caps with a visible remainder, never a silent cut.
function search(catalog, query, opts) {
  var o = opts || {}
  var scope = o.scope || "reachable"
  var limit = o.limit || 200
  var favorites = o.favorites || []
  var recents = o.recents || []
  var current = o.current || ""

  var t = terms(query)
  var models = (catalog && catalog.models) || []
  var scored = []

  var favSet = {}, recSet = {}
  for (var f = 0; f < favorites.length; f++) favSet[favorites[f]] = true
  for (var r = 0; r < recents.length; r++) recSet[recents[r]] = recents.length - r

  for (var i = 0; i < models.length; i++) {
    var m = models[i]
    if (scope === "reachable" && !m.reachable && m.id !== current) continue
    var s = scoreQuery(m, t)
    if (s < 0) continue
    if (favSet[m.id]) s += 4000
    if (recSet[m.id]) s += 2000 + recSet[m.id]
    if (m.id === current) s += 8000
    scored.push({ model: m, score: s })
  }

  scored.sort(function (a, b) {
    if (b.score !== a.score) return b.score - a.score
    return String(a.model.id).localeCompare(String(b.model.id))
  })

  var total = scored.length
  var out = []
  for (var k = 0; k < Math.min(limit, total); k++) {
    var e = scored[k]
    out.push({
      id: e.model.id, model: e.model,
      favorite: !!favSet[e.model.id],
      recent: !!recSet[e.model.id],
      current: e.model.id === current
    })
  }
  return { rows: out, total: total, shown: out.length, truncated: total > out.length }
}

// A provider heading on each provider change, so a long list reads as a few catalogues.
// Unqueried lists only: while typing, rank matters more and headings push the answer down.
function withGroups(result, grouped) {
  if (!grouped) return result.rows
  var out = [], last = ""
  for (var i = 0; i < result.rows.length; i++) {
    var row = result.rows[i]
    var p = row.model.providerName || row.model.provider
    if (p !== last) { out.push({ header: p, id: "__header__" + p }); last = p }
    out.push(row)
  }
  return out
}

// ---------------------------------------------------------------- recents

// Eight, newest first, no duplicates: enough for the models a person rotates between, not a second catalogue to scan.
function pushRecent(recents, id) {
  var out = [id]
  for (var i = 0; i < (recents || []).length; i++) {
    if (recents[i] !== id) out.push(recents[i])
    if (out.length >= 8) break
  }
  return out
}

function toggleFavorite(favorites, id) {
  var out = [], found = false
  for (var i = 0; i < (favorites || []).length; i++) {
    if (favorites[i] === id) { found = true; continue }
    out.push(favorites[i])
  }
  if (!found) out.unshift(id)
  return out
}
