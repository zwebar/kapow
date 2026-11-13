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

-- These are what happened, so they show on the right; your own abilities show on the left.
-- A crit is meant to be loud: a big burst with the number in large yellow figures under it,
-- stars and a jolt. amount may be hidden from us in combat; the burst can still show it.
function Show.Crit(amount)
    local x, y = FX:Word("CRIT!", { side = 1, color = C.red, shape = "burst2", size = 1.15, sub = amount,
        subSize = 24, subFlags = "THICKOUTLINE", subColor = C.yellow, textColor = C.yellow })
    if x then FX:Sparks(x, y, C.yellow, 5, 50) end
    HUD:Shake(3, 0.18)
end

-- An ordinary hit: a small number, ink-outlined and a little tilted like a comic, that drifts up
-- and fades just right of the HUD, below the word bursts. Kept modest on purpose.
local hitSlot = 0
function Show.Hit(amount)
    hitSlot = hitSlot % 4 + 1
    local x = 150 + hitSlot * 12 + math.random() * 10
    local y = 70 + (hitSlot % 2) * 12
    FX:Pop(amount, x, y, C.paper, 13, 16)
end

function Show.Miss(word)
    FX:Word(word, { side = 1, color = C.grey, shape = "cloud", size = 0.8, textColor = C.paper, hold = 0.7 })
end

function Show.Denied()
    local x, y = FX:Word("DENIED!", { side = 1, color = C.red, shape = "burst2", size = 1.1, textColor = C.yellow, hold = 1.1 })
    if x then FX:Flourish(x, y, C.cyan, 1) end
    HUD:Shake(4, 0.22)
end

function Show.KO()
    local x, y = FX:Word("K.O.!", { side = 1, color = C.yellow, shape = "burst2", size = 1.15, textColor = C.red, hold = 1.2 })
    if x then FX:Flourish(x, y, C.yellow, 1) end
end

--------------------------------------------------------------------------------
-- Energy
--------------------------------------------------------------------------------
local function SetFull(full)
    HUD:SetFull(full)
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
local function Announce(def, cp)
    if not K.db.words then return end
    local size, big, sub, hold = def.size or 1, def.big, def.sub, nil
    if def.finisher then
        size = 0.8 + 0.06 * cp
        big = cp >= 5
        hold = 1.1
        if cp > 0 then sub = cp .. (cp == 1 and " POINT" or " POINTS") end
    end
    local x, y = FX:Word(def.word, {
        side = -1, color = def.color, size = size, shape = def.shape, sub = sub,
        textColor = def.textColor, hold = hold,
    })
    if not x then return end
    if big then
        FX:Flourish(x, y, def.color, 1)
        HUD:Shake(4, 0.24)
    elseif def.finisher then
        FX:Ring(x, y, def.color, 30, 110, 0.3)
    end
end

T.Announce = Announce

-- Cooldown boxes: start on the cooldown learned last time (or the spell's base value), then
-- take the game's own cooldown timer as soon as it exists.
local function BindCooldown(key, spell)
    local d = K.Game.SpellCooldown(spell)
    if d then return Timers:Bind(key, d) end
    -- no duration objects in this client: read the numbers if they are not hidden
    if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spell)
    if not ok or IsSecret(info) or type(info) ~= "table" then return false end
    local start, dur = info.startTime, info.duration
    if IsSecret(start) or IsSecret(dur) or type(start) ~= "number" or type(dur) ~= "number" then return false end
    if dur > 2 and start + dur > GetTime() + 1 then Timers:Adjust(key, start + dur, dur) end
    return true
end

local function StartCooldown(def, spellID)
    local key = "cd:" .. def.key
    Timers:Start(key, {
        label = def.short, icon = def.icon, kind = "cd", ready = def.short .. " READY!",
        duration = Timers:Learned(key) or def.cd, learn = key, spell = def.name or spellID,
    })
    K.After(0.15, function() BindCooldown(key, def.name or spellID) end)
