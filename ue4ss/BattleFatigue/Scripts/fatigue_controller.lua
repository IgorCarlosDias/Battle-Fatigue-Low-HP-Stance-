-- Battle Fatigue (Low HP Stance) - Core Controller v1.1.0
-- Dragon Ball: Sparking! ZERO
-- 100% Game-Thread driven, zero LoopAsync threads, zero per-frame allocations/exceptions.
-- Purely visual exhausted idle stance (ground & air) on the last (red) health bar.
-- Automatically disabled in online battles and replays.

local config = require("config")

local Controller = {}

-- UE5 Enums verified from SparkingZERO-Win64-Shipping.exe
local LOCO_STATE_IDLE_MOVE     = 0   -- EKoratLocomotionState::IdleMove
local LOCO_STATE_JUMP          = 2   -- EKoratLocomotionState::Jump
local LOCO_STATE_DASH_UP_DOWN  = 9   -- EKoratLocomotionState::DashUpDown
local LOCO_STATE_STUN_REACTION = 12  -- EKoratLocomotionState::StunReaction

local STUN_STATUS_OFF   = 0          -- EKoratStunReactionState::OFF
local STUN_STATUS_STAND = 1          -- EKoratStunReactionState::STAND

local DETAIL_IDLE_MOVE         = 0   -- EKoratCharacterLocomotionDetailStatus::IdleMove
local DETAIL_IDLE_STAND_FAR    = 1   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandFar
local DETAIL_IDLE_STAND_GROUND = 2   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandGround
local DETAIL_IDLE_STAND_AIR    = 3   -- EKoratCharacterLocomotionDetailStatus::IdleMoveStandAir
local DETAIL_STUN_STAND        = 78  -- EKoratCharacterLocomotionDetailStatus::StunReactionSTAND

-- EMovementMode values from UE5
local MOVE_WALKING = 1
local MOVE_FALLING = 3
local MOVE_FLYING  = 5

-- Action key substrings that represent active combat/charging/descent/landing moves
local BUSY_ACTION_PATTERNS = {
    "chg", "grd", "spm", "ult", "exa", "frmc",
    "rsh", "smb", "kdn", "trw", "atk", "cnt",
    "pry", "dmg", "blw", "dwn", "lta", "hse", "uppf",
    "jmp", "dsh", "stp", "lnd", "fln", "fal", "sfl"
}

-- Cached config thresholds (avoid table lookups in 60Hz hook)
local maxIdleSpeed    = config.maxIdleSpeed or 25.0
local maxIdleSpeedSq  = maxIdleSpeed * maxIdleSpeed
local maxInputMag     = config.maxInputMagnitude or 0.05
local maxInputMagSq   = maxInputMag * maxInputMag
local idleDelaySec    = config.idleDelaySec or 0.08
local airDelaySec     = config.airTransitionDelaySec or 0.25

-- Cached engine singletons
local gameInstance     = nil
local bpLib            = nil
local gameplayStatics  = nil
local locoCompClass    = nil
local nextDiscovery    = 0

-- Hook & Game-Thread tick throttle state
local hooksRegistered  = false
local registeredHooks  = {}
local hookFiredCount   = 0
local nextTickClock    = 0
local lastBattleKey    = nil
local inValidBattle    = false

-- Per-side fighter state (0 = P1, 1 = P2/CPU)
local function newFighterState()
    return {
        addr = 0,
        charKey = "",
        pawn = nil,
        locoComp = nil,
        -- Tick-level flags (updated at 10-20Hz on the Game Thread, never on an async thread)
        lowHp = false,
        eligible = false,
        tickBusyReason = "",
        movMode = -1,
        hp = 0,
        maxHp = 0,
        actKey = "",
        -- Synchronous hook state (updated in-place with zero heap allocations)
        weOverrode = false,
        isFatigued = false,
        lastReason = "",
        lastInAir = nil,
        busyUntil = 0,
        nativeState = -1,
        nativeStun = -1,
        nativeDetail = -1,
        dashUpDown = 0,
        jumpStatus = 0,
        groundRun = 0
    }
end

local fighterState = {
    [0] = newFighterState(),
    [1] = newFighterState()
}

-- O(1) lookup from locoComp address -> side index
local locoAddrToSide = {}

