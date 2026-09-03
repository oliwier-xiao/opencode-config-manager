# Changelog

## 1.1.3

New models (e.g. `muse-spark-1.3`) stayed invisible for days despite `opencode models`
listing them, until the cache was deleted by hand.

### Fixed

- **Opening the panel refreshes a stale model cache.** The cache was only rebuilt on
  a timer that never fired on a shell restarted more often than `catalogRefreshHours`,
  so it sat stale until someone pressed `r`. A panel open — and a shell start — now
  trigger a background sync, and the sync itself decides whether anything is due: a
  fresh cache answers `cached` without touching the network or `opencode models`, so
  the common case costs nothing and the list still paints instantly.
- **Reachability has its own short TTL.** `opencode models` is local and takes seconds,
  so what you can reach is re-checked every 15 minutes, while the multi-MB models.dev
  catalogue keeps the long `catalogRefreshHours` TTL. Connecting a provider — or a new
  model dropping — shows up within minutes, without re-downloading the catalogue. The
  two clocks are read off two different files, so the short cycle cannot postpone the
  long one: measured against the file it rewrites, the catalogue would have been
  downloaded once and then never again.
- **A refresh asked for during a background sync is no longer dropped.** `r`,
  middle-click and `refresh` over IPC set a flag on a process whose environment was
  already fixed at spawn, so the forced run never happened — and syncing on every
  panel open is what made that the usual case. The request is now held and run as
  soon as the one in flight finishes.
- **A model the catalogue rules out stays out.** `opencode models` lists models
  models.dev marks as unable to call tools; those were being added back as ordinary,
  selectable rows, which is a model that loads and then fails on an agent's first
  tool call. Only ids models.dev has genuinely never heard of are kept now.
- **Changing the model on an opencode agent keeps an effort it supports.** Efforts
  were only stepped down for oh-my-openagent rows. opencode's own `AgentConfig`
  carries one too, so an opencode agent kept the old model's effort on a new model
  that offered none — the one config this plugin could write that loads and then fails.
- **A broken `opencode` costs one probe, not one per panel open.** A failed or
  timed-out `opencode models` left the reachability clock untouched, so the next
  panel open tried again, and the next. The attempt is now recorded whether or not
  it worked, and a non-zero exit no longer throws away a list opencode did print —
  it returns non-zero when any single provider is missing credentials.
- **`categories.<name>.models` is accepted.** It is a real field on
  oh-my-openagent's category schema; only the agent schema lacks it. The refusal
  applied to both, with a reason that was only ever true of agents.
- **The refresh timer works at every setting.** At `catalogRefreshHours` above 596
  the interval overflowed a 32-bit int, so the timer never fired and restarted
  itself hundreds of times a second. The settings slider goes to 720.
- **The model list is built from the config folder you pointed the plugin at.**
  The sync was the one process not told `OPENCODE_CONFIG_DIR`.
- **`dev-sync.sh` removes what it excludes.** `--delete` leaves already-deployed
  copies of an excluded name in place; a `.codegraph` symlink from an earlier run
  stayed in the plugin folder and kept failing `omarchy plugin validate`.

## 1.1.2

A config this plugin wrote could be refused by the software it was written for.

### Fixed

- **oh-my-openagent entries are always written as objects.** `doctor` since 4.19
  validates `agents.*` and `categories.*` under `[opencode]` with
  `AgentOverrideConfigSchema`, which has no string branch. This plugin kept the
  short string form (`"sisyphus": "provider/model"`) for any entry that carried
  only a model, so a profile that pinned three agents with no effort wrote three
  bare strings. `doctor` then refused each with `Invalid input: expected object,
  received string` and `Affects: plugin startup`, and openCode showed
  `config invalid — run doctor` in the bar. The short form is now kept only for
  `opencode.json` `model`/`small_model`; every oh-my-openagent row is written as
  `{ model }`, and clearing an effort leaves `{ model }` rather than collapsing
  back to a string.

## 1.1.1

oh-my-openagent 4.19 renamed the field an effort is written into, and its own migration
now writes a shape its own schema has no field for. Both of those reached the panel: one
as an effort that read back blank, the other as a config that can be written but not
started.

### Fixed

- **`reasoning` is read and written.** 4.19 renamed `variant` to `reasoning`, and keeps
  `reasoning` when an entry carries both. This plugin read only `variant`, so an entry
  oh-my-openagent had migrated for itself showed no effort at all — and lost the one it
  had on the next write. Either spelling is now read, and an entry is written back in
  the spelling it already uses.
