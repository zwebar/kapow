-- Demo: /kapow test plays a short scripted fight so every effect can be seen (and the HUD
-- placed) without pulling a mob. Live updates are paused while it runs.
local _, K = ...
local Demo = {}
K.Demo = Demo
local C = K.C

function Demo:Run()
    if K.demo then return end
    K.demo = true
    local HUD, FX, Timers, S, T = K.HUD, K.FX, K.Timers, K.Spells, K.Tracker
    T.Bind()
    HUD.root:Show()
    Timers:Clear()
    K.Print("demo: a 15-second pretend fight")
    if K.db.pips ~= "hud" and not K.Plate:Attach() then
        K.Print("(target an enemy with nameplates on to see the combo arc over its head)")
    end

    local energy, combo = 100, 0

    local function at(time, fn)
        K.After(time, function()
            if K.demo then fn() end
        end)
    end
    local function setEnergy(v, instant)
        energy = v
        HUD:SetEnergy(v, 100, instant)
        HUD:SetFull(v >= 100, true)
    end
    local function spend(cost)
        setEnergy(math.max(0, energy - cost))
        HUD:Spend(cost)
    end
    local function tick(amount)
        local v = math.min(100, energy + amount)
        local d = v - energy
        setEnergy(v)
        HUD:SetTickClock(GetTime())
        if d > 0 then HUD:Tick(d, v) end
    end
    local function points(n)
        combo = n
        HUD:SetCombo(n)
    end
    local function cast(key, cp)
        local def = S:Get(key)
        if def then T.Announce(def, cp or 0) end
        return def
    end
    local function box(key, label, kind, duration, ready)
        local def = S:Get(key)
        Timers:Start("demo:" .. label, { label = label, icon = def and def.icon, duration = duration, kind = kind, ready = ready })
    end

    setEnergy(100, true)
    HUD:SetCombo(0, true)
    HUD:SetPrompt(nil)
    HUD:SetPalette(true)
    HUD:SetTickClock(GetTime() - 1)

    at(0.3, function() cast("stealth") end)
    at(1.2, function()
        HUD:SetPalette(false)
        spend(60)
        points(2)
        cast("cheap")
        box("cheap", "STUNNED", "cc", 4)
    end)
    at(1.0, function() tick(20) end) -- (at full: nothing to gain, the runner just laps)
    at(2.0, function() spend(45); points(3); cast("sinister") end)
    at(2.3, function() T.Show.Crit("187") end)
    at(2.7, function() HUD:Error() end)
    at(3.0, function() tick(20) end)
    at(3.5, function() HUD:SetPrompt("KICK IT!") end)
    at(4.3, function()
        HUD:SetPrompt(nil)
        spend(15)
        cast("kick")
        box("kick", "KICK", "cd", 5, "KICK READY!")
    end)
    at(4.5, function() T.Show.Denied() end)
    at(5.0, function() tick(20) end)
    at(5.6, function() T.Show.Miss("DODGED!") end)
    at(6.2, function() cast("rush"); box("rush", "RUSH", "buff", 6) end)
    at(7.0, function() tick(40) end)
    at(7.4, function() spend(45); points(4); cast("gouge"); box("gouge", "GOUGED", "cc", 4) end)
    at(8.2, function() FX:Pop("PARRY!", -70, HUD.PIP_Y + 28, C.cyan, 15, 18); box("riposte", "RIPOSTE!", "now", 2.5) end)
    at(9.0, function() tick(40) end)
    at(9.5, function() spend(45); points(5); cast("sinister") end)
    at(11.0, function() tick(40) end)
    at(11.5, function() spend(35); cast("evis", 5); points(0) end)
    at(12.3, function() T.Show.KO() end)
    at(13.0, function() tick(40) end)
    at(13.4, function() cast("sap"); box("sap", "SAPPED", "cc", 25) end)
    at(15.0, function() Demo:Stop() end)
end

function Demo:Stop()
    if not K.demo then return end
    K.demo = false
    local HUD, T = K.HUD, K.Tracker
    K.Timers:Clear()
    HUD:SetPrompt(nil)
    HUD:SetTickClock(nil)
    HUD:SetCombo(0, true)
    HUD:SetPalette(false)
    if T.started then
        T:Refresh()
    else
        -- not a rogue: put the HUD away again
        HUD:SetEnergy(100, 100, true)
        HUD:SetFull(false)
        HUD.root:Hide()
    end
    K.Print("demo over. /kapow unlock to move the HUD.")
end
