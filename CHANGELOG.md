# Changelog

## 1.1.0

The oh-my-openagent half of this plugin was editing a file oh-my-openagent no longer
reads, and the plain-opencode half was drawing an agent that never existed. Both are
fixed, and the agent lists are now read off the installed software instead of being
carried in this repository.

### Fixed

- **oh-my-openagent config is read and written at `~/.omo/omo.jsonc`**, under its
  `"[opencode]"` section. Its `2026-07-opencode-config-unification` migration moved
  the config there; until now this plugin still targeted
  `~/.config/opencode/oh-my-openagent.json`, so on any machine where that migration
  had run, every model it wrote had no effect. The old paths are still used as a
  fallback for installs that have not migrated yet.
- **A `.jsonc` config is editable.** It used to be refused outright, because `jq`
  cannot read comments — which made the file above uneditable by definition. Edits
  are now a splice into the text, so comments, indentation and blank lines survive.
- **`scout` is gone.** It was listed as an opencode built-in, appeared as a row, and
  `Every agent on …` wrote it into `opencode.json`. No opencode release ships it.
- **opencode `agent` entries are written as objects.** Pinning a model on an agent
  that had none produced `"plan": "provider/model"`, which opencode's schema rejects;
  setting and then clearing an effort demoted a valid entry to the same broken shape.
  A preflight check now refuses the string form outright.
- **Reasoning effort works on opencode agent rows.** opencode's `AgentConfig` carries
  a `variant`; the control was disabled on the belief that it does not.
- **Undo restores the oh-my-openagent half.** The path allowlist a restore is bounded
  by did not include `~/.omo`, so an undo skipped that file and still reported success.
- **Undo is all-or-nothing.** It checked each file as it wrote it, so a refusal on the
  second left the first already rolled back, under an exit code promising nothing was
  written. It now gates every file first and reports a partial write as one.
- **A missing oh-my-openagent config no longer blocks a switch.** The half that has a
  file is applied and the other is reported as skipped, instead of the whole profile
  refusing.
- **A saved profile can restore a key being absent.** It captured only the keys that
  were set, so coming back to it left behind whatever the profile you were on added.
- **A config holding only providers and MCP servers can be saved as a profile.** It
  used to be refused as empty — the most common shape on the plain-opencode side.
- **The project-shadow warning finds real shadows.** It probed
  `./.opencode/oh-my-openagent.json`, which is not a path either tool reads; it now
  walks up from the working directory for `.omo/` and `.opencode/`.
- **The oh-my-openagent version probe reads the right path**, so the version is
  reported instead of coming back empty.

### Changed

- **Which shape you are running is decided by the software, not by a leftover file.**
  oh-my-openagent counts as in use when it is in your `opencode.json` `plugin` list or
  its package is installed. A config file left behind by an uninstall is reported as
  stale rather than obeyed. `manageOhMyOpenAgent: false` still forces the plain view.
- **Under oh-my-openagent, opencode's own agent rows are no longer drawn.**
  oh-my-openagent supplies its own `build` and `plan` and they win, so two rows for one
  decision is a trap. `model` and `small_model` remain, in an **opencode base** section,
  because oh-my-openagent falls back to them.
- **Agent and category names come from the installed software** — opencode's generated
  config schema and oh-my-openagent's shipped JSON Schema — cached per version. The
  lists in `lib/Model.js` are now only a fallback for a machine neither probe can read.
- **A template applied under oh-my-openagent carries only the base model across** from
  its opencode half, rather than its `agent` block.

### Added

- `bin/jsonc-edit` — the comment-preserving reader and writer the above depends on.
  No new dependency: `python3` was already required.
- `test/` — 67 checks over the row model, the JSONC editor, shape detection and the
  write path. `test/run.sh` runs them all and fails if any of them touched your real
  config.

### Upgrading

If you run oh-my-openagent, your profiles now apply to `~/.omo/omo.jsonc`. Profiles
captured before this release hold whatever was in the old file; re-save them from your
running config if that is not what you want. `~/.config/opencode/oh-my-openagent.json`
can be deleted once the panel reports no stale config.

## 1.0.1

Documentation and screenshots.

## 1.0.0

First release.
