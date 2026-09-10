-- server/checker.lua
-- The REMOTE half: what is published, versus what is installed.
--
-- This CHECKS and REPORTS. It does not download anything and it does not touch
-- a file on disk, and that is a deliberate limit rather than an unfinished
-- feature. Overwriting a running resource's files mid-session hot-restarts it
-- underneath whatever it was doing -- a race in COUNTDOWN, a profile mid-save --
-- with no rollback and no way to undo it from a server that has just replaced
-- its own code. Applying an update is a decision for a human at a console
-- during a restart window. Telling that human there IS one is what this does.

SPZUpdate = SPZUpdate or {}

local Report = {
    checkedAt  = nil,     -- os.time() of the last COMPLETED check
    ok         = false,   -- did the last check complete
    error      = nil,     -- why not
    channel    = nil,
    updates    = {},      -- { { name, current, latest, url, notes }, ... }
    unknown    = {},      -- installed here, absent from the manifest
    ahead      = {},      -- installed version is NEWER than published
}

local inFlight    = false
local lastManual  = 0
local warnedNoUrl = false

local function say(msg, ...)
    print(("^5[spz-update]^7 " .. msg):format(...))
end

local function warn(msg, ...)
    print(("^3[spz-update]^7 " .. msg):format(...))
end

--- @return table  a copy, so a caller cannot mutate the live report
function SPZUpdate.GetReport()
    return {
        checkedAt = Report.checkedAt,
        ok        = Report.ok,
        error     = Report.error,
        channel   = Report.channel,
        updates   = Report.updates,
        unknown   = Report.unknown,
        failed    = Report.failed,
        ahead     = Report.ahead,
    }
end

--- Turn a decoded manifest into the resource->version table for our channel.
---
--- Two shapes are accepted, because a one-channel manifest should not have to
--- pretend to have channels:
---   { "resources": { "spz-core": {...} } }              -- single channel
---   { "channels": { "stable": { "spz-core": {...} } } } -- multi channel
---
--- @return table|nil resources, string|nil channelName, string|nil err
local function selectChannel(data)
    if type(data) ~= "table" then return nil, nil, "manifest is not a JSON object" end

    if type(data.channels) == "table" then
        local want = Config.Channel or "stable"
        local set  = data.channels[want]

        if type(set) ~= "table" then
            -- A typo'd channel silently checking against nothing is the worst
            -- outcome here: it looks exactly like "you are fully up to date".
            set = data.channels.stable
            if type(set) ~= "table" then
                return nil, nil, ("channel '%s' not in manifest, and no 'stable' to fall back to"):format(want)
            end
            warn("channel '%s' is not in the manifest - falling back to 'stable'.", want)
            want = "stable"
        end

        return set, want, nil
    end

    if type(data.resources) == "table" then
        return data.resources, data.channel or "default", nil
    end

    return nil, nil, "manifest has neither 'resources' nor 'channels'"
end

--- Normalise one manifest entry. A bare string is allowed as shorthand for
--- { version = "..." }, since most entries carry nothing else.
local function entryVersion(v)
    if type(v) == "string" then return v, nil, nil end
    if type(v) == "table"  then return v.version, v.url, v.notes end
    return nil, nil, nil
end