end

-- Cooldowns changed (Preparation, a reset, a talent): re-read every cooldown box.
function T:CooldownsChanged()
    Timers:Each(function(t)
        if t.kind == "cd" and t.spell then BindCooldown(t.key, t.spell) end
    end)
end

--------------------------------------------------------------------------------
-- Aura boxes
--
-- The IDs of a unit's auras are never hidden, so the debuff (or buff) a cast created shows up
-- as a new ID on that unit right after the cast. The box is then bound to the game's timer for
-- that aura, and goes away when the aura does (broken, dispelled, or over). Without IDs the
-- box falls back to the estimate, checked against the aura by name when that is readable.
--------------------------------------------------------------------------------
local AURAS = {
    player = { filter = "HELPFUL|PLAYER", seen = {} },
    target = { filter = "HARMFUL|PLAYER", seen = {} },
}
local CLAIM_WINDOW = 1.5 -- seconds for a cast's aura to appear before we decide it did not land

local function AuraEstimate(def, spellID, cp)
    local dur = def.aura.dur
    local learnKey = "aura:" .. def.key
    if type(dur) == "function" then
        dur = dur(math.max(cp, 1), spellID)
        learnKey = learnKey .. ":" .. math.max(cp, 1) -- finishers last longer with more points
    end
    return Timers:Learned(learnKey) or dur, learnKey
end

local function StartAura(def, spellID, cp)
    local a = def.aura
    local key = "aura:" .. def.key
    local dur, learnKey = AuraEstimate(def, spellID, cp)
    if not dur or dur <= 0 then return end
    -- recasting on the same unit (Slice and Dice again) may refresh the aura it already has
    local old = Timers:Get(key)
    local prev = old and old.onUnit and old.auraID or nil
    local t = Timers:Start(key, {
        label = a.short, icon = def.icon, duration = dur, kind = a.kind, learn = learnKey,
        unit = a.unit, spell = def.name, born = GetTime(), onUnit = true,
    })
    if not t then return end
    t.auraID, t.prevID = nil, prev
    T:ScanAuras(a.unit)
    K.After(0.1, function() T:ScanAuras(a.unit) end)
    K.After(0.5, function() T:ScanAuras(a.unit) end)
    K.After(CLAIM_WINDOW + 0.05, function() T:ScanAuras(a.unit) end)
end

-- Fallback when the game gives no aura IDs: match by name when that is readable.
local function RefineByName(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return end
    local now = GetTime()
    local filter = (unit == "player") and "HELPFUL" or "HARMFUL|PLAYER"
    Timers:Each(function(t)
        if t.unit ~= unit or not t.spell or not t.onUnit then return end
        local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, t.spell, filter)
        if not ok or IsSecret(aura) or type(aura) ~= "table" then return end
        local exp, dur = aura.expirationTime, aura.duration
        if not IsSecret(exp) and not IsSecret(dur) and type(exp) == "number" and type(dur) == "number"
            and dur > 0 and exp > now then
            Timers:Adjust(t.key, exp, dur)
        end
    end)
end

