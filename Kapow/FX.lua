-- FX: the comic effects. Word bursts (POW!), small floating pops, rings, sparks and speed
-- lines. Everything is positioned relative to the centre of the HUD.
local _, K = ...
local FX = {}
K.FX = FX
local C = K.C

-- Word bursts land to the left and right, a little above the HUD: clear of the middle of the
-- screen (your character and your target) and of the unit frames lower down at the sides.
-- There is one spot on each side, so you always know where to look: left for what you did
-- (SLASH!, KICK!), right for what happened (CRIT!, DODGED!, K.O.!). A new word replaces the one
-- on its side instead of piling up.
local WORD_EDGE, WORD_Y = 175, 150 -- inner edge's distance from the HUD's centre, height
local WORD_JITTER_X, WORD_JITTER_Y = 26, 22 -- how far a burst may stray from its spot
local WORD_FONT = 30              -- lettering size at size 1

local words, pops, sprites = {}, {}, {}
local current = {} -- side -> the word showing there
local seq = 0

function FX:Build()
    self.layer = K.HUD.fx
    -- Damage numbers and CRIT! go over the target, where the game's own combat numbers would:
    -- a layer of their own, not part of the HUD (they do not move or fade with it).
    local hits = CreateFrame("Frame", nil, UIParent)
    hits:SetSize(10, 10)
    hits:SetFrameStrata("MEDIUM")
    hits:SetFrameLevel(40)
    hits:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    self.hits = hits
end

-- Puts the hit layer just above the target's nameplate (clear of the combo arc), or in the
-- middle of the screen above your character when the target has no nameplate we can use.
function FX:AimHits()
    local hits = self.hits
    if not hits then return end
    local plate
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        plate = K.Safe(C_NamePlate.GetNamePlateForUnit, "target")
        if K.IsSecret(plate) or type(plate) ~= "table" then plate = nil end
    end
    hits:ClearAllPoints()
    if plate then
        hits:SetPoint("BOTTOM", plate, "TOP", 0, 72)
    else
        hits:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
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
    pop:SetDuration(0.12)
    pop:SetScaleFrom(0.4, 0.4)
    pop:SetScaleTo(1.12, 1.12)
    pop:SetOrigin("CENTER", 0, 0)
    pop:SetSmoothing("OUT")

    local settle = ag:CreateAnimation("Scale")
    settle:SetOrder(2)
    settle:SetDuration(0.1)
    settle:SetScaleFrom(1.12, 1.12)
    settle:SetScaleTo(1, 1)
    settle:SetOrigin("CENTER", 0, 0)
    settle:SetSmoothing("IN_OUT")

    local fade = ag:CreateAnimation("Alpha")
    fade:SetOrder(3)
    fade:SetDuration(0.3)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)

    local drift = ag:CreateAnimation("Translation")
    drift:SetOrder(3)
    drift:SetDuration(0.3)
    drift:SetOffset(0, 8)
    drift:SetSmoothing("IN")

    f.ag, f.tail = ag, { fade, drift }
    ag:SetScript("OnFinished", function()
        f:Hide()
        f.busy = false
        if current[f.side] == f then current[f.side] = nil end
    end)
    return f
end

