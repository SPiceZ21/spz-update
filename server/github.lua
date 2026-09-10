-- server/github.lua
-- GitHub as the source of truth: no published manifest file to maintain.
--
-- Every spz-* module has its own repository named after the resource, so the
-- "what is published" side can be read straight from those repos. Releasing a
-- module IS the update notice; there is no second file to remember to bump, and
-- therefore no way for it to drift from what was actually shipped.
--
-- Two things it can read, and the default is the less obvious one:
--
--   "manifest"  the version line in fxmanifest.lua on the default branch,
--               fetched from raw.githubusercontent.com. This is the DEFAULT,
--               for two reasons. It is the exact value spz-update compares
--               against locally, so both sides of the comparison mean the same
--               thing; and raw.githubusercontent.com is a CDN, not the API, so
--               it does not spend the 60-requests-per-hour unauthenticated
--               budget that would otherwise be gone after two checks.
--
--   "release"   the latest release tag via the REST API. Truer to "published"
--               if you cut real releases, but it needs the API budget, and a
--               repo with no releases yet answers 404 -- which is why it falls
--               back to the manifest read rather than reporting nothing.

SPZUpdate = SPZUpdate or {}

local function cfg(key, default)
    local v = Config[key]
    if v == nil then return default end
    return v
end

--- The repo name for a resource. Same name by default, since that is the
--- convention across the whole set; overrides exist for the exceptions.
local function repoName(resource)
    local overrides = cfg("RepoOverrides", {})
    return overrides[resource] or resource
end

local function rawManifestUrl(resource)
    return ("https://raw.githubusercontent.com/%s/%s/%s/fxmanifest.lua"):format(
        cfg("GitHubOwner", "SPiceZ21"), repoName(resource), cfg("GitHubBranch", "main"))
end

local function releaseApiUrl(resource)
    return ("https://api.github.com/repos/%s/%s/releases/latest"):format(
        cfg("GitHubOwner", "SPiceZ21"), repoName(resource))
end

--- Read the version out of raw fxmanifest text.
--- Accepts either quote style, because both appear in the wild.
local function versionFromManifest(text)
    if type(text) ~= "string" then return nil end
    return text:match("[\r\n]%s*version%s+'([^']+)'")
        or text:match("[\r\n]%s*version%s+\"([^\"]+)\"")
        or text:match("^%s*version%s+'([^']+)'")
        or text:match("^%s*version%s+\"([^\"]+)\"")
end

--- Headers. The token, when set, goes ONLY to api.github.com -- never to the
--- raw CDN, which does not need it and is a different host than the one the
--- operator granted it for.
local function headers(isApi)
    local h = { ["User-Agent"] = "spz-update" }
    if isApi then
        h["Accept"] = "application/vnd.github+json"
        -- Read from a convar first so a token need not be committed to config.lua.
        local token = GetConvar("spz_update_github_token", "")
        if token == "" then token = cfg("GitHubToken", "") or "" end
        if token ~= "" then h["Authorization"] = "Bearer " .. token end
    end
    return h
end

