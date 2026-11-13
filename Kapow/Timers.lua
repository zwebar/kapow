-- Timers: comic caption boxes under the energy cells that count down crowd control,
-- your own buffs and bleeds, and short cooldowns (KICK 7.2).
--
-- A box starts on an estimate (a duration learned earlier, or the spell's base value) and is
-- bound to the game's own timer as soon as the game hands one over (Timers:Bind): from then
-- on the game fills its bar and writes its seconds, so they are exact even in combat when the
-- numbers are hidden from addons.
local _, K = ...
local Timers = {}
K.Timers = Timers
local C = K.C

local W, H, GAP, PER_ROW = 96, 22, 6, 3

-- paper colour, bar colour
local KINDS = {
    cc   = { { 1.00, 0.93, 0.62 }, C.orange },
    cd   = { { 0.84, 0.93, 1.00 }, C.cyan },
    buff = { { 0.83, 1.00, 0.90 }, C.teal },
    dot  = { { 1.00, 0.86, 0.92 }, C.pink },
    now  = { { 1.00, 0.85, 0.85 }, C.red },
}

local active, pool = {}, {}
Timers.count = 0

function Timers:Build()
    self.parent = K.HUD.body
    K.Every(function(dt, now) Timers:OnUpdate(now) end)
end

local function NewChip()
    local f = K.Panel(Timers.parent, W, H)
    f:SetFrameLevel(Timers.parent:GetFrameLevel() + 8)
    f.fill = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.fill:SetPoint("TOPLEFT", 2, -2)
    f.fill:SetHeight(H - 4)
    -- the same fill, driven by the game's timer once the box is bound
    local gb = CreateFrame("StatusBar", nil, f)
    gb:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    gb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    gb:SetFrameLevel(f:GetFrameLevel())
    gb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    gb:SetMinMaxValues(0, 1)
    gb:Hide()
    f.gameBar = gb
    local over = CreateFrame("Frame", nil, f)
    over:SetAllPoints(f)
    over:SetFrameLevel(f:GetFrameLevel() + 2)
    f.over = over
    f.icon = over:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(H - 6, H - 6)
    f.icon:SetPoint("LEFT", 3, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.label = K.Text(over, "OVERLAY", 11, "")
    f.label:SetPoint("LEFT", f.icon, "RIGHT", 4, 0)
    f.label:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    f.time = K.Text(over, "OVERLAY", 12, "")
    f.time:SetPoint("RIGHT", -5, 0)
    f.time:SetTextColor(C.ink[1], C.ink[2], C.ink[3])

    local ag = f:CreateAnimationGroup()
    local pop = ag:CreateAnimation("Scale")
    pop:SetDuration(0.14)
    pop:SetScaleFrom(1.35, 1.35)
    pop:SetScaleTo(1, 1)
    pop:SetOrigin("CENTER", 0, 0)
    pop:SetSmoothing("OUT")
    f.pop = ag
    return f
end

local function Layout()
    local n = #active
    for i = 1, n do
        local t = active[i]
        local row = math.floor((i - 1) / PER_ROW)
        local inRow = math.min(PER_ROW, n - row * PER_ROW)
        local col = (i - 1) % PER_ROW
        local x = (col - (inRow - 1) / 2) * (W + GAP)
        local y = K.HUD.CHIP_Y - row * (H + GAP)
        t.x, t.y = x, y
        t.chip:ClearAllPoints()
        t.chip:SetPoint("CENTER", Timers.parent, "CENTER", x, y)
    end
    Timers.count = n
    -- the swing timer sits under the last row of boxes (or where the first row would be)
    if K.Swing then
        local rows = math.ceil(n / PER_ROW)
        K.Swing:Place(K.HUD.CHIP_Y - math.max(0, rows) * (H + GAP) + (rows == 0 and 0 or 4))
    end
end

local function Find(key)
    for i = 1, #active do
        if active[i].key == key then return active[i], i end
    end
end

local function Unbind(t)
    if not t.bound then return end
    t.bound, t.dur = false, nil
    local chip = t.chip
    K.Game.Unbind(chip.binding)
    chip.gameBar:Hide()
    chip.fill:Show()
end

local function Remove(i)
    local t = table.remove(active, i)
    Unbind(t)
    t.chip:Hide()
    pool[#pool + 1] = t.chip
    Layout()
    return t
end

-- Timers:Start("kick", { label = "KICK", icon = 132219, duration = 10, kind = "cd", ready = "KICK READY!" })
-- Extra fields are kept on the timer (the tracker stores what it needs to re-check auras).
function Timers:Start(key, o)
    if not self.parent then return end
    local now = GetTime()
    local t, i = Find(key)
    if not t then
        if #active >= 9 then return end
        t = { key = key, chip = table.remove(pool) or NewChip() }
        active[#active + 1] = t
    end
    for k, v in pairs(o) do t[k] = v end
    t.start = now
    t.expires = now + o.duration
    t.warned = false

    local chip = t.chip
    local kind = KINDS[o.kind] or KINDS.cd
    t.paper, t.bar = kind[1], kind[2]
    chip.bg:SetColorTexture(t.paper[1], t.paper[2], t.paper[3], 1)
    chip.fill:SetColorTexture(t.bar[1], t.bar[2], t.bar[3], 0.85)
    chip.gameBar:SetStatusBarColor(t.bar[1], t.bar[2], t.bar[3], 0.85)
    Unbind(t)
    if o.icon then
        chip.icon:SetTexture(o.icon)
        chip.icon:Show()
    else
        chip.icon:Hide()
    end
    chip.label:SetText(o.label or "")
    chip:Show()
    Layout()
    chip.pop:Stop()
    chip.pop:Play()
    return t
end

function Timers:Get(key)
    return (Find(key))
end

function Timers:Stop(key)
    local _, i = Find(key)
    if i then Remove(i) end
end

-- Remembers how long something really lasted, so the next estimate is right (talents,
-- ranks and Forever's own spell versions included). Kept per character.
local function Learn(t, total)
    if t.learn and total and total > 0.5 then
        KapowCharDB = KapowCharDB or {}
        KapowCharDB.learned = KapowCharDB.learned or {}
        KapowCharDB.learned[t.learn] = math.floor(total * 10 + 0.5) / 10
    end
end

function Timers:Learned(learnKey)
    return KapowCharDB and KapowCharDB.learned and KapowCharDB.learned[learnKey]
end

-- Swap in the real end time once the game tells us.
function Timers:Adjust(key, expires, duration)
    local t = Find(key)
    if t then
        t.expires = expires
        if duration and duration > 0 then
            t.duration = duration
            Learn(t, duration)
        end
    end
end

-- Hands the box the game's own timer (a duration object). Returns false if the game would not
-- take it, and the box keeps its estimate.
function Timers:Bind(key, d)
    local t = Find(key)
    if not (t and d) then return false end
    local chip = t.chip
    if not K.Game.BindBar(chip.gameBar, d) then return false end
    local binding = K.Game.BindText(chip.binding, chip.time, d, t.kind == "cd" and "READY" or "")
    if not binding then
        chip.gameBar:Hide()
        return false
    end
    chip.binding = binding
    t.bound, t.dur = true, d
    chip.fill:Hide()
    chip.gameBar:Show()
    -- readable: the box can also end exactly on time
    local rem, total = K.Game.Remaining(d), K.Game.Total(d)
    if rem then
        if rem <= 0 then
            local _, i = Find(key)
            Remove(i)
            return true
        end
        t.expires = GetTime() + rem
        if total then
            t.duration = total
            Learn(t, total)
        end
    end
    return true
end

-- Seconds left: from the game's timer when it may be read, else the estimate.
function Timers:Remaining(key)
    local t = Find(key)
    if not t then return 0 end
    local rem = t.bound and K.Game.Remaining(t.dur)
    if rem then return rem end
    return t.expires - GetTime()
end

function Timers:Each(fn)
    for i = #active, 1, -1 do fn(active[i]) end
end

function Timers:Clear()
    for i = #active, 1, -1 do Remove(i) end
end

function Timers:OnUpdate(now)
    for i = #active, 1, -1 do
        local t = active[i]
        local rem = t.expires - now
        local exact = t.bound and K.Game.Remaining(t.dur)
        if exact then
            rem = exact
        elseif t.bound then
            local active = K.Game.Active(t.dur)
            if active == false then
                rem = 0
            elseif t.watched then
                -- an aura box still on its unit: it ends when the aura leaves, not on a guess
                rem = math.max(rem, 0.5)
            end
        end
        if rem <= 0 then
            Remove(i)
            if t.ready then
                K.FX:Pop(t.ready, t.x, t.y + 14, C.cyan, 14, 20)
                K.FX:Ring(t.x, t.y, C.cyan, 20, 90, 0.3)
            end
            if t.onDone then t.onDone() end
        else
            local chip = t.chip
            if not t.bound then
                -- the game is not drawing this one: our own estimate
                local frac = rem / t.duration
                if frac > 1 then frac = 1 end
                chip.fill:SetWidth(math.max(0.01, (W - 4) * frac))
                if rem >= 10 then
                    chip.time:SetFormattedText("%ds", math.floor(rem + 0.5))
                else
                    chip.time:SetFormattedText("%.1f", rem)
                end
            end
            -- crowd control about to break: the box blinks red
            if t.kind == "cc" and rem < 1.5 then
                local on = (math.floor(now * 8) % 2) == 0
                local p = on and KINDS.now[1] or t.paper
                chip.bg:SetColorTexture(p[1], p[2], p[3], 1)
            end
        end
    end
end
