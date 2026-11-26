-- Battle Fatigue (Low HP Stance) - Main Entry Point v1.1.0
-- 100% Game-Thread driven (zero LoopAsync threads, zero mutex contention).
-- Hotkeys (when config.enableHotkeys = true):
--   F7 = Toggle Battle Fatigue ON/OFF live
--   F8 = Hot-Reload config.lua & fatigue_controller.lua live (no game restart)
--   F9 = Dump live diagnostics snapshot to %TEMP%\BattleFatigue.log

local config = require("config")
local controller = require("fatigue_controller")

local function startController()
    local ok, err = pcall(controller.init)
    if not ok then
        print("[BattleFatigue INIT ERROR] " .. tostring(err))
    end
end

startController()

if config.enableHotkeys ~= false then
    -- F7: Toggle mod ON/OFF live
    pcall(function()
        RegisterKeyBind(Key.F7, function()
            ExecuteInGameThread(function()
                pcall(controller.toggleEnabled)
            end)
        end)
    end)

    -- F8: Hot-reload Lua scripts live without restarting the game
    pcall(function()
        RegisterKeyBind(Key.F8, function()
            ExecuteInGameThread(function()
                print("[BattleFatigue] Hot-reloading scripts...")
                pcall(controller.unregisterHooks)
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
                pcall(controller.dumpDiagnostics, "F9-hotkey")
            end)
        end)
    end)
end