- **`reasoning` and `displayName` are no longer refused.** Both are real fields on an
  agent entry. The check that rejected them was written against the belief that an
  unknown key makes oh-my-openagent drop the whole entry; the entry is a plain object,
  an unknown key is stripped rather than rejected, and neither of these is unknown.
- **`models` is still refused, now for the reason that is actually true.**
  oh-my-openagent's own 4.19 migration rewrites `model` + `fallback_models` into a
  `models` array, but the schema behind the `[opencode]` block has no `models` field, so
  every agent that migration touches loses its pin: `doctor` reports
  `Unknown config key: agents.<name>.models` against `Affects: plugin startup`. A
  profile must not write the same shape.
- **A profile no longer owns a file-level `fallback_models` inside `[opencode]`.** That
  key belongs to the legacy `oh-my-openagent.json`; the unified config has no such
  field, and writing it there costs the plugin its startup the same way. It stays owned
  on the legacy path, which installs that have not migrated still read. Per-agent and
  per-category `fallback_models` are untouched — they remain legal in both.

### Compatibility

No version floor, and nothing to upgrade. `variant` is still a field in 4.19, so a config
this plugin writes is read by every 3.x and 4.x alike, and there is no version check
anywhere in this change.

Which spelling a *new* entry gets is decided by the file, not by a version number:
oh-my-openagent migrates a whole config in one pass, so a single entry already carrying
`reasoning` is proof the install that wrote it uses the new name, and the rest of the
file follows suit. A file that has never seen `reasoning` keeps getting `variant`. That
holds on both sides of the rename — including the release where `variant` finally goes
away, since by then the config will have been migrated and the file will say so itself.

### Changed

- The detection suite no longer pins oh-my-openagent's version. It reads a roster off
  whatever package is installed, so a literal `4.19.3` in an assertion turned every
  oh-my-openagent release into a failing test run. Counts taken from that package are
  floors now, not exact numbers.

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
- **A config that matches a saved profile is no longer reported as matching none.**
  The panel decided what was running from `state.activeProfileId` alone — the id of
  the last profile *switched to*. An undo to a backup taken before any profile was
  active leaves that null, and the heading then read `Custom · no profile matches
  what is on disk` over a config that matched a saved profile exactly, in the same
  answer that listed it under `matches`. `list` now returns `effectiveProfileId`,
  and derives `drift` from it.
- **Undo records the profile it landed on.** When the backup names none to go back
  to, the restored config is compared against the saved profiles and the one it
  matches is marked active, instead of leaving the store saying nothing is.

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
- **The panel says what it is doing before it knows what is running.** `list` answers
  in about a tenth of the time `detect` takes, so the first paint used to state — as
  fact — that nothing matched, and drew the rows against the wrong shape. The heading
  and the drift strip now wait for both reads, and a shape that arrives late forces
  the rows to be drawn again: `lib/Model.js` is a `.pragma library`, so what it holds
  is a global no QML binding can depend on.

### Hardened

