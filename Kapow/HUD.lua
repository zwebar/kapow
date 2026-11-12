-- HUD: the energy cells, the energy number, the combo pips and the tick runner.
-- Energy can be a "secret" value in combat, so it is only ever handed straight to widgets
-- (StatusBar:SetValue, FontString:SetFormattedText); nothing here does maths on it.
local _, K = ...
local HUD = {}
K.HUD = HUD
local C = K.C

local CELLS = 5
local CELL_W, CELL_H, PITCH = 60, 30, 45
local CELL_Y, PIP_Y = -6, 27
local PIP = 27
local LAG = 0.35 -- how long the pale "just spent" chunk lingers
local PROMPT_W, PROMPT_H, PROMPT_Y = 210, 28, PIP_Y + 44
local CAP_H, CAP_OVERLAP = 22, 3 -- the caption tab, and how far it overlaps the bar
local NUM_EVERY = 0.25 -- while energy regenerates, the number changes at most this often
local NUM_FAST = 0.5 -- after you spend, it follows every change for this long

HUD.CELL_Y, HUD.PIP_Y, HUD.CHIP_Y = CELL_Y, PIP_Y, -52

local PIP_COLORS = { C.yellow, C.yellow, C.orange, C.orange, C.red }
local EMPTY = { 0.24, 0.21, 0.33 }

local EASE = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut

local function CellX(i) return (i - (CELLS + 1) / 2) * PITCH end
local function PipX(i) return CellX(i) + 5 end
HUD.PipX = PipX

