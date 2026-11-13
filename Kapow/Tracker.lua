-- Tracker: listens to the game and turns what happens into HUD effects.
--
-- This client has no combat log for addons and hides some numbers in combat ("secret"
-- values: energy, aura and cooldown data). So:
--   * energy goes straight to the widgets; ticks, spending and "full" are worked out from
--     exact numbers when we have them and from event timing when we don't;
--   * what you did comes from your own spell casts (never hidden);
--   * crowd control and cooldown boxes run on known durations, corrected by the real aura
--     or cooldown whenever the game lets us read it.
local _, K = ...
local T = {}
K.Tracker = T
local C = K.C
local IsSecret = K.IsSecret
local HUD, FX, Timers, Spells

-- The other modules, once the HUD is built.
function T.Bind()
    HUD, FX, Timers, Spells = K.HUD, K.FX, K.Timers, K.Spells
    Spells:Init()
end

local ENERGY = Enum and Enum.PowerType and Enum.PowerType.Energy or 3

-- Abilities that stop a spell cast: if the target's cast breaks right as one lands, DENIED!
local STOPPERS = { kick = true, gouge = true, kidney = true, cheap = true, blind = true }

local MISSES = {
    DODGE = "DODGED!", PARRY = "PARRIED!", MISS = "MISS!", BLOCK = "BLOCKED!",
    IMMUNE = "IMMUNE!", RESIST = "RESIST!", EVADE = "EVADE!", DEFLECT = "DEFLECT!",
}

local E = { max = 100, lastGain = 0, lastSpend = 0, lastCost = -10, fast = 0 }
local TICK_GAP = 1.6 -- regen ticks are two seconds apart; gains closer together are not ticks
T.energy = E

-- A plain true/false out of something that might be hidden.
local function Bool(v)
    if IsSecret(v) then return false end
    return v and true or false
end

-- In a party or raid. Some things cannot be told apart from what your groupmates do
-- (whose crit that was, who got the kill), so those effects only show when you are alone.
local function Grouped()
    return IsInGroup and Bool(IsInGroup()) or false
end

--------------------------------------------------------------------------------
-- The bigger moments (shared with the demo)
--------------------------------------------------------------------------------
local Show = {}
T.Show = Show

function Show.Crit(amount)
    local x, y = FX:Word("CRIT!", { color = C.red, shape = "burst2", size = 1.0, sub = amount, textColor = C.yellow })
    if x then FX:Sparks(x, y, C.yellow, 5, 44) end
    HUD:Shake(3, 0.18)
end

function Show.Miss(word)
    FX:Word(word, { color = C.grey, shape = "cloud", size = 0.72, textColor = C.paper, hold = 0.3 })
end

function Show.Denied()
    local x, y = FX:Word("DENIED!", { color = C.red, shape = "burst2", size = 1.1, textColor = C.yellow, hold = 0.55 })
    if x then FX:Flourish(x, y, C.cyan, 1) end
    HUD:Shake(4, 0.22)
end

function Show.KO()
    local x, y = FX:Word("K.O.!", { color = C.yellow, shape = "burst2", size = 1.15, textColor = C.red, hold = 0.6 })
    if x then FX:Flourish(x, y, C.yellow, 1) end
end

--------------------------------------------------------------------------------
-- Energy
--------------------------------------------------------------------------------
local function SetFull(full)
    HUD:SetFull(full, HUD.inCombat)
end

-- Energy either arrives in two-second ticks or trickles in continuously. Gains that keep
-- coming less than a second apart mean trickling: then there are no ticks to show, only the
-- bar filling.
local function Trickling(now)
    local gap = now - (E.lastGain or 0)
    if gap < 1.0 then
        E.fast = E.fast + 1
    elseif gap > 2.5 then
        E.fast = 0
    end
    if E.fast >= 3 and E.mode ~= "smooth" then
        E.mode = "smooth"
        E.lastTick = nil
        HUD:SetTickClock(nil)
    elseif E.fast == 0 and E.mode == "smooth" then
        E.mode = nil
    end
    return E.mode == "smooth"
end

local function TickDue(now)
    return not E.lastTick or now - E.lastTick >= TICK_GAP
