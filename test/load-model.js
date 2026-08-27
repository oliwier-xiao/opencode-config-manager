// Load lib/Model.js (a QML .pragma library) into plain node for testing.
const fs = require("fs"), vm = require("vm");
module.exports = function loadModel(path) {
  let src = fs.readFileSync(path, "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "");
  const ctx = { console };
  vm.createContext(ctx);
  vm.runInContext(src, ctx, { filename: path });
  return ctx;
};
