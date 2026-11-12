-- Spells: what each rogue ability looks like on the HUD.
-- Listed by rank-1 spell id; other ranks are matched by name, so this works in any language.
local _, K = ...
local S = {}
K.Spells = S
local C = K.C

--   word/color/size/shape  the burst shown when you use it
--   finisher               spends combo points (the burst grows with the points spent)
--   cd, short              show a cooldown box (only for short cooldowns worth watching)
--   aura = { unit, kind, short, dur }  show a countdown box; dur is our best guess in
--                          seconds (or a function of combo points and spell id) and is
--                          replaced by the real duration whenever the game lets us read it
S.list = {
    { key = "sinister", id = 1752,  word = "SLASH!",  color = C.yellow, size = 0.72 },
    { key = "backstab", id = 53,    word = "STAB!",   color = C.orange, size = 0.85 },
    { key = "hemo",     id = 16511, word = "SLICE!",  color = C.red,    size = 0.75 },
    { key = "ghostly",  id = 14278, word = "GHOST!",  color = C.cyan,   size = 0.8 },
    { key = "riposte",  id = 14251, word = "RIPOSTE!", color = C.cyan,  size = 0.95 },
    { key = "ambush",   id = 8676,  word = "AMBUSH!", color = C.red,    size = 1.15, shape = "burst2", big = true },
    { key = "garrote",  id = 703,   word = "GARROTE!", color = C.pink,  size = 1.0,
      aura = { unit = "target", kind = "dot", short = "GARROTE", dur = 18 } },
    { key = "cheap",    id = 1833,  word = "CHEAP SHOT!", color = C.orange, size = 1.0,
      aura = { unit = "target", kind = "cc", short = "STUNNED", dur = 4 } },

    { key = "evis",     id = 2098,  word = "EVISCERATE!", color = C.red, finisher = true, shape = "burst2" },
    { key = "kidney",   id = 408,   word = "KIDNEY SHOT!", color = C.orange, finisher = true, cd = 20, short = "KIDNEY",
      aura = { unit = "target", kind = "cc", short = "STUNNED", dur = function(cp, id) return cp + (id == 408 and 0 or 1) end } },
    { key = "snd",      id = 5171,  word = "SLICE & DICE!", color = C.teal, finisher = true,
      aura = { unit = "player", kind = "buff", short = "S&D", dur = function(cp) return 6 + 3 * cp end } },
    { key = "rupture",  id = 1943,  word = "RUPTURE!", color = C.pink, finisher = true,
      aura = { unit = "target", kind = "dot", short = "RUPTURE", dur = function(cp) return 6 + 2 * cp end } },
    { key = "expose",   id = 8647,  word = "EXPOSED!", color = C.purple, finisher = true,
      aura = { unit = "target", kind = "dot", short = "EXPOSE", dur = 30 } },

    { key = "kick",     id = 1766,  word = "KICK!",   color = C.cyan,   size = 1.0, cd = 10, short = "KICK" },
    { key = "gouge",    id = 1776,  word = "GOUGE!",  color = C.yellow, size = 1.0, cd = 10, short = "GOUGE",
      aura = { unit = "target", kind = "cc", short = "GOUGED", dur = 4 } },
    { key = "sap",      id = 6770,  word = "SAP!",    color = C.purple, size = 1.05, shape = "cloud", sub = "z z z",
      aura = { unit = "target", kind = "cc", short = "SAPPED",
               dur = function(_, id) return (id == 11297 and 45) or (id == 2070 and 35) or 25 end } },
    { key = "blind",    id = 2094,  word = "BLIND!",  color = C.paper,  size = 1.0, shape = "cloud", textColor = C.yellow,
      aura = { unit = "target", kind = "cc", short = "BLINDED", dur = 10 } },

    { key = "vanish",   id = 1856,  word = "POOF!",   color = C.purple, size = 1.1, shape = "cloud" },
    { key = "stealth",  id = 1784,  word = "sneak...", color = C.night, size = 0.7, shape = "cloud", textColor = C.purple },
    { key = "sprint",   id = 2983,  word = "ZOOM!",   color = C.cyan,   size = 0.95,
      aura = { unit = "player", kind = "buff", short = "SPRINT", dur = 15 } },
    { key = "evasion",  id = 5277,  word = "EVASION!", color = C.teal,  size = 0.95,
      aura = { unit = "player", kind = "buff", short = "EVASION", dur = 15 } },
    { key = "feint",    id = 1966,  word = "FEINT!",  color = C.grey,   size = 0.75, cd = 10, short = "FEINT" },
    { key = "flurry",   id = 13877, word = "FLURRY!", color = C.orange, size = 1.0,
      aura = { unit = "player", kind = "buff", short = "FLURRY", dur = 15 } },
    { key = "rush",     id = 13750, word = "RUSH!!",  color = C.red,    size = 1.15, shape = "burst2", big = true,
      aura = { unit = "player", kind = "buff", short = "RUSH", dur = 15 } },
    { key = "coldblood", id = 14177, word = "COLD BLOOD", color = C.cyan, size = 0.8 },
    { key = "prep",     id = 14185, word = "PREP!",   color = C.teal,   size = 0.85 },
    { key = "distract", id = 1725,  word = "HEY!",    color = C.yellow, size = 0.8 },
    { key = "pickpocket", id = 921, word = "YOINK!",  color = C.yellow, size = 0.8 },
}

local byID, byName, byKey = {}, {}, {}

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return K.Safe(C_Spell.GetSpellName, id) end
    if GetSpellInfo then return (K.Safe(GetSpellInfo, id)) end
end

local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return (K.Safe(C_Spell.GetSpellTexture, id)) end
    if GetSpellTexture then return (K.Safe(GetSpellTexture, id)) end
end

function S:Init()
    if self.ready then return end
    self.ready = true
    for _, def in ipairs(self.list) do
        byID[def.id] = def
        byKey[def.key] = def
        local name = SpellName(def.id)
        if name and not K.IsSecret(name) then
            def.name = name
            byName[name] = def
        end
        def.icon = SpellIcon(def.id)
    end
end

function S:Get(key)
    return byKey[key]
end

-- The definition for a spell the player just cast, or nil if it is not one of ours.
function S:Find(spellID)
    local def = byID[spellID]
    if def ~= nil then return def or nil end
    local name = SpellName(spellID)
    def = name and not K.IsSecret(name) and byName[name] or false
    byID[spellID] = def -- remember misses too
    return def or nil
end

local ENERGY = Enum and Enum.PowerType and Enum.PowerType.Energy or 3
local costs = {}

-- Energy cost of a spell, or 0.
function S:EnergyCost(spellID)
    local list = C_Spell and C_Spell.GetSpellPowerCost and K.Safe(C_Spell.GetSpellPowerCost, spellID)
    if type(list) == "table" then
        for i = 1, #list do
            local c = list[i]
            if type(c) == "table" and not K.IsSecret(c.type) and c.type == ENERGY
                and not K.IsSecret(c.cost) and type(c.cost) == "number" then
                costs[spellID] = c.cost
                return c.cost
            end
        end
        return 0
    end
    return costs[spellID] or 0
end
