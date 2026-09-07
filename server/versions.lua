-- server/versions.lua
-- The LOCAL half: what this server is actually running.
--
-- Versions are read from each resource's fxmanifest via GetResourceMetadata,
-- not from a list maintained in here. A hand-kept list is a second place for a
-- version to live and it drifts the first time someone bumps a manifest without
-- remembering this resource exists — which is exactly the failure this module
-- is supposed to catch, so it must not be built on one.

SPZUpdate = SPZUpdate or {}

local PATTERN = Config.ResourcePattern or "^spz%-"
local IGNORE  = Config.Ignore or {}

--- Every started resource matching the SPiceZ pattern, with its manifest version.
---
--- Sorted by name so console output is stable between runs — an unsorted report
--- reorders itself every boot and stops being diffable.
---
--- @return table list  { { name, version, state, exported, drift }, ... }
function SPZUpdate.ScanLocal()
    local list = {}

    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)

        if name and name:match(PATTERN) and not IGNORE[name] then
            local state = GetResourceState(name)

            -- Stopped resources are still reported. "spz-poll is stopped" is
            -- information an admin wants from a status command, and silently
            -- dropping it makes a missing module look like it was never there.
            local version = GetResourceMetadata(name, "version", 0)

            local entry = {
                name    = name,
                version = (version and version ~= "") and version or nil,
                state   = state,
            }

            -- Cross-check against a GetVersion export where one exists.
            --
            -- spz-core carries its version in BOTH shared/version.lua and its
            -- fxmanifest, and those two have already diverged once. Where a
            -- resource publishes both, disagreement is reported rather than one
            -- being silently preferred: neither copy is authoritative enough to
            -- overrule the other, and the fix is to stop having two.
            if state == "started" then
                local ok, exported = pcall(function()
                    return exports[name]:GetVersion()
                end)
                if ok and type(exported) == "string" and exported ~= "" then
                    entry.exported = exported
                    entry.drift    = (entry.version ~= nil and exported ~= entry.version)
                end
            end

            list[#list + 1] = entry
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--- Map form of ScanLocal, for callers that want one resource by name.
--- @return table  [name] = entry
function SPZUpdate.LocalMap()
    local map = {}
    for _, entry in ipairs(SPZUpdate.ScanLocal()) do
        map[entry.name] = entry
    end
    return map
end

--- Print the local version report to the console.
--- @param printer function|nil  defaults to print; pass a per-player sink for chat
function SPZUpdate.PrintLocalReport(printer)
    local out  = printer or print
    local list = SPZUpdate.ScanLocal()

    out("^5── SPiceZ version report ─────────────────────────────^7")

    local missing, drifted, stopped = 0, 0, 0

    for _, e in ipairs(list) do
        local ver = e.version or "^3no version in fxmanifest^7"
        if not e.version then missing = missing + 1 end

        local flags = ""
        if e.state ~= "started" then
            flags   = flags .. ("  ^3[%s]^7"):format(e.state)
            stopped = stopped + 1
        end
        if e.drift then
            flags   = flags .. ("  ^1[export says v%s]^7"):format(e.exported)
            drifted = drifted + 1
        end

        out(("  %-22s v%s%s"):format(e.name, ver, flags))
    end

    out(("^5%d resources^7"):format(#list))
    if missing > 0 then
        out(("^3%d without a version in their fxmanifest — these cannot be update checked.^7"):format(missing))
    end
    if stopped > 0 then
        out(("^3%d not started.^7"):format(stopped))
    end
    if drifted > 0 then
        out(("^1%d carry a version in two places and the two disagree. "
          .. "The fxmanifest is what this report and the update check use.^7"):format(drifted))
    end

    return list
end

exports("ScanLocal",       SPZUpdate.ScanLocal)
exports("GetLocalVersions", SPZUpdate.LocalMap)
