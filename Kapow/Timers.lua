-- Timers: comic caption boxes under the energy cells that count down crowd control,
-- your own buffs and bleeds, and short cooldowns (KICK 7.2).
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
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(H - 6, H - 6)
    f.icon:SetPoint("LEFT", 3, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.label = K.Text(f, "OVERLAY", 11, "")
    f.label:SetPoint("LEFT", f.icon, "RIGHT", 4, 0)
    f.label:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    f.time = K.Text(f, "OVERLAY", 12, "")
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
end

local function Find(key)
    for i = 1, #active do
        if active[i].key == key then return active[i], i end
    end
end

local function Remove(i)
    local t = table.remove(active, i)
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

-- Swap in the real end time once the game tells us.
function Timers:Adjust(key, expires, duration)
    local t = Find(key)
    if t then
        t.expires = expires
        if duration and duration > 0 then t.duration = duration end
    end
end

function Timers:Remaining(key)
    local t = Find(key)
    return t and (t.expires - GetTime()) or 0
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
        if rem <= 0 then
            Remove(i)
            if t.ready then
                K.FX:Pop(t.ready, t.x, t.y + 14, C.cyan, 14, 20)
                K.FX:Ring(t.x, t.y, C.cyan, 20, 90, 0.3)
            end
            if t.onDone then t.onDone() end
        else
            local chip = t.chip
            local frac = rem / t.duration
            if frac > 1 then frac = 1 end
            chip.fill:SetWidth(math.max(0.01, (W - 4) * frac))
            if rem >= 10 then
                chip.time:SetFormattedText("%d", math.floor(rem + 0.5))
            else
                chip.time:SetFormattedText("%.1f", rem)
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