end

-- d: how much was gained, or nil if the game hides it. v: the new value, or nil.
local function Gain(d, now, v, prev)
    local smooth = Trickling(now)
    E.lastGain = now
    if d and d > 45 then
        HUD:Refill(d, v) -- Thistle Tea and the like
    elseif smooth then
        if d then HUD:CellCross(prev, v) end
    elseif TickDue(now) and (not d or d >= 10) then
        E.mode = "tick"
        E.lastTick = now
        HUD:SetTickClock(now)
        HUD:Tick(d, v)
    elseif d then
        HUD:CellCross(prev, v)
    end
end

function T:Energy(instant)
    if K.demo then return end
    local v = UnitPower("player", ENERGY)
    local m = UnitPowerMax("player", ENERGY)
    if IsSecret(m) or type(m) ~= "number" or m <= 0 then m = E.max end
    E.max = m
    HUD:SetEnergy(v, m, instant)

    local now = GetTime()
    if not IsSecret(v) then
        local prev = E.val
        E.val, E.known = v, true
        E.pending = nil
        if prev and not instant then
            local d = v - prev
            if d > 0 then
                Gain(d, now, v, prev)
            elseif d < 0 then
                E.lastSpend = now
                HUD:Spend(-d)
            end
        end
        SetFull(v >= m)
    else
        if E.known ~= false then
            -- just went dark: assume we were not sitting at full unless we knew we were
            if E.val and E.val < m then E.lastGain = now end
            E.known, E.val = false, nil
        end
        -- Sort this change into "spent" or "gained" a moment later, once the cast event
        -- that may explain it has had time to arrive.
        E.pending = E.pending or now
    end
end

--------------------------------------------------------------------------------
-- Combo points
--------------------------------------------------------------------------------
function T:Combo(quiet)
    if K.demo then return end
    local ok, cp = pcall(GetComboPoints, "player", "target")
    if not ok then cp = 0 end
    if IsSecret(cp) then
        T.cp = nil
        HUD:SetComboSecret(cp)
        return
    end
    cp = cp or 0
    local prev = T.cp or 0
    if cp < prev then
        T.cpDropFrom, T.cpDropAt = prev, GetTime()
    end
    T.cp = cp
    HUD:SetCombo(cp, quiet)
end

-- How many points the finisher that was just cast used. The cast and the combo update can
-- arrive in either order.
local function ComboSpent(now)
    if T.cp and T.cp > 0 then return T.cp end
    if T.cpDropAt and now - T.cpDropAt < 0.7 then return T.cpDropFrom end
    return 0
end

--------------------------------------------------------------------------------
-- Your casts
--------------------------------------------------------------------------------
local slashSide = 1

local function Announce(def, cp)
    if not K.db.words then return end
    local size, big, sub, hold = def.size or 1, def.big, def.sub, nil
    if def.finisher then
        size = 0.8 + 0.06 * cp
        big = cp >= 5
        hold = 0.55
        if cp > 0 then sub = cp .. (cp == 1 and " POINT" or " POINTS") end
    end
    local x, y = FX:Word(def.word, {
        color = def.color, size = size, shape = def.shape, big = big, sub = sub,
        textColor = def.textColor, hold = hold,
    })
    if not x then return end
    if def.slash then
        slashSide = -slashSide
        FX:Slash(x, y - 2, C.white, slashSide * (0.35 + math.random() * 0.4), (110 * size + 50) * (K.db.fx or 1))
    end
    if big then
        FX:Flourish(x, y, def.color, 1)
        HUD:Shake(4, 0.24)
    elseif def.finisher then
        FX:Ring(x, y, def.color, 30, 110, 0.3)
    end
end

T.Announce = Announce

local function StartCooldown(def, spellID)
    local key = "cd:" .. def.key
    Timers:Start(key, {
        label = def.short, icon = def.icon, duration = def.cd, kind = "cd",
        ready = def.short .. " READY!",
    })
    -- Use the real cooldown if the game will say (talents can shorten it).
    K.After(0.15, function()
        if not (C_Spell and C_Spell.GetSpellCooldown) then return end
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if not ok or IsSecret(info) or type(info) ~= "table" then return end
        local start, dur = info.startTime, info.duration
        if IsSecret(start) or IsSecret(dur) or type(start) ~= "number" or type(dur) ~= "number" then return end
        if dur > 2 and start + dur > GetTime() + 1 then Timers:Adjust(key, start + dur, dur) end
    end)