local function MakeBar(cell, texture, level)
    local bar = CreateFrame("StatusBar", nil, cell)
    bar:SetAllPoints(cell)
    bar:SetFrameLevel(level)
    bar:SetStatusBarTexture(texture)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    -- Clip the fill to the slanted cell shape.
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(K.ART .. "seg_mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bar)
    local tex = bar:GetStatusBarTexture()
    if tex and tex.AddMaskTexture then tex:AddMaskTexture(mask) end
    return bar
end

function HUD:Build()
    local root = CreateFrame("Frame", "KapowHUD", UIParent)
    root:SetSize(340, 120)
    root:SetFrameStrata("MEDIUM")
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    self.root = root

    -- Everything sits on "body", which is what shakes.
    local body = CreateFrame("Frame", nil, root)
    body:SetSize(340, 120)
    body:SetPoint("CENTER")
    self.body = body

    local fx = CreateFrame("Frame", nil, root)
    fx:SetSize(340, 120)
    fx:SetPoint("CENTER")
    fx:SetFrameLevel(body:GetFrameLevel() + 20)
    self.fx = fx

    local base = body:GetFrameLevel()

    -- Energy cells
    self.cells = {}
    for i = 1, CELLS do
        local x = CellX(i)
        local shadow = K.Tex(body, "BACKGROUND", "seg_mask", CELL_W, CELL_H, -1)
        shadow:SetPoint("CENTER", x + 3, CELL_Y - 4)
        shadow:SetVertexColor(0, 0, 0, 0.5)

        local cell = CreateFrame("Frame", nil, body)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("CENTER", x, CELL_Y)
        cell:SetFrameLevel(base + 1)
        cell.x = x

        cell.bg = K.Tex(cell, "BACKGROUND", "seg_mask")
        cell.bg:SetAllPoints()
        K.Tint(cell.bg, C.night, 0.92)

        cell.lag = MakeBar(cell, "Interface\\Buttons\\WHITE8X8", base + 2)
        cell.lag:SetStatusBarColor(1, 0.93, 0.8, 0.95)
        cell.fill = MakeBar(cell, K.ART .. "seg_fill", base + 3)

        local top = CreateFrame("Frame", nil, cell)
        top:SetAllPoints(cell)
        top:SetFrameLevel(base + 4)
        cell.flash = K.Tex(top, "ARTWORK", "seg_mask")
        cell.flash:SetAllPoints()
        cell.flash:SetBlendMode("ADD")
        cell.flash:SetAlpha(0)
        cell.frame = K.Tex(top, "OVERLAY", "seg_frame")
        cell.frame:SetAllPoints()

        self.cells[i] = cell
    end

    -- Energy number, hugging the left end of the cells
    local num = CreateFrame("Frame", nil, body)
    num:SetSize(64, 40)
    num:SetPoint("RIGHT", body, "CENTER", CellX(1) - CELL_W / 2 + 4, CELL_Y + 1)
    num:SetFrameLevel(base + 6)
    num.back = K.Text(num, "ARTWORK", 30)
    num.back:SetPoint("RIGHT", 2, -3)
    num.back:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    num.text = K.Text(num, "OVERLAY", 30)
    num.text:SetPoint("RIGHT")
    num.text:SetRotation(0.08)
    num.back:SetRotation(0.08)
    local bump = num:CreateAnimationGroup()
    local b = bump:CreateAnimation("Scale")
    b:SetDuration(0.16)
    b:SetScaleFrom(1.28, 1.28)
    b:SetScaleTo(1, 1)
    b:SetOrigin("RIGHT", 0, 0)
    b:SetSmoothing("OUT")
    num.bump = bump
    self.num = num

    -- Tick runner: a bolt that crosses under the cells once per energy tick
    local track = body:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(C.ink[1], C.ink[2], C.ink[3], 0.85)
    track:SetSize(PITCH * (CELLS - 1) + 36, 3)
    track:SetPoint("CENTER", -4, CELL_Y - 21)
    self.track = track
    self.trackW = PITCH * (CELLS - 1) + 36
    local bolt = K.Tex(body, "OVERLAY", "bolt", 17, 17)
    K.Tint(bolt, C.cyan)
    self.bolt = bolt
    track:Hide()
    bolt:Hide()

    -- Combo pips, one above each cell
    self.pips = {}
    for i = 1, CELLS do
        local x = PipX(i)
        local pip = { x = x, on = false }
        pip.shadow = K.Tex(body, "ARTWORK", "pip", PIP, PIP, 0)
        pip.shadow:SetPoint("CENTER", x + 2, PIP_Y - 3)
        pip.shadow:SetVertexColor(0, 0, 0, 0.5)
        pip.glow = K.Tex(body, "ARTWORK", "glow", PIP * 2.3, PIP * 2.3, 1)
        pip.glow:SetPoint("CENTER", x, PIP_Y)
        pip.glow:SetBlendMode("ADD")
        pip.glow:SetAlpha(0)
        pip.tex = K.Tex(body, "ARTWORK", "pip", PIP, PIP, 2)
        pip.tex:SetPoint("CENTER", x, PIP_Y)
        K.Tint(pip.tex, EMPTY)
        self.pips[i] = pip
    end
    self.combo = 0
    self.pipsShown = true

    -- Shown instead of lit pips if the game ever hides the combo count from addons
    local ct = K.Text(body, "OVERLAY", 20)
    ct:SetPoint("LEFT", body, "CENTER", PipX(CELLS) + 20, PIP_Y)
    ct:SetTextColor(C.red[1], C.red[2], C.red[3])
    ct:Hide()
    self.comboText = ct

    -- Prompt: a comic cast bar. A yellow caption tab on top says what to do (KICK IT!); the bar
    -- below carries the spell's icon and name and fills as the cast goes on; a HEAL! burst sits
    -- on its right end when the spell is a heal.
    local prompt = CreateFrame("Frame", nil, body)
    prompt:SetSize(PROMPT_W, PROMPT_H + CAP_H - CAP_OVERLAP)
    prompt:SetPoint("CENTER", body, "CENTER", 0, PROMPT_Y)
    prompt:SetFrameLevel(base + 10)

    local bar = K.Panel(prompt, PROMPT_W, PROMPT_H)
    bar:SetPoint("BOTTOM", prompt, "BOTTOM", 0, 0)
    bar:SetFrameLevel(base + 10)
    bar.bg:SetColorTexture(1, 1, 1, 1)
    K.Tint(bar.bg, C.red)
    prompt.body = bar

    -- the cast's progress: a lighter sweep across the bar
    local fill = CreateFrame("StatusBar", nil, bar)
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", PROMPT_H, -2)
    fill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -2, 2)
    fill:SetFrameLevel(base + 11)
    fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetStatusBarColor(1, 1, 1, 0.28)
    fill:SetMinMaxValues(0, 1)
    fill:Hide()
    prompt.bar = fill

    local face = CreateFrame("Frame", nil, bar)
    face:SetAllPoints(bar)
    face:SetFrameLevel(base + 12)
    local iconInk = face:CreateTexture(nil, "BORDER")
    iconInk:SetColorTexture(C.ink[1], C.ink[2], C.ink[3], 1)
    iconInk:SetSize(PROMPT_H, PROMPT_H)
    iconInk:SetPoint("LEFT", bar, "LEFT", 0, 0)
    prompt.icon = face:CreateTexture(nil, "ARTWORK")
    prompt.icon:SetSize(PROMPT_H - 4, PROMPT_H - 4)
    prompt.icon:SetPoint("CENTER", iconInk, "CENTER", 0, 0)
    prompt.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    prompt.spell = K.Text(face, "OVERLAY", 15, "OUTLINE")
    prompt.spell:SetPoint("LEFT", iconInk, "RIGHT", 7, 0)
    prompt.spell:SetWidth(PROMPT_W - PROMPT_H - 60) -- room for the tag on the right
    prompt.spell:SetJustifyH("LEFT")
    prompt.spell:SetWordWrap(false)
    prompt.spell:SetTextColor(1, 1, 1)

    -- caption tab, overlapping the bar's top edge on the left
    local cap = K.Panel(prompt, 80, CAP_H)
    cap:SetPoint("TOPLEFT", prompt, "TOPLEFT", PROMPT_H - 6, 0)
    cap:SetFrameLevel(base + 14)
    cap.bg:SetColorTexture(1, 1, 1, 1)
    K.Tint(cap.bg, C.yellow)
    cap.text = K.Text(cap, "OVERLAY", 15, "")
    cap.text:SetPoint("CENTER", 0, 0)
    cap.text:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
    cap.text:SetRotation(0.04)
    prompt.cap = cap
    prompt.text = cap.text

    local tag = CreateFrame("Frame", nil, prompt)
    tag:SetSize(10, 10)
    tag:SetPoint("CENTER", bar, "RIGHT", -16, 1)
    tag:SetFrameLevel(base + 15)
    tag.shadow = K.Tex(tag, "BACKGROUND", "burst2", 74, 50)
    tag.shadow:SetPoint("CENTER", 3, -3)
    tag.shadow:SetVertexColor(0, 0, 0, 0.5)
    tag.shape = K.Tex(tag, "BORDER", "burst2", 74, 50)
    tag.shape:SetPoint("CENTER")
    K.Tint(tag.shape, C.yellow)
    tag.text = K.Text(tag, "OVERLAY", 16, "OUTLINE")
    tag.text:SetPoint("CENTER", 0, 0)
    tag.text:SetRotation(-0.12)
    tag:Hide()
    prompt.tag = tag
    local pp = prompt:CreateAnimationGroup()
    pp:SetLooping("BOUNCE")
    local ps = pp:CreateAnimation("Scale")
    ps:SetDuration(0.2)
    ps:SetScaleFrom(1, 1)
    ps:SetScaleTo(1.06, 1.06)
    ps:SetOrigin("CENTER", 0, 0)
    ps:SetSmoothing("IN_OUT")
    prompt.pulse = pp
    prompt:Hide()
    self.prompt = prompt

    -- Mover, shown while unlocked
    local mover = CreateFrame("Frame", nil, root)
    mover:SetAllPoints(root)
    mover:SetFrameLevel(base + 40)
    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(C.cyan[1], C.cyan[2], C.cyan[3], 0.18)
    mover.text = K.Text(mover, "OVERLAY", 13, "OUTLINE")
    mover.text:SetPoint("TOP", 0, -4)
    mover.text:SetText("Kapow - drag me, then /kapow lock")
    mover:Hide()
    self.mover = mover

    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(f)
        if not K.db.locked then f:StartMoving() end
    end)
    root:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local cx, cy = f:GetCenter()
        local ux, uy = UIParent:GetCenter()
        local s = f:GetScale()
        if cx and ux and s and s > 0 then
            K.db.x = math.floor(cx - ux / s + 0.5)
            K.db.y = math.floor(cy - uy / s + 0.5)
        end
        HUD:ApplyPosition()
    end)

    self.maxE = nil
    self.alpha = 1
    self:SetPalette(false)
    self:ApplyPosition()
    self:ApplyLock()

    K.Every(function(dt, now) HUD:OnUpdate(dt, now) end)