-- fresh: the unit just changed (new target); auras it already has are not new.
function T:ScanAuras(unit, fresh)
    local a = AURAS[unit]
    if not a then return end
    local ids = K.Game.AuraIDs(unit, a.filter)
    if not ids then return RefineByName(unit) end
    local now = GetTime()
    if fresh then
        for id in pairs(a.seen) do a.seen[id] = nil end
    end
    local present = {}
    for _, id in ipairs(ids) do
        if not IsSecret(id) then
            present[id] = true
            if not a.seen[id] then a.seen[id] = fresh and 0 or now end
        end
    end
    for id in pairs(a.seen) do
        if not present[id] then a.seen[id] = nil end
    end

    -- boxes on this unit, oldest first
    local boxes, claimed = {}, {}
    Timers:Each(function(t)
        if t.unit == unit and t.onUnit then
            boxes[#boxes + 1] = t
            if t.auraID then claimed[t.auraID] = true end
        end
    end)
    table.sort(boxes, function(x, y) return (x.born or 0) < (y.born or 0) end)

    for _, t in ipairs(boxes) do
        if t.auraID then
            if present[t.auraID] then
                -- still there: re-read its timer (it may have been refreshed)
                Timers:Bind(t.key, K.Game.AuraDuration(unit, t.auraID))
            else
                Timers:Stop(t.key) -- the aura is gone: broken early, dispelled, or over
            end
        else
            local pick
            if t.prevID and present[t.prevID] and not claimed[t.prevID] then
                pick = t.prevID
            else
                local best
                for id, seenAt in pairs(a.seen) do
                    if not claimed[id] and seenAt >= (t.born or now) - 0.3 and (not best or seenAt < best) then
                        pick, best = id, seenAt
                    end
                end
            end
            if pick then
                claimed[pick] = true
                t.auraID, t.watched = pick, true
                Timers:Bind(t.key, K.Game.AuraDuration(unit, pick))
            elseif now - (t.born or now) > CLAIM_WINDOW then
                Timers:Stop(t.key) -- it never landed (missed, resisted, immune)
            end
        end
    end
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

local function Present(v) return IsSecret(v) or v ~= nil end

-- What the target is casting, or nil. Parts the game hides stay secret: the HUD can still show
-- the name and icon, and turn "helpful" and "can't be interrupted" into colour and visibility.
local function ReadCast()
    local channel = false
    local ok, name, _, icon, startMs, endMs, _, _, notInt, spellID = pcall(UnitCastingInfo, "target")
    if not ok or not Present(name) then
        if not UnitChannelInfo then return nil end
        local ok2, n, _, i, s, e, _, ni, sid = pcall(UnitChannelInfo, "target")
        if not ok2 or not Present(n) then return nil end
        name, icon, startMs, endMs, notInt, spellID, channel = n, i, s, e, ni, sid, true
    end
    local cast = { name = name, icon = icon, startMs = startMs, endMs = endMs,
        notInterruptible = notInt, channel = channel }
    if Present(spellID) and C_Spell and C_Spell.IsSpellHelpful then
        local helpful = K.Safe(C_Spell.IsSpellHelpful, spellID)
        if IsSecret(helpful) then
            cast.helpful = helpful
        else
            cast.helpful = helpful and true or false
            -- readable: a helpful spell is a heal if it says so, otherwise a buff
            if cast.helpful then
                local desc = C_Spell.GetSpellDescription and K.Safe(C_Spell.GetSpellDescription, spellID)
                if type(desc) == "string" and not IsSecret(desc) and desc ~= "" then
                    cast.heal = desc:lower():find("heal", 1, true) ~= nil
                else
                    cast.heal = true
                end
            end
        end
    end
    return cast
end

-- Ways to stop a cast, best first. Gouge and Kidney Shot interrupt too.
local STOP_WITH = { { "kick", "KICK IT!" }, { "gouge", "GOUGE IT!" }, { "kidney", "KIDNEY SHOT!" } }

-- Seconds until a spell's cooldown is over: the game's own timer when it may be read, else
-- the cooldown box's estimate.
local function CooldownLeft(key)
    local def = Spells:Get(key)
    local rem = def and K.Game.Remaining(K.Game.SpellCooldown(def.name or def.id))
    if rem then return rem end
    return math.max(0, Timers:Remaining("cd:" .. key))
end

-- Known, off cooldown, and enough energy (and combo points, for Kidney Shot).
local function Ready(key)
    local def = Spells:Get(key)
    if not def or CooldownLeft(key) > 0.1 then return false end
    if not (C_Spell and C_Spell.IsSpellUsable) then return false end
    -- by name, so the highest rank you know is the one checked
    local ok, usable = pcall(C_Spell.IsSpellUsable, def.name or def.id)
    return ok and Bool(usable)
end

-- While the target casts something that can be stopped: KICK IT!, or with Kick on cooldown
-- GOUGE IT! / KIDNEY SHOT!, or failing all of those a quieter "KICK IN 4" so you still see
-- what is coming.
function T:UpdatePrompt()
    local text, mode
    if T.casting and K.db.prompt and HUD.hasTarget then
        local cast = T.cast
        local shielded = cast and not IsSecret(cast.notInterruptible) and cast.notInterruptible
        if not shielded then
            for _, way in ipairs(STOP_WITH) do
                if Ready(way[1]) then
                    text, mode = way[2], "go"
                    break
                end
            end
            if not text and Spells:Get("kick") then
                local wait = CooldownLeft("kick")
                text = wait > 0 and string.format("KICK IN %d", math.ceil(wait)) or "NEED ENERGY"
                mode = "wait"
            end
        end
    end
    HUD:SetPrompt(text, text and T.cast or nil, mode)
end

function T:TargetCasting(on)
    T.casting = on
    T.castStart = on and GetTime() or nil
    T.cast = on and ReadCast() or nil
    T:UpdatePrompt()
end

-- The cast became kickable or stopped being kickable.
function T:CastChanged()
    if T.casting then T:TargetCasting(true) end
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
    T.cast = T.casting and ReadCast() or nil
    T:UpdatePrompt()
    T:Combo(true)
    -- Boxes for the old target keep running on the game's timer (that is what a sap timer is
    -- for); they just can no longer be checked against the unit, which is someone else now.
    Timers:Each(function(t)
        if t.unit == "target" then t.onUnit, t.watched = false, false end
    end)
    T:ScanAuras("target", true)
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