end

local function StartAura(def, spellID, cp)
    local a = def.aura
    local dur = a.dur
    if type(dur) == "function" then dur = dur(math.max(cp, 1), spellID) end
    if not dur or dur <= 0 then return end
    Timers:Start("aura:" .. def.key, {
        label = a.short, icon = def.icon, duration = dur, kind = a.kind,
        unit = a.unit, spell = def.name, attached = true, born = GetTime(),
    })
    K.After(0.25, function() T:RefineAuras(a.unit) end)
    K.After(0.7, function() T:RefineAuras(a.unit) end)
end

-- Checks our countdown boxes against the unit's real auras, when those are readable:
-- fixes the end time, and drops a box whose effect never landed or has broken.
function T:RefineAuras(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return end
    local hidden = true
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and not IsSecret(v) then hidden = v and true or false end
    end
    local now = GetTime()
    local filter = (unit == "player") and "HELPFUL" or "HARMFUL|PLAYER"
    Timers:Each(function(t)
        if t.unit ~= unit or not t.spell then return end
        local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, t.spell, filter)
        if not ok or IsSecret(aura) then return end
        if type(aura) == "table" then
            local exp, dur = aura.expirationTime, aura.duration
            if not IsSecret(exp) and not IsSecret(dur) and type(exp) == "number" and type(dur) == "number"
                and dur > 0 and exp > now then
                t.attached = true
                Timers:Adjust(t.key, exp, dur)
            end
        elseif aura == nil and t.attached and not hidden and now - t.born > 0.5 then
            Timers:Stop(t.key)
        end
    end)
end

local function Denied()
    T.stopAt, T.interruptAt = nil, nil
    if K.db.words then Show.Denied() end
end

function T:Cast(spellID)
    if IsSecret(spellID) or type(spellID) ~= "number" then return end
    local now = GetTime()
    T.lastCastAt = now

    local cost = Spells:EnergyCost(spellID)
    if cost > 0 then
        E.lastCost, E.lastSpend = now, now
        if E.known == false then HUD:Spend(cost) else HUD:ExpectSpend() end
    end

    local def = Spells:Find(spellID)
    if not def then return end
    local cp = def.finisher and ComboSpent(now) or 0
    Announce(def, cp)
    if def.cd then StartCooldown(def, spellID) end
    if def.aura then StartAura(def, spellID, cp) end
    if def.key == "riposte" then Timers:Stop("riposte") end
    if STOPPERS[def.key] then
        T.stopAt = now
        if T.interruptAt and now - T.interruptAt < 0.5 then Denied() end
    end
    T:UpdatePrompt()
end

--------------------------------------------------------------------------------
-- The target
--------------------------------------------------------------------------------
local function IsCasting(unit)
    if UnitCastingInfo then
        local ok, name = pcall(UnitCastingInfo, unit)
        if ok and (IsSecret(name) or name ~= nil) then return true end
    end
    if UnitChannelInfo then
        local ok, name = pcall(UnitChannelInfo, unit)
        if ok and (IsSecret(name) or name ~= nil) then return true end
    end
    return false
end

-- KICK IT! while the target is casting and Kick is ready.
function T:UpdatePrompt()
    local show = false
    if T.casting and K.db.prompt and HUD.hasTarget then
        local kick = Spells:Get("kick")
        if kick and Timers:Remaining("cd:kick") <= 0 and C_Spell and C_Spell.IsSpellUsable then
            local ok, usable = pcall(C_Spell.IsSpellUsable, kick.id)
            if ok and Bool(usable) then show = true end
        end
    end
    HUD:SetPrompt(show and "KICK IT!" or nil)
end

function T:TargetCasting(on)
    T.casting = on
    T.castStart = on and GetTime() or nil
    T:UpdatePrompt()
end

