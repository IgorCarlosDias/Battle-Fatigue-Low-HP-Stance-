-- Battle Fatigue (Low HP Stance) - Main Entry Point v1.0.0
-- Hotkeys (when config.enableHotkeys = true):
--   F7 = Toggle Battle Fatigue ON/OFF live
--   F8 = Hot-Reload config.lua & fatigue_controller.lua live (no game restart)
--   F9 = Dump live diagnostics snapshot to %TEMP%\BattleFatigue.log

local config = require("config")
local controller = require("fatigue_controller")

local generation = 1

local function startController()
    local ok, err = pcall(function()
        controller.init()
    end)
    if not ok then
        print("[BattleFatigue INIT ERROR] " .. tostring(err))
    end
end

startController()

-- Lightweight Game-Thread safe update loop
LoopAsync(config.checkIntervalMs or 33, function()
    local myGen = generation
    ExecuteInGameThread(function()
        if myGen ~= generation then return end
        local ok, err = pcall(function()
            controller.tick()
        end)
        if not ok then
            print("[BattleFatigue TICK ERROR] " .. tostring(err))
        end
    end)
    return false
end)

if config.enableHotkeys ~= false then
    -- F7: Toggle mod ON/OFF live
    pcall(function()
        RegisterKeyBind(Key.F7, function()
            ExecuteInGameThread(function()
                pcall(function() controller.toggleEnabled() end)
            end)
        end)
    end)

    -- F8: Hot-reload Lua scripts live without restarting the game
    pcall(function()
        RegisterKeyBind(Key.F8, function()
            ExecuteInGameThread(function()
                print("[BattleFatigue] Hot-reloading scripts...")
                pcall(function() controller.unregisterHooks() end)
                generation = generation + 1
                package.loaded["config"] = nil
                package.loaded["fatigue_controller"] = nil
                local okCfg, newCfg = pcall(require, "config")
                local okCtrl, newCtrl = pcall(require, "fatigue_controller")
                if okCfg and okCtrl then
                    config = newCfg
                    controller = newCtrl
                    startController()
                    print("[BattleFatigue] Hot-reload complete!")
                else
                    print("[BattleFatigue] Hot-reload FAILED: " .. tostring(newCfg) .. " / " .. tostring(newCtrl))
                end
            end)
        end)
    end)

    -- F9: Dump live diagnostics snapshot
    pcall(function()
        RegisterKeyBind(Key.F9, function()
            ExecuteInGameThread(function()
                pcall(function() controller.dumpDiagnostics("F9-hotkey") end)
            end)
        end)
    end)
end