end

function HUD:ApplyPosition()
    local root = self.root
    root:SetScale(K.db.scale or 1)
    root:ClearAllPoints()
    root:SetPoint("CENTER", UIParent, "CENTER", K.db.x or 0, K.db.y or -190)
end

function HUD:ApplyLock()
    local unlocked = not K.db.locked
    self.root:EnableMouse(unlocked)
    self.mover:SetShown(unlocked)
end

-- Yellow by day, purple in stealth.
function HUD:SetPalette(stealth)
    self.stealth = stealth
    local c = stealth and C.purple or C.yellow
    self.fillColor = c
    for i = 1, CELLS do
        self.cells[i].fill:SetStatusBarColor(c[1], c[2], c[3], 1)
    end
    local t = stealth and C.purple or C.paper
    self.num.text:SetTextColor(t[1], t[2], t[3])
end

--------------------------------------------------------------------------------
-- Energy
--------------------------------------------------------------------------------
-- value may be secret; maxValue never is.
function HUD:SetEnergy(value, maxValue, instant)
    if maxValue ~= self.maxE then
        self.maxE = maxValue
        local seg = maxValue / CELLS
        for i = 1, CELLS do
            local cell = self.cells[i]
            cell.fill:SetMinMaxValues((i - 1) * seg, i * seg)
            cell.lag:SetMinMaxValues((i - 1) * seg, i * seg)
        end
    end
    for i = 1, CELLS do
        self.cells[i].fill:SetValue(value, (not instant) and EASE or nil)
    end
    -- The number: spending shows at once; regeneration is shown in calm steps rather than
    -- every few milliseconds. (The value may be secret, so this goes by time, not by size.)
    self.numValue = value
    local now = GetTime()
    if instant or now < (self.numFastUntil or 0) or now - (self.numAt or 0) >= NUM_EVERY then
        self:ShowNumber(now)
    else
        self.numDirty = true
    end

    self.lagValue = value
    if instant then
        self.lagDue = nil
        for i = 1, CELLS do self.cells[i].lag:SetValue(value) end
    elseif not self.lagDue then
        self.lagDue = GetTime() + LAG
    end
