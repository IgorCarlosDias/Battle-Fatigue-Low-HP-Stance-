-- Battle Fatigue (Low HP Stance) - Core Controller v1.0.0
-- Dragon Ball: Sparking! ZERO
-- Purely visual exhausted idle stance (ground & air) on the last (red) health bar.
-- Automatically disabled in online battles and replays.

local config = require("config")

local Controller = {}

-- UE5 Enums verified from SparkingZERO-Win64-Shipping.exe
local LOCO_STATE_IDLE_MOVE     = 0   -- EKoratLocomotionState::IdleMove
local LOCO_STATE_STUN_REACTION = 12  -- EKoratLocomotionState::StunReaction

local STUN_STATUS_OFF   = 0          -- EKoratStunReactionState::OFF
local STUN_STATUS_STAND = 1          -- EKoratStunReactionState::STAND

local DETAIL_IDLE_MOVE         = 0   -- EKoratCharacterLocomotionDetailStatus::IdleMove
local DETAIL_IDLE_STAND_FAR    = 1   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandFar
local DETAIL_IDLE_STAND_GROUND = 2   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandGround
local DETAIL_IDLE_STAND_AIR    = 3   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandAir
local DETAIL_STUN_STAND        = 78  -- EKoratCharacterLocomotionDetailStatus::StunReactionSTAND

-- Action key substrings that clearly represent active combat/charging moves
local BUSY_ACTION_PATTERNS = {
    "chg", "grd", "spm", "ult", "exa", "frmc",
    "rsh", "smb", "kdn", "trw", "atk", "cnt",
    "pry", "dmg", "blw", "dwn", "lta", "hse", "uppf"
}

-- Cached engine singletons
local gameInstance = nil
local bpLib = nil
local gameplayStatics = nil
local locoCompClass = nil
local montageCompClass = nil
local nextDiscovery = 0

-- Hook state
local hooksRegistered = false
local registeredHooks = {}
local hookFiredCount = 0

-- Active battle state
local lastBattleKey = nil
local battleSnapshotLogged = false

-- Per-side fighter state (0 = P1, 1 = P2/CPU)
local fighterState = {
    [0] = { addr = 0, charKey = "", locoComp = nil, montageComp = nil, wantFatigue = false, isFatigued = false, lastReason = "" },
    [1] = { addr = 0, charKey = "", locoComp = nil, montageComp = nil, wantFatigue = false, isFatigued = false, lastReason = "" }
}

-- O(1) lookup from locoComp address -> side index for synchronous hooks
local locoAddrToSide = {}

local function getLogPath()
    if config.logFile and config.logFile ~= "" then
        return config.logFile
    end
    local tmp = os.getenv("TEMP") or os.getenv("TMP")
    if tmp and tmp ~= "" then
        return tmp .. "\\BattleFatigue.log"
    end
    return nil
end

local function writeLog(msg, force)
    if not force and not config.logDebug then return end
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
    print("[BattleFatigue] " .. line)
    if config.logDebug or force then
        local path = getLogPath()
        if path then
            local f = io.open(path, "a")
            if f then
                f:write(line .. "\n")
                f:close()
            end
        end
    end
end

local function clearLog()
    if not config.logDebug then return end
    local path = getLogPath()
    if path then
        local f = io.open(path, "w")
        if f then
            f:write("=== Battle Fatigue v1.0.0 Runtime Log (" .. os.date("%Y-%m-%d %H:%M:%S") .. ") ===\n")
            f:close()
        end
    end
end

local function valid(obj)
    if obj == nil or (type(obj) ~= "userdata" and type(obj) ~= "table") then
        return false
    end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

local function safeAddr(obj)
    if not valid(obj) then return 0 end
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or 0
end

local function safeName(obj)
    if not valid(obj) then return "<nil>" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and tostring(n) or "<err>"
end

local function getBPLib()
    if valid(bpLib) then return bpLib end
    bpLib = StaticFindObject("/Script/SS.Default__SSBlueprintFunctionLibrary")
    return bpLib
end

local function getGameplayStatics()
    if valid(gameplayStatics) then return gameplayStatics end
    gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return gameplayStatics
end

local function getLocoCompClass()
    if valid(locoCompClass) then return locoCompClass end
    locoCompClass = StaticFindObject("/Script/SS.KoratCharacterLocomotionComponent")
    return locoCompClass
