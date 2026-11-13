-- Swing: the weapon swing timer, a bar along the bottom of the HUD (under the countdown boxes).
-- It fills as your next melee swing comes round, flashes when one lands, and shows your weapon
-- speed. Shown while you auto-attack.
--
-- There is no combat log for addons, so a swing is read from what happens to your target: a
-- physical hit, or a dodge/parry/miss/block (spells are not physical, and resists are spells).
-- The game does not say whose hit it was, so one only counts when it lands about when your next
-- swing is due; hits from others in a group mostly fall outside that and are ignored.
-- The same file is used by Kapow and Holy Moly.
local _, K = ...
local Swing = { speed = 3.5, on = false }
K.Swing = Swing
local C = K.C

local H = 14
local MISSES = { DODGE = true, PARRY = true, MISS = true, BLOCK = true, DEFLECT = true }

local function Style(key, default)
    return K.S and K.S[key] or default
end

-- parent: the HUD's body; width: the bar's length; level: a frame level to build on.
function Swing:Build(parent, width, level)
    self.parent, self.width = parent, width
    local dark = Style("darkPlates", false)
    local bar = K.Panel(parent, width, H)
    bar:SetFrameLevel(level)
    local bg = dark and K.Mix(C.iron, C.ink, 0.3) or C.night
    bar.bg:SetColorTexture(bg[1], bg[2], bg[3], 1)

    local fillC = dark and (C.goldText or C.yellow) or C.paper
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMLEFT", 2, 2)
    fill:SetWidth(0.01)
    fill:SetColorTexture(fillC[1], fillC[2], fillC[3], 0.9)
    bar.fill = fill

    -- a bright edge on the front of the fill, so the moment it fills is easy to see
    local tip = bar:CreateTexture(nil, "OVERLAY")
    tip:SetSize(3, H - 4)
    tip:SetPoint("LEFT", fill, "RIGHT", -1, 0)
    tip:SetColorTexture(1, 1, 1, 0.9)
    bar.tip = tip

    local flash = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    flash:SetPoint("TOPLEFT", 2, -2)
    flash:SetPoint("BOTTOMRIGHT", -2, 2)
    flash:SetColorTexture(1, 1, 1, 1)
    flash:SetAlpha(0)
    bar.flash = flash

    local tc = dark and (C.bone or C.paper) or C.paper
    local label = K.Text(bar, "OVERLAY", 10, "OUTLINE")
    label:SetPoint("LEFT", 5, 0)
    label:SetText("SWING")
    label:SetTextColor(tc[1], tc[2], tc[3])
    local speed = K.Text(bar, "OVERLAY", 10, "OUTLINE")
    speed:SetPoint("RIGHT", -5, 0)
    speed:SetTextColor(tc[1], tc[2], tc[3])
    bar.label, bar.speed = label, speed

    self.bar = bar
    self:Place(nil)
    self:Set(false)
    K.Every(function(_, now) Swing:OnUpdate(now) end)
end

-- Puts the bar's centre at height y on the HUD (the countdown boxes call this as they grow).
function Swing:Place(y)
    if not self.bar then return end
    self.y = y or self.y or -60
    self.bar:ClearAllPoints()
    self.bar:SetPoint("CENTER", self.parent, "CENTER", -4, self.y)
end

-- at: GetTime() of the last swing (nil: auto-attack is on but no swing seen yet); false hides
-- the bar. speed: seconds between swings.
function Swing:Set(at, speed)
    local bar = self.bar
    if not bar then return end
    self.speedShown = speed or self.speedShown or self.speed
    if at == false then
        bar:Hide()
        self.at = nil
        return
    end
    bar:Show()
    bar.speed:SetFormattedText("%.1fs", self.speedShown)
    self.at = at
    if at then
        K.Cancel(self.flashTween)
        self.flashTween = K.Tween(0.25, function(p) bar.flash:SetAlpha(0.6 * (1 - p)) end)
    else
        bar.fill:SetWidth(0.01)
    end
end

function Swing:OnUpdate(now)
    local bar = self.bar
    if not (bar and self.at) then return end
    local p = math.min(1, (now - self.at) / (self.speedShown or 3))
    bar.fill:SetWidth(math.max(0.01, (self.width - 4) * p))
    -- full and waiting for the swing: the edge pulses
    bar.tip:SetAlpha(p >= 1 and (0.5 + 0.5 * math.sin(now * 12)) or 0.9)
end

--------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------
local IsSecret = K.IsSecret

function Swing:AttackSpeed()
    if not UnitAttackSpeed then return end
    local ok, s = pcall(UnitAttackSpeed, "player")
    if ok and not IsSecret(s) and type(s) == "number" and s > 0.5 then
        self.speed = s
        if self.on then self:Set(self.last, s) end
    end
end

-- Auto-attack switched on or off.
function Swing:AutoAttack(on)
    self.on, self.last = on, nil
    if on then
        self:AttackSpeed()
        self:Set(nil, self.speed)
    else
        self:Set(false)
    end
end

-- Something happened to the target (UNIT_COMBAT): count it as your swing if it can be one.
function Swing:Seen(action, school)
    if not self.on or IsSecret(action) then return end
    local melee
    if action == "WOUND" then
        -- 1 is physical; a hidden or missing school could be anything, so it may still count
        melee = IsSecret(school) or school == nil or school == 1
    else
        melee = MISSES[action] or false
    end
    if not melee then return end
    local now = GetTime()
    -- the first swing, or one about when the next is due (not much earlier)
    if self.last and now - self.last < self.speed * 0.8 then return end
    self.last = now
    self:Set(now, self.speed)
end

-- Listens for auto-attack and weapon speed changes, and drives the bar.
function Swing:Start()
    local f = CreateFrame("Frame")
    pcall(f.RegisterEvent, f, "PLAYER_ENTER_COMBAT")
    pcall(f.RegisterEvent, f, "PLAYER_LEAVE_COMBAT")
    pcall(f.RegisterUnitEvent, f, "UNIT_ATTACK_SPEED", "player")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTER_COMBAT" then
            Swing:AutoAttack(true)
        elseif event == "PLAYER_LEAVE_COMBAT" then
            Swing:AutoAttack(false)
        else
            Swing:AttackSpeed()
        end
    end)
    self:AttackSpeed()
    self:AutoAttack(false)
end
