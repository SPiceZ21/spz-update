Config = Config or {}

-- ── Where "latest" comes from ────────────────────────────────────────────────
--
--   "github"   (default) Each resource's OWN repository is asked: the version
--              line in fxmanifest.lua on its default branch. Every spz repo's
--              release workflow bumps that line automatically on push, so
--              publishing a module IS the update notice — there is no second
--              file to keep in step, and nothing to forget.
--
--   "manifest" A single hand-maintained JSON file at Config.ManifestUrl, listing
--              every module's version. Only for servers that pin their own
--              channel. Nothing in this repo maintains one any more: the
--              versions.json that used to live here was synced by hand, went
--              stale the first time anyone forgot, and was never read by the
--              default mode anyway.
Config.Source = "github"

-- Only used when Source is "manifest". A RAW file, not a rendered page — a
-- GitHub blob URL returns HTML and will be rejected as malformed.
Config.ManifestUrl = ""

-- Release channel to read out of the manifest. A manifest may publish several;
-- a channel that is absent falls back to "stable" and says so.
Config.Channel = "stable"

-- ── When to check ────────────────────────────────────────────────────────────
Config.CheckOnStart   = true    -- once, after spz-core signals ready
Config.IntervalHours  = 6       -- 0 disables the repeat check
Config.StartDelayMs   = 15000   -- let the other resources finish starting first,
                                -- so the first report covers the whole set

-- HTTP timeout is not configurable in FiveM's PerformHttpRequest, so a check
-- that never calls back would hang the "in flight" flag forever and block every
-- later check. This is the guard for that.
Config.RequestTimeoutMs = 20000

-- Minimum gap between manual /spzupdate runs, so the command cannot be used to
-- hammer whatever is hosting the manifest.
Config.ManualCooldownMs = 30000

-- ── Who hears about it ───────────────────────────────────────────────────────
Config.NotifyAdminsOnJoin = true   -- tell an admin, once, if updates are pending
Config.AdminAce           = "spz.admin"

-- ── What counts as ours ──────────────────────────────────────────────────────
-- Resources matched by this Lua pattern are the ones scanned and version
-- checked. Third-party dependencies (ox_lib, oxmysql, fivem-appearance) are
-- deliberately outside it: this resource reports on the SPiceZ set, and a
-- dependency's version is that project's business.
Config.ResourcePattern = "^spz%-"

-- Resources to leave out of the report entirely — asset-only packs with no
-- meaningful version, local forks you do not want flagged as out of date.
Config.Ignore = {
  -- ["spz-carfx"] = true,
}
