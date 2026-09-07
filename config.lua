Config = Config or {}

-- ── Where the latest versions are published ──────────────────────────────────
--
-- A URL returning the JSON manifest documented in README.md. Empty means the
-- remote half is OFF: the local version report still works in full, and the
-- checker says once, on boot, that it has nowhere to check against rather than
-- failing quietly every hour.
--
-- Point this at a RAW file, not a rendered page — a GitHub blob URL returns
-- HTML and will be rejected as malformed.
Config.ManifestUrl = "https://raw.githubusercontent.com/SPiceZ21/spz-update/main/versions.json"

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