end

function HUD:ShowNumber(now)
    self.numAt, self.numDirty = now, false
    self.num.text:SetFormattedText("%d", self.numValue)
    self.num.back:SetFormattedText("%d", self.numValue)
end

-- Energy is about to drop (a cast went off): let the number follow every change for a moment.
function HUD:ExpectSpend()
    local now = GetTime()
    self.numFastUntil = now + NUM_FAST
    if self.numDirty then self:ShowNumber(now) end
end

function HUD:BumpNumber()
    self.num.bump:Stop()
    self.num.bump:Play()
end

local function FlashCell(cell, color, alpha, dur)
    K.Tint(cell.flash, color)
    K.Cancel(cell.flashTween)
    cell.flashTween = K.Tween(dur or 0.25, function(p)
        cell.flash:SetAlpha(alpha * (1 - p))
    end)
end

-- Energy rose from prev to value: any cell that just filled up pops.
function HUD:CellCross(prev, value)
    if not prev or not value then return end
    local seg = (self.maxE or 100) / CELLS
    for i = 1, CELLS do
        local edge = i * seg - 0.5
        if prev < edge and value >= edge then
            FlashCell(self.cells[i], C.white, 0.85, 0.3)
        end
    end
end

-- A regular energy tick landed. Kept quiet on purpose, it happens every two seconds:
-- a soft flash on the cell being filled and a blink at the end of the tick track.
-- amount and value are nil when the game hides them.
function HUD:Tick(amount, value)
    if value then
        local seg = (self.maxE or 100) / CELLS
        local i = math.max(1, math.min(CELLS, math.floor(value / seg) + 1))
        FlashCell(self.cells[i], C.white, 0.3, 0.25)
        if amount then self:CellCross(value - amount, value) end
    end
    K.FX:Glow(self.trackW / 2 - 4, CELL_Y - 21, C.cyan, 30, 0.25)