-- Zero-allocation pcall helper functions (defined once, reused everywhere)
local function _isValid(obj) return obj:IsValid() end
local function _getAddr(obj) return obj:GetAddress() end
local function _getFullName(obj) return obj:GetFullName() end
local function _getSelf(param) return param:get() end

local function valid(obj)
    if obj == nil then return false end
    local t = type(obj)
    if t ~= "userdata" and t ~= "table" then return false end
    local ok, res = pcall(_isValid, obj)
    return ok and res == true
end

local function safeAddr(obj)
    if obj == nil then return 0 end
    local ok, a = pcall(_getAddr, obj)
    return (ok and a) or 0
end

local function safeName(obj)
    if not valid(obj) then return "<nil>" end
    local ok, n = pcall(_getFullName, obj)
    return ok and tostring(n) or "<err>"
end

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
            f:write("=== Battle Fatigue v1.1.0 Runtime Log (" .. os.date("%Y-%m-%d %H:%M:%S") .. ") ===\n")
            f:close()
        end
    end
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

local function isBusyActionKey(actKey)
    if not actKey or actKey == "" or actKey == "None" then return false end
    local lower = actKey:lower()
    for i = 1, #BUSY_ACTION_PATTERNS do
        if lower:find(BUSY_ACTION_PATTERNS[i], 1, true) then
            return true
        end
    end
    return false
end

-- Zero-allocation cache clear/write helpers
local function _clearOverride(lc)
    if lc.LocomotionStateCache == LOCO_STATE_STUN_REACTION
       and lc.StunReactionStatusCache == STUN_STATUS_STAND then
        lc.LocomotionStateCache = LOCO_STATE_IDLE_MOVE
        lc.StunReactionStatusCache = STUN_STATUS_OFF
    end
end

local function _applyOverride(lc)
    lc.LocomotionStateCache = LOCO_STATE_STUN_REACTION
    lc.StunReactionStatusCache = STUN_STATUS_STAND
    lc.StunReactionIsFrontCache = true
end

local function clearFatigueSafe(locoComp, st)
    if valid(locoComp) then
        pcall(_clearOverride, locoComp)
    end
    if st then
        st.weOverrode = false
        st.isFatigued = false
    end
end

-- Resolve fighter's locomotion component ONCE per character spawn
local function resolveFighterComponents(pawn, side)
    local st = newFighterState()
    fighterState[side] = st
    local pAddr = safeAddr(pawn)
    st.addr = pAddr
    st.pawn = pawn

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

    locoAddrToSide = {}
    for s = 0, 1 do
        local la = safeAddr(fighterState[s].locoComp)
        if la ~= 0 then
            locoAddrToSide[la] = s
        end
    end

    writeLog(string.format("Resolved P%d (%s) | LocoComp=%s", side + 1, st.charKey, safeName(st.locoComp)))
end

-- Locate active offline battle context safely
function Controller.getBattle()
    local instances
    if valid(gameInstance) then
        instances = { gameInstance }
    else
        local nowSec = os.time()
        if nowSec < nextDiscovery then return nil end
        nextDiscovery = nowSec + 2
        instances = FindAllOf("SSGameInstance") or {}
    end

    local gsLib = getGameplayStatics()
    local apiLib = getBPLib()
    if not valid(gsLib) or not valid(apiLib) then return nil end

    for i = 1, #instances do
        local gi = instances[i]
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

