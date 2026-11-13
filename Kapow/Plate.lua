-- Plate: the combo points as an arc of pips above your target's nameplate.
-- Combo points live on the target, so that is where they are shown. When the target has no
-- nameplate the game will hand us (nameplates off, out of sight, or hidden from addons in some
-- places) the pips on the HUD take over.
local _, K = ...
local P = {}
K.Plate = P
local C = K.C

local N = 5
local PIP = 22
local RADIUS = 58
local SPREAD = 104 -- degrees from the first pip to the last: a gentle curve
local COLORS = { C.yellow, C.yellow, C.orange, C.orange, C.red }
local EMPTY = { 0.24, 0.21, 0.33 }

local function Mode() return K.db.pips or "plate" end

function P:Build()
    -- The pips sit on an arc whose top is the middle pip.
    -- The frame is exactly as tall as the arc, so its bottom edge is the outer pips' bottom.
    local first = 90 + SPREAD / 2
    local low = math.sin(math.rad(first)) * RADIUS
    local rise = RADIUS - low
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(RADIUS * 2 + PIP * 2, rise + PIP)
    f:Hide()
    self.frame = f

    self.pips = {}
    for i = 1, N do
        local a = math.rad(first - (i - 1) * SPREAD / (N - 1))
        local x = math.cos(a) * RADIUS
        local y = PIP / 2 + math.sin(a) * RADIUS - low - (rise + PIP) / 2
        local pip = { x = x, y = y, on = false }
        pip.shadow = K.Tex(f, "ARTWORK", "pip", PIP, PIP, 0)
        pip.shadow:SetPoint("CENTER", x + 2, y - 2)
        pip.shadow:SetVertexColor(0, 0, 0, 0.55)
        pip.glow = K.Tex(f, "ARTWORK", "glow", PIP * 2.4, PIP * 2.4, 1)
        pip.glow:SetPoint("CENTER", x, y)
        pip.glow:SetBlendMode("ADD")
        pip.glow:SetAlpha(0)
        pip.ring = K.Tex(f, "ARTWORK", "ring", PIP, PIP, 2)
        pip.ring:SetPoint("CENTER", x, y)
        pip.ring:SetAlpha(0)
        pip.tex = K.Tex(f, "ARTWORK", "pip", PIP, PIP, 3)
        pip.tex:SetPoint("CENTER", x, y)
        K.Tint(pip.tex, EMPTY, 0.9)
        self.pips[i] = pip
    end

    -- shown instead of lit pips if the game hides the count
    local num = K.Text(f, "OVERLAY", 18)
    num:SetPoint("CENTER", 0, self.pips[3].y)
    num:SetTextColor(C.red[1], C.red[2], C.red[3])
    num:Hide()
    self.num = num

    local max = K.Text(f, "OVERLAY", 14)
    max:SetPoint("BOTTOM", f, "CENTER", 0, self.pips[3].y + PIP * 0.7)
    max:SetTextColor(C.red[1], C.red[2], C.red[3])
    max:SetText("MAX!")
    max:SetRotation(0.08)
    max:SetAlpha(0)
    self.max = max

    self.combo = 0

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function()
        P:Attach()
        -- A removed plate is recycled for another mob right after: look again next frame.
        K.After(0, function() P:Attach() end)
    end)

    K.Every(function(dt, now) P:OnUpdate(now) end)
    self:Attach()
end

-- Finds the target's nameplate and sits on it, or gives the pips back to the HUD.
function P:Attach()
    if not self.frame then return end
    local plate
    if Mode() ~= "hud" and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        plate = K.Safe(C_NamePlate.GetNamePlateForUnit, "target")
        if K.IsSecret(plate) or type(plate) ~= "table" then plate = nil end
    end
    local f = self.frame
    if plate then
        if plate ~= self.plate then
            self.plate = plate
            f:SetParent(plate)
            f:ClearAllPoints()
            f:SetPoint("BOTTOM", plate, "TOP", 0, K.db.arcY or 2)
            f:SetFrameLevel(math.min(9000, (K.Safe(plate.GetFrameLevel, plate) or 0) + 20))
        end
        f:Show()
    else
        self.plate = nil
        f:Hide()
        f:SetParent(UIParent)
    end
    self.attached = plate ~= nil
    K.HUD:SetPipsShown(Mode() == "both" or (Mode() == "hud") or not plate)
    return self.attached