end

-- A big chunk of energy at once (Thistle Tea, Adrenaline Rush refunds...): that one is worth a pop.
function HUD:Refill(amount, value)
    for i = 1, CELLS do FlashCell(self.cells[i], C.white, 0.5, 0.3) end
    self:CellCross(value and amount and (value - amount) or nil, value)
    if amount then
        K.FX:Pop("+" .. math.floor(amount + 0.5), self.trackW / 2 + 10, CELL_Y - 16, C.cyan, 15, 18)
    end
end

-- Spending is already shown by the cells draining; the number just bumps.
function HUD:Spend(cost)
    self:ExpectSpend()
    self:BumpNumber()
end

function HUD:Shake(strength, dur)
    local body, root = self.body, self.root
    K.Cancel(self.shake)
    self.shake = K.Tween(dur or 0.22, function(p)
        local a = (1 - p) * strength
        body:SetPoint("CENTER", root, "CENTER", (math.random() * 2 - 1) * a, (math.random() * 2 - 1) * a)
    end, function()
        body:SetPoint("CENTER", root, "CENTER", 0, 0)
    end)
end

-- "Not enough energy"
function HUD:Error()
    local now = GetTime()
    for i = 1, CELLS do FlashCell(self.cells[i], C.red, 0.75, 0.32) end
    self:Shake(5, 0.25)
    if not self.lastError or now - self.lastError > 0.9 then
        self.lastError = now
        K.FX:Pop("NO ENERGY!", 0, CELL_Y + 22, C.red, 15, 14)
    end
end

-- Only remembered: nothing is drawn for "full".
function HUD:SetFull(full)
    self.full = full
end

local function Color(c)
    if CreateColor then return CreateColor(c[1], c[2], c[3], 1) end
    return { r = c[1], g = c[2], b = c[3], a = 1 }
end
local QUESTION_MARK = 134400

