-- FX: the comic effects. Word bursts (POW!), small floating pops (+20), rings, sparks,
-- speed lines and slashes. Everything is positioned relative to the centre of the HUD.
local _, K = ...
local FX = {}
K.FX = FX
local C = K.C

-- Word bursts land beside the HUD, alternating left and right, so they never cover the
-- middle of the screen where your character and your target are.
-- Each slot: side (-1 left, 1 right), how far its inner edge sits from the HUD's centre, height.
local WORD_SLOTS = { { -1, 186, 10 }, { 1, 194, 14 }, { -1, 204, 56 }, { 1, 212, 60 }, { -1, 190, -36 }, { 1, 196, -34 } }

local words, pops, sprites = {}, {}, {}
local slot, seq = 0, 0

function FX:Build()
    self.layer = K.HUD.fx
end

local SetFontSize = K.SetFont

--------------------------------------------------------------------------------
-- Word bursts
--------------------------------------------------------------------------------
local function NewWord()
    local f = CreateFrame("Frame", nil, FX.layer)
    f:SetSize(10, 10)

    f.shadow = K.Tex(f, "BACKGROUND", "burst", 160)
    f.shadow:SetPoint("CENTER", 6, -7)
    f.shadow:SetVertexColor(0, 0, 0, 0.5)
    f.shape = K.Tex(f, "BORDER", "burst", 160)
    f.shape:SetPoint("CENTER")

    f.back = K.Text(f, "ARTWORK", 26)
    f.back:SetPoint("CENTER", 3, -3)
    f.back:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    f.text = K.Text(f, "OVERLAY", 26)
    f.text:SetPoint("CENTER")
    f.sub = K.Text(f, "OVERLAY", 13, "OUTLINE")
    f.sub:SetPoint("TOP", f.text, "BOTTOM", 0, 1)

    local ag = f:CreateAnimationGroup()
    ag:SetToFinalAlpha(true)

    local pop = ag:CreateAnimation("Scale")
    pop:SetOrder(1)
    pop:SetDuration(0.11)
    pop:SetScaleFrom(0.2, 0.2)
    pop:SetScaleTo(1.22, 1.22)
    pop:SetOrigin("CENTER", 0, 0)
    pop:SetSmoothing("OUT")

    local settle = ag:CreateAnimation("Scale")
    settle:SetOrder(2)
    settle:SetDuration(0.09)
    settle:SetScaleFrom(1.22, 1.22)
    settle:SetScaleTo(1, 1)
    settle:SetOrigin("CENTER", 0, 0)
    settle:SetSmoothing("IN_OUT")

    local fade = ag:CreateAnimation("Alpha")
    fade:SetOrder(3)
    fade:SetDuration(0.22)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)

    local drift = ag:CreateAnimation("Translation")
    drift:SetOrder(3)
    drift:SetDuration(0.22)
    drift:SetOffset(0, 22)
    drift:SetSmoothing("IN")

    local grow = ag:CreateAnimation("Scale")
    grow:SetOrder(3)
    grow:SetDuration(0.22)
    grow:SetScaleFrom(1, 1)
    grow:SetScaleTo(1.12, 1.12)
    grow:SetOrigin("CENTER", 0, 0)

    f.ag, f.tail = ag, { fade, drift, grow }
    ag:SetScript("OnFinished", function()
        f:Hide()
        f.busy = false
    end)
    return f
end

