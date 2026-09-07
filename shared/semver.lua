SPZ = SPZ or {}
SPZ.Semver = SPZ.Semver or {}

-- Version comparison, deliberately lenient about what it accepts.
--
-- These strings come out of hand-edited fxmanifests, so they are not reliably
-- semver: "2.0.0", "v1.9.0", "1.1.2-beta", "1.0" and "" all appear in practice.
-- Parsing returns nil for anything it cannot read rather than guessing, and
-- every caller treats nil as "cannot compare" instead of "older" — a version
-- this cannot parse must never be reported as an available update.
--
--- @param v string
--- @return number|nil major, number|nil minor, number|nil patch, string|nil pre
function SPZ.Semver.Parse(v)
    if type(v) ~= "string" then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[vV]", "")
    if v == "" then return nil end

    local major, minor, patch = v:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
        -- "1.1" and "1" are common enough in the wild to be worth reading; the
        -- missing places are zero, which is what semver says they mean.
        major, minor = v:match("^(%d+)%.(%d+)")
        if major then
            patch = "0"
        else
            major = v:match("^(%d+)$")
            if not major then return nil end
            minor, patch = "0", "0"
        end
    end

    -- Anything after the numbers: "-beta.1", "+build7". Kept because a
    -- pre-release sorts BELOW the release it leads to.
    local pre = v:match("^%d+%.?%d*%.?%d*%-([%w%.%-]+)")

    return tonumber(major), tonumber(minor), tonumber(patch), pre
end

--- Compare two version strings.
--- Returns -1 if a < b, 0 if equal, 1 if a > b, or nil if either is unparseable.
--- @return number|nil
function SPZ.Semver.Compare(a, b)
    local aMaj, aMin, aPat, aPre = SPZ.Semver.Parse(a)
    local bMaj, bMin, bPat, bPre = SPZ.Semver.Parse(b)
    if not aMaj or not bMaj then return nil end

    if aMaj ~= bMaj then return aMaj < bMaj and -1 or 1 end
    if aMin ~= bMin then return aMin < bMin and -1 or 1 end
    if aPat ~= bPat then return aPat < bPat and -1 or 1 end

    -- Same numbers: a pre-release is BEHIND the plain release ("1.2.0-rc1" is
    -- older than "1.2.0"), and two different pre-releases of the same version
    -- are not ranked here — they compare equal rather than being guessed at.
    if aPre and not bPre then return -1 end
    if bPre and not aPre then return 1 end
    return 0
end

--- True when `latest` is strictly newer than `current`.
--- Unparseable input is NOT an update — see the note in Parse.
--- @return boolean
function SPZ.Semver.IsNewer(latest, current)
    return SPZ.Semver.Compare(latest, current) == 1
end