-- The KICK IT! box above the HUD, or nil text to hide it. cast describes what the target is
-- casting (Tracker's ReadCast); any part of it may be secret, so it is only handed to widgets:
-- the name and icon are displayed, and "helpful" / "can't be interrupted" pick colours and
-- visibility through the game's boolean setters without the addon ever reading them.
-- mode "wait" (nothing to stop it with right now) shows the box dimmer and without pulsing.
function HUD:SetPrompt(text, cast, mode)
    local prompt = self.prompt
    if not text then
        if self.promptText then
            prompt.pulse:Stop()
            prompt:Hide()
        end
        self.promptText, self.promptCast, self.promptMode = nil, nil, nil
        return
    end
    mode = mode or "go"
    if text == self.promptText and cast == self.promptCast and mode == self.promptMode then return end
    local nowGo = mode == "go" and self.promptMode ~= "go"
    self.promptText, self.promptCast, self.promptMode = text, cast, mode
    local alpha = mode == "go" and 1 or 0.8
    cast = cast or {}
    local IsSecret = K.IsSecret

    prompt.text:SetText(text)
    prompt.cap:SetWidth(math.max(64, (prompt.text:GetStringWidth() or 60) + 16))
    K.Tint(prompt.cap.bg, mode == "go" and C.yellow or C.grey)
    if IsSecret(cast.name) or cast.name ~= nil then
        prompt.spell:SetText(cast.name)
    else
        prompt.spell:SetText("")
    end
    if IsSecret(cast.icon) or cast.icon ~= nil then
        prompt.icon:SetTexture(cast.icon)
    else
        prompt.icon:SetTexture(QUESTION_MARK)
    end

    -- heal or not
    local tag = prompt.tag
    if IsSecret(cast.helpful) then
        -- hidden: a helpful spell cast by an enemy is all but always a heal
        tag.text:SetText("HEAL!")
        tag.text:SetTextColor(C.red[1], C.red[2], C.red[3])
        tag:Show()
        tag:SetAlphaFromBoolean(cast.helpful, 1, 0)
        prompt.body.bg:SetVertexColorFromBoolean(cast.helpful, Color(C.teal), Color(C.red))
    else
        local label = (cast.heal and "HEAL!") or (cast.helpful and "BUFF!") or nil
        tag:SetAlpha(1)
        tag:SetShown(label ~= nil)
        if label then
            local c = cast.heal and C.red or C.purple
            tag.text:SetText(label)
            tag.text:SetTextColor(c[1], c[2], c[3])
        end
        K.Tint(prompt.body.bg, cast.helpful and C.teal or C.red)
    end

    -- a shielded cast cannot be kicked: the box stays out of the way
    if IsSecret(cast.notInterruptible) then
        prompt:SetAlphaFromBoolean(cast.notInterruptible, 0, alpha)
    else
        prompt:SetAlpha(alpha)
    end

    -- how far along the cast is
    local s, e = cast.startMs, cast.endMs
    if not IsSecret(s) and not IsSecret(e) and type(s) == "number" and type(e) == "number" and e > s then
        prompt.bar:SetMinMaxValues(s / 1000, e / 1000)
        prompt.bar:SetValue(GetTime())
        prompt.bar:Show()
        prompt.bar.reverse = cast.channel
        self.castBar = true
    else
        prompt.bar:Hide()
        self.castBar = false
    end

    prompt:Show()
    if mode ~= "go" then
        prompt.pulse:Stop()
    elseif nowGo then
        -- just became something you can do: pulse and a ring to catch the eye
        prompt.pulse:Play()
        K.FX:Ring(0, PROMPT_Y, cast.helpful == true and C.teal or C.red, 50, 150, 0.3)
    end
end

-- lastTick: GetTime() of the last energy tick, or nil to hide the runner.
function HUD:SetTickClock(lastTick)
    self.lastTick = lastTick
    local show = lastTick ~= nil and K.db.ticker ~= false
    self.track:SetShown(show)
    self.bolt:SetShown(show)
end

--------------------------------------------------------------------------------
-- Combo points
--------------------------------------------------------------------------------
local function PipSize(pip, s)
    pip.tex:SetSize(PIP * s, PIP * s)
    pip.shadow:SetSize(PIP * s, PIP * s)
end

-- The HUD's own pips step aside while the arc on the target's nameplate shows them.
function HUD:SetPipsShown(show)
    if show == self.pipsShown then return end
    self.pipsShown = show
    for i = 1, CELLS do
        local pip = self.pips[i]
        pip.tex:SetShown(show)
        pip.shadow:SetShown(show)
        pip.glow:SetShown(show)
    end
    if not show then self.comboText:Hide() end
end

function HUD:SetCombo(n, quiet)
    K.Plate:SetCombo(n, quiet)
    local loud = not quiet
    self.comboText:Hide()
    local was = self.combo or 0
    self.combo = n
    if not self.pipsShown then quiet = true end -- the arc does the popping
    for i = 1, CELLS do
        local pip = self.pips[i]
        local on = i <= n
        if on ~= pip.on then
            pip.on = on
            K.Cancel(pip.tween)
            if on then
                local c = PIP_COLORS[i]
                pip.color = c
                K.Tint(pip.tex, c)
                if quiet then
                    PipSize(pip, 1)
                else
                    pip.tween = K.Tween(0.3, function(p)
                        PipSize(pip, 0.35 + 0.65 * K.Ease.outBack(p))
                    end)
                    K.FX:Ring(pip.x, PIP_Y, c, 14, 50, 0.28)
                end
            else
                K.Tint(pip.tex, EMPTY)
                PipSize(pip, 1)
                pip.glow:SetAlpha(0)
                if not quiet and pip.color then
                    -- spent: the pip bursts, one after another
                    local c, x = pip.color, pip.x
                    K.After((i - 1) * 0.035, function()
                        K.FX:Ring(x, PIP_Y, c, 20, 60, 0.25)
                    end)
                end
            end
        end
    end
    if n >= CELLS and was < CELLS and not quiet then
        K.FX:Pop("MAX!", PipX(CELLS) + 34, PIP_Y + 2, C.red, 17, 16)
    end
    if n >= CELLS and was < CELLS and loud then self:Shake(3, 0.2) end
end

-- The count itself is hidden: show it as a number the game fills in.
function HUD:SetComboSecret(value)
    K.Plate:SetSecret(value)
    self.combo = nil
    for i = 1, CELLS do
        local pip = self.pips[i]
        pip.on = false
        K.Tint(pip.tex, EMPTY)
        PipSize(pip, 1)
        pip.glow:SetAlpha(0)
    end
    self.comboText:SetFormattedText("%d", value)
    self.comboText:SetShown(self.pipsShown)
end

--------------------------------------------------------------------------------
-- Per frame
--------------------------------------------------------------------------------
function HUD:OnUpdate(dt, now)
    -- the cast bar in the KICK IT! box
    if self.castBar and self.promptText then
        local bar = self.prompt.bar
        local lo, hi = bar:GetMinMaxValues()
        local v = math.min(hi, math.max(lo, now))
        bar:SetValue(bar.reverse and (hi - (v - lo)) or v)
    end

    -- the number catches up after a quiet spell
    if self.numDirty and now - (self.numAt or 0) >= NUM_EVERY then self:ShowNumber(now) end

    -- the pale chunk catches up with the real value
    if self.lagDue and now >= self.lagDue then
        self.lagDue = nil
        for i = 1, CELLS do self.cells[i].lag:SetValue(self.lagValue, EASE) end
    end

    -- tick runner
    if self.lastTick then
        local p = ((now - self.lastTick) % 2) / 2
        self.bolt:SetPoint("CENTER", self.body, "CENTER", -4 - self.trackW / 2 + self.trackW * p, CELL_Y - 21)
    end

    -- five points: the pips throb
    if self.combo and self.combo >= CELLS then
        local s = 1 + 0.09 * math.sin(now * 11)
        for i = 1, CELLS do
            local pip = self.pips[i]
            if not pip.tween or pip.tween.dead then PipSize(pip, s) end
            pip.glow:SetVertexColor(C.red[1], C.red[2], C.red[3])
            pip.glow:SetAlpha(0.45 + 0.25 * math.sin(now * 11))
        end
    elseif self.glowing then
        for i = 1, CELLS do
            local pip = self.pips[i]
            pip.glow:SetAlpha(0)
            if not pip.tween or pip.tween.dead then PipSize(pip, 1) end
        end
    end
    self.glowing = self.combo and self.combo >= CELLS

    -- Shown in combat only (and for the demo, or while unlocked). It stays up for a moment
    -- after combat so the last burst (K.O.!) can finish. /kapow idle sets the opacity out of
    -- combat; 0, the default, hides it.
    if self.inCombat then self.lastCombat = now end
    local busy = K.demo or self.inCombat or not K.db.locked
        or (self.lastCombat ~= nil and now - self.lastCombat < 2)
    local target = busy and 1 or (K.db.idle or 0)
    if self.alpha ~= target then
        if self.alpha < target then
            self.alpha = math.min(target, self.alpha + dt * 8) -- pop up at once on a pull
        else
            self.alpha = math.max(target, self.alpha - dt * 2)
        end
        self.root:SetAlpha(self.alpha)
    end
end