The marketplace reviewer's standing objection, in his words on
[#2774](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2774):
"Open the file once with `O_NOFOLLOW` and `O_NONBLOCK`, validate that descriptor as
a user-owned regular file, and read the capped bytes through it." Every read here now
does exactly that, through one place — `bin/safe-read`.

- **Nothing is checked by name and then opened by name.** The previous `safe_open`
  and `bin/read-catalog` both did `exec 3< "$path"`, which blocks inside `open(2)` on
  a FIFO planted at the path — before any check can run, with only the outer timeout
  to end it. A FIFO now returns in milliseconds and is refused.
- **Every read is bounded and validated on the descriptor**: a regular file, owned by
  this user, within a byte ceiling. That covers the profile store, the model cache,
  the roster cache, `auth.json`, `~/.opencode/opencode.json`, both config files, the
  oh-my-openagent bundle, and every backup payload — previously most of these were
  handed to `jq` or `python` by name with no ceiling at all.
- **The profile store is never written through a symlink.** `atomic_write` follows a
  link by design, which is right for a dotfiles-managed config and wrong for a file
  this plugin owns at a predictable path; writing there could be redirected into any
  file the user can write. It now refuses.
- **The lock fails closed.** `take_lock` returned success when the state directory
  could not be opened, running the whole switch with no lock at all.
- **A killed switch is put back.** The timebox can end the process mid-apply, where
  the in-process rollback cannot run. The same restore is now armed on `SIGTERM`,
  `SIGINT` and `SIGHUP`, so a two-file switch is never left half-applied.
- **A killed run no longer leaves config in `/tmp`.** `cmd_detect` writes whole
  projected documents — provider keys and MCP bearer tokens included — to temporary
  files so they never reach `argv`. They are now registered and removed on the way
  out, signals included, and live under the plugin's own cache rather than `/tmp`.
- **Undo refuses a backup it cannot restore from.** An empty manifest or a missing
  copy used to report `ok:true` with `restored: []` and still move the active
  profile. Both now refuse and leave the state alone.
- **A run stopped by the timebox is visible.** Exit 124, 137 and 143 arrive with
  nothing on stdout; the panel used to clear itself and quietly redraw the state
  from before the switch, which looks exactly like having done it.
- **The rollback paths go through `atomic_write`.** They used `cp`, which truncates
  and then streams — a signal landing inside one left a half-written config, on the
  path taken when things have already gone wrong.
- **The profile store is written compact.** `jq`'s pretty-printer tripled it, so the
  reader's 2 MB ceiling was really about 700 KB of profile data.
- **A failed roster probe is not memoised.** One transient failure of
  `opencode generate` used to pin the panel to an empty agent list until a version
  bump; the probe also has its own timeout now, instead of spending the whole
  30-second budget.
- **`seed` keeps the JSON contract** it shares with every other command.
- `test/hardening.test.sh` holds each of the above as a test, including a killed
  two-file switch and a canary provider key that must not survive in a temp file.

Then a second pass, against the rest of the standard the same reviewer applies across
the marketplace — the classes he blocks on most often, in descending order of how
often they appear in his review comments:

- **Every writable text sink is `Text.PlainText`.** It is his single most frequent
  one-line blocker. Every `Text` in this plugin now sets it, and the shell's own
  components — `PanelHero` and friends, whose internals are not ours to set it on —
  are handed strings through `Model.plain()`, which takes the markup and the control
  characters out. A profile name comes from a file on disk somebody else can write.
- **Byte ceilings sit at the end the bytes come out of**, not after a `StdioCollector`
  has already materialised the whole thing inside the shell. `oc-profiles backups`
  was unbounded and read each manifest by name; the model sync bounded neither
  `opencode models` nor the download.
- **The network path.** No redirects to follow (`--proto '=https'`, no `-L`), a
  `--max-filesize` ceiling, and the downloaded file validated on a descriptor before
  it is parsed — because `--max-filesize` is not a hard bound when a response has no
  usable declared length. `--compressed` is gone: a bounded download that expands
  without bound is not bounded.
- **Writes go through `bin/safe-write`**: an `O_EXCL`, `O_NOFOLLOW`, mode 0600
  temporary in the destination's own directory, `fsync`, `rename`, and an `fsync` of
  the directory so the rename is durable too. A destination that is not a regular
  file this user owns is refused. The staging names are unpredictable — `.new` and
  `.tmp` beside the real file are neither.
- **Settings are range-checked at both ends.** `catalogRefreshHours` reached a Timer
  as `NaN` if `shell.json` held something that was not a number.
- **A missing helper says which one.** Without this, every command refused with a
  story about the profile store.

- **The pid that gets signalled is pinned to the process that was checked.**
  `SIGUSR2` terminates a process that does not handle it, and pids get reused, so
  the start tick, the command name and the handler are all rechecked in the
  instruction before the `kill` rather than once at the top of a loop.
- **No runtime value reaches interpreter source.** The signal-mask check spliced a
  value read at runtime into a `python3 -c` string; it is bash arithmetic now.
- **The IPC surface is documented rather than undeclared.** None of its methods
  writes a config or switches a profile; `reload` is the only one that reaches
  another process, and it now goes through the identity check above.

One of these was a bug in the pass above it: `mktemp_tracked` and `stage` are called
inside `$( )`, so their appends to the cleanup array happened in a subshell and never
reached the trap. Cleanup is by filename prefix now, and the test that covers it
builds a copy that really does stall and really does get killed.

### Added

- `bin/jsonc-edit` — the comment-preserving reader and writer the above depends on.
  No new dependency: `python3` was already required.
- `bin/safe-read` and `bin/safe-write` — the one place a file is opened, judged and
  read, and the one place one is replaced. Everything else goes through them.
- `test/` — 118 checks over the reader and writer, the hardening above, the row
  model, the JSONC editor, shape detection and the write path. `test/run.sh` runs them all and fails
  if any of them touched your real config.

### Upgrading

If you run oh-my-openagent, your profiles now apply to `~/.omo/omo.jsonc`. Profiles
captured before this release hold whatever was in the old file; re-save them from your
running config if that is not what you want. `~/.config/opencode/oh-my-openagent.json`
can be deleted once the panel reports no stale config.

## 1.0.1

Documentation and screenshots.

## 1.0.0

First release.
