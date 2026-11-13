-- Kapow: a comic-book HUD for rogues.
-- Core: shared namespace, colours, the tween driver, saved settings and the slash command.
local ADDON, K = ...

K.ART = "Interface\\AddOns\\" .. ADDON .. "\\Art\\"
-- Lettering: Bangers (SIL Open Font License, see Fonts\\OFL.txt). If it cannot be loaded the
-- game's own chunky damage-number font stands in.
K.FONT = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\Bangers-Regular.ttf"
K.FONT_FALLBACK = "Fonts\\skurri.ttf"

K.C = {
    ink    = { 0.05, 0.04, 0.08 },
    paper  = { 1.00, 0.96, 0.84 },
    white  = { 1.00, 1.00, 1.00 },
    yellow = { 1.00, 0.82, 0.25 },
    orange = { 1.00, 0.54, 0.12 },
    red    = { 1.00, 0.20, 0.33 },
    pink   = { 1.00, 0.18, 0.58 },
    cyan   = { 0.18, 0.89, 0.90 },
    purple = { 0.55, 0.42, 1.00 },
    teal   = { 0.10, 0.83, 0.64 },
    grey   = { 0.62, 0.62, 0.68 },
    night  = { 0.13, 0.11, 0.20 },
}

local DEFAULTS = {
    x = 0, y = -190,   -- offset from the centre of the screen
    scale = 1,
    locked = true,
    idle = 0,          -- HUD opacity out of combat (0: hidden)
    fx = 1,            -- size of the word bursts
    ticker = true,     -- the bolt under the cells that counts down to the next energy tick
    pips = "plate",    -- combo points: "plate" (arc on the target's nameplate), "hud" or "both"
    arcY = 2,          -- how high the arc sits above the nameplate
    words = true,      -- POW! bursts for abilities
    hits = true,       -- CRIT! / DODGED! from what happens to the target
    dmg = true,        -- small damage numbers for your ordinary hits
    prompt = true,     -- KICK IT! when the target starts casting
}
K.DEFAULTS = DEFAULTS

-- Some values are hidden from addons in combat ("secret"): they can be handed to widgets,
-- but any maths or comparison on them is an error. Everything that reads the game checks first.
local issecretvalue = issecretvalue
function K.IsSecret(v)
    if issecretvalue then return issecretvalue(v) and true or false end
    return false
end

-- Calls fn and swallows errors; returns nil if it failed.
function K.Safe(fn, ...)
    if not fn then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

function K.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd23fKapow|r " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Easing
--------------------------------------------------------------------------------
K.Ease = {}
function K.Ease.outCubic(p) p = 1 - p; return 1 - p * p * p end
function K.Ease.inCubic(p) return p * p * p end
function K.Ease.outBack(p)
    local c = 2.2
    p = p - 1
    return 1 + (c + 1) * p * p * p + c * p * p
end
function K.Ease.outElastic(p)
    if p <= 0 then return 0 elseif p >= 1 then return 1 end
    return (2 ^ (-9 * p)) * math.sin((p * 8 - 0.75) * (2 * math.pi) / 3) + 1
end

--------------------------------------------------------------------------------
-- Tween driver: one OnUpdate for everything that moves.
--------------------------------------------------------------------------------
local driver = CreateFrame("Frame")
local tweens, tickers = {}, {}

-- Runs step(p) with p going 0..1 over dur seconds, then done().
function K.Tween(dur, step, done)
    local t = { t = 0, dur = dur, step = step, done = done }
    tweens[#tweens + 1] = t
    step(0)
    return t
end

function K.Cancel(t)
    if t then t.dead = true end
end

-- fn(elapsed, now) on every frame.
function K.Every(fn)
    tickers[#tickers + 1] = fn
end

function K.After(sec, fn)
    C_Timer.After(sec, fn)
end

driver:SetScript("OnUpdate", function(_, dt)
    if dt > 0.1 then dt = 0.1 end
    local now = GetTime()
    for i = 1, #tickers do tickers[i](dt, now) end
    for i = 1, #tweens do
        local t = tweens[i]
        if t and not t.dead then
            t.t = t.t + dt
            local p = t.t / t.dur
            if p >= 1 then
                t.dead = true
                t.step(1)
                if t.done then t.done() end
            else
                t.step(p)
            end
        end
    end
    local k = 0
    for i = 1, #tweens do
        local t = tweens[i]
        if not t.dead then
            k = k + 1
            tweens[k] = t
        end
    end
    for i = #tweens, k + 1, -1 do tweens[i] = nil end
end)

--------------------------------------------------------------------------------
-- Small widget helpers
--------------------------------------------------------------------------------
function K.Tex(parent, layer, file, w, h, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    if file then t:SetTexture(K.ART .. file) end
    if w then t:SetSize(w, h or w) end
    return t
end

function K.Tint(tex, c, a)
    tex:SetVertexColor(c[1], c[2], c[3], a or 1)
end

function K.SetFont(fs, size, flags)
    flags = flags or "THICKOUTLINE"
    -- Bangers is narrow and runs small, so it is set a little larger than the size asked for.
    if fs:SetFont(K.FONT, math.floor(size * 1.14 + 0.5), flags) then return end
    if fs:SetFont(K.FONT_FALLBACK, size, flags) then return end
    fs:SetFont(STANDARD_TEXT_FONT, size, flags)
end

function K.Text(parent, layer, size, flags)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFontObject(GameFontNormalLarge)
    K.SetFont(fs, size, flags)
    fs:SetShadowOffset(0, 0)
    return fs
end

-- A flat rectangle with an ink border and a hard offset shadow: the comic "caption box".
function K.Panel(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -2)
    f.shadow:SetColorTexture(0, 0, 0, 0.55)
    f.shadow:SetPoint("TOPLEFT", 3, -3)
    f.shadow:SetPoint("BOTTOMRIGHT", 3, -3)
    f.border = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.border:SetColorTexture(K.C.ink[1], K.C.ink[2], K.C.ink[3], 1)
    f.border:SetAllPoints()
    f.bg = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.bg:SetPoint("TOPLEFT", 2, -2)
    f.bg:SetPoint("BOTTOMRIGHT", -2, 2)
    f.bg:SetColorTexture(K.C.paper[1], K.C.paper[2], K.C.paper[3], 1)
    return f
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------
local function InitDB()
    KapowDB = KapowDB or {}
    -- v2: the HUD hides out of combat. Settings saved before then still hold the old 0.35
    -- default for idle; move that one to the new default, keep any other value chosen.
    if (KapowDB.v or 1) < 2 then
        if KapowDB.idle == 0.35 then KapowDB.idle = nil end
        KapowDB.v = 2
    end
    for k, v in pairs(DEFAULTS) do
        if KapowDB[k] == nil then KapowDB[k] = v end
    end
    K.db = KapowDB
    K.Options:Register()
end

-- Builds the HUD the first time it is needed.
function K.Build()
    if K.built then return end
    K.built = true
    K.HUD:Build()
    K.FX:Build()
    K.Timers:Build()
    K.Plate:Build()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then InitDB() end
    elseif event == "PLAYER_LOGIN" then
        if not K.db then InitDB() end
        K.Options:Register() -- no-op if already done when the settings loaded
        local _, class = UnitClass("player")
        K.isRogue = (class == "ROGUE")
        if K.isRogue then
            K.Build()
            K.Tracker:Start()
        end
    end
end)

--------------------------------------------------------------------------------
-- /kapow
--------------------------------------------------------------------------------
local function Toggle(key, label)
    K.db[key] = not K.db[key]
    K.Print(label .. (K.db[key] and " on" or " off"))
end

SLASH_KAPOW1 = "/kapow"
SlashCmdList["KAPOW"] = function(msg)
    msg = (msg or ""):lower()
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if not K.db then InitDB() end
    if cmd == "options" or cmd == "config" or cmd == "settings" then
        if not K.Options:Open() then K.Print("the options page is not available in this client; use the commands below") end
    elseif cmd == "test" or cmd == "demo" then
        K.Build()
        K.Demo:Run()
    elseif cmd == "unlock" or cmd == "move" then
        K.Build()
        K.db.locked = false
        K.HUD:ApplyLock()
        K.Print("unlocked: drag the HUD, then /kapow lock")
    elseif cmd == "lock" then
        K.Build()
        K.db.locked = true
        K.HUD:ApplyLock()
        K.Print("locked")
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if s and s >= 0.5 and s <= 2.5 then
            K.db.scale = s
            if K.built then K.HUD:ApplyPosition() end
            K.Print("scale " .. s)
        else
            K.Print("scale takes a number from 0.5 to 2.5")
        end
    elseif cmd == "idle" then
        local a = tonumber(arg)
        if a and a >= 0 and a <= 1 then
            K.db.idle = a
            K.Print("idle opacity " .. a)
        else
            K.Print("idle takes a number from 0 (hidden) to 1")
        end
    elseif cmd == "fx" then
        local s = tonumber(arg)
        if s and s >= 0.5 and s <= 1.5 then
            K.db.fx = s
            K.Print("word burst size " .. s)
        else
            K.Print("fx takes a number from 0.5 (small bursts) to 1.5")
        end
    elseif cmd == "pips" then
        if arg == "plate" or arg == "hud" or arg == "both" then
            K.db.pips = arg
            if K.built then K.Plate:Reanchor() end
            K.Print("combo points: " .. (arg == "plate" and "arc on the target's nameplate (HUD when there is none)"
                or arg == "hud" and "on the HUD" or "on the nameplate and the HUD"))
        else
            K.Print("pips takes plate, hud or both")
        end
    elseif cmd == "arc" then
        local y = tonumber(arg)
        if y and y >= -40 and y <= 80 then
            K.db.arcY = y
            if K.built then K.Plate:Reanchor() end
            K.Print("arc height " .. y)
        else
            K.Print("arc takes a number from -40 to 80 (how high above the nameplate)")
        end
    elseif cmd == "ticker" then
        Toggle("ticker", "energy tick timer")
        if K.built then K.HUD:SetTickClock(K.HUD.lastTick) end
    elseif cmd == "words" then
        Toggle("words", "ability words")
    elseif cmd == "hits" then
        Toggle("hits", "crit/dodge words")
    elseif cmd == "dmg" or cmd == "damage" then
        Toggle("dmg", "damage numbers")
    elseif cmd == "prompt" then
        Toggle("prompt", "KICK IT! prompt")
    elseif cmd == "reset" then
        K.db.x, K.db.y, K.db.scale, K.db.arcY = DEFAULTS.x, DEFAULTS.y, DEFAULTS.scale, DEFAULTS.arcY
        if K.built then
            K.HUD:ApplyPosition()
            K.Plate:Reanchor()
        end
        K.Print("position and scale reset")
    else
        K.Print("commands (or Options > AddOns > Kapow):")
        K.Print("  /kapow options - open the options page")
        K.Print("  /kapow test - play a demo of every effect")
        K.Print("  /kapow unlock | lock - move the HUD")
        K.Print("  /kapow scale 1.2 - resize   /kapow idle 0.35 - opacity out of combat (0 hides it)")
        K.Print("  /kapow fx 0.8 - size of the word bursts")
        K.Print("  /kapow pips plate | hud | both - where combo points show   /kapow arc 10 - arc height")
        K.Print("  /kapow words | hits | prompt | ticker - toggle ability words, CRIT!/DODGED!, KICK IT!, tick timer")
        K.Print("  /kapow dmg - toggle the small damage numbers")
        K.Print("  /kapow reset - back to the default spot")
        if K.isRogue == false then K.Print("(not a rogue: the HUD only runs for rogues, but the demo works)") end
    end
end
