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
t("oh-my-openagent rows keep the short string form", () => {
  const p = omProfile();
  const row = M.rowsFor(p).find(r => r.file === "ohmy" && r.key === "sisyphus");
  const out = M.setRowModel(p, row, "anthropic/claude-opus-5");
  assert.strictEqual(out.targets[0].payload.agents.sisyphus, "anthropic/claude-opus-5");
});

console.log("\n" + (fail ? "FAILED " + fail + " / " : "") + pass + " passed");
process.exit(fail ? 1 : 0);