-- Low-frequency Game-Thread evaluation (10Hz at high HP, 20Hz at Low HP).
-- Checks HP, Ki charge, finish demo, MovementMode, Pawn detail status, and CurrentRunningAction.
local function evaluateFighter(pawn, side, now)
    local st = fighterState[side]
    if not valid(pawn) then
        st.lowHp = false
        st.eligible = false
        st.isFatigued = false
        st.weOverrode = false
        return false
    end

    if safeAddr(pawn) ~= st.addr then
        resolveFighterComponents(pawn, side)
        st = fighterState[side]
    end
    st.pawn = pawn

    if not config.enabled then
        st.lowHp = false
        st.eligible = false
        st.tickBusyReason = "disabled"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
        end
        return false
    end

    -- 1. Check HP (Red bar = <= 10,000 HP)
    local okHp, hp, maxHp = pcall(function()
        return pawn:GetHPGaugeValue(), pawn:GetMaxHPGaugeValue()
    end)
    if not okHp or not hp or not maxHp or hp <= 0 or maxHp <= 0 then
        st.lowHp = false
        st.eligible = false
        st.tickBusyReason = "invalidHP"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
        end
        return false
    end
    st.hp = hp
    st.maxHp = maxHp

    local isLowHp
    if maxHp > config.hpThreshold then
        isLowHp = (hp <= config.hpThreshold)
    else
        isLowHp = ((hp / maxHp) <= config.fallbackRatio)
    end
    st.lowHp = isLowHp

    if not isLowHp then
        st.eligible = false
        st.tickBusyReason = "hpOK"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
            writeLog(string.format("P%d (%s) HP recovered (%.0f/%.0f) -> normal stance", side + 1, st.charKey, hp, maxHp))
        end
        return false
    end

    -- Only reaches here when fighter is actually at Low HP (last red bar)!
    local busyReason = nil

    -- 2. Check active Ki charge level & finish demo
    local okChg, chargeLv, finishDemo = pcall(function()
        return pawn:GetChargeLv(), pawn.bIsFinishDemo
    end)
    if okChg then
        if type(chargeLv) == "number" and chargeLv > 0 then
            busyReason = "charging"
        elseif finishDemo then
            busyReason = "finishDemo"
        end
    end

    -- 3. Check CharacterMovement MovementMode & 3D Velocity (block Falling / Custom / Moving)
    if not busyReason then
        local okMov, movMode, speedSq, velZ = pcall(function()
            local mov = pawn.CharacterMovement
            if not valid(mov) then return -1, 0, 0 end
            local mm = mov.MovementMode
            local v = mov.Velocity
            local sq = v and ((v.X * v.X) + (v.Y * v.Y) + (v.Z * v.Z)) or 0
            return mm, sq, (v and v.Z or 0)
        end)
        if okMov then
            st.movMode = type(movMode) == "number" and movMode or -1
            if st.movMode == MOVE_FALLING or (st.movMode ~= -1 and st.movMode ~= MOVE_WALKING and st.movMode ~= MOVE_FLYING) then
                busyReason = "movMode"
            elseif speedSq > maxIdleSpeedSq then
                busyReason = "pawnVel"
                if velZ > maxIdleSpeed or velZ < -maxIdleSpeed then
                    local u = now + airDelaySec
                    if u > st.busyUntil then st.busyUntil = u end
                end
            end
        end
    end

    -- 4. Check CurrentLocomotionDetailStatus on pawn
    if not busyReason then
        local okDet, ds = pcall(function() return pawn:GetCurrentLocomotionDetailStatus() end)
        if okDet and type(ds) == "number" then
            local isIdleDetail = (
                ds == DETAIL_IDLE_MOVE
                or ds == DETAIL_IDLE_STAND_FAR
                or ds == DETAIL_IDLE_STAND_GROUND
                or ds == DETAIL_IDLE_STAND_AIR
            )
            local isOurStun = (st.isFatigued and ds == DETAIL_STUN_STAND)
            if not isIdleDetail and not isOurStun then
                busyReason = "pawnDetail"
            end
        end
    end

    -- 5. Check CurrentRunningAction on LocomotionComponent (blocks actSFL, actCHG, actGRD, etc.)
    if not busyReason and valid(st.locoComp) then
        local okAct, actKey = pcall(function()
            local a = st.locoComp.CurrentRunningAction
            return a and a.Key and a.Key:ToString() or ""
        end)
        if okAct then
            st.actKey = actKey
            if isBusyActionKey(actKey) then
                busyReason = "action=" .. actKey
                -- Descent/jump/fall actions get the extra air/landing stabilization window
                local low = actKey:lower()
                if low:find("sfl", 1, true) or low:find("jmp", 1, true) or low:find("lnd", 1, true) then
                    local u = now + airDelaySec
                    if u > st.busyUntil then st.busyUntil = u end
                end
            end
        end
    end

    if busyReason then
        st.eligible = false
        st.tickBusyReason = busyReason
        local delay = (st.movMode == MOVE_FALLING) and airDelaySec or idleDelaySec
        local untilT = now + delay
        if untilT > st.busyUntil then st.busyUntil = untilT end
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
            st.lastReason = busyReason
            writeLog(string.format("P%d (%s) -> normal stance (%s)", side + 1, st.charKey, busyReason))
        end
        return true
    end

    st.eligible = true
    st.tickBusyReason = ""
    return true
end