local function AcquireWord()
    for i = 1, #words do
        if not words[i].busy then return words[i] end
    end
    if #words >= 8 then
        -- All in use: recycle the oldest.
        local oldest = words[1]
        for i = 2, #words do
            if words[i].born < oldest.born then oldest = words[i] end
        end
        oldest.ag:Stop()
        return oldest
    end
    local f = NewWord()
    words[#words + 1] = f
    return f
end

-- FX:Word("KICK!", { color = C.cyan, size = 1, shape = "burst", sub = "412", hold = 0.45 })
function FX:Word(text, o)
    if not self.layer then return end
    o = o or {}
    local f = AcquireWord()
    f.busy = true
    seq = seq + 1
    f.born = seq

    local size = o.size or 1
    local font = math.floor(21 * size + 0.5)
    SetFontSize(f.text, font)
    SetFontSize(f.back, font)
    f.text:SetText(text)
    f.back:SetText(text)
    local tc = o.textColor or C.white
    f.text:SetTextColor(tc[1], tc[2], tc[3])

    if o.sub then
        f.sub:SetText(o.sub)
        f.sub:SetTextColor(C.paper[1], C.paper[2], C.paper[3])
        f.sub:Show()
    else
        f.sub:Hide()
    end

    local w = math.max(f.text:GetStringWidth() or 0, #text * font * 0.42)
    local sw = math.max(w * 1.4 + 30, 84 * size)
    local sh = math.max(font * 3.0, sw * 0.6) + (o.sub and 12 or 0)
    local art = K.ART .. (o.shape or "burst")
    f.shape:SetTexture(art)
    f.shadow:SetTexture(art)
    f.shape:SetSize(sw, sh)
    f.shadow:SetSize(sw, sh)
    K.Tint(f.shape, o.color or C.yellow)

    local tilt = o.tilt or ((math.random() * 2 - 1) * 0.13)
    f.text:SetRotation(tilt)
    f.back:SetRotation(tilt)

    -- /kapow fx: the whole burst can be made smaller or larger. Offsets are in the frame's
    -- own scale, hence the division below.
    local s = K.db.fx or 1
    slot = slot % #WORD_SLOTS + 1
    local side, edge, height = WORD_SLOTS[slot][1], WORD_SLOTS[slot][2], WORD_SLOTS[slot][3]
    -- placed by its inner edge, so a wide burst grows outward instead of over the HUD
    local x = side * (edge + sw * s / 2 + math.random() * 8)
    local y = height + (math.random() * 2 - 1) * 6
    f:SetScale(s)
    f:ClearAllPoints()
    f:SetPoint("CENTER", self.layer, "CENTER", x / s, y / s)
    f:SetFrameLevel(self.layer:GetFrameLevel() + 1 + (seq % 30))

    local hold = o.hold or 0.42
    for i = 1, #f.tail do f.tail[i]:SetStartDelay(hold) end
    f.ag:Stop()
    f:SetAlpha(1)
    f:Show()
    f.ag:Play()

    -- "Boiling" outline: the burst jitters between two angles while it is up.
    K.Cancel(f.boil)
    local total, last = 0.2 + hold + 0.22, -1
    local base = (math.random() * 2 - 1) * 0.2
    f.boil = K.Tween(total, function(p)
        local n = math.floor(p * total / 0.085)
        if n ~= last then
            last = n
            local r = base + ((n % 2 == 0) and 0.05 or -0.05)
            f.shape:SetRotation(r)
            f.shadow:SetRotation(r)
        end
    end)
    return x, y
end

--------------------------------------------------------------------------------
-- Pops: small floating text
--------------------------------------------------------------------------------
local function NewPop()
    local f = CreateFrame("Frame", nil, FX.layer)
    f:SetSize(10, 10)
    f.back = K.Text(f, "ARTWORK", 14)
    f.back:SetPoint("CENTER", 2, -2)
    f.back:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    f.text = K.Text(f, "OVERLAY", 14)
    f.text:SetPoint("CENTER")

    local ag = f:CreateAnimationGroup()
    ag:SetToFinalAlpha(true)
    local pop = ag:CreateAnimation("Scale")
    pop:SetOrder(1)
    pop:SetDuration(0.12)
    pop:SetScaleFrom(1.7, 1.7)
    pop:SetScaleTo(1, 1)
    pop:SetOrigin("CENTER", 0, 0)
    pop:SetSmoothing("OUT")
    local rise = ag:CreateAnimation("Translation")
    rise:SetOrder(2)
    rise:SetDuration(0.5)
    rise:SetOffset(0, 24)
    rise:SetSmoothing("OUT")
    local fade = ag:CreateAnimation("Alpha")
    fade:SetOrder(2)
    fade:SetDuration(0.3)
    fade:SetStartDelay(0.2)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    f.ag, f.rise = ag, rise
    ag:SetScript("OnFinished", function()
        f:Hide()
        f.busy = false
    end)
    return f
end

function FX:Pop(text, x, y, color, size, rise)
    if not self.layer then return end
    local f
    for i = 1, #pops do
        if not pops[i].busy then f = pops[i]; break end
    end
    if not f then
        if #pops >= 14 then return end
        f = NewPop()
        pops[#pops + 1] = f
    end
    f.busy = true
    size = size or 14
    SetFontSize(f.text, size)
    SetFontSize(f.back, size)
    f.text:SetText(text)
    f.back:SetText(text)
    color = color or C.white
    f.text:SetTextColor(color[1], color[2], color[3])
    local tilt = (math.random() * 2 - 1) * 0.1
    f.text:SetRotation(tilt)
    f.back:SetRotation(tilt)
    f.rise:SetOffset(0, rise or 24)
    f:ClearAllPoints()
    f:SetPoint("CENTER", self.layer, "CENTER", x, y)
    f.ag:Stop()
    f:SetAlpha(1)
    f:Show()
    f.ag:Play()
end

--------------------------------------------------------------------------------
-- Sprites: pooled textures moved by tweens
--------------------------------------------------------------------------------
local function Sprite(file, blend)
    local t
    for i = 1, #sprites do
        if not sprites[i].busy then t = sprites[i]; break end
    end
    if not t then
        if #sprites >= 60 then return nil end
        t = FX.layer:CreateTexture(nil, "ARTWORK")
        sprites[#sprites + 1] = t
    end
    t.busy = true
    t:SetTexture(K.ART .. file)
    t:SetBlendMode(blend or "BLEND")
    t:SetRotation(0)
    t:SetVertexColor(1, 1, 1, 1)
    t:SetAlpha(1)
    t:Show()
    return t
end

local function Release(t)
    t:Hide()
    t.busy = false
end

local function Place(t, x, y)
    t:ClearAllPoints()
    t:SetPoint("CENTER", FX.layer, "CENTER", x, y)
end

-- An expanding shockwave ring.
function FX:Ring(x, y, color, from, to, dur)
    if not self.layer then return end
    local t = Sprite("ring")
    if not t then return end
    K.Tint(t, color or C.white)
    Place(t, x, y)
    K.Tween(dur or 0.3, function(p)
        local e = K.Ease.outCubic(p)
        local s = from + (to - from) * e
        t:SetSize(s, s)
        t:SetAlpha(1 - p * p)
    end, function() Release(t) end)
end

-- Little stars thrown outward.
function FX:Sparks(x, y, color, n, reach)
    if not self.layer then return end
    reach = reach or 34
    local a0 = math.random() * 6.28
    for i = 1, n or 5 do
        local t = Sprite("star")
        if not t then return end
        K.Tint(t, color or C.yellow)
        local a = a0 + (i / (n or 5)) * 6.28 + (math.random() - 0.5) * 0.5
        local d = reach * (0.7 + math.random() * 0.6)
        local s0 = 10 + math.random() * 8
        local spin = (math.random() - 0.5) * 4
        K.Tween(0.34 + math.random() * 0.12, function(p)
            local e = K.Ease.outCubic(p)
            Place(t, x + math.cos(a) * d * e, y + math.sin(a) * d * e)
            local s = s0 * (1 - p * 0.7)
            t:SetSize(s, s)
            t:SetRotation(spin * p)
            t:SetAlpha(1 - p * p * p)
        end, function() Release(t) end)
    end
end

-- Radial speed lines that spin up and fade.
function FX:Lines(x, y, color, size, dur)
    if not self.layer then return end
    local t = Sprite("lines", "ADD")
    if not t then return end
    K.Tint(t, color or C.white)
    Place(t, x, y)
    local r0 = math.random() * 6.28
    K.Tween(dur or 0.5, function(p)
        local s = size * (0.75 + 0.35 * K.Ease.outCubic(p))
        t:SetSize(s, s)
        t:SetRotation(r0 + p * 0.5)
        t:SetAlpha(0.6 * math.sin(p * math.pi))
    end, function() Release(t) end)
end

-- A blade streak.
function FX:Slash(x, y, color, angle, length)
    if not self.layer then return end
    local t = Sprite("streak")
    if not t then return end
    K.Tint(t, color or C.white)
    Place(t, x, y)
    t:SetRotation(angle or 0.5)
    length = length or 170
    K.Tween(0.26, function(p)
        local s = length * (0.35 + 0.65 * K.Ease.outCubic(math.min(1, p * 2.2)))
        t:SetSize(s, s)
        t:SetAlpha(p < 0.45 and 1 or (1 - (p - 0.45) / 0.55))
    end, function() Release(t) end)
end

-- A soft additive flash.
function FX:Glow(x, y, color, size, dur)
    if not self.layer then return end
    local t = Sprite("glow", "ADD")
    if not t then return end
    K.Tint(t, color or C.white)
    Place(t, x, y)
    K.Tween(dur or 0.35, function(p)
        local s = size * (0.6 + 0.6 * K.Ease.outCubic(p))
        t:SetSize(s, s)
        t:SetAlpha(0.9 * (1 - p))
    end, function() Release(t) end)
end

-- The big moment: lines, ring, sparks.
function FX:Flourish(x, y, color, size)
    size = (size or 1) * (K.db.fx or 1)
    self:Lines(x, y, color, 150 * size, 0.5)
    self:Ring(x, y, color, 24 * size, 100 * size, 0.34)
    self:Sparks(x, y, color, 6, 46 * size)
end