local function DropWord(f)
    f.ag:Stop()
    f:Hide()
    f.busy = false
    if current[f.side] == f then current[f.side] = nil end
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
        DropWord(oldest)
        return oldest
    end
    local f = NewWord()
    words[#words + 1] = f
    return f
end

-- FX:Word("KICK!", { color = C.cyan, size = 1, shape = "burst", sub = "412", hold = 0.9, side = -1 })
-- side: -1 (left, the default) for your own abilities, 1 (right) for what happened.
function FX:Word(text, o)
    if not self.layer then return end
    o = o or {}
    -- side: -1 left, 1 right of the HUD; 0 over the target (o.mid)
    local side = o.mid and 0 or (o.side == 1) and 1 or -1
    if current[side] then DropWord(current[side]) end
    local f = AcquireWord()
    f.busy = true
    f.side = side
    current[side] = f
    seq = seq + 1
    f.born = seq

    local size = o.size or 1
    local font = math.floor(WORD_FONT * size + 0.5)
    SetFontSize(f.text, font)
    SetFontSize(f.back, font)
    f.text:SetText(text)
    f.back:SetText(text)
    local tc = o.textColor or C.white
    f.text:SetTextColor(tc[1], tc[2], tc[3])

    if o.sub then
        SetFontSize(f.sub, math.floor((o.subSize or 17) * math.max(size, 0.9) + 0.5), o.subFlags or "OUTLINE")
        if type(o.sub) == "string" then
            f.sub:SetText(o.sub)
        else
            -- a number, possibly hidden from us in combat: the widget can still show it
            f.sub:SetFormattedText("%d", o.sub)
        end
        local sc = o.subColor or C.paper
        f.sub:SetTextColor(sc[1], sc[2], sc[3])
        f.sub:Show()
    else
        f.sub:Hide()
    end

    local w = math.max(f.text:GetStringWidth() or 0, #text * font * 0.42)
    local sw = math.max(w * 1.3 + 36, 110 * size)
    local sh = math.max(font * 2.6, sw * 0.55) + (o.sub and 18 or 0)
    local art = K.ART .. (o.shape or "burst")
    f.shape:SetTexture(art)
    f.shadow:SetTexture(art)
    f.shape:SetSize(sw, sh)
    f.shadow:SetSize(sw, sh)
    K.Tint(f.shape, o.color or C.yellow)

    -- A lean towards the middle with a little variety, but no wobble while it is up, so the
    -- word can still be read at a glance.
    local tilt = o.tilt or (-side * 0.06 + (math.random() * 2 - 1) * 0.05)
    f.text:SetRotation(tilt)
    f.back:SetRotation(tilt)
    local lean = -side * 0.08 + (math.random() * 2 - 1) * 0.08
    f.shape:SetRotation(lean)
    f.shadow:SetRotation(lean)

    -- /kapow fx: the whole burst can be made smaller or larger. Offsets are in the frame's
    -- own scale, hence the division below.
    local s = K.db.fx or 1
    -- Placed by its inner edge, so a wide burst grows outward instead of over the HUD, and
    -- nudged around its side's spot so it does not land in exactly the same place each time.
    -- A mid burst goes over the target instead, nudged a little.
    local parent = (side == 0) and self.hits or self.layer
    local x, y
    if side == 0 then
        self:AimHits()
        x, y = (math.random() * 2 - 1) * 14, 30 + (math.random() * 2 - 1) * 8
    else
        x = side * (WORD_EDGE + math.random() * WORD_JITTER_X + sw * s / 2)
        y = WORD_Y + (math.random() * 2 - 1) * WORD_JITTER_Y
    end
    f:SetParent(parent)
    f:SetScale(s)
    f:ClearAllPoints()
    f:SetPoint("CENTER", parent, "CENTER", x / s, y / s)
    f:SetFrameLevel(parent:GetFrameLevel() + 1 + (seq % 30))

    local hold = o.hold or 0.9
    for i = 1, #f.tail do f.tail[i]:SetStartDelay(hold) end
    f.ag:Stop()
    f:SetAlpha(1)
    f:Show()
    f.ag:Play()
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

-- parent: the frame x, y are relative to (default the HUD's effect layer)
function FX:Pop(text, x, y, color, size, rise, parent)
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
    if type(text) == "string" then
        f.text:SetText(text)
        f.back:SetText(text)
    else
        -- a number, possibly hidden from us in combat: the widget can still show it
        f.text:SetFormattedText("%d", text)
        f.back:SetFormattedText("%d", text)
    end
    color = color or C.white
    f.text:SetTextColor(color[1], color[2], color[3])
    local tilt = (math.random() * 2 - 1) * 0.1
    f.text:SetRotation(tilt)
    f.back:SetRotation(tilt)
    f.rise:SetOffset(0, rise or 24)
    f:ClearAllPoints()
    parent = parent or self.layer
    f:SetParent(parent)
    f:SetFrameLevel(parent:GetFrameLevel() + 2)
    f:SetPoint("CENTER", parent, "CENTER", x + (math.random() * 2 - 1) * 8, y + (math.random() * 2 - 1) * 5)
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