-- Runs directly on the Game Thread via throttled call from the hook (zero async threads!)
local function runThrottledTick(now)
    local battle = Controller.getBattle()
    if not battle then
        if inValidBattle or lastBattleKey ~= nil then
            inValidBattle = false
            lastBattleKey = nil
            for s = 0, 1 do
                fighterState[s] = newFighterState()
            end
            locoAddrToSide = {}
        end
        -- Re-check once per second when outside an offline battle (menus, online, replays)
        nextTickClock = now + 1.0
        return
    end

    inValidBattle = true
    if battle.key ~= lastBattleKey then
        lastBattleKey = battle.key
        writeLog("New battle detected: " .. battle.key)
    end

    local anyLowHp = false
    if config.enablePlayer1 and valid(battle.p1) then
        if evaluateFighter(battle.p1, 0, now) then anyLowHp = true end
    end
    if config.enablePlayer2 and valid(battle.p2) then
        if evaluateFighter(battle.p2, 1, now) then anyLowHp = true end
    end

    -- 20Hz (50ms) when any fighter is at Low HP; 10Hz (100ms) when both have healthy HP
    nextTickClock = now + (anyLowHp and 0.05 or 0.10)
end

-- Zero-allocation fast evaluation helper called inside pcall from onPostUpdateCache.
-- Only runs when st.lowHp and st.eligible are ALREADY true!
-- Never accesses non-existent fields (InputVectorCache is FVector2D: X and Y only).
local function _evalAndApplyPostHook(lc, st, now)
    local nState = lc.LocomotionStateCache
    st.nativeState = nState
    if nState ~= LOCO_STATE_IDLE_MOVE then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "nativeState"
        local d = (nState == LOCO_STATE_DASH_UP_DOWN or nState == LOCO_STATE_JUMP) and airDelaySec or idleDelaySec
        if (now + d) > st.busyUntil then st.busyUntil = now + d end
        return
    end

    local nStun = lc.StunReactionStatusCache
    st.nativeStun = nStun
    if nStun ~= STUN_STATUS_OFF then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "nativeStun"
        if (now + idleDelaySec) > st.busyUntil then st.busyUntil = now + idleDelaySec end
        return
    end

    local inAir = (lc.IsInAirCache == true)
    if st.lastInAir ~= nil and st.lastInAir ~= inAir then
        if (now + airDelaySec) > st.busyUntil then st.busyUntil = now + airDelaySec end
    end
    st.lastInAir = inAir

    if config.groundOnly and inAir then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "inAir"
        return
    end

    -- Check critical movement sub-states (DashUpDown, Jump, ShortDash, Step, GroundRunning)
    local dd = lc.DashUpDownStatusCache
    local jp = lc.JumpStatusCache
    local sd = lc.ShortDashStatusCache
    local stp = lc.StepStatusCache
    local gr = lc.GroundRunningState
    st.dashUpDown = dd
    st.jumpStatus = jp
    st.groundRun = gr
    if dd ~= 0 or jp ~= 0 then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = (dd ~= 0) and "DashUpDown" or "Jump"
        if (now + airDelaySec) > st.busyUntil then st.busyUntil = now + airDelaySec end
        return
    end
    if sd ~= 0 or stp ~= 0 or gr ~= 0 then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "subMove"
        if (now + idleDelaySec) > st.busyUntil then st.busyUntil = now + idleDelaySec end
        return
    end

    -- Check vertical & 2D directional input (FVector2D: X, Y only - NEVER touch .Z!)
    local iz = lc.InputZCache
    if iz and (iz > maxInputMag or iz < -maxInputMag) then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "inputZ"
        if (now + airDelaySec) > st.busyUntil then st.busyUntil = now + airDelaySec end
        return
    end

    local iv = lc.InputVectorCache
    if iv ~= nil then
        local ix = iv.X or 0
        local iy = iv.Y or 0
        if (ix * ix + iy * iy) > maxInputMagSq then
            st.isFatigued = false
            st.weOverrode = false
            st.lastReason = "inputXY"
            if (now + idleDelaySec) > st.busyUntil then st.busyUntil = now + idleDelaySec end
            return
        end
    end

    -- Check locomotion speed caches directly (no sqrt!)
    local vz = lc.VelocityZCache
    if vz and (vz > maxIdleSpeed or vz < -maxIdleSpeed) then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "velZ"
        if (now + airDelaySec) > st.busyUntil then st.busyUntil = now + airDelaySec end
        return
    end

    local spd = lc.SpeedCache
    if spd and spd > maxIdleSpeed then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "speed"
        if (now + idleDelaySec) > st.busyUntil then st.busyUntil = now + idleDelaySec end
        return
    end

    -- Check native locomotion detail status
    local det = lc.CurrentLocomotionDetailStatus
    st.nativeDetail = det or -1
    if det ~= nil then
        local isIdleDet = (
            det == DETAIL_IDLE_MOVE
            or det == DETAIL_IDLE_STAND_FAR
            or det == DETAIL_IDLE_STAND_GROUND
            or det == DETAIL_IDLE_STAND_AIR
        )
        local isOurStun = (st.isFatigued and det == DETAIL_STUN_STAND)
        if not isIdleDet and not isOurStun then
            st.isFatigued = false
            st.weOverrode = false
            st.lastReason = "detail"
            if (now + idleDelaySec) > st.busyUntil then st.busyUntil = now + idleDelaySec end
            return
        end
    end

    -- Wait for brief stabilization delay after movement/landing ends
    if now < st.busyUntil then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "stabilizing"
        return
    end

    -- All checks passed: apply visual-only exhausted idle stance!
    lc.LocomotionStateCache = LOCO_STATE_STUN_REACTION
    lc.StunReactionStatusCache = STUN_STATUS_STAND
    lc.StunReactionIsFrontCache = true
    st.weOverrode = true
    st.lastReason = ""
    if not st.isFatigued then
        st.isFatigued = true
        if config.logDebug then
            local sideNum = (st == fighterState[0]) and 1 or 2
            writeLog(string.format("P%d (%s) -> EXHAUSTED STANCE ON (HP=%.0f/%.0f air=%s)", sideNum, st.charKey, st.hp, st.maxHp, tostring(inAir)))
        end
    end