end

local function getMontageCompClass()
    if valid(montageCompClass) then return montageCompClass end
    montageCompClass = StaticFindObject("/Script/SS.KoratCharacterMontageComponent")
    return montageCompClass
end

local function isBusyActionKey(actKey)
    if not actKey or actKey == "" or actKey == "None" then return false end
    local lower = actKey:lower()
    for _, pat in ipairs(BUSY_ACTION_PATTERNS) do
        if lower:find(pat, 1, true) then
            return true
        end
    end
    return false
end

-- Resolve fighter's locomotion component ONCE per character spawn (zero per-frame FindAllOf)
local function resolveFighterComponents(pawn, side)
    local st = fighterState[side]
    local pAddr = safeAddr(pawn)
    st.addr = pAddr
    st.locoComp = nil
    st.montageComp = nil
    st.wantFatigue = false
    st.isFatigued = false
    st.lastReason = ""

    local okKey, keyStr = pcall(function()
        local d = pawn:GetCharacterDataList()
        return d and d.Key and d.Key:ToString() or ""
    end)
    st.charKey = (okKey and keyStr ~= "") and keyStr or ("Side" .. tostring(side + 1))

    local lcClass = getLocoCompClass()
    if valid(lcClass) then
        local ok, comp = pcall(function() return pawn:GetComponentByClass(lcClass) end)
        if ok and valid(comp) then
            st.locoComp = comp
        end
    end

    if not valid(st.locoComp) then
        local okAll, list = pcall(function() return FindAllOf("KoratCharacterLocomotionComponent") end)
        if okAll and list then
            local meshAddr = safeAddr(pawn.Mesh)
            for _, obj in ipairs(list) do
                if valid(obj) and not safeName(obj):find("Default__", 1, true) then
                    local okO, outer = pcall(function() return obj:GetOuter() end)
                    local okOwner, owner = pcall(function() return obj:GetOwner() end)
                    if (okO and (safeAddr(outer) == pAddr or safeAddr(outer) == meshAddr)) or
                       (okOwner and safeAddr(owner) == pAddr) then
                        st.locoComp = obj
                        break
                    end
                end
            end
        end
    end

    local okM, mComp = pcall(function() return pawn:GetKoratCharacterMontageComponent() end)
    if okM and valid(mComp) then
        st.montageComp = mComp
    else
        local mcClass = getMontageCompClass()
        if valid(mcClass) then
            local ok2, c2 = pcall(function() return pawn:GetComponentByClass(mcClass) end)
            if ok2 and valid(c2) then st.montageComp = c2 end
        end
    end

    locoAddrToSide = {}
    for s = 0, 1 do
        local la = safeAddr(fighterState[s].locoComp)
        if la ~= 0 then
            locoAddrToSide[la] = s
        end
    end

    writeLog(string.format("Resolved P%d (%s) | LocoComp=%s", side + 1, st.charKey, safeName(st.locoComp)))
end

-- Override ONLY the animation cache fields on KoratCharacterLocomotionComponent (never locks gameplay controls)
local function writeFatigueToLocoComp(locoComp, enable)
    if not valid(locoComp) then return false end
    local targetState = enable and LOCO_STATE_STUN_REACTION or LOCO_STATE_IDLE_MOVE
    local targetStun  = enable and STUN_STATUS_STAND or STUN_STATUS_OFF

    local ok = pcall(function()
        locoComp.LocomotionStateCache = targetState
        locoComp.StunReactionStatusCache = targetStun
        if enable then
            locoComp.StunReactionIsFrontCache = true
        end
    end)

    return ok
end

