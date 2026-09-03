const assert = require("assert");
const path = require("path");
const REPO = path.resolve(__dirname, "..");
const M = require(path.join(__dirname, "load-model.js"))(path.join(REPO, "lib/Model.js"));
let pass = 0, fail = 0;
const eq = (a,b,m) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b), (m||"") + "\n       got: " + JSON.stringify(a) + "\n       want:" + JSON.stringify(b));
function t(name, fn) { try { fn(); pass++; console.log("  ok   " + name); }
  catch (e) { fail++; console.log("  FAIL " + name + "\n       " + e.message); } }

const ocProfile = () => ({ id: "p", name: "P", targets: [
  { file: "opencode", shape: "opencode", manages: ["model","small_model","agent"],
    payload: { model: "anthropic/claude-sonnet-5", small_model: "anthropic/claude-haiku-4-5",
               agent: { build: { model: "anthropic/claude-sonnet-5" }, "my-reviewer": { mode: "subagent" } } } } ] });
const omProfile = () => ({ id: "o", name: "O", targets: [
  { file: "ohmy", shape: "oh-my-openagent", manages: ["agents","categories"],
    payload: { agents: { librarian: "anthropic/claude-haiku-4-5" }, categories: {} } } ] });

console.log("\n--- D1: no phantom opencode agent ---");
t("roster never contains 'scout'", () => {
  assert(M.roster().opencode.agents.indexOf("scout") < 0);
  assert(M.rowsFor(ocProfile()).every(r => r.key !== "scout"));
});

console.log("\n--- setRoster: detected roster replaces the fallback ---");
t("detected opencode roster is used", () => {
  M.setRoster({ opencode: { agents: ["plan","build","general","explore","title","summary","compaction"] } });
  const keys = M.rowsFor(ocProfile()).filter(r => r.group === "agent").map(r => r.key);
  eq(keys, ["build","my-reviewer","plan","general","explore","title","summary","compaction"]);
});
t("empty detected roster does not blank the panel", () => {
  const before = M.roster().opencode.agents.slice();
  M.setRoster({ opencode: { agents: [] } });
  eq(M.roster().opencode.agents, before);
});
t("detected ohmy roster is used", () => {
  M.setRoster({ ohmy: { agents: ["sisyphus","oracle"], categories: ["deep","quick"] } });
  const rows = M.rowsFor(omProfile());
  eq(rows.filter(r=>r.group==="agent").map(r=>r.key), ["librarian","sisyphus","oracle"]);
  eq(rows.filter(r=>r.group==="category").map(r=>r.key), ["deep","quick"]);
});

console.log("\n--- D2: opencode agent entries must stay objects ---");
t("pinning an unpinned opencode agent writes {model}", () => {
  const p = ocProfile();
  const row = M.rowsFor(p).find(r => r.file === "opencode" && r.key === "plan");
  const out = M.setRowModel(p, row, "anthropic/claude-opus-5");
  eq(out.targets[0].payload.agent.plan, { model: "anthropic/claude-opus-5" });
});
t("setting then clearing a variant does not demote to a bare string", () => {
  let p = ocProfile();
  const row = M.rowsFor(p).find(r => r.file === "opencode" && r.key === "build");
  p = M.setRowVariant(p, row, "high");
  eq(p.targets[0].payload.agent.build, { model: "anthropic/claude-sonnet-5", variant: "high" });
  p = M.setRowVariant(p, row, "");
  eq(p.targets[0].payload.agent.build, { model: "anthropic/claude-sonnet-5" });
});
t("'every agent on X' leaves no bare strings under agent{}", () => {
  const out = M.setAllModels(ocProfile(), "anthropic/claude-opus-5", () => "");
  const agent = out.targets[0].payload.agent;
  for (const k of Object.keys(agent))
    assert.strictEqual(typeof agent[k], "object", k + " is " + JSON.stringify(agent[k]));
  assert.strictEqual(typeof out.targets[0].payload.model, "string");
});
t("a user-defined subagent keeps its non-model fields", () => {
  const out = M.setAllModels(ocProfile(), "anthropic/claude-opus-5", () => "");
  assert.strictEqual(out.targets[0].payload.agent["my-reviewer"].mode, "subagent");
});
t("oh-my-openagent rows are always objects (4.19+ requires object, not string)", () => {
  const p = omProfile();
  const row = M.rowsFor(p).find(r => r.file === "ohmy" && r.key === "sisyphus");
  const out = M.setRowModel(p, row, "anthropic/claude-opus-5");
  eq(out.targets[0].payload.agents.sisyphus, { model: "anthropic/claude-opus-5" });
});