-- by: who broke the cast, when the game says (it may be missing or hidden).
function T:Interrupted(by)
    local now = GetTime()
    T:TargetCasting(false)
    local mine -- true, false, or nil when we cannot tell
    if not IsSecret(by) and type(by) == "string" then
        local me = UnitGUID and UnitGUID("player")
        if not IsSecret(me) and type(me) == "string" then mine = (by == me) end
    end
    -- Without a name on it, an interrupt that lands as you kick is yours when you are
    -- alone; in a group it could be anyone's, so it does not count.
    if mine == nil then mine = not Grouped() end
    if not mine then
        T.interruptAt = nil
        return
    end
    T.interruptAt = now
    if T.stopAt and now - T.stopAt < 0.7 then Denied() end
end

function T:TargetChanged()
    local exists = Bool(UnitExists("target"))
    local hostile = exists and Bool(UnitCanAttack("player", "target")) and not Bool(UnitIsDead("target"))
    HUD.hasTarget = hostile
    T.koDone = not hostile
    T.casting = hostile and IsCasting("target")
    T.castStart = T.casting and GetTime() or nil
    T:UpdatePrompt()
    T:Combo(true)
    -- Countdowns keep running for the old target (that is what a sap timer is for), but
    -- they are no longer checked against this target's auras unless it carries them too.
    Timers:Each(function(t)
        if t.unit == "target" then t.attached = false end
    end)
    T:RefineAuras("target")
end

function T:TargetHealth()
    if T.koDone or not HUD.hasTarget then return end
    if Bool(UnitIsDead("target")) then
        T.koDone = true
        HUD.hasTarget = false
        T:TargetCasting(false)
        local now = GetTime()
        -- alone, a target that dies mid-fight is your kill; in a group it may not be
        if K.db.words and not Grouped() and (HUD.inCombat or now - (T.lastCastAt or -10) < 6) then
            Show.KO()
        end
    end
end

-- What just happened to the target: CRIT!, DODGED!... The game does not say who dealt the
-- hit, so this is only shown when you are alone and it can only be yours.
function T:TargetHit(action, flag, amount)
    if not K.db.hits or IsSecret(action) or Grouped() then return end
    local now = GetTime()
    if action == "WOUND" then
        if not IsSecret(flag) and flag == "CRITICAL" and now - (T.lastCrit or -10) > 0.25 then
            T.lastCrit = now
            local sub
            if not IsSecret(amount) and type(amount) == "number" and amount > 0 then
                sub = tostring(math.floor(amount + 0.5))
            end
            Show.Crit(sub)
        end
    else
        local word = MISSES[action]
        if word and now - (T.lastMiss or -10) > 0.4 then
            T.lastMiss = now
            Show.Miss(word)
        end
    end
end

-- What just happened to you: a parry opens Riposte.
function T:PlayerHit(action)
    if IsSecret(action) then return end
    if action == "PARRY" then
        FX:Pop("PARRY!", -70, HUD.PIP_Y + 28, C.cyan, 15, 18)
        local rip = Spells:Get("riposte")
        K.After(0.1, function()
            if not (rip and C_Spell and C_Spell.IsSpellUsable) then return end
            local ok, usable = pcall(C_Spell.IsSpellUsable, rip.id)
            if ok and Bool(usable) then
                Timers:Start("riposte", { label = "RIPOSTE!", icon = rip.icon, duration = 5, kind = "now" })
            end
        end)
    elseif action == "DODGE" then
        FX:Pop("DODGE!", -70, HUD.PIP_Y + 28, C.teal, 15, 18)
    end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
function T:Stealth()
    local s = Bool(IsStealthed())
    if s ~= T.stealth then
        T.stealth = s
        HUD:SetPalette(s)
    end
end

function T:Refresh()
    HUD.inCombat = Bool(UnitAffectingCombat("player"))
    E.val = nil
    T:Energy(true)
    T:Stealth()
    T:TargetChanged()
end