-- Locate active offline battle context safely
function Controller.getBattle()
    local instances
    if valid(gameInstance) then
        instances = { gameInstance }
    else
        if os.time() < nextDiscovery then return nil end
        nextDiscovery = os.time() + 2
        instances = FindAllOf("SSGameInstance") or {}
    end

    local gsLib = getGameplayStatics()
    local apiLib = getBPLib()
    if not valid(gsLib) or not valid(apiLib) then return nil end

    for _, gi in ipairs(instances) do
        if valid(gi) and not safeName(gi):find("Default__", 1, true) then
            gameInstance = gi

            -- Safety guard: auto-disable in online battles and replays
            local okNet, isOnlineOrReplay = pcall(function()
                return (gi.BattleSetting and gi.BattleSetting.bOnlineBattleFlg)
                    or gi.bOnlineBattleObserver
                    or gi.BattleStartMode == 3
            end)
            if okNet and isOnlineOrReplay then return nil end

            local pc = gsLib:GetPlayerController(gi, 0)
            if valid(pc) then
                local world = pc:GetWorld()
                if valid(world) then
                    local okDriver, hasNetDriver = pcall(function()
                        return valid(world.NetDriver) or valid(world.DemoNetDriver)
                    end)
                    if okDriver and hasNetDriver then return nil end

                    local gs = world.GameState
                    if valid(gs) then
                        local okPlay, playing = pcall(function()
                            return gs:IsPlayingBattle() and not gs:IsSettleStatus()
                        end)
                        if okPlay and playing then
                            local level = apiLib:GetSSBattleLevelScriptActor(world)
                            if valid(level) then
                                local p1 = level:GetPlayerPawn(0)
                                local p2 = level:GetPlayerPawn(1)
                                local bKey = tostring(safeAddr(world)) .. ":" .. tostring(safeAddr(level))
                                return {
                                    key = bKey,
                                    world = world,
                                    gs = gs,
                                    level = level,
                                    p1 = p1,
                                    p2 = p2
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

-- Evaluate whether a fighter should display the visual Low-HP exhausted stance
local function evaluateFighter(pawn, side)
    local st = fighterState[side]
    if not valid(pawn) then
        st.wantFatigue = false
        st.isFatigued = false
        return
    end

    if safeAddr(pawn) ~= st.addr then
        resolveFighterComponents(pawn, side)
    end

    if not config.enabled then
        if st.isFatigued then
            st.wantFatigue = false
            writeFatigueToLocoComp(st.locoComp, false)
            st.isFatigued = false
        end
        return
    end

    -- 1. Check HP (Red bar = <= 10,000 HP)
    local okHp, hp, maxHp = pcall(function()
        return pawn:GetHPGaugeValue(), pawn:GetMaxHPGaugeValue()
    end)
    if not okHp or not hp or not maxHp or hp <= 0 or maxHp <= 0 then
        st.wantFatigue = false
        if st.isFatigued then
            writeFatigueToLocoComp(st.locoComp, false)
            st.isFatigued = false
        end
        return
    end

    local isLowHp
    if maxHp > config.hpThreshold then
        isLowHp = (hp <= config.hpThreshold)
    else
        isLowHp = ((hp / maxHp) <= config.fallbackRatio)
    end

    if not isLowHp then
        st.wantFatigue = false
        if st.isFatigued then
            writeFatigueToLocoComp(st.locoComp, false)
            st.isFatigued = false
            writeLog(string.format("P%d (%s) HP recovered (%.0f/%.0f) -> normal stance", side + 1, st.charKey, hp, maxHp))
        end
        return
    end

    -- 2. Optional ground-only mode (false by default: works on ground AND in the air)
    if config.groundOnly then
        local okAir, isInAir = pcall(function()
            return valid(st.locoComp) and st.locoComp.IsInAirCache
        end)
        if okAir and isInAir then
            st.wantFatigue = false
            if st.isFatigued then
                writeFatigueToLocoComp(st.locoComp, false)
                st.isFatigued = false
            end
            return
        end
    end

    local busyReason = nil

    -- 3. Check active Ki charge level / finish demo
    local okCharge, chargeLv = pcall(function() return pawn:GetChargeLv() end)
    if okCharge and type(chargeLv) == "number" and chargeLv > 0 then
        busyReason = "charging(lv=" .. tostring(chargeLv) .. ")"
    end

    if not busyReason then
        local okDemo, finishDemo = pcall(function() return pawn.bIsFinishDemo end)
        if okDemo and finishDemo then
            busyReason = "finishDemo"
        end
    end

    -- 4. Check 3D velocity (ground walking & aerial flying/ascending/descending)
    if not busyReason then
        local okVel, speedSq = pcall(function()
            local mov = pawn.CharacterMovement
            if not valid(mov) then return 0 end
            local v = mov.Velocity
            return (v.X * v.X) + (v.Y * v.Y) + (v.Z * v.Z)
        end)
        if okVel and speedSq > (config.maxIdleSpeed * config.maxIdleSpeed) then
            busyReason = string.format("moving(v=%.0f)", math.sqrt(speedSq))
        end
    end

    -- 5. Check analog stick / movement input vector (instant 0ms release on tilt)
    if not busyReason and valid(st.locoComp) then
        local okIn, inMagSq, inZ = pcall(function()
            local iv = st.locoComp.InputVectorCache
            local iz = st.locoComp.InputZCache or 0
            local m2 = iv and ((iv.X * iv.X) + (iv.Y * iv.Y) + (iv.Z * iv.Z)) or 0
            return m2, math.abs(iz)
        end)
        if okIn then
            local limSq = config.maxInputMagnitude * config.maxInputMagnitude
            if inMagSq > limSq or inZ > config.maxInputMagnitude then
                busyReason = "input"
            end
        end
    end

    -- 6. Check locomotion detail status (IdleMove / StandFar / StandGround / StandAir)
    local detailStatus = -1
    local okDet, ds = pcall(function() return pawn:GetCurrentLocomotionDetailStatus() end)
    if okDet and type(ds) == "number" then
        detailStatus = ds
        local isIdleDetail = (
            ds == DETAIL_IDLE_MOVE
            or ds == DETAIL_IDLE_STAND_FAR
            or ds == DETAIL_IDLE_STAND_GROUND
            or ds == DETAIL_IDLE_STAND_AIR
        )
        local isOurStun = (st.isFatigued and ds == DETAIL_STUN_STAND)
        if not isIdleDetail and not isOurStun then
            busyReason = "detailStatus=" .. tostring(ds)
        end
    end

    -- 7. Check active combat action key on LocomotionComponent (guard, charge, blast, rush, transform, etc.)
    if not busyReason and valid(st.locoComp) then
        local okAct, actKey = pcall(function()
            local a = st.locoComp.CurrentRunningAction
            return a and a.Key and a.Key:ToString() or ""
        end)
        if okAct and isBusyActionKey(actKey) then
            busyReason = "action=" .. tostring(actKey)
        end
    end

    if busyReason then
        st.wantFatigue = false
        if st.isFatigued then
            writeFatigueToLocoComp(st.locoComp, false)
            st.isFatigued = false
            writeLog(string.format("P%d (%s) -> normal stance (%s)", side + 1, st.charKey, busyReason))
        end
        st.lastReason = busyReason
        return
    end

    -- All conditions met: Low HP + Stationary/Idle (Ground or Air)!
    st.wantFatigue = true
    local applied = writeFatigueToLocoComp(st.locoComp, true)
    if not st.isFatigued then
        st.isFatigued = true
        writeLog(string.format(
            "P%d (%s) -> EXHAUSTED STANCE ON (HP=%.0f/%.0f detail=%d applied=%s)",
            side + 1, st.charKey, hp, maxHp, detailStatus, tostring(applied)
        ))
    end
end

-- On-demand diagnostic snapshot (F9 hotkey)
function Controller.dumpDiagnostics(tag)
    writeLog("========== DIAGNOSTIC SNAPSHOT [" .. tostring(tag or "manual") .. "] ==========", true)
    writeLog(string.format("enabled=%s hooksRegistered=%s hookFiredCount=%d", tostring(config.enabled), tostring(hooksRegistered), hookFiredCount), true)

    local battle = Controller.getBattle()
    if not battle then
        writeLog("No active offline battle detected.", true)
        return
    end

    for side, pawn in pairs({ [0] = battle.p1, [1] = battle.p2 }) do
        if valid(pawn) then
            local st = fighterState[side]
            if safeAddr(pawn) ~= st.addr then
                resolveFighterComponents(pawn, side)
            end
            local okHp, hp, mhp = pcall(function() return pawn:GetHPGaugeValue(), pawn:GetMaxHPGaugeValue() end)
            local okDet, det = pcall(function() return pawn:GetCurrentLocomotionDetailStatus() end)
            local okChg, chg = pcall(function() return pawn:GetChargeLv() end)
            local okVel, vx, vy, vz = pcall(function()
                local v = pawn.CharacterMovement.Velocity
                return v.X, v.Y, v.Z
            end)
            writeLog(string.format(
                "P%d (%s) HP=%.0f/%.0f detail=%s chargeLv=%s vel=(%.1f,%.1f,%.1f) wantFatigue=%s isFatigued=%s lastReason=%s",
                side + 1, st.charKey,
                okHp and hp or -1, okHp and mhp or -1,
                tostring(okDet and det or "err"), tostring(okChg and chg or "err"),
                okVel and vx or 0, okVel and vy or 0, okVel and vz or 0,
                tostring(st.wantFatigue), tostring(st.isFatigued), tostring(st.lastReason)
            ), true)

            if valid(st.locoComp) then
                local okL, lState, sStat, inAir, actKey = pcall(function()
                    local lc = st.locoComp
                    local ak = lc.CurrentRunningAction and lc.CurrentRunningAction.Key and lc.CurrentRunningAction.Key:ToString() or "None"
                    return lc.LocomotionStateCache, lc.StunReactionStatusCache, lc.IsInAirCache, ak
                end)
                writeLog(string.format(
                    "  LocoComp: ok=%s StateCache=%s StunCache=%s InAir=%s Act=%s",
                    tostring(okL), tostring(lState), tostring(sStat), tostring(inAir), tostring(actKey)
                ), true)
            end
        end
    end
    writeLog("==========================================================", true)
end

-- Register synchronous Game-Thread hooks on KoratCharacterLocomotionComponent
function Controller.registerHooks()
    if hooksRegistered then return end
    local targets = {
        "/Script/SS.KoratCharacterLocomotionComponent:UpdateLocomotionParameterCache",
        "/Script/SS.KoratCharacterLocomotionComponent:SetLocomotionParameterCache"
    }

    for _, fnPath in ipairs(targets) do
        local ok, preId, postId = pcall(function()
            return RegisterHook(fnPath, function() end, function(selfObj)
                hookFiredCount = hookFiredCount + 1
                local lc = selfObj and selfObj:get() or nil
                local addr = safeAddr(lc)
                local side = locoAddrToSide[addr]
                if side ~= nil then
                    local st = fighterState[side]
                    if st and st.wantFatigue then
                        writeFatigueToLocoComp(lc, true)
                    end
                end
            end)
        end)
        if ok and preId then
            table.insert(registeredHooks, { path = fnPath, pre = preId, post = postId })
            writeLog("Hook registered: " .. fnPath)
        else
            writeLog("Hook unavailable: " .. fnPath)
        end
    end

    hooksRegistered = true
end

function Controller.unregisterHooks()
    for _, h in ipairs(registeredHooks) do
        pcall(function() UnregisterHook(h.path, h.pre, h.post) end)
    end
    registeredHooks = {}
    hooksRegistered = false
end

function Controller.init()
    clearLog()
    print("[BattleFatigue] v1.0.0 loaded (Ground & Air | Last Red Bar <= " .. tostring(config.hpThreshold) .. " HP)")
    Controller.registerHooks()
end

function Controller.toggleEnabled()
    config.enabled = not config.enabled
    print("[BattleFatigue] Toggled: enabled = " .. tostring(config.enabled))
    if not config.enabled then
        for s = 0, 1 do
            if fighterState[s].isFatigued then
                fighterState[s].wantFatigue = false
                writeFatigueToLocoComp(fighterState[s].locoComp, false)
                fighterState[s].isFatigued = false
            end
        end
    end
end

function Controller.tick()
    local battle = Controller.getBattle()
    if not battle then
        if lastBattleKey ~= nil then
            lastBattleKey = nil
            battleSnapshotLogged = false
            for s = 0, 1 do
                fighterState[s].addr = 0
                fighterState[s].locoComp = nil
                fighterState[s].montageComp = nil
                fighterState[s].wantFatigue = false
                fighterState[s].isFatigued = false
            end
            locoAddrToSide = {}
        end
        return
    end

    if battle.key ~= lastBattleKey then
        lastBattleKey = battle.key
        battleSnapshotLogged = false
        writeLog("New battle detected: " .. battle.key)
    end

    if config.enablePlayer1 and valid(battle.p1) then
        evaluateFighter(battle.p1, 0)
    end
    if config.enablePlayer2 and valid(battle.p2) then
        evaluateFighter(battle.p2, 1)
    end

    if config.logDebug and not battleSnapshotLogged and valid(battle.p1) and valid(battle.p2) then
        battleSnapshotLogged = true
        Controller.dumpDiagnostics("battle-start")
    end
end

return Controller