--- @param failed table|nil  set of names whose lookup FAILED this run.
---
--- A failed lookup and an absent entry both leave `published[name]` nil, and
--- the report used to print them identically: "not in the manifest, so not
--- checked". That is false for a failure — the module IS published, the request
--- just did not complete — and it sends you looking for a missing repo that
--- exists. They are separate lists now.
local function compare(published, channelName, failed)
    local locals  = SPZUpdate.LocalMap()
    local updates, unknown, ahead, failedList = {}, {}, {}, {}
    failed = failed or {}

    for name, entry in pairs(locals) do
        local pubRaw = published[name]

        if pubRaw == nil and failed[name] then
            failedList[#failedList + 1] = name
        elseif pubRaw == nil then
            unknown[#unknown + 1] = name
        elseif entry.version then
            local latest, url, notes = entryVersion(pubRaw)
            local cmp = latest and SPZ.Semver.Compare(latest, entry.version) or nil

            if cmp == 1 then
                updates[#updates + 1] = {
                    name    = name,
                    current = entry.version,
                    latest  = latest,
                    url     = url,
                    notes   = notes,
                }
            elseif cmp == -1 then
                -- Running ahead of the channel is normal on a dev box and is
                -- reported as its own thing, never as "up to date" -- if it is
                -- NOT a dev box, it means someone installed off-channel.
                ahead[#ahead + 1] = { name = name, current = entry.version, latest = latest }
            elseif cmp == nil then
                warn("cannot compare %s: installed '%s' vs published '%s'.",
                    name, tostring(entry.version), tostring(latest))
            end
        end
    end

    table.sort(updates, function(a, b) return a.name < b.name end)
    table.sort(unknown)
    table.sort(ahead, function(a, b) return a.name < b.name end)

    Report.checkedAt = os.time()
    Report.ok        = true
    Report.error     = nil
    Report.channel   = channelName
    Report.updates   = updates
    Report.unknown   = unknown
    table.sort(failedList)
    Report.failed    = failedList
    Report.ahead     = ahead

    return Report
end

function SPZUpdate.PrintRemoteReport(printer)
    local out = printer or print

    if not Report.checkedAt then
        out("^3[spz-update]^7 no completed check yet.")
        if Report.error then out(("^1  last attempt failed: %s^7"):format(Report.error)) end
        return
    end

    if #Report.updates == 0 then
        out(("^2[spz-update]^7 up to date on channel '%s'."):format(tostring(Report.channel)))
    else
        out(("^3[spz-update]^7 %d update%s available on channel '%s':"):format(
            #Report.updates, #Report.updates == 1 and "" or "s", tostring(Report.channel)))
        for _, u in ipairs(Report.updates) do
            out(("  ^3%-22s v%s ^7-> ^2v%s^7%s"):format(
                u.name, u.current, u.latest, u.notes and ("  - " .. u.notes) or ""))
            if u.url then out(("      %s"):format(u.url)) end
        end
    end

    if #Report.ahead > 0 then
        local names = {}
        for _, a in ipairs(Report.ahead) do
            names[#names + 1] = ("%s (v%s > published v%s)"):format(a.name, a.current, a.latest)
        end
        out(("^5  ahead of channel:^7 %s"):format(table.concat(names, ", ")))
    end

    if Report.failed and #Report.failed > 0 then
        out(("^3  lookup failed, not checked this run:^7 %s"):format(table.concat(Report.failed, ", ")))
    end

    if #Report.unknown > 0 then
        out(("^5  not in the manifest, so not checked:^7 %s"):format(table.concat(Report.unknown, ", ")))
    end
end

-- Source: github ------------------------------------------------------------
--
-- Asks each module's own repository what it publishes, so there is no manifest
-- file to keep in step with the resources it describes.
local function checkViaGitHub(finish)
    local names = {}
    for _, e in ipairs(SPZUpdate.ScanLocal()) do
        if not (Config.SkipRepos or {})[e.name] then
            names[#names + 1] = e.name
        end
    end

    SPZUpdate.FetchGitHub(names, function(published, stats)
        -- A run where NOTHING resolved is a failure, not "up to date". The two
        -- look identical in the report and only one of them is safe to believe:
        -- DNS down, no outbound HTTP, a wrong owner name in config all produce
        -- an empty result set, and reporting that as green is the worst thing
        -- this resource could do.
        if stats.ok == 0 and #names > 0 then
            return finish(false, ("could not read any repository (%s)")
                :format(stats.errors[1] or "no responses"))
        end

        if stats.failed > 0 then
            warn("%d of %d lookups failed; those modules are reported as unchecked.",
                stats.failed, #names)
            for _, e in ipairs(stats.errors) do warn("  %s", e) end
        end

        compare(published, ("github:%s/%s"):format(
            Config.GitHubOwner or "SPiceZ21", Config.GitHubBranch or "main"),
            stats.failedNames)
        finish(true)
        SPZUpdate.PrintRemoteReport()
    end)
end

--- Run a check.
--- @param onDone function|nil called with (ok, report) when it finishes
function SPZUpdate.Check(onDone)
    local source = Config.Source or "github"

    if source == "github" then
        if inFlight then
            warn("a check is already running.")
            if onDone then onDone(false, Report) end
            return
        end

        inFlight = true
        local settled = false

        local function finish(ok, err)
            if settled then return end
            settled  = true
            inFlight = false
            if not ok then
                Report.ok    = false
                Report.error = err
                warn("check failed: %s", err)
            end
            if onDone then onDone(ok, Report) end
        end

        return checkViaGitHub(finish)
    end

    local url = Config.ManifestUrl

    if not url or url == "" then
        -- Said once, not every interval. An hourly complaint about a setting
        -- the operator has deliberately left empty is noise, and noise in a
        -- server console is how real warnings get missed.
        if not warnedNoUrl then
            warnedNoUrl = true
            warn("Config.ManifestUrl is empty - remote update checking is off. "
              .. "The local version report (/spzversion) still works.")
        end
        Report.error = "no manifest url configured"
        if onDone then onDone(false, Report) end
        return
    end

    if inFlight then
        warn("a check is already running.")
        if onDone then onDone(false, Report) end
        return
    end

    inFlight = true
    local settled = false

    local function finish(ok, err)
        if settled then return end   -- a late callback after the timeout fired
        settled  = true
        inFlight = false
        if not ok then
            Report.ok    = false
            Report.error = err
            warn("check failed: %s", err)
        end
        if onDone then onDone(ok, Report) end
    end

    -- PerformHttpRequest has no timeout of its own, and a callback that never
    -- arrives would leave inFlight set for the rest of the server's uptime and
    -- block every check after it. This is what releases it.
    SetTimeout(Config.RequestTimeoutMs or 20000, function()
        if not settled then finish(false, "request timed out") end
    end)

    PerformHttpRequest(url, function(status, body, _headers)
        if status ~= 200 then
            return finish(false, ("HTTP %s from %s"):format(tostring(status), url))
        end
        if type(body) ~= "string" or body == "" then
            return finish(false, "empty response")
        end

        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= "table" then
            -- Overwhelmingly this is a rendered HTML page rather than the raw
            -- JSON file, so it is worth naming the likely cause.
            return finish(false, "response was not JSON (is the URL a RAW file, not a web page?)")
        end

        local published, channelName, err = selectChannel(data)
        if not published then
            return finish(false, err or "unusable manifest")
        end

        compare(published, channelName)
        finish(true)
        SPZUpdate.PrintRemoteReport()
    end, "GET", "", { ["User-Agent"] = "spz-update" })
end

exports("CheckNow",     function(cb) return SPZUpdate.Check(cb) end)
exports("GetReport",    SPZUpdate.GetReport)
exports("UpdatesReady", function() return #Report.updates end)

--- Manual runs are rate limited so the command cannot hammer the host.
--- @return boolean started, string|nil why not
function SPZUpdate.ManualCheck(onDone)
    local now  = GetGameTimer()
    local gap  = Config.ManualCooldownMs or 30000
    if lastManual > 0 and (now - lastManual) < gap then
        return false, ("wait %ds"):format(math.ceil((gap - (now - lastManual)) / 1000))
    end
    lastManual = now
    SPZUpdate.Check(onDone)
    return true, nil
end

-- Scheduling -----------------------------------------------------------------
--
-- The first check waits for spz-core AND for StartDelayMs on top, because the
-- report is only as complete as the resource list it scans: a check that fires
-- while half the modules are still starting reports them as absent.
CreateThread(function()
    if not Config.CheckOnStart then return end

    local waited = 0
    while waited < 30000 do
        local ok, ready = pcall(function() return exports["spz-core"]:IsCoreReady() end)
        if ok and ready then break end
        Wait(500)
        waited = waited + 500
    end

    Wait(Config.StartDelayMs or 15000)

    SPZUpdate.PrintLocalReport()
    SPZUpdate.Check()

    local hours = Config.IntervalHours or 0
    if hours > 0 then
        while true do
            Wait(math.floor(hours * 3600 * 1000))
            SPZUpdate.Check()
        end
    end
end)

-- Admin notice on join -------------------------------------------------------
AddEventHandler(SPZ.Events.PLAYER_CONNECTED, function(src)
    if not Config.NotifyAdminsOnJoin then return end
    if #Report.updates == 0 then return end
    src = tonumber(src)
    if not src then return end

    CreateThread(function()
        Wait(20000)   -- let them finish loading in before anything is pushed at them
        if not GetPlayerName(src) then return end

        local ok, allowed = pcall(function()
            return exports["spz-core"]:HasPermission(src, Config.AdminAce or "spz.admin")
        end)
        if not ok or not allowed then return end

        TriggerClientEvent("chat:addMessage", src, {
            color = { 255, 190, 60 },
            multiline = true,
            args = { "spz-update", ("%d SPiceZ module%s have updates available. Run /spzupdate for the list.")
                :format(#Report.updates, #Report.updates == 1 and "" or "s") },
        })
    end)
end)
