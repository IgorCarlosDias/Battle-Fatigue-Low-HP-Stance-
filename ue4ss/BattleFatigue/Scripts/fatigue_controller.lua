-- Battle Fatigue (Low HP Stance) - Core Controller v1.0.1
-- Dragon Ball: Sparking! ZERO
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

-- Sub-status cache properties on KoratCharacterLocomotionComponent (all verified: 0 = OFF/None)
local SUB_STATUS_FIELDS = {
    "DashUpDownStatusCache",
    "JumpStatusCache",
    "ShortDashStatusCache",
    "StepStatusCache",
    "DragonDashStatusCache",
    "BlowStatusCache",
    "DragonHomingStatusCache",
    "RevengeDashStatusCache",
    "BlastDashStatusCache",
    "HighSpeedMoveStatusCache",
    "ZBurstDashStatusCache",
    "DashUkemiStatusCache",
    "WallUkemiStatusCache",
    "GroundRunningState"
}

-- Optional numeric cache fields probed once per spawn so missing fields never break reads
local OPTIONAL_FIELDS = {
    "CurrentLocomotionDetailStatus",
    "SpeedCache",
    "XYSpeedCache",
    "ZSpeedCache",
    "VelocityZCache",
    "DashUpDownTypeCache"
}

-- Action key substrings that clearly represent active combat/charging/descent/landing moves
local BUSY_ACTION_PATTERNS = {
    "chg", "grd", "spm", "ult", "exa", "frmc",
    "rsh", "smb", "kdn", "trw", "atk", "cnt",
    "pry", "dmg", "blw", "dwn", "lta", "hse", "uppf",
    "jmp", "dsh", "stp", "lnd", "fln", "fal", "sfl"
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
local function newFighterState()
    return {
        addr = 0,
        charKey = "",
        pawn = nil,
        locoComp = nil,
        montageComp = nil,
        validSubFields = {},
        caps = {},
        -- Eligibility calculated on the 33ms tick (HP, online guard, chargeLv, finishDemo, MovementMode)
        eligible = false,
        tickBusyReason = "",
        movMode = -1,
        pawnSpeed = 0,
        pawnVelZ = 0,
        hp = 0,
        maxHp = 0,
        -- Live state maintained synchronously inside UpdateLocomotionParameterCache pre/post hook
        weOverrode = false,
        isFatigued = false,
        lastReason = "",
        lastInAir = nil,
        busyUntil = 0,
        -- Native (unmodified) snapshot captured on each UpdateLocomotionParameterCache call
        nativeState = -1,
        nativeStun = -1,
        nativeDetail = -1,
        dashUpDown = 0,
        dashUpDownType = 0,
        jumpStatus = 0,
        groundRun = 0,
        actKey = "",
        sectionName = "",
        inAir = false,
        speed = 0,
        velZ = 0,
        inMag = 0,
        inZ = 0,
        -- Compact ring buffer of recent state transitions for F9 diagnostics
        lastCoreErr = "",
        history = {},
        lastHistSig = ""
    }
end

local fighterState = {
    [0] = newFighterState(),
    [1] = newFighterState()
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
            f:write("=== Battle Fatigue v1.0.1 Runtime Log (" .. os.date("%Y-%m-%d %H:%M:%S") .. ") ===\n")
            f:close()
        end
    end
end

local function pushHistory(st)
    local sig = string.format(
        "ns=%d st=%d dd=%d jp=%d gr=%d air=%s mm=%d act=%s sec=%s fat=%s r=%s",
        st.nativeState, st.nativeStun, st.dashUpDown, st.jumpStatus, st.groundRun,
        tostring(st.inAir), st.movMode, st.actKey, st.sectionName,
        tostring(st.isFatigued), st.lastReason
    )
    if sig == st.lastHistSig then return end
    st.lastHistSig = sig
    local h = st.history
    h[#h + 1] = string.format("[%.2f] %s | spd=%.0f vz=%.0f in=%.2f iz=%.2f det=%d",
        os.clock(), sig, st.speed, st.velZ, st.inMag, st.inZ, st.nativeDetail)
    if #h > 30 then
        table.remove(h, 1)
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

-- Safely clear ONLY our own fatigue override; NEVER overwrite a real game state (e.g. DashUpDown / Jump / Blow)
local function clearFatigueSafe(locoComp, st)
    if valid(locoComp) then
        pcall(function()
            if locoComp.LocomotionStateCache == LOCO_STATE_STUN_REACTION
               and locoComp.StunReactionStatusCache == STUN_STATUS_STAND then
                locoComp.LocomotionStateCache = LOCO_STATE_IDLE_MOVE
                locoComp.StunReactionStatusCache = STUN_STATUS_OFF
            end
        end)
    end
    if st then
        st.weOverrode = false
        st.isFatigued = false
    end
end

-- Apply visual fatigue override (called ONLY from synchronous postHook after verifying native state is IdleMove)
local function applyFatigueOverride(locoComp, st)
    if not valid(locoComp) then return false end
    local ok = pcall(function()
        locoComp.LocomotionStateCache = LOCO_STATE_STUN_REACTION
        locoComp.StunReactionStatusCache = STUN_STATUS_STAND
        locoComp.StunReactionIsFrontCache = true
    end)
    if ok and st then
        st.weOverrode = true
        st.isFatigued = true
    end
    return ok
end

-- Resolve fighter's locomotion component ONCE per character spawn (zero per-frame FindAllOf)
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

    -- Probe which sub-status and optional cache fields exist on this locomotion component once at spawn
    if valid(st.locoComp) then
        for _, field in ipairs(SUB_STATUS_FIELDS) do
            local okF, val = pcall(function() return st.locoComp[field] end)
            if okF and type(val) == "number" then
                st.validSubFields[#st.validSubFields + 1] = field
            end
        end
        for _, field in ipairs(OPTIONAL_FIELDS) do
            local okF, val = pcall(function() return st.locoComp[field] end)
            if okF and val ~= nil then
                st.caps[field] = true
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

    writeLog(string.format(
        "Resolved P%d (%s) | LocoComp=%s | SubFields=%d",
        side + 1, st.charKey, safeName(st.locoComp), #st.validSubFields
    ))
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

-- Periodic 33ms evaluation: checks battle/HP/charge/finishDemo/MovementMode eligibility ONLY.
-- Actual animation override happens synchronously inside UpdateLocomotionParameterCache postHook.
local function evaluateFighter(pawn, side)
    local st = fighterState[side]
    if not valid(pawn) then
        st.eligible = false
        st.isFatigued = false
        st.weOverrode = false
        return
    end

    if safeAddr(pawn) ~= st.addr then
        resolveFighterComponents(pawn, side)
        st = fighterState[side]
    end
    st.pawn = pawn

    if not config.enabled then
        st.eligible = false
        st.tickBusyReason = "disabled"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
        end
        return
    end

    -- 1. Check HP (Red bar = <= 10,000 HP)
    local okHp, hp, maxHp = pcall(function()
        return pawn:GetHPGaugeValue(), pawn:GetMaxHPGaugeValue()
    end)
    if not okHp or not hp or not maxHp or hp <= 0 or maxHp <= 0 then
        st.eligible = false
        st.tickBusyReason = "invalidHP"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
        end
        return
    end
    st.hp = hp
    st.maxHp = maxHp

    local isLowHp
    if maxHp > config.hpThreshold then
        isLowHp = (hp <= config.hpThreshold)
    else
        isLowHp = ((hp / maxHp) <= config.fallbackRatio)
    end

    if not isLowHp then
        st.eligible = false
        st.tickBusyReason = "hpOK"
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
            writeLog(string.format("P%d (%s) HP recovered (%.0f/%.0f) -> normal stance", side + 1, st.charKey, hp, maxHp))
        end
        return
    end

    local busyReason = nil

    -- 2. Check active Ki charge level
    local okCharge, chargeLv = pcall(function() return pawn:GetChargeLv() end)
    if okCharge and type(chargeLv) == "number" and chargeLv > 0 then
        busyReason = "charging(lv=" .. tostring(chargeLv) .. ")"
    end

    -- 3. Check finish demo
    if not busyReason then
        local okDemo, finishDemo = pcall(function() return pawn.bIsFinishDemo end)
        if okDemo and finishDemo then
            busyReason = "finishDemo"
        end
    end

    -- 4. Check CharacterMovement MovementMode & 3D Velocity (block Falling / moving)
    local okMov, movMode, speedSq, velZ = pcall(function()
        local mov = pawn.CharacterMovement
        if not valid(mov) then return -1, 0, 0 end
        local mm = mov.MovementMode
        local v = mov.Velocity
        local sq = v and ((v.X * v.X) + (v.Y * v.Y) + (v.Z * v.Z)) or 0
        return mm, sq, v and v.Z or 0
    end)
    if okMov then
        st.movMode = type(movMode) == "number" and movMode or -1
        st.pawnSpeed = math.sqrt(speedSq)
        st.pawnVelZ = velZ
        if not busyReason then
            -- Never trigger while falling (3) or in non-Walking/Flying transition modes
            if st.movMode == MOVE_FALLING or (st.movMode ~= -1 and st.movMode ~= MOVE_WALKING and st.movMode ~= MOVE_FLYING) then
                busyReason = "movMode=" .. tostring(st.movMode)
            elseif speedSq > (config.maxIdleSpeed * config.maxIdleSpeed) then
                busyReason = string.format("pawnVel=%.0f", st.pawnSpeed)
            end
        end
    end

    -- 5. Check CurrentLocomotionDetailStatus on pawn
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
                busyReason = "pawnDetail=" .. tostring(ds)
            end
        end
    end

    if busyReason then
        st.eligible = false
        st.tickBusyReason = busyReason
        local isAirMove = (st.movMode == MOVE_FALLING) or (math.abs(st.pawnVelZ) > (config.maxIdleSpeed or 25.0))
        local delay = isAirMove and (config.airTransitionDelaySec or 0.30) or (config.idleDelaySec or 0.15)
        local untilT = os.clock() + delay
        if untilT > st.busyUntil then st.busyUntil = untilT end
        if st.isFatigued or st.weOverrode then
            clearFatigueSafe(st.locoComp, st)
            st.lastReason = busyReason
            pushHistory(st)
            writeLog(string.format("P%d (%s) -> normal stance (%s)", side + 1, st.charKey, busyReason))
        end
        return
    end

    st.eligible = true
    st.tickBusyReason = ""
end

-- Synchronous pre-hook: restore clean IdleMove before Unreal recalculates caches
-- so UpdateLocomotionParameterCache never mistakes our visual override for a real stun.
local function onPreUpdateCache(selfObj)
    local lc = selfObj and selfObj:get() or nil
    local addr = safeAddr(lc)
    local side = locoAddrToSide[addr]
    if side == nil then return end

    local st = fighterState[side]
    if st and st.weOverrode then
        pcall(function()
            if lc.LocomotionStateCache == LOCO_STATE_STUN_REACTION
               and lc.StunReactionStatusCache == STUN_STATUS_STAND then
                lc.LocomotionStateCache = LOCO_STATE_IDLE_MOVE
                lc.StunReactionStatusCache = STUN_STATUS_OFF
            end
        end)
        st.weOverrode = false
    end
end

-- Synchronous post-hook: inspect the EXACT native caches Unreal just computed this frame.
-- ONLY apply visual fatigue if the fighter is genuinely in native IdleMove with all sub-states OFF,
-- zero input, zero velocity, and past the stabilization delay.
local function onPostUpdateCache(selfObj)
    hookFiredCount = hookFiredCount + 1
    local lc = selfObj and selfObj:get() or nil
    local addr = safeAddr(lc)
    local side = locoAddrToSide[addr]
    if side == nil then return end

    local st = fighterState[side]
    if not st then return end

    local now = os.clock()

    -- Read core verified locomotion cache values computed by C++ this exact frame
    local okCore, nState, nStun, inAir = pcall(function()
        return lc.LocomotionStateCache, lc.StunReactionStatusCache, (lc.IsInAirCache == true)
    end)

    if not okCore then
        st.lastCoreErr = tostring(nState)
        st.isFatigued = false
        st.weOverrode = false
        return
    end
    st.lastCoreErr = ""

    -- Read input vector safely (FVector2D has X/Y without Z; InputZCache is separate!)
    local inMag, inZ = 0, 0
    pcall(function()
        local iv = lc.InputVectorCache
        if iv ~= nil then
            local ix = iv.X or 0
            local iy = iv.Y or 0
            local okZ, izVal = pcall(function() return iv.Z end)
            local iz0 = (okZ and type(izVal) == "number") and izVal or 0
            inMag = math.sqrt((ix * ix) + (iy * iy) + (iz0 * iz0))
        end
    end)
    pcall(function()
        inZ = math.abs(lc.InputZCache or 0)
    end)

    -- Read current running action & section safely
    local actKey, secName = "", ""
    pcall(function()
        local a = lc.CurrentRunningAction
        if a and a.Key then
            actKey = a.Key:ToString() or ""
        end
    end)
    pcall(function()
        local sec = lc.CurrentRunningSection
        if sec then
            secName = sec:ToString() or ""
        end
    end)

    -- Read optional probed fields safely
    local caps = st.caps
    local nDet = -1
    local spd, xySpd, zSpd, velZ = st.pawnSpeed, 0, 0, st.pawnVelZ
    local ddType = 0

    pcall(function()
        if caps.CurrentLocomotionDetailStatus then nDet = lc.CurrentLocomotionDetailStatus or -1 end
        if caps.SpeedCache then spd = lc.SpeedCache or 0 end
        if caps.XYSpeedCache then xySpd = lc.XYSpeedCache or 0 end
        if caps.ZSpeedCache then zSpd = lc.ZSpeedCache or 0 end
        if caps.VelocityZCache then velZ = lc.VelocityZCache or 0 end
        if caps.DashUpDownTypeCache then ddType = lc.DashUpDownTypeCache or 0 end
    end)

    st.nativeState = type(nState) == "number" and nState or -1
    st.nativeStun = type(nStun) == "number" and nStun or -1
    st.nativeDetail = type(nDet) == "number" and nDet or -1
    st.inAir = inAir
    st.speed = spd
    st.velZ = velZ
    st.inMag = inMag
    st.inZ = inZ
    st.actKey = actKey
    st.sectionName = secName
    st.dashUpDownType = type(ddType) == "number" and ddType or 0

    -- Detect air <-> ground transition (landing / takeoff) and grant a cooldown window
    if st.lastInAir ~= nil and st.lastInAir ~= inAir then
        local airDelay = config.airTransitionDelaySec or 0.30
        if (now + airDelay) > st.busyUntil then
            st.busyUntil = now + airDelay
        end
    end
    st.lastInAir = inAir

    -- Check all locomotion sub-status caches (DashUpDown, Jump, Step, ShortDash, Blow, etc.)
    local activeSubField = nil
    local activeSubVal = 0
    st.dashUpDown = 0
    st.jumpStatus = 0
    st.groundRun = 0

    for _, field in ipairs(st.validSubFields) do
        local okF, val = pcall(function() return lc[field] end)
        if okF and type(val) == "number" then
            if field == "DashUpDownStatusCache" then st.dashUpDown = val end
            if field == "JumpStatusCache" then st.jumpStatus = val end
            if field == "GroundRunningState" then st.groundRun = val end
            if val ~= 0 and not activeSubField then
                activeSubField = field
                activeSubVal = val
            end
        end
    end

    -- Evaluate synchronous busy reason for this exact frame
    local reason = nil
    local isTransitionBusy = false
    local maxSpd = config.maxIdleSpeed or 25.0
    local maxIn = config.maxInputMagnitude or 0.05

    if not config.enabled then
        reason = "disabled"
    elseif not st.eligible then
        reason = st.tickBusyReason ~= "" and st.tickBusyReason or "notEligible"
    elseif config.groundOnly and inAir then
        reason = "inAir(groundOnly)"
    elseif st.nativeState ~= LOCO_STATE_IDLE_MOVE then
        reason = "nativeState=" .. tostring(st.nativeState)
        if st.nativeState == LOCO_STATE_DASH_UP_DOWN or st.nativeState == LOCO_STATE_JUMP then
            isTransitionBusy = true
        end
    elseif st.nativeStun ~= STUN_STATUS_OFF then
        reason = "nativeStun=" .. tostring(st.nativeStun)
    elseif activeSubField then
        reason = activeSubField .. "=" .. tostring(activeSubVal)
        if activeSubField == "DashUpDownStatusCache" or activeSubField == "JumpStatusCache" then
            isTransitionBusy = true
        end
    elseif inMag > maxIn or inZ > maxIn then
        reason = string.format("input(%.2f,z=%.2f)", inMag, inZ)
        if inZ > maxIn then
            isTransitionBusy = true
        end
    elseif spd > maxSpd or xySpd > maxSpd or zSpd > maxSpd or math.abs(velZ) > maxSpd then
        reason = string.format("speed(%.0f,vz=%.0f)", spd, velZ)
        if math.abs(velZ) > maxSpd then
            isTransitionBusy = true
        end
    elseif isBusyActionKey(actKey) then
        reason = "action=" .. actKey
    else
        local isIdleDetail = (
            st.nativeDetail == DETAIL_IDLE_MOVE
            or st.nativeDetail == DETAIL_IDLE_STAND_FAR
            or st.nativeDetail == DETAIL_IDLE_STAND_GROUND
            or st.nativeDetail == DETAIL_IDLE_STAND_AIR
        )
        local isOurStun = (st.isFatigued and st.nativeDetail == DETAIL_STUN_STAND)
        if st.nativeDetail >= 0 and not isIdleDetail and not isOurStun then
            reason = "detail=" .. tostring(st.nativeDetail)
        end
    end

    if reason then
        -- Extend stabilization delay whenever actively moving, inputting, or landing/ascending/descending
        if reason ~= "disabled" and reason ~= "hpOK" and reason ~= "invalidHP" and reason ~= "notEligible" then
            local delay = isTransitionBusy and (config.airTransitionDelaySec or 0.30) or (config.idleDelaySec or 0.15)
            if (now + delay) > st.busyUntil then
                st.busyUntil = now + delay
            end
        end
        if st.isFatigued then
            st.isFatigued = false
            writeLog(string.format("P%d (%s) -> normal stance (%s)", side + 1, st.charKey, reason))
        end
        st.weOverrode = false
        st.lastReason = reason
        pushHistory(st)
        return
    end

    -- Wait for brief stabilization window after movement/landing ends
    if now < st.busyUntil then
        st.isFatigued = false
        st.weOverrode = false
        st.lastReason = "stabilizing"
        pushHistory(st)
        return
    end

    -- All synchronous & tick safety checks passed: apply visual-only exhausted idle stance!
    local wasFatigued = st.isFatigued
    local applied = applyFatigueOverride(lc, st)
    st.lastReason = ""
    pushHistory(st)
    if not wasFatigued and applied then
        writeLog(string.format(
            "P%d (%s) -> EXHAUSTED STANCE ON (HP=%.0f/%.0f air=%s act=%s sec=%s det=%d)",
            side + 1, st.charKey, st.hp, st.maxHp, tostring(inAir), actKey, secName, st.nativeDetail
        ))
    end
end

-- On-demand diagnostic snapshot (F9 hotkey)
function Controller.dumpDiagnostics(tag)
    writeLog("========== DIAGNOSTIC SNAPSHOT v1.0.1 [" .. tostring(tag or "manual") .. "] ==========", true)
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
                "P%d (%s) HP=%.0f/%.0f detail=%s chargeLv=%s movMode=%s vel=(%.1f,%.1f,%.1f) eligible=%s isFatigued=%s lastReason=%s",
                side + 1, st.charKey,
                okHp and hp or -1, okHp and mhp or -1,
                tostring(okDet and det or "err"), tostring(okChg and chg or "err"),
                tostring(okVel and mm or "err"),
                okVel and vx or 0, okVel and vy or 0, okVel and vz or 0,
                tostring(st.eligible), tostring(st.isFatigued), tostring(st.lastReason)
            ), true)

            if valid(st.locoComp) then
                local okL, lState, sStat, inAir, actKey, secName, iz = pcall(function()
                    local lc = st.locoComp
                    local ak = lc.CurrentRunningAction and lc.CurrentRunningAction.Key and lc.CurrentRunningAction.Key:ToString() or "None"
                    local sn = lc.CurrentRunningSection and lc.CurrentRunningSection:ToString() or "None"
                    return lc.LocomotionStateCache, lc.StunReactionStatusCache, lc.IsInAirCache, ak, sn, lc.InputZCache
                end)
                writeLog(string.format(
                    "  LocoComp: ok=%s State=%s(native=%d) Stun=%s(native=%d) InAir=%s Act=%s Sec=%s DashUD=%d(type=%d) Jump=%d GRun=%d InZ=%s SubFields=%d CoreErr=%s",
                    tostring(okL), tostring(lState), st.nativeState, tostring(sStat), st.nativeStun,
                    tostring(inAir), tostring(actKey), tostring(secName),
                    st.dashUpDown, st.dashUpDownType, st.jumpStatus, st.groundRun, tostring(iz), #st.validSubFields, tostring(st.lastCoreErr)
                ), true)
            end

            if #st.history > 0 then
                writeLog("  Recent transitions (" .. tostring(#st.history) .. "):", true)
                local startIdx = math.max(1, #st.history - 14)
                for i = startIdx, #st.history do
                    writeLog("    " .. st.history[i], true)
                end
            end
        end
    end
    writeLog("=================================================================", true)
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
            return RegisterHook(fnPath, onPreUpdateCache, onPostUpdateCache)
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
    for s = 0, 1 do
        local st = fighterState[s]
        if st and (st.isFatigued or st.weOverrode) then
            clearFatigueSafe(st.locoComp, st)
        end
    end
    for _, h in ipairs(registeredHooks) do
        pcall(function() UnregisterHook(h.path, h.pre, h.post) end)
    end
    registeredHooks = {}
    hooksRegistered = false
end

function Controller.init()
    clearLog()
    print("[BattleFatigue] v1.0.1 loaded (Ground & Air | Last Red Bar <= " .. tostring(config.hpThreshold) .. " HP)")
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

function Controller.tick()
    local battle = Controller.getBattle()
    if not battle then
        if lastBattleKey ~= nil then
            lastBattleKey = nil
            battleSnapshotLogged = false
            for s = 0, 1 do
                fighterState[s] = newFighterState()
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
