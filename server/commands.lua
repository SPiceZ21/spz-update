-- server/commands.lua
-- Console and in-game entry points.
--
-- Both commands are permission gated through spz-core rather than registering
-- as restricted commands, so they follow the same ACE hierarchy as the rest of
-- the framework and the console stays exempt (HasPermission passes source 0).

local function replyTo(src)
    if src == 0 then
        return print
    end

    -- Console colour codes are meaningless in chat, so they are stripped rather
    -- than shipped to the client as literal "^3" noise.
    return function(line)
        TriggerClientEvent("chat:addMessage", src, {
            color = { 200, 200, 200 },
            multiline = true,
            args = { "spz-update", (tostring(line):gsub("%^%d", "")) },
        })
    end
end

local function guard(src)
    local ok, allowed = pcall(function()
        return exports["spz-core"]:HasPermission(src, Config.AdminAce or "spz.admin")
    end)
    if ok and allowed then return true end

    local out = replyTo(src)
    out("^1Access denied.^7")
    return false
end

-- /spzversion - what this server is running, right now, from the fxmanifests.
-- Works with no network and no manifest URL configured.
RegisterCommand("spzversion", function(src)
    src = tonumber(src) or 0
    if not guard(src) then return end
    SPZUpdate.PrintLocalReport(replyTo(src))
end, false)

-- /spzupdate - the last remote check, or force a fresh one with /spzupdate now.
RegisterCommand("spzupdate", function(src, args)
    src = tonumber(src) or 0
    if not guard(src) then return end

    local out = replyTo(src)

    if args and args[1] == "now" then
        local started, why = SPZUpdate.ManualCheck(function(ok)
            if ok then
                SPZUpdate.PrintRemoteReport(out)
            else
                out("^1Check failed. See the server console for why.^7")
            end
        end)
        if not started then
            out(("^3Checked too recently - %s.^7"):format(why))
            return
        end
        out("^5Checking...^7")
        return
    end

    SPZUpdate.PrintRemoteReport(out)

    -- GetReport, not checker.lua's Report upvalue: that is a file local and is
    -- not visible from here even though both files share one Lua state.
    local report = SPZUpdate.GetReport()
    if report.checkedAt then
        out(("^5  last checked %s^7"):format(os.date("%Y-%m-%d %H:%M:%S", report.checkedAt)))
    end
    out("^5  /spzupdate now forces a fresh check.^7")
end, false)