end

-- Synchronous pre-hook: ultra-fast restore ONLY if we overrode a component on the previous frame
local function onPreUpdateCache(selfObj)
    if not inValidBattle or not config.enabled then return end
    if not fighterState[0].weOverrode and not fighterState[1].weOverrode then return end
    local okS, lc = pcall(_getSelf, selfObj)
    if not okS or lc == nil then return end
    local addr = safeAddr(lc)
    local side = locoAddrToSide[addr]
    if side == nil then return end

    local st = fighterState[side]
    if st and st.weOverrode then
        pcall(_clearOverride, lc)
        st.weOverrode = false
    end
end

-- Synchronous post-hook: runs on Game Thread.
-- Drives the throttled HP/battle tick AND applies fatigue with zero heap allocations.
local function onPostUpdateCache(selfObj)
    hookFiredCount = hookFiredCount + 1
    local now = os.clock()

    -- Drive low-frequency HP/battle evaluation directly on Game Thread (no LoopAsync thread!)
    if now >= nextTickClock then
        pcall(runThrottledTick, now)
    end

    if not inValidBattle or not config.enabled then return end

    -- Fast exit if neither fighter is at Low HP (0 reflection reads during ~80% of every match!)
    if not fighterState[0].eligible and not fighterState[1].eligible then
        return
    end

    local okS, lc = pcall(_getSelf, selfObj)
    if not okS or lc == nil then return end
    local addr = safeAddr(lc)
    local side = locoAddrToSide[addr]
    if side == nil then return end

    local st = fighterState[side]
    if not st or not st.eligible then
        st.isFatigued = false
        st.weOverrode = false
        return
    end

    -- Zero-allocation pcall into pre-defined function
    local okEval = pcall(_evalAndApplyPostHook, lc, st, now)
    if not okEval then
        st.isFatigued = false
        st.weOverrode = false
    end
end

