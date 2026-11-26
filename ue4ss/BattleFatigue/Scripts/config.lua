-- Battle Fatigue (Low HP Stance) - Configuration
-- Edit any value below and press F8 in-game to hot-reload without restarting.

local config = {
    -- Enable or disable the mod (can also be toggled live in-game with F7)
    enabled = true,

    -- Last health bar threshold (10,000 HP = red bar in Dragon Ball: Sparking! ZERO)
    hpThreshold = 10000.0,
    -- Fallback percentage if a fighter/mode has MaxHP <= hpThreshold
    fallbackRatio = 0.30,

    -- Apply to all fighters (Player 1 and Player 2 / CPU)
    enablePlayer1 = true,
    enablePlayer2 = true,

    -- false = works both standing on the ground AND hovering idle in the air
    -- true  = only triggers while standing on the ground
    groundOnly = false,

    -- Max 3D speed (X, Y, Z) to consider the fighter stationary/idle
    maxIdleSpeed = 25.0,

    -- Analog stick deadzone (moving the stick beyond this immediately cancels the stance)
    maxInputMagnitude = 0.05,

    -- Main check interval in milliseconds (33ms = ~30Hz, negligible CPU cost)
    checkIntervalMs = 33,

    -- Enable live hotkeys: F7 (Toggle), F8 (Hot-Reload), F9 (Diagnostic Dump)
    enableHotkeys = true,

    -- Diagnostic logging (keep false for zero disk writes during normal play)
    logDebug = false,
    -- Leave empty ("") to use %TEMP%\BattleFatigue.log when logDebug = true
    logFile = ""
}

return config
