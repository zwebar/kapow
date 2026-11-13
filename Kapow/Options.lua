-- Options: a small page under Options > AddOns > Kapow, built with Blizzard's Settings panel.
-- The settings live in KapowDB (the same values the /kapow commands change), so the page and
-- the commands always agree.
local _, K = ...
local O = {}
K.Options = O

local function Percent(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local function Times(v) return string.format("%.2fx", v) end
local function Pixels(v) return string.format("%d", math.floor(v + 0.5)) end

-- What to do when a setting changes (the rest are read live).
local APPLY = {
    scale = function() if K.built then K.HUD:ApplyPosition() end end,
    locked = function() if K.built then K.HUD:ApplyLock() end end,
    ticker = function() if K.built then K.HUD:SetTickClock(K.HUD.lastTick) end end,
    pips = function() if K.built then K.Plate:Reanchor() end end,
    arcY = function() if K.built then K.Plate:Reanchor() end end,
    hideNative = function() K.ApplyNativeDamage() end,
}

function O:Build()
    local db, D = KapowDB, K.DEFAULTS
    local cat = Settings.RegisterVerticalLayoutCategory("Kapow")
    local layout = SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(cat)

    local function Register(key, kind, name)
        local s = Settings.RegisterAddOnSetting(cat, "KAPOW_" .. key:upper(), key, db, kind, name, D[key])
        if APPLY[key] then s:SetValueChangedCallback(function() APPLY[key]() end) end
        return s
    end
    local function Header(text)
        if layout and CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end
    local function Checkbox(key, name, tip)
        Settings.CreateCheckbox(cat, Register(key, Settings.VarType.Boolean, name), tip)
    end
    local function Slider(key, name, tip, lo, hi, step, fmt)
        local opts = Settings.CreateSliderOptions(lo, hi, step)
        if MinimalSliderWithSteppersMixin then
            opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, fmt)
        end
        Settings.CreateSlider(cat, Register(key, Settings.VarType.Number, name), opts, tip)
    end
    local function Button(name, text, tip, fn)
        if layout and CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer(name, text, fn, tip, true))
        end
    end

    Header("HUD")
    Checkbox("locked", "Lock the HUD", "Untick to drag the HUD somewhere else, then tick again.")
    Slider("scale", "Size", "How big the HUD is.", 0.5, 2.5, 0.05, Times)
    Slider("idle", "Opacity when idle", "How visible the HUD is out of combat with nothing going on. 0% hides it.",
        0, 1, 0.05, Percent)
    Checkbox("ticker", "Energy tick timer", "The bolt under the energy cells that arrives as the next energy tick lands.")

    Header("Combo points")
    Settings.CreateDropdown(cat, Register("pips", Settings.VarType.String, "Show combo points"), function()
        local c = Settings.CreateControlTextContainer()
        c:Add("plate", "Above the target's nameplate", "An arc over your target. On the HUD when it has no nameplate.")
        c:Add("hud", "On the HUD", "Above the energy cells.")
        c:Add("both", "Both", "Over the target and on the HUD.")
        return c:GetData()
    end, "Where the combo point pips appear.")
    Slider("arcY", "Arc height", "How far above the nameplate the arc sits.", -40, 80, 1, Pixels)

    Header("Effects")
    Checkbox("words", "Ability bursts", "POW!-style words for your abilities (SLASH!, GOUGE!, EVISCERATE!...).")
    Slider("fx", "Burst size", "How big the word bursts are.", 0.5, 1.5, 0.05, Times)
    Checkbox("hits", "CRIT! and DODGED!", "Words for what happens to your target. Only when you are not in a group, "
        .. "since the game does not say whose hit it was.")
    Checkbox("dmg", "Damage numbers", "Small numbers for your ordinary hits (crits get the big CRIT! burst). "
        .. "Only when you are not in a group.")
    Checkbox("hideNative", "Hide the game's own damage numbers", "Switches off the numbers the game shows over "
        .. "your target, so only Kapow's are left. Untick to bring the game's back as they were.")
    Checkbox("prompt", "KICK IT! cast bar", "Shows what your target is casting, flags heals, and tells you to "
        .. "Kick, Gouge or Kidney Shot it.")

    Header("")
    Button("Try it out", "Play demo", "A 15-second pretend fight showing every effect.", function()
        if SettingsPanel and SettingsPanel.Close then SettingsPanel:Close() end
        K.Build()
        K.Demo:Run()
    end)
    Button("Position", "Reset", "Puts the HUD back in its default spot and size.", function()
        SlashCmdList["KAPOW"]("reset")
    end)

    Settings.RegisterAddOnCategory(cat)
    self.category = cat
end

-- Called once the saved settings are loaded.
function O:Register()
    if self.category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
        return
    end
    local ok, err = pcall(O.Build, O)
    if not ok then
        self.failed = tostring(err)
    end
end

function O:Open()
    if self.category and Settings.OpenToCategory then
        local id = self.category.GetID and self.category:GetID() or self.category.ID
        Settings.OpenToCategory(id)
        return true
    end
    return false
end