console.log("\n--- resolveActiveId: which profile the panel may call the running one ---");
const store = (over) => Object.assign({
  profiles: [{ id: "a", name: "A" }, { id: "b", name: "B" }],
  state: { activeProfileId: null },
  matches: []
}, over || {});

t("a stored id that still names a profile wins", () => {
  eq(M.resolveActiveId(store({ state: { activeProfileId: "b" }, matches: ["a"] })), "b");
});
t("a stored id wins even when the config has drifted off it", () => {
  eq(M.resolveActiveId(store({ state: { activeProfileId: "b" }, matches: [] })), "b");
});
t("no stored id falls back to what disk matches", () => {
  eq(M.resolveActiveId(store({ matches: ["a"] })), "a");
});
t("a stored id naming a deleted profile falls back too", () => {
  eq(M.resolveActiveId(store({ state: { activeProfileId: "gone" }, matches: ["b"] })), "b");
});
t("a match naming a profile the store no longer has is ignored", () => {
  eq(M.resolveActiveId(store({ matches: ["gone"] })), "");
});
t("nothing stored and nothing matching reads as custom", () => {
  eq(M.resolveActiveId(store({})), "");
});
t("oc-profiles' own answer is preferred over both", () => {
  eq(M.resolveActiveId(store({ effectiveProfileId: "a", state: { activeProfileId: "b" } })), "a");
});
t("but only when it still names a profile", () => {
  eq(M.resolveActiveId(store({ effectiveProfileId: "gone", state: { activeProfileId: "b" } })), "b");
});
t("junk in place of a store is not an active profile", () => {
  eq(M.resolveActiveId(null), "");
  eq(M.resolveActiveId("nope"), "");
  eq(M.resolveActiveId({ profiles: "not a list", matches: "not a list" }), "");
});

console.log("\n--- setRoster/setShape report whether a repaint is owed ---");
t("a shape that did not move reports no change", () => {
  M.setShape("opencode");
  assert.strictEqual(M.setShape("opencode"), false);
  assert.strictEqual(M.setShape("oh-my-openagent"), true);
  assert.strictEqual(M.setShape("oh-my-openagent"), false);
});
t("an empty or absent shape is not a change", () => {
  M.setShape("opencode");
  assert.strictEqual(M.setShape(""), false);
  assert.strictEqual(M.setShape(null), false);
  eq(M.shape(), "opencode");
});
t("the same roster twice reports no change", () => {
  const r = { opencode: { agents: ["build", "plan"] },
              ohmy: { agents: ["oracle"], categories: ["deep"] } };
  M.setRoster(r);
  assert.strictEqual(M.setRoster(r), false);
  assert.strictEqual(M.setRoster({ opencode: { agents: ["build", "plan", "explore"] } }), true);
});
t("a roster the probe could not read is not a change", () => {
  assert.strictEqual(M.setRoster({ opencode: { agents: [] } }), false);
  assert.strictEqual(M.setRoster(null), false);
});

console.log("\n--- oh-my-openagent 4.19: `reasoning` is the current spelling of `variant` ---");

const omoEffort = () => ({ id: "o", name: "O", targets: [
  { file: "ohmy", shape: "oh-my-openagent", manages: ["agents","categories"],
    payload: { agents: {
      oracle: { model: "anthropic/claude-opus-5", reasoning: "high" },
      metis:  { model: "anthropic/claude-opus-5", variant: "max" },
      momus:  { model: "anthropic/claude-opus-5" },
      atlas:  { model: "anthropic/claude-opus-5", reasoning: "high", variant: "low" } },
      categories: {} } } ] });
const omoRow = (p, key) => M.rowsFor(p).find(r => r.file === "ohmy" && r.key === key);