--- Fetch the published version of every installed resource.
---
--- Requests are dispatched through a small concurrency window rather than all
--- at once. Thirty-odd simultaneous requests to one host on server boot is both
--- rude and the shape of traffic that gets an IP throttled; a window of a few
--- finishes the whole set in well under a second anyway.
---
--- @param resources table  list of resource names to look up
--- @param onDone function  called with (published, stats)
function SPZUpdate.FetchGitHub(resources, onDone)
    local mode      = cfg("GitHubMode", "manifest")
    local maxActive = cfg("Concurrency", 6)
    local timeout   = cfg("RequestTimeoutMs", 20000)

    local published = {}
    local stats     = { ok = 0, missing = 0, failed = 0, errors = {}, failedNames = {} }

    local queue, active, finished, settled = {}, 0, 0, false
    for _, name in ipairs(resources) do queue[#queue + 1] = name end
    local total = #queue

    if total == 0 then
        onDone(published, stats)
        return
    end

    local function complete()
        if settled then return end
        settled = true
        onDone(published, stats)
    end

    -- One overall deadline. A PerformHttpRequest whose callback never arrives
    -- would otherwise leave the whole check hanging forever, and there is no
    -- per-request timeout to lean on.
    SetTimeout(timeout, function()
        if not settled then
            stats.failed = stats.failed + (total - finished)
            stats.errors[#stats.errors + 1] = ("timed out with %d of %d outstanding")
                :format(total - finished, total)
            complete()
        end
    end)

    local function done(name, version, err)
        if version then
            published[name] = { version = version, url = ("https://github.com/%s/%s")
                :format(cfg("GitHubOwner", "SPiceZ21"), repoName(name)) }
            stats.ok = stats.ok + 1
        elseif err == "missing" then
            -- No repo, or nothing published there yet. Not an error: a
            -- locally-developed module that was never pushed is a normal thing
            -- to have installed, and it must not be reported as a failure.
            stats.missing = stats.missing + 1
        else
            stats.failed = stats.failed + 1
            stats.failedNames[name] = true
            if #stats.errors < 5 then
                stats.errors[#stats.errors + 1] = ("%s: %s"):format(name, tostring(err))
            end
        end

        finished = finished + 1
        active   = active - 1
        if finished >= total then complete() end
    end

    -- Read fxmanifest.lua from the default branch.
    -- Status 0 is not an answer from GitHub: the connection never completed
    -- (TLS handshake dropped, socket reset). It is transient by nature, and it
    -- arrives in bursts, so one retry after a pause turns almost all of them
    -- into a real result. A 404 or any other genuine status is never retried.
    local RETRY_AFTER_MS = 900

    local function fetchManifest(name, attempt)
        attempt = attempt or 1
        PerformHttpRequest(rawManifestUrl(name), function(status, body)
            if (not status or status <= 0) and attempt < 2 then
                SetTimeout(RETRY_AFTER_MS, function() fetchManifest(name, attempt + 1) end)
                return
            end
            if status == 404 then return done(name, nil, "missing") end
            if status ~= 200 then return done(name, nil, ("HTTP %s"):format(tostring(status))) end

            local v = versionFromManifest(body)
            if not v then return done(name, nil, "no version line in fxmanifest") end
            done(name, v)
        end, "GET", "", headers(false))
    end

    -- Read the latest release tag, falling back to the manifest when a repo has
    -- no releases -- which is most of them until you start cutting releases.
    local function fetchRelease(name)
        PerformHttpRequest(releaseApiUrl(name), function(status, body)
            if status == 404 then return fetchManifest(name) end
            if status == 403 then
                -- Rate limited. Falling back keeps the check useful instead of
                -- returning nothing for the rest of the set.
                return fetchManifest(name)
            end
            if status ~= 200 then return done(name, nil, ("HTTP %s"):format(tostring(status))) end

            local ok, data = pcall(json.decode, body)
            if not ok or type(data) ~= "table" or type(data.tag_name) ~= "string" then
                return fetchManifest(name)
            end
            done(name, (data.tag_name:gsub("^[vV]", "")))
        end, "GET", "", headers(true))
    end

    local fetch = (mode == "release") and fetchRelease or fetchManifest

    -- The concurrency window used to be filled in ONE tick: six TLS handshakes
    -- to the same host opened in the same instant. The ones at the back of that
    -- burst were the ones that failed — spz-core and spz-crew one run, spz-chat
    -- and spz-crew the next, always from positions 3-6 of the alphabetical
    -- list, while their URLs answered 200 on their own. Spacing the dispatches
    -- keeps the parallelism and loses the burst.
    local dispatchGap = cfg("DispatchGapMs", 120)

    CreateThread(function()
        while #queue > 0 do
            if active < maxActive then
                local name = table.remove(queue, 1)
                active = active + 1
                fetch(name)
                Wait(dispatchGap)
            else
                Wait(25)
            end
        end
    end)
end
