# spz-update

Version report and update checker for the SPiceZ module set.

Two halves, and the first one works with no network and no configuration:

- **Version checker** — what this server is running right now, read straight from each
  resource's `fxmanifest.lua`. `/spzversion`.
- **Update checker** — compares that against what each module's GitHub repository has
  published, and reports what is behind. `/spzupdate`.

## It checks, it does not install

This resource never downloads a file and never writes to disk. That is a deliberate limit.

Overwriting a running resource's files hot-restarts it underneath whatever it was doing — a
race in `COUNTDOWN`, a profile mid-save — with no rollback, from a server that has just
replaced its own code. Applying an update is a decision for a human at a console during a
restart window. Telling that human there is one is what this does.

## Setup

Add `ensure spz-update` to `server.cfg`, after `spz-core`. That is all — the default source
needs no configuration.

## Where "latest" comes from

**`Config.Source = "github"` (default).** Each module's own repository is asked for the
`version` line in its `fxmanifest.lua` on the default branch. Every spz repo's release
workflow bumps that line automatically from its commit messages on push, so publishing a
module *is* the update notice. There is no second file to keep in step with the modules.

It reads `raw.githubusercontent.com`, which is a CDN rather than the API, so a check across
the whole set does not spend the 60-requests-per-hour unauthenticated API budget.

Together with spz-deploy this is the whole loop: **`/spzupdate` tells you an update is
published, `spzdeploy apply` takes it live.** spz-update still never installs anything itself.

## The manifest source (optional)

**`Config.Source = "manifest"`** reads one hand-maintained JSON file at `Config.ManifestUrl`
instead — only worth it for a server that wants to pin its own channel. Nothing in this repo
maintains one any more: the `versions.json` that used to live here was synced by hand, went
stale the first time anyone forgot, and was never read by the default source anyway.

See `versions.example.json`. Either shape is accepted:

```json
{ "resources": { "spz-core": { "version": "2.0.0" } } }
```

```json
{ "channels": { "stable": { "spz-core": { "version": "2.0.0" } } } }
```

An entry may be a bare string (`"spz-core": "2.0.0"`) or an object with optional `url` and
`notes`. Versions must match the `version` field in each resource's `fxmanifest.lua` — that
is the side being compared.

A channel named in config but absent from the manifest falls back to `stable` **and warns**.
It is not silently treated as empty, because an empty channel looks exactly like "you are
fully up to date".

## Commands

| Command | Does |
|---|---|
| `/spzversion` | Local version report, from the fxmanifests |
| `/spzupdate` | The last completed check |
| `/spzupdate now` | Force a fresh check (rate limited) |

Both are gated on `spz.admin` through `spz-core`'s `HasPermission`, so the console is exempt.

## Exports

```lua
exports['spz-update']:GetLocalVersions()   -- [name] = { version, state, exported, drift }
exports['spz-update']:ScanLocal()          -- same, as a sorted list
exports['spz-update']:GetReport()          -- last remote check
exports['spz-update']:UpdatesReady()       -- count of pending updates
exports['spz-update']:CheckNow(cb)         -- force a check
```

## What it reports beyond "out of date"

- **No version in fxmanifest** — cannot be update checked at all.
- **Ahead of channel** — installed version is *newer* than published. Normal on a dev box;
  off a dev box it means someone installed off-channel. Never folded into "up to date".
- **Not in the manifest** — installed here, absent upstream. Listed, not flagged.
- **Version drift** — a resource that publishes its version in both `fxmanifest.lua` and a
  `GetVersion` export, where the two disagree. `spz-core` does this today: its manifest says
  `2.0.0`, `shared/version.lua` says `1.0.0`. The fxmanifest is what this resource uses.

An unparseable version is never reported as an update. `Compare` returns nil for anything it
cannot read, and every caller treats nil as "cannot compare" rather than "older" — guessing
here would mean telling an operator to update something that is already current.