end

-- Moves the arc up or down (after /kapow arc).
function P:Reanchor()
    self.plate = nil
    self:Attach()
end

local function Size(pip, s)
    pip.tex:SetSize(PIP * s, PIP * s)
    pip.shadow:SetSize(PIP * s, PIP * s)
end

local function Burst(pip, color, from, to, dur)
    K.Tint(pip.ring, color)
    K.Cancel(pip.ringTween)
    pip.ringTween = K.Tween(dur, function(p)
        local s = from + (to - from) * K.Ease.outCubic(p)
        pip.ring:SetSize(s, s)
        pip.ring:SetAlpha(1 - p * p)
    end)
end

-- quiet: just show the state (new target, login), no pops.
function P:SetCombo(n, quiet)
    if not self.pips then return end
    self.num:Hide()
    local was = self.combo or 0
    self.combo = n
    for i = 1, N do
        local pip = self.pips[i]
        local on = i <= n
        if on ~= pip.on then
            pip.on = on
            K.Cancel(pip.tween)
            if on then
                local c = COLORS[i]
                pip.color = c
                K.Tint(pip.tex, c)
                if quiet then
                    Size(pip, 1)
                else
                    pip.tween = K.Tween(0.3, function(p)
                        Size(pip, 0.3 + 0.7 * K.Ease.outBack(p))
                    end)
                    Burst(pip, c, PIP * 0.6, PIP * 2.4, 0.3)
                end
            else
                K.Tint(pip.tex, EMPTY, 0.9)
                Size(pip, 1)
                pip.glow:SetAlpha(0)
                if not quiet and pip.color then
                    local c = pip.color
                    K.After((i - 1) * 0.035, function() Burst(pip, c, PIP, PIP * 3, 0.3) end)
                end
            end
        end
    end
    if n >= N and was < N and not quiet then
        K.Cancel(self.maxTween)
        self.maxTween = K.Tween(0.9, function(p)
            self.max:SetAlpha(p < 0.7 and 1 or (1 - (p - 0.7) / 0.3))
            self.max:SetTextScale(1 + 0.5 * (1 - K.Ease.outBack(math.min(1, p * 4))))
        end, function() self.max:SetAlpha(0) end)
    end
end

function P:SetSecret(value)
    if not self.pips then return end
    self.combo = nil
    for i = 1, N do
        local pip = self.pips[i]
        pip.on = false
        K.Tint(pip.tex, EMPTY, 0.9)
        Size(pip, 1)
        pip.glow:SetAlpha(0)
    end
    self.num:SetFormattedText("%d", value)
    self.num:Show()
end

function P:OnUpdate(now)
    if not self.attached then return end
    -- five points: the arc throbs
    if self.combo and self.combo >= N then
        local s = 1 + 0.1 * math.sin(now * 11)
        for i = 1, N do
            local pip = self.pips[i]
            if not pip.tween or pip.tween.dead then Size(pip, s) end
            pip.glow:SetVertexColor(C.red[1], C.red[2], C.red[3])
            pip.glow:SetAlpha(0.5 + 0.25 * math.sin(now * 11))
        end
        self.throbbing = true
    elseif self.throbbing then
        self.throbbing = false
        for i = 1, N do
            local pip = self.pips[i]
            pip.glow:SetAlpha(0)
            if not pip.tween or pip.tween.dead then Size(pip, 1) end
        end
    end
end