function T:OnUpdate(now)
    if K.demo then return end

    -- hidden energy: classify the last change, and infer "full" from silence
    if E.pending and now - E.pending >= 0.06 then
        local t = E.pending
        E.pending = nil
        if math.abs(t - E.lastCost) < 0.3 then
            E.lastSpend = t
        else
            Gain(nil, t)
        end
    end
    if E.known == false then
        local quiet = now - math.max(E.lastGain, E.lastSpend)
        SetFull(quiet > ((E.mode == "smooth") and 0.8 or 2.6))
    end

    -- the tick runner drifts if we have not seen a tick for a long while
    if E.lastTick and now - E.lastTick > 60 then
        E.lastTick = nil
        HUD:SetTickClock(nil)
    end

    -- keep the prompt honest
    if T.casting and now - (T.promptAt or 0) > 0.2 then
        T.promptAt = now
        if T.castStart and now - T.castStart > 12 then
            T:TargetCasting(false)
        else
            T:UpdatePrompt()
        end
    end
end

function T:Start()
    T.Bind()
    T.started = true

    local main = CreateFrame("Frame")
    main:RegisterEvent("PLAYER_ENTERING_WORLD")
    main:RegisterEvent("PLAYER_TARGET_CHANGED")
    main:RegisterEvent("COMBO_TARGET_CHANGED")
    main:RegisterEvent("PLAYER_REGEN_DISABLED")
    main:RegisterEvent("PLAYER_REGEN_ENABLED")
    main:RegisterEvent("UPDATE_STEALTH")
    main:RegisterEvent("UI_ERROR_MESSAGE")
    main:SetScript("OnEvent", function(_, event, a, b)
        if event == "PLAYER_ENTERING_WORLD" then
            T:Refresh()
        elseif event == "PLAYER_TARGET_CHANGED" then
            T:TargetChanged()
        elseif event == "COMBO_TARGET_CHANGED" then
            T:Combo()
        elseif event == "PLAYER_REGEN_DISABLED" then
            HUD.inCombat = true
        elseif event == "PLAYER_REGEN_ENABLED" then
            HUD.inCombat = false
        elseif event == "UPDATE_STEALTH" then
            T:Stealth()
        elseif event == "UI_ERROR_MESSAGE" then
            if not IsSecret(b) and b ~= nil and b == ERR_OUT_OF_ENERGY then HUD:Error() end
        end
    end)

    local me = CreateFrame("Frame")
    me:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    me:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    me:RegisterUnitEvent("UNIT_MAXPOWER", "player")
    me:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    me:RegisterUnitEvent("UNIT_AURA", "player")
    me:SetScript("OnEvent", function(_, event, _, a, b)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            T:Cast(b)
        elseif event == "UNIT_AURA" then
            T:RefineAuras("player")
        elseif event == "UNIT_MAXPOWER" then
            T:Energy()
        else
            -- a: the power type token
            if IsSecret(a) or a == "ENERGY" then T:Energy() end
            if IsSecret(a) or a == "COMBO_POINTS" then T:Combo() end
        end
    end)

    -- Registered for the target only, so the handlers never need the unit argument (which
    -- may be hidden). The one argument used, who interrupted, is checked before use.
    local them = CreateFrame("Frame")
    them:RegisterUnitEvent("UNIT_SPELLCAST_START", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "target")
    them:RegisterUnitEvent("UNIT_AURA", "target")
    them:RegisterUnitEvent("UNIT_HEALTH", "target")
    them:SetScript("OnEvent", function(_, event, _, _, _, by)
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            T:TargetCasting(true)
        elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
            T:Interrupted(by)
        elseif event == "UNIT_AURA" then
            T:RefineAuras("target")
        elseif event == "UNIT_HEALTH" then
            T:TargetHealth()
        else
            T:TargetCasting(false)
        end
    end)

    local hitThem = CreateFrame("Frame")
    hitThem:RegisterUnitEvent("UNIT_COMBAT", "target")
    hitThem:SetScript("OnEvent", function(_, _, _, action, flag, amount)
        T:TargetHit(action, flag, amount)
    end)

    local hitMe = CreateFrame("Frame")
    hitMe:RegisterUnitEvent("UNIT_COMBAT", "player")
    hitMe:SetScript("OnEvent", function(_, _, _, action)
        T:PlayerHit(action)
    end)

    K.Every(function(_, now) T:OnUpdate(now) end)
    T:Refresh()
end