-- On-demand diagnostic snapshot (F9 hotkey)
function Controller.dumpDiagnostics(tag)
    writeLog("========== DIAGNOSTIC SNAPSHOT v1.1.0 [" .. tostring(tag or "manual") .. "] ==========", true)
    writeLog(string.format("enabled=%s hooksRegistered=%s hookFiredCount=%d inValidBattle=%s",
        tostring(config.enabled), tostring(hooksRegistered), hookFiredCount, tostring(inValidBattle)), true)

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
                st = fighterState[side]
            end
            local okHp, hp, mhp = pcall(function() return pawn:GetHPGaugeValue(), pawn:GetMaxHPGaugeValue() end)
            local okDet, det = pcall(function() return pawn:GetCurrentLocomotionDetailStatus() end)
            local okChg, chg = pcall(function() return pawn:GetChargeLv() end)
            local okVel, vx, vy, vz, mm = pcall(function()
                local mov = pawn.CharacterMovement
                local v = mov.Velocity
                return v.X, v.Y, v.Z, mov.MovementMode
            end)
            writeLog(string.format(
                "P%d (%s) HP=%.0f/%.0f detail=%s chargeLv=%s movMode=%s vel=(%.1f,%.1f,%.1f) lowHp=%s eligible=%s isFatigued=%s lastReason=%s tickReason=%s",
                side + 1, st.charKey,
                okHp and hp or -1, okHp and mhp or -1,
                tostring(okDet and det or "err"), tostring(okChg and chg or "err"),
                tostring(okVel and mm or "err"),
                okVel and vx or 0, okVel and vy or 0, okVel and vz or 0,
                tostring(st.lowHp), tostring(st.eligible), tostring(st.isFatigued),
                tostring(st.lastReason), tostring(st.tickBusyReason)
            ), true)

            if valid(st.locoComp) then
                local okL, lState, sStat, inAir, actKey, iz = pcall(function()
                    local lc = st.locoComp
                    local ak = lc.CurrentRunningAction and lc.CurrentRunningAction.Key and lc.CurrentRunningAction.Key:ToString() or "None"
                    return lc.LocomotionStateCache, lc.StunReactionStatusCache, lc.IsInAirCache, ak, lc.InputZCache
                end)
                writeLog(string.format(
                    "  LocoComp: ok=%s State=%s(native=%d) Stun=%s(native=%d) InAir=%s Act=%s DashUD=%d Jump=%d GRun=%d InZ=%s",
                    tostring(okL), tostring(lState), st.nativeState, tostring(sStat), st.nativeStun,
                    tostring(inAir), tostring(actKey), st.dashUpDown, st.jumpStatus, st.groundRun, tostring(iz)
                ), true)
            end
        end
    end
    writeLog("=================================================================", true)
end

-- Register synchronous Game-Thread hook on KoratCharacterLocomotionComponent
function Controller.registerHooks()
    if hooksRegistered then return end
    local fnPath = "/Script/SS.KoratCharacterLocomotionComponent:UpdateLocomotionParameterCache"
    local ok, preId, postId = pcall(function()
        return RegisterHook(fnPath, onPreUpdateCache, onPostUpdateCache)
    end)
    if ok and preId then
        table.insert(registeredHooks, { path = fnPath, pre = preId, post = postId })
        writeLog("Hook registered: " .. fnPath)
    else
        writeLog("Hook unavailable: " .. fnPath)
    end
    hooksRegistered = true
end

function Controller.unregisterHooks()
    for s = 0, 1 do
        local st = fighterState[s]
        if st and (st.isFatigued or st.weOverrode) then
            clearFatigueSafe(st.locoComp, st)
        end
    end
    for i = 1, #registeredHooks do
        local h = registeredHooks[i]
        pcall(UnregisterHook, h.path, h.pre, h.post)
    end
    registeredHooks = {}
    hooksRegistered = false
    inValidBattle = false
    lastBattleKey = nil
    locoAddrToSide = {}
    nextTickClock = 0
end

function Controller.init()
    clearLog()
    maxIdleSpeed    = config.maxIdleSpeed or 25.0
    maxIdleSpeedSq  = maxIdleSpeed * maxIdleSpeed
    maxInputMag     = config.maxInputMagnitude or 0.05
    maxInputMagSq   = maxInputMag * maxInputMag
    idleDelaySec    = config.idleDelaySec or 0.08
    airDelaySec     = config.airTransitionDelaySec or 0.25
    nextTickClock   = 0
    print("[BattleFatigue] v1.1.0 loaded (Zero-Overhead Single-Thread | Ground & Air | <= " .. tostring(config.hpThreshold) .. " HP)")
    Controller.registerHooks()
end

function Controller.toggleEnabled()
    config.enabled = not config.enabled
    print("[BattleFatigue] Toggled: enabled = " .. tostring(config.enabled))
    if not config.enabled then
        for s = 0, 1 do
            local st = fighterState[s]
            if st then
                st.eligible = false
                if st.isFatigued or st.weOverrode then
                    clearFatigueSafe(st.locoComp, st)
                end
            end
        end
    end
end

return Controller