-- A damage amount fit to show: a whole number, the hidden value itself (the widget can show
-- it though we cannot read it), or nil when there is nothing to show.
local function Amount(amount)
    if IsSecret(amount) then return amount end
    if type(amount) == "number" and amount > 0 then return math.floor(amount + 0.5) end
    return nil
end

-- What just happened to the target: CRIT!, DODGED!... The game does not say who dealt the
-- hit, so this is only shown when you are alone and it can only be yours.
function T:TargetHit(action, flag, amount)
    if not K.db.hits or IsSecret(action) or Grouped() then return end
    local now = GetTime()
    if action == "WOUND" then
        if not IsSecret(flag) and flag == "CRITICAL" and now - (T.lastCrit or -10) > 0.25 then
            T.lastCrit = now
            Show.Crit(Amount(amount))
        elseif K.db.dmg and (IsSecret(flag) or flag ~= "CRITICAL") then
            local n = Amount(amount)
            if n ~= nil then Show.Hit(n) end
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

    -- Riposte: the box lasts as long as the game says Riposte can be used
    if Timers:Get("riposte") and now - (T.riposteAt or 0) > 0.2 then
        T.riposteAt = now
        local rip = Spells:Get("riposte")
        local ok, usable = pcall(C_Spell.IsSpellUsable, rip.name or rip.id)
        if ok and not IsSecret(usable) and not usable and Timers:Remaining("riposte") < 4.8 then
            Timers:Stop("riposte")
        end
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
    main:RegisterEvent("SPELL_UPDATE_COOLDOWN")
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
        elseif event == "SPELL_UPDATE_COOLDOWN" then
            T:CooldownsChanged()
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
            T:ScanAuras("player")
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
    them:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTIBLE", "target")
    them:RegisterUnitEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
    them:RegisterUnitEvent("UNIT_AURA", "target")
    them:RegisterUnitEvent("UNIT_HEALTH", "target")
    them:SetScript("OnEvent", function(_, event, _, _, _, by)
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            T:TargetCasting(true)
        elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
            T:Interrupted(by)
        elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
            T:CastChanged()
        elseif event == "UNIT_AURA" then
            T:ScanAuras("target")
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