t("an entry the plugin migrated to `reasoning` still reads back its effort", () => {
  const p = omoEffort();
  eq(omoRow(p, "oracle").variant, "high");
  eq(omoRow(p, "metis").variant, "max");
});
t("`reasoning` is written back as `reasoning`, not duplicated as `variant`", () => {
  let p = omoEffort();
  p = M.setRowVariant(p, omoRow(p, "oracle"), "max");
  eq(p.targets[0].payload.agents.oracle, { model: "anthropic/claude-opus-5", reasoning: "max" });
});
t("an entry with no spelling follows the file it is in", () => {
  let p = omoEffort();
  p = M.setRowVariant(p, omoRow(p, "momus"), "high");
  eq(p.targets[0].payload.agents.momus, { model: "anthropic/claude-opus-5", reasoning: "high" });
});
t("a file that has never seen `reasoning` gets `variant`, which every 3.x and 4.x reads", () => {
  let p = { id: "o", name: "O", targets: [
    { file: "ohmy", shape: "oh-my-openagent", manages: ["agents","categories"],
      payload: { agents: { momus: { model: "anthropic/claude-opus-5" } }, categories: {} } } ] };
  p = M.setRowVariant(p, omoRow(p, "momus"), "high");
  eq(p.targets[0].payload.agents.momus, { model: "anthropic/claude-opus-5", variant: "high" });
});
t("an entry carrying both spellings keeps the one the plugin keeps", () => {
  let p = omoEffort();
  eq(omoRow(p, "atlas").variant, "high");
  p = M.setRowVariant(p, omoRow(p, "atlas"), "max");
  eq(p.targets[0].payload.agents.atlas, { model: "anthropic/claude-opus-5", reasoning: "max" });
});
t("clearing an effort removes both spellings but keeps object form (ohmy requires object)", () => {
  let p = omoEffort();
  p = M.setRowVariant(p, omoRow(p, "atlas"), "");
  eq(p.targets[0].payload.agents.atlas, { model: "anthropic/claude-opus-5" });
});
t("a fallback follows the spelling its own entry uses", () => {
  let p = omoEffort();
  p = M.setRowFallbacks(p, omoRow(p, "oracle"), [{ model: "google/gemini-3.1-pro-preview", variant: "high" }]);
  eq(p.targets[0].payload.agents.oracle.fallback_models, [{ model: "google/gemini-3.1-pro-preview", reasoning: "high" }]);
  p = M.setRowFallbacks(p, omoRow(p, "metis"), [{ model: "google/gemini-3.1-pro-preview", variant: "high" }]);
  eq(p.targets[0].payload.agents.metis.fallback_models, [{ model: "google/gemini-3.1-pro-preview", variant: "high" }]);
});

console.log("\n--- an effort never survives onto a model that has no efforts ---");
// ProfileEditor.applyRowModel steps the effort down through Catalog.nearestVariant
// before writing. It used to do that only for oh-my-openagent rows, so an opencode
// agent kept the old model's effort — the one config this plugin could write that
// loads and then fails on the first request. These assert the writer half: given
// what nearestVariant returns, the row must end up correct either way.
const CAT = require("path").join(REPO, "lib/Catalog.js");
const C = require(require("path").join(__dirname, "load-model.js"))(CAT);
const index = {
  "anthropic/claude-opus-5":   { id: "anthropic/claude-opus-5",   variants: ["low","medium","high","max"] },
  "openai/gpt-5-nano":         { id: "openai/gpt-5-nano",         variants: [] },
  "google/gemini-3-flash":     { id: "google/gemini-3-flash",     variants: ["low","medium"] }
};
// Exactly what ProfileEditor.applyRowModel does, with the file condition removed.
function applyRowModel(profile, row, modelId) {
  let next = M.setRowModel(profile, row, modelId);
  const wanted = row.variant;
  if (wanted) next = M.setRowVariant(next, row, C.nearestVariant(index, modelId, wanted));
  return next;
}
const ocAgentRow = (p) => M.rowsFor(p).filter(r => r.group === "agent" && r.key === "build")[0];

t("an opencode agent loses an effort the new model does not offer", () => {
  let p = ocProfile();
  p = M.setRowVariant(p, ocAgentRow(p), "max");
  eq(p.targets[0].payload.agent.build.variant, "max", "precondition");
  p = applyRowModel(p, ocAgentRow(p), "openai/gpt-5-nano");
  const e = p.targets[0].payload.agent.build;
  eq(e.model, "openai/gpt-5-nano");
  assert(e.variant === undefined, "variant survived onto a model with none: " + JSON.stringify(e));
});
t("an opencode agent keeps the nearest effort the new model does offer", () => {
  let p = ocProfile();
  p = M.setRowVariant(p, ocAgentRow(p), "max");
  p = applyRowModel(p, ocAgentRow(p), "google/gemini-3-flash");
  eq(p.targets[0].payload.agent.build.variant, "medium");
});
t("an oh-my-openagent row still steps down, as it always did", () => {
  let p = omProfile();
  let r = M.rowsFor(p).filter(x => x.file === "ohmy" && x.key === "librarian")[0];
  p = M.setRowVariant(p, r, "max");
  r = M.rowsFor(p).filter(x => x.file === "ohmy" && x.key === "librarian")[0];
  p = applyRowModel(p, r, "openai/gpt-5-nano");
  const e = p.targets[0].payload.agents.librarian;
  assert(e.variant === undefined && e.reasoning === undefined,
         "effort survived: " + JSON.stringify(e));
});

console.log("\n" + (fail ? "FAILED " + fail + " / " : "") + pass + " passed");
process.exit(fail ? 1 : 0);
