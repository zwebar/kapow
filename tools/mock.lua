-- Mock WoW UI for tools/test.js. DOC (from Blizzard's API docs), ART, FILES and VERBOSE are
-- defined by the runner before this file.
local OUT, ERRORS, WARNED, LOG = {}, {}, {}, {}
local function say(s) OUT[#OUT + 1] = s end
local function warn(s)
    if not WARNED[s] then
        WARNED[s] = true
        WARNED[#WARNED + 1] = s
    end
end
local function fail(s) ERRORS[#ERRORS + 1] = s end

local clock, t0 = 100.0, 100.0
local G
local function log(s) LOG[#LOG + 1] = string.format("  %6.2f  %s", clock - t0, s) end

--------------------------------------------------------------------------------
-- Secret values: any maths, ordering, concatenation or indexing is an error.
-- (Lua cannot trap `secret == 5` or `if secret then`; those slip through here.)
--------------------------------------------------------------------------------
local SecretMT = {}
local function secretErr() error("attempt to use a secret value", 2) end
for _, m in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__unm", "__lt", "__le", "__concat",
    "__len", "__index", "__newindex", "__call", "__idiv", "__pow" }) do
    SecretMT[m] = secretErr
end
local function secret(v)
    local s = {}
    rawset(s, "__real", v) -- what the game would draw; the addon cannot reach it
    return setmetatable(s, SecretMT)
end
function issecretvalue(v) return getmetatable(v) == SecretMT end
local function real(v) if issecretvalue(v) then return rawget(v, "__real") end return v end
local function hide(v) if G.secret then return secret(v) end return v end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------
local BASE = { "SimpleScriptRegionAPI", "SimpleScriptRegionResizingAPI", "SimpleObjectAPI",
    "SimpleFrameScriptObjectAPI", "SimpleAnimatableObjectAPI" }
local function chain(...)
    local t = { ... }
    for _, b in ipairs(BASE) do t[#t + 1] = b end
    return t
end
local ANIM = { "SimpleAnimAPI", "SimpleObjectAPI", "SimpleFrameScriptObjectAPI" }
local CHAINS = {
    Frame = chain("SimpleFrameAPI"),
    StatusBar = chain("SimpleStatusBarAPI", "SimpleFrameAPI"),
    Texture = chain("SimpleTextureAPI", "SimpleTextureBaseAPI", "SimpleRegionAPI"),
    MaskTexture = chain("SimpleMaskTextureAPI", "SimpleTextureBaseAPI", "SimpleRegionAPI"),
    FontString = chain("SimpleFontStringAPI", "SimpleRegionAPI"),
    AnimationGroup = { "SimpleAnimGroupAPI", "SimpleObjectAPI", "SimpleFrameScriptObjectAPI" },
    Scale = { "SimpleAnimScaleAPI", ANIM[1], ANIM[2], ANIM[3] },
    Alpha = { "SimpleAnimAlphaAPI", ANIM[1], ANIM[2], ANIM[3] },
    Translation = { "SimpleAnimTranslationAPI", ANIM[1], ANIM[2], ANIM[3] },
}
for kind, list in pairs(CHAINS) do
    for _, api in ipairs(list) do
        if not DOC.methods[api] then warn("docs have no script object " .. api .. " (for " .. kind .. ")") end
    end
end

local function docFlag(kind, k)
    for _, api in ipairs(CHAINS[kind]) do
        local m = DOC.methods[api]
        if m and m[k] then return m[k] end
    end
end

local EVENTS, UPDATERS, PLAYING, TIMERS = {}, {}, {}, {}
local COUNT = { frames = 0, textures = 0, fontstrings = 0 }
local IMPL = {}
local WidgetMT = {}
local methodCache = {}

local ALL = {}
local function new(kind, parent)
    local o = setmetatable({ __kind = kind, __parent = parent, __shown = true, __v = {}, __scripts = {}, __points = {} }, WidgetMT)
    ALL[#ALL + 1] = o
    o.__id = #ALL
    return o
end

local function num(v, what)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        error(what .. " must be a number, got " .. tostring(v), 3)
    end
end

WidgetMT.__index = function(o, k)
    local kind = rawget(o, "__kind")
    local flag = type(k) == "string" and docFlag(kind, k)
    if not flag then return nil end -- a plain field, or a method the client does not have
    local id = kind .. ":" .. k
    local fn = methodCache[id]
    if not fn then
        fn = function(self, ...)
            if getmetatable(self) ~= WidgetMT then error(id .. " called with '.' instead of ':'", 2) end
            for i = 1, select("#", ...) do
                if issecretvalue((select(i, ...))) and flag ~= "T" then
                    error(id .. " does not accept secret values", 2)
                end
            end
            local p3 = k:sub(1, 3)
            if p3 == "Set" then self.__v[k:sub(4)] = { ... } end
            local impl = IMPL[k]
            if impl then return impl(self, ...) end
            if p3 == "Set" then
                return true
            elseif p3 == "Get" then
                local v = self.__v[k:sub(4)]
                if v then return table.unpack(v) end
                return 0
            elseif k:sub(1, 2) == "Is" then
                return false
            elseif k:sub(1, 6) == "Create" then
                error("mock: " .. id .. " is not implemented", 2)
            end
        end
        methodCache[id] = fn
    end
    return fn
end

local LAYERS = { BACKGROUND = true, BORDER = true, ARTWORK = true, OVERLAY = true, HIGHLIGHT = true }
local POINTS = { CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }

local function checkArt(file)
    if type(file) == "string" then
        local name = file:match("AddOns\\Kapow\\Art\\(.+)$")
        if file:find("Kapow", 1, true) and not (name and ART[name]) then
            error("missing art file: " .. file, 3)
        end
    end
end

function IMPL.SetScript(self, name, fn)
    if fn ~= nil and type(fn) ~= "function" then error("SetScript needs a function", 2) end
    self.__scripts[name] = fn
    if name == "OnUpdate" then UPDATERS[self] = fn and true or nil end
end
function IMPL.GetScript(self, name) return self.__scripts[name] end
function IMPL.RegisterEvent(self, e)
    if not DOC.events[e] then error("unknown event " .. tostring(e), 2) end
    EVENTS[e] = EVENTS[e] or {}
    EVENTS[e][self] = "*"
    return true
end
function IMPL.RegisterUnitEvent(self, e, ...)
    if not DOC.events[e] then error("unknown event " .. tostring(e), 2) end
    if not e:find("^UNIT_") then error("not a unit event: " .. e, 2) end
    local units = {}
    for i = 1, select("#", ...) do units[(select(i, ...))] = true end
    EVENTS[e] = EVENTS[e] or {}
    EVENTS[e][self] = units
    return true
end
function IMPL.SetParent(self, p)
    if p ~= nil and getmetatable(p) ~= WidgetMT then error("SetParent: bad parent " .. tostring(p), 2) end
    self.__parent = p
end
function IMPL.GetParent(self) return self.__parent end
function IMPL.Show(self) self.__shown = true end
function IMPL.Hide(self) self.__shown = false end
function IMPL.SetShown(self, s)
    if type(s) ~= "boolean" then error("SetShown needs a boolean, got " .. tostring(s), 2) end
    self.__shown = s
end
function IMPL.IsShown(self) return self.__shown end
function IMPL.CreateTexture(self, name, layer, template, sub)
    if layer and not LAYERS[layer] then error("bad draw layer " .. tostring(layer), 2) end
    if sub and (type(sub) ~= "number" or sub < -8 or sub > 7) then error("bad sublevel " .. tostring(sub), 2) end
    COUNT.textures = COUNT.textures + 1
    local t = new("Texture", self)
    t.__layer, t.__sub = layer or "ARTWORK", sub or 0
    return t
end
function IMPL.CreateFontString(self, name, layer)
    if layer and not LAYERS[layer] then error("bad draw layer " .. tostring(layer), 2) end
    COUNT.fontstrings = COUNT.fontstrings + 1
    local t = new("FontString", self)
    t.__layer, t.__sub = layer or "ARTWORK", 0
    return t
end
function IMPL.CreateMaskTexture(self) return new("MaskTexture", self) end
function IMPL.CreateAnimationGroup(self)
    local ag = new("AnimationGroup", self)
    ag.__anims = {}
    return ag
end
function IMPL.CreateAnimation(self, kind)
    if not CHAINS[kind] or not kind then error("mock: animation type " .. tostring(kind), 2) end
    local a = new(kind, self)
    self.__anims[#self.__anims + 1] = a
    return a
end
function IMPL.SetTexture(self, file)
    checkArt(file)
    self.__file, self.__color = file, nil
    return true
end
function IMPL.SetStatusBarTexture(self, file)
    checkArt(file)
    self.__sbtex = self.__sbtex or new("Texture", self)
    self.__sbtex.__file, self.__sbtex.__fill = file, true
    return true
end
function IMPL.GetStatusBarTexture(self) return self.__sbtex end
function IMPL.AddMaskTexture(self, mask)
    if getmetatable(mask) ~= WidgetMT or mask.__kind ~= "MaskTexture" then error("AddMaskTexture needs a MaskTexture", 2) end
    self.__mask = mask
end
local FLAGS = { [""] = true, OUTLINE = true, THICKOUTLINE = true, MONOCHROME = true }
function IMPL.SetFont(self, file, size, flags)
    if type(file) ~= "string" then error("SetFont: bad font file " .. tostring(file), 2) end
    local own = file:match("AddOns\\Kapow\\Fonts\\(.+)$")
    if file:find("Kapow", 1, true) and not (own and FONTFILES[own]) then
        error("missing font file: " .. file, 2)
    end
    num(size, "font size")
    if size <= 0 then error("SetFont: size " .. size, 2) end
    for f in (flags or ""):gmatch("[^,%s]+") do
        if not FLAGS[f] then error("SetFont: bad flag " .. f, 2) end
    end
    return true
end
function IMPL.GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function IMPL.SetFontObject(self, obj)
    if obj == nil then error("SetFontObject(nil)", 2) end
end
function IMPL.SetText(self, t)
    self.__text = t
end
function IMPL.SetFormattedText(self, fmt, ...)
    local hidden = false
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then hidden = true end
    end
    local a = { ... }
    for i = 1, #a do a[i] = real(a[i]) end
    local text = string.format(fmt, table.unpack(a))
    self.__text = hidden and secret(text) or text
end
function IMPL.GetStringWidth(self)
    if issecretvalue(self.__text) then error("GetStringWidth on secret text", 2) end
    return #(tostring(self.__text or "")) * 7
end
function IMPL.SetPoint(self, point, a, b, c, d)
    if not POINTS[point] then error("SetPoint: bad point " .. tostring(point), 2) end
    local rel, relPoint, x, y = nil, point, 0, 0
    if type(a) == "number" then
        num(a, "SetPoint x"); num(b, "SetPoint y")
        x, y = a, b
    elseif a ~= nil then
        if getmetatable(a) ~= WidgetMT then error("SetPoint: bad relative frame " .. tostring(a), 2) end
        rel = a
        if type(b) == "string" then
            if not POINTS[b] then error("SetPoint: bad relative point " .. b, 2) end
            relPoint = b
            if c ~= nil then num(c, "SetPoint x"); num(d, "SetPoint y"); x, y = c, d end
        elseif b ~= nil then
            num(b, "SetPoint x"); num(c, "SetPoint y")
            x, y = b, c
        end
    end
    local p = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
    for i, old in ipairs(self.__points) do
        if old.point == point then self.__points[i] = p return end
    end
    self.__points[#self.__points + 1] = p
end
function IMPL.ClearAllPoints(self) self.__points = {} end
function IMPL.SetAllPoints(self, rel)
    if rel ~= nil and getmetatable(rel) ~= WidgetMT then error("SetAllPoints: bad frame", 2) end
    self.__points = {
        { point = "TOPLEFT", rel = rel, relPoint = "TOPLEFT", x = 0, y = 0 },
        { point = "BOTTOMRIGHT", rel = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 },
    }
end
function IMPL.SetSize(self, w, h)
    num(w, "width"); num(h, "height")
    if w < 0 or h < 0 then error("negative size", 2) end
    self.__v.Size = { w, h }
end
function IMPL.SetWidth(self, w)
    num(w, "width"); if w < 0 then error("negative width", 2) end
    self.__v.Size = { w, self.__v.Size and self.__v.Size[2] or 0 }
end
function IMPL.SetHeight(self, h)
    num(h, "height"); if h < 0 then error("negative height", 2) end
    self.__v.Size = { self.__v.Size and self.__v.Size[1] or 0, h }
end
function IMPL.SetFrameLevel(self, n)
    num(n, "frame level")
    if n < 0 or n > 10000 then error("frame level " .. n, 2) end
    self.__level = n
end
function IMPL.GetFrameLevel(self)
    return self.__level or ((self.__parent and self.__parent ~= self and self.__parent:GetFrameLevel() or 0) + 1)
end
function IMPL.SetScale(self, s)
    num(s, "scale")
    if s <= 0 then error("scale " .. s, 2) end
    self.__scale = s
end
function IMPL.GetScale(self) return self.__scale or 1 end
function IMPL.GetCenter() return 640, 360 end
function IMPL.SetAlpha(self, a)
    if not issecretvalue(a) then
        num(a, "alpha")
        if a < -0.001 or a > 1.001 then warn("alpha out of range: " .. a) end
    end
end
local function colour(self, r, g, b, a)
    num(r, "red"); num(g, "green"); num(b, "blue")
    if a ~= nil then num(a, "alpha") end
end
IMPL.SetVertexColor, IMPL.SetTextColor, IMPL.SetStatusBarColor = colour, colour, colour
function IMPL.SetColorTexture(self, r, g, b, a)
    colour(self, r, g, b, a)
    self.__color, self.__file = { r, g, b, a or 1 }, nil
end
local BLEND = { BLEND = true, ADD = true, DISABLE = true, ALPHAKEY = true, MOD = true }
-- The boolean setters take a (possibly secret) true/false; the game applies it, the addon never
-- learns which. Here the real value picks, so snapshots show what the player would see.
function IMPL.SetVertexColorFromBoolean(self, v, yes, no)
    if type(yes) ~= "table" or type(no) ~= "table" then error("SetVertexColorFromBoolean needs colours", 2) end
    local c = real(v) and yes or no
    self.__v.VertexColor = { c.r, c.g, c.b, c.a or 1 }
end
function IMPL.SetAlphaFromBoolean(self, v, yes, no)
    num(yes, "alpha"); num(no, "alpha")
    if yes > 1 or no > 1 then warn("SetAlphaFromBoolean given alpha above 1") end
    self.__v.Alpha = { real(v) and yes or no }
end
function IMPL.SetBlendMode(self, m) if not BLEND[m] then error("blend mode " .. tostring(m), 2) end end
function IMPL.SetRotation(self, r) num(r, "rotation") end
function IMPL.SetTexCoord(self, a, b, c, d) num(a, "tc"); num(b, "tc"); num(c, "tc"); num(d, "tc") end
function IMPL.SetMinMaxValues(self, a, b) num(a, "min"); num(b, "max") end
function IMPL.SetValue(self, v) if not issecretvalue(v) then num(v, "value") end end

-- The game's duration objects: they keep counting on the game clock. With hidden values, the
-- addon gets secrets back from them, but widgets bound to them still show the real thing.
local DurMT = {}
DurMT.__index = DurMT
local function newDur(start, total, hidden) return setmetatable({ s = start, t = total, hid = hidden }, DurMT) end
local function durLeft(d) return math.max(0, d.s + d.t - clock) end
local function durWrap(d, v) if d.hid then return secret(v) end return v end
function DurMT:HasSecretValues() return self.hid and true or false end
function DurMT:GetRemainingDuration() return durWrap(self, durLeft(self)) end
function DurMT:GetTotalDuration() return durWrap(self, self.t) end
function DurMT:IsActive() return durWrap(self, durLeft(self) > 0) end
function DurMT:HasExpired() return durWrap(self, durLeft(self) <= 0) end
function DurMT:IsZero() return self.t <= 0 end
local function isDur(d) return getmetatable(d) == DurMT end

function IMPL.SetTimerDuration(self, d, interp, dir)
    if not isDur(d) then error("SetTimerDuration needs a duration object", 2) end
    if interp ~= nil then num(interp, "interpolation") end
    if dir ~= nil then num(dir, "direction") end
    self.__timer = d
end

-- Text bindings: the game rewrites the font string from the duration every tick.
local BINDINGS = {}
local BindMT = {}
BindMT.__index = BindMT
local function bindText(b)
    if not (b.on and b.fs and b.d) then return end
    local r = durLeft(b.d)
    local text
    if r <= 0 then text = b.zero or "" elseif r >= 10 then text = string.format("%ds", math.floor(r + 0.5)) else text = string.format("%.1f", r) end
    b.fs.__text = text
end
function BindMT:SetFontString(fs)
    if getmetatable(fs) ~= WidgetMT or fs.__kind ~= "FontString" then error("SetFontString needs a font string", 2) end
    self.fs = fs
end
function BindMT:SetFormatter(f) if type(f) ~= "table" then error("SetFormatter needs a formatter", 2) end end
function BindMT:SetUpdateInterval(n) num(n, "interval") end
function BindMT:SetZeroDurationText(t) self.zero = t end
function BindMT:SetExpiredText(t) self.zero = t end
function BindMT:SetDuration(d)
    if not isDur(d) then error("SetDuration needs a duration object", 2) end
    self.d = d
    bindText(self)
end
function BindMT:SetEnabled(on) self.on = on and true or false; bindText(self) end
local STRATA = { BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true, DIALOG = true, FULLSCREEN = true, TOOLTIP = true }
function IMPL.SetFrameStrata(self, s) if not STRATA[s] then error("strata " .. tostring(s), 2) end end
local LOOP = { NONE = true, REPEAT = true, BOUNCE = true }
function IMPL.SetLooping(self, m)
    if not LOOP[m] then error("looping " .. tostring(m), 2) end
    self.__loop = m
end
local SMOOTH = { NONE = true, IN = true, OUT = true, IN_OUT = true, OUT_IN = true }
function IMPL.SetSmoothing(self, m) if not SMOOTH[m] then error("smoothing " .. tostring(m), 2) end end
function IMPL.SetOrder(self, n) num(n, "order"); self.__order = n end
function IMPL.SetDuration(self, n) num(n, "duration"); self.__dur = n end
function IMPL.SetStartDelay(self, n) num(n, "delay"); self.__delay = n end
function IMPL.SetScaleFrom(self, x, y) num(x, "scale"); num(y, "scale") end
function IMPL.SetScaleTo(self, x, y) num(x, "scale"); num(y, "scale") end
function IMPL.SetOrigin(self, p, x, y)
    if not POINTS[p] then error("origin point " .. tostring(p), 2) end
    num(x, "origin"); num(y, "origin")
end
function IMPL.SetOffset(self, x, y) num(x, "offset"); num(y, "offset") end
function IMPL.SetFromAlpha(self, a) num(a, "alpha") end
function IMPL.SetToAlpha(self, a) num(a, "alpha") end
function IMPL.Play(self)
    local byOrder, total = {}, 0
    for _, a in ipairs(self.__anims) do
        local o = a.__order or 1
        byOrder[o] = math.max(byOrder[o] or 0, (a.__dur or 0) + (a.__delay or 0))
    end
    for _, d in pairs(byOrder) do total = total + d end
    self.__total, self.__t = total, 0
    PLAYING[self] = true
end
function IMPL.Stop(self) PLAYING[self] = nil end
function IMPL.IsPlaying(self) return PLAYING[self] and true or false end
function IMPL.RegisterForDrag(self, b) if b ~= "LeftButton" and b ~= "RightButton" then error("drag button", 2) end end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------
local function define(name, fn)
    if not DOC.globals[name] then warn("global function not in the client's API docs: " .. name) end
    _G[name] = fn
end
local function defineNS(ns, name, fn)
    if not (DOC.ns[ns] and DOC.ns[ns][name]) then warn("not in the client's API docs: " .. ns .. "." .. name) end
    _G[ns] = _G[ns] or {}
    _G[ns][name] = fn
end

local NAMES = {
    [1752] = "Sinister Strike", [1757] = "Sinister Strike", [53] = "Backstab", [16511] = "Hemorrhage",
    [14278] = "Ghostly Strike", [14251] = "Riposte", [8676] = "Ambush", [703] = "Garrote", [1833] = "Cheap Shot",
    [2098] = "Eviscerate", [408] = "Kidney Shot", [8643] = "Kidney Shot", [5171] = "Slice and Dice",
    [6774] = "Slice and Dice", [1943] = "Rupture", [8647] = "Expose Armor", [1766] = "Kick", [1776] = "Gouge",
    [6770] = "Sap", [2094] = "Blind", [1856] = "Vanish", [1784] = "Stealth", [2983] = "Sprint", [5277] = "Evasion",
    [1966] = "Feint", [13877] = "Blade Flurry", [13750] = "Adrenaline Rush", [14177] = "Cold Blood",
    [14185] = "Preparation", [1725] = "Distract", [921] = "Pick Pocket", [6603] = "Attack",
    [133] = "Fireball", [2050] = "Lesser Heal", [2054] = "Heal", [168] = "Frost Armor",
}
local COSTS = { ["Sinister Strike"] = 45, ["Cheap Shot"] = 60, Eviscerate = 35, Kick = 25, Gouge = 45,
    ["Kidney Shot"] = 25, ["Slice and Dice"] = 25, Sap = 65, Rupture = 25 }

local function setup()
    CreateFrame = function(kind, name, parent)
        if not CHAINS[kind] or kind == "Texture" then error("CreateFrame: type " .. tostring(kind), 2) end
        COUNT.frames = COUNT.frames + 1
        local f = new(kind, parent)
        if name then rawset(_G, name, f) end
        return f
    end
    UIParent = new("Frame")

    -- Blizzard's Settings panel is Lua in the client, not in the API docs: enough of it here
    -- to build Kapow's page and flip its settings, with the same arguments the real one takes.
    SETTINGS = { cats = {}, settings = {} }
    local VarType = { Boolean = "boolean", String = "string", Number = "number" }
    local function add(cat, init) table.insert(cat.inits, init) return init end
    Settings = {
        VarType = VarType,
        RegisterVerticalLayoutCategory = function(name)
            if type(name) ~= "string" then error("category name", 2) end
            return { name = name, inits = {}, ID = 7, GetID = function(c) return c.ID end }
        end,
        RegisterAddOnCategory = function(cat) table.insert(SETTINGS.cats, cat) end,
        RegisterAddOnSetting = function(cat, variable, key, tbl, kind, name, default)
            if type(cat) ~= "table" or type(variable) ~= "string" or type(key) ~= "string" or type(tbl) ~= "table"
                or type(name) ~= "string" then
                error("RegisterAddOnSetting arguments", 2)
            end
            if kind ~= "boolean" and kind ~= "string" and kind ~= "number" then error("variable type " .. tostring(kind), 2) end
            if type(default) ~= kind then error("default for " .. key .. " is " .. type(default) .. ", not " .. kind, 2) end
            if tbl[key] == nil then tbl[key] = default end
            if type(tbl[key]) ~= kind then error("saved " .. key .. " is not a " .. kind, 2) end
            local s = { key = key, kind = kind, name = name, default = default }
            function s:GetValue() return tbl[key] end
            function s:SetValue(v)
                if type(v) ~= kind then error("setting " .. key .. " to a " .. type(v), 2) end
                tbl[key] = v
                if s.cb then s.cb(s, v) end
            end
            function s:SetValueChangedCallback(fn) s.cb = fn end
            SETTINGS.settings[key] = s
            return s
        end,
        CreateCheckbox = function(cat, s, tip)
            if s.kind ~= "boolean" then error("checkbox for a " .. s.kind, 2) end
            return add(cat, { kind = "checkbox", setting = s })
        end,
        CreateSliderOptions = function(lo, hi, step)
            return { lo = lo, hi = hi, step = step, SetLabelFormatter = function(o, label, fn)
                if type(fn) ~= "function" then error("label formatter", 2) end
                o.fmt = fn
            end }
        end,
        CreateSlider = function(cat, s, o, tip)
            if s.kind ~= "number" then error("slider for a " .. s.kind, 2) end
            if s.default < o.lo or s.default > o.hi then error("default " .. s.key .. " outside the slider", 2) end
            if o.fmt and type(o.fmt(s:GetValue())) ~= "string" then error("label formatter must return text", 2) end
            return add(cat, { kind = "slider", setting = s, options = o })
        end,
        CreateDropdown = function(cat, s, optionsFn, tip)
            local data = optionsFn()
            local ok = false
            for _, d in ipairs(data) do if d.value == s.default then ok = true end end
            if not ok then error("dropdown default not among its options", 2) end
            return add(cat, { kind = "dropdown", setting = s, data = data })
        end,
        CreateControlTextContainer = function()
            local c = { data = {} }
            function c:Add(v, label, tip) table.insert(self.data, { value = v, label = label, tooltip = tip }) end
            function c:GetData() return self.data end
            return c
        end,
        OpenToCategory = function(id) SETTINGS.opened = id end,
    }
    SettingsPanel = {
        GetLayout = function(_, cat) return { AddInitializer = function(_, init) add(cat, init) end } end,
        Close = function() SETTINGS.closed = true end,
    }
    MinimalSliderWithSteppersMixin = { Label = { Left = 1, Right = 2, Top = 3, Min = 4, Max = 5 } }
    CreateSettingsListSectionHeaderInitializer = function(name) return { kind = "header", name = name } end
    CreateSettingsButtonInitializer = function(name, text, click, tip)
        if type(click) ~= "function" then error("button needs a click handler", 2) end
        return { kind = "button", name = name, text = text, click = click }
    end
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) log("chat: " .. msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end }
    GameFontNormalLarge = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 16, "" end }
    STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    ERR_OUT_OF_ENERGY = "Not enough energy"
    SlashCmdList = {}
    Enum = DOC.enums

    define("GetTime", function() return clock end)
    defineNS("C_Timer", "After", function(sec, fn)
        if type(sec) ~= "number" or type(fn) ~= "function" then error("C_Timer.After(sec, fn)", 2) end
        TIMERS[#TIMERS + 1] = { at = clock + sec, fn = fn }
    end)
    define("UnitClass", function() return "Whatever", G.class, 4 end)
    define("UnitPower", function(unit, kind)
        if kind == Enum.PowerType.Energy then return hide(G.energy) end
        if kind == Enum.PowerType.ComboPoints then return G.cp end
        return 0
    end)
    define("UnitPowerMax", function(unit, kind) return kind == Enum.PowerType.Energy and G.maxEnergy or 5 end)
    define("GetComboPoints", function(a, b)
        if a ~= "player" or b ~= "target" then error("GetComboPoints args", 2) end
        return G.target and G.cp or 0
    end)
    -- used by Blizzard's own UI code in this client, though missing from the generated docs
    IsInGroup = function() return G.grouped end
    define("UnitGUID", function(unit) return unit == "player" and "Player-1-0001" or hide("Creature-0-1") end)
    define("UnitExists", function() return G.target end)
    -- A stand-in nameplate for the target, high up in the middle of the screen, with a health
    -- bar and a name so snapshots show where the arc lands.
    NAMEPLATE = new("Frame", UIParent)
    NAMEPLATE:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 640, 470)
    NAMEPLATE:SetSize(110, 26)
    local border = NAMEPLATE:CreateTexture(nil, "BORDER")
    border:SetColorTexture(0.02, 0.02, 0.03, 1)
    border:SetPoint("BOTTOM", NAMEPLATE, "BOTTOM", 0, 1)
    border:SetSize(104, 12)
    local hb = NAMEPLATE:CreateTexture(nil, "ARTWORK")
    hb:SetColorTexture(0.78, 0.12, 0.1, 1)
    hb:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT", 2, 2)
    hb:SetSize(74, 8)
    local nm = NAMEPLATE:CreateFontString(nil, "OVERLAY")
    nm:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    nm:SetPoint("BOTTOM", border, "TOP", 0, 2)
    nm:SetTextColor(1, 0.25, 0.2)
    nm:SetText("Defias Pillager")
    defineNS("C_NamePlate", "GetNamePlateForUnit", function(unit)
        if unit == "target" and G.target and G.plates then return NAMEPLATE end
        return nil
    end)
    define("UnitCanAttack", function() return G.target end)
    define("UnitIsDead", function() return G.dead end)
    define("UnitAffectingCombat", function() return G.combat end)
    define("IsStealthed", function() return G.stealth end)
    -- What enemies cast in these tests (spell id -> helpful?, description)
    local CASTS = {
        [133] = { false, "Hurls a fiery ball that causes 16 to 25 Fire damage." },
        [2050] = { true, "Heal your target for 47 to 58." },
        [2054] = { true, "Heal your target for 295 to 341." },
        [168] = { true, "Increases Armor by 30 for 30 min." },
    }
    define("UnitCastingInfo", function(unit)
        if unit ~= "target" or not G.casting then return nil end
        local id = G.castID or 133
        local function h(v) if G.secret then return secret(v) end return v end
        local start = G.castAt or clock
        return h(NAMES[id]), h(NAMES[id]), h(136000 + id % 100), h(start * 1000), h((start + 2.5) * 1000),
            h(false), h("Cast-9"), h(G.castNoKick or false), h(id)
    end)
    defineNS("C_Spell", "IsSpellHelpful", function(id)
        local v = CASTS[real(id)] and CASTS[real(id)][1] or false
        if issecretvalue(id) then return secret(v) end
        return v
    end)
    defineNS("C_Spell", "GetSpellDescription", function(id)
        local d = CASTS[real(id)] and CASTS[real(id)][2] or ""
        if issecretvalue(id) then return secret(d) end
        return d
    end)
    CreateColor = function(r, g, b, a)
        return { r = r, g = g, b = b, a = a, GetRGBA = function(c) return c.r, c.g, c.b, c.a end }
    end
    define("UnitChannelInfo", function() return nil end)
    defineNS("C_Spell", "GetSpellName", function(id) return NAMES[id] end)
    defineNS("C_Spell", "GetSpellTexture", function(id) return NAMES[id] and 136000 + id % 100 or nil end)
    defineNS("C_Spell", "GetSpellPowerCost", function(id)
        local c = COSTS[NAMES[id] or ""]
        return c and { { type = Enum.PowerType.Energy, cost = c, minCost = c, name = "ENERGY" } } or {}
    end)
    local FINISHERS = { Eviscerate = true, ["Kidney Shot"] = true, ["Slice and Dice"] = true, Rupture = true }
    local BYNAME = {}
    for id, n in pairs(NAMES) do BYNAME[n] = BYNAME[n] or id end
    defineNS("C_Spell", "IsSpellUsable", function(id)
        local name = type(id) == "string" and id or NAMES[id]
        if not name or not BYNAME[name] then return false, false end -- not a spell you know
        if FINISHERS[name] and (G.cp or 0) == 0 then return false, false end
        local enough = G.energy >= (COSTS[name] or 0)
        return enough, not enough
    end)
    local function cooldownOf(spell)
        local name = type(spell) == "string" and spell or NAMES[spell]
        local cd = name and G.cds[name]
        if cd and cd.s + cd.t > clock then return cd end
    end
    defineNS("C_Spell", "GetSpellCooldown", function(id)
        local cd = cooldownOf(id) or { s = 0, t = 0 }
        if G.secret then return { startTime = secret(cd.s), duration = secret(cd.t), isEnabled = secret(true), modRate = 1 } end
        return { startTime = cd.s, duration = cd.t, isEnabled = true, modRate = 1 }
    end)
    defineNS("C_Spell", "GetSpellCooldownDuration", function(id, ignoreGCD)
        local cd = cooldownOf(id)
        if cd then return newDur(cd.s, cd.t, G.secret) end
        return newDur(clock, 0, G.secret)
    end)
    local FILTERS = { player = "HELPFUL|PLAYER", target = "HARMFUL|PLAYER" }
    local function auraList(unit)
        if unit == "target" and not G.target then return {} end
        return G.auraList[unit] or {}
    end
    defineNS("C_UnitAuras", "GetUnitAuraInstanceIDs", function(unit, filter)
        if FILTERS[unit] ~= filter then error("aura filter " .. tostring(filter) .. " for " .. tostring(unit), 2) end
        local ids = {}
        for _, a in ipairs(auraList(unit)) do ids[#ids + 1] = a.id end
        return ids
    end)
    defineNS("C_UnitAuras", "GetAuraDuration", function(unit, id)
        for _, a in ipairs(auraList(unit)) do
            if a.id == id then return newDur(a.s, a.t, G.secret) end
        end
        error("RequiresValidUnitAuraInstance: no aura " .. tostring(id) .. " on " .. tostring(unit), 2)
    end)
    defineNS("C_UnitAuras", "GetAuraDataBySpellName", function(unit, name, filter)
        if filter ~= "HELPFUL" and filter ~= "HARMFUL|PLAYER" then error("aura filter " .. tostring(filter), 2) end
        if G.secret then return nil end
        for _, a in ipairs(auraList(unit)) do
            if a.name == name then return { expirationTime = a.s + a.t, duration = a.t } end
        end
    end)
    defineNS("C_DurationUtil", "CreateDurationTextBinding", function()
        local b = setmetatable({}, BindMT)
        BINDINGS[#BINDINGS + 1] = b
        return b
    end)
    defineNS("C_StringUtil", "CreateSecondsFormatter", function()
        return setmetatable({}, { __index = function() return function() end end })
    end)
    defineNS("C_Secrets", "ShouldAurasBeSecret", function() return G.secret end)
end

--------------------------------------------------------------------------------
-- Driving it
--------------------------------------------------------------------------------
local function call(what, fn, ...)
    local ok, err = xpcall(fn, function(e) return tostring(e) .. debug.traceback("", 2) end, ...)
    if not ok then fail(string.format("[%s at %.2f] %s", what, clock - t0, err)) end
end

local function fire(event, ...)
    local regs = EVENTS[event]
    if not regs then return end
    local unit = ...
    local list = {}
    for frame, units in pairs(regs) do
        if units == "*" or units[unit] then list[#list + 1] = frame end
    end
    for _, frame in ipairs(list) do
        local h = frame.__scripts.OnEvent
        if h then call(event, h, frame, event, ...) end
    end
end

local function step(seconds)
    local dt = 1 / 30
    for _ = 1, math.floor(seconds / dt + 0.5) do
        clock = clock + dt
        local due = {}
        for i = #TIMERS, 1, -1 do
            if TIMERS[i].at <= clock then due[#due + 1] = table.remove(TIMERS, i) end
        end
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do call("C_Timer", t.fn) end
        for _, b in ipairs(BINDINGS) do bindText(b) end
        for unit, list in pairs(G.auraList) do
            local gone = false
            for i = #list, 1, -1 do
                if list[i].s + list[i].t <= clock then table.remove(list, i); gone = true end
            end
            if gone then fire("UNIT_AURA", unit, {}) end
        end
        local ups = {}
        for f in pairs(UPDATERS) do ups[#ups + 1] = f end
        for _, f in ipairs(ups) do
            if f.__scripts.OnUpdate then call("OnUpdate", f.__scripts.OnUpdate, f, dt) end
        end
        local done = {}
        for ag in pairs(PLAYING) do
            ag.__t = ag.__t + dt
            if ag.__t >= ag.__total and (ag.__loop or "NONE") == "NONE" then done[#done + 1] = ag end
        end
        for _, ag in ipairs(done) do
            PLAYING[ag] = nil
            if ag.__scripts.OnFinished then call("OnFinished", ag.__scripts.OnFinished, ag) end
        end
    end
end

local K
local function boot(class)
    EVENTS, UPDATERS, PLAYING, TIMERS = {}, {}, {}, {}
    for i = #ALL, 1, -1 do ALL[i] = nil end
    G = { energy = 100, maxEnergy = 100, cp = 0, secret = false, target = false, dead = false, casting = false,
        stealth = false, combat = false, auraList = { player = {}, target = {} }, cds = {}, nextAura = 100, class = class }
    KapowDB, KapowCharDB, KapowHUD = nil, nil, nil
    BINDINGS = {}
    setup()
    K = {}
    for _, f in ipairs(FILES) do
        local chunk, err = load(f.code, "@" .. f.name)
        if not chunk then
            fail("syntax: " .. tostring(err))
        else
            call("load " .. f.name, chunk, "Kapow", K)
        end
    end
    -- watch what the addon decides to show
    local function spy(tbl, name, fmt)
        local orig = tbl[name]
        if not orig then fail("missing function " .. name) return end
        tbl[name] = function(self, ...)
            local s = fmt(...)
            if s then log(s) end
            return orig(self, ...)
        end
    end
    local function str(v) return issecretvalue(v) and "<secret>" or tostring(v) end
    spy(K.FX, "Word", function(text, o) return "WORD  " .. text .. (o and o.sub and ("  [" .. o.sub .. "]") or "") end)
    spy(K.FX, "Pop", function(text) return "pop   " .. text end)
    spy(K.Timers, "Start", function(key, o) return string.format("box   %s  %s %.1fs", key, o.label, o.duration) end)
    spy(K.Timers, "Stop", function(key) return K.Timers:Get(key) and ("box   " .. key .. " removed") or nil end)
    spy(K.Timers, "Adjust", function(key, exp, dur) return string.format("box   %s corrected to %.1fs left", key, exp - clock) end)
    spy(K.Timers, "Bind", function(key, d)
        local t = K.Timers:Get(key)
        if t and not t.bound and isDur(d) then
            return string.format("box   %s on the game's timer: %.1fs left%s", key, durLeft(d), d.hid and " (hidden from addon)" or "")
        end
    end)
    spy(K.HUD, "SetFull", function(full) if full ~= K.HUD.full then return "full  " .. tostring(full) end end)
    spy(K.HUD, "SetPrompt", function(text, cast, ...)
        if text == K.HUD.promptText and cast == K.HUD.promptCast and (... or "go") == (K.HUD.promptMode or "go") then return nil end
        if not text then return K.HUD.promptText and "prompt hidden" or nil end
        local c = cast or {}
        local hidden = issecretvalue(c.name) and " [hidden from addon]" or ""
        local tag = real(c.helpful) and (c.heal == false and "BUFF!" or "HEAL!") or "-"
        local kickable = real(c.notInterruptible) and "  (box invisible: can't be kicked)" or ""
        local quiet = ((...) == "wait") and "  (dim, no pulse)" or ""
        return string.format("prompt %s  spell=%s  tag=%s%s%s%s", text, tostring(real(c.name)), tag, hidden, kickable, quiet)
    end)
    spy(K.HUD, "Tick", function(amount) return "tick  " .. str(amount) end)
    spy(K.HUD, "Spend", function(cost) return "spend " .. str(cost) end)
    spy(K.HUD, "SetCombo", function(n, quiet) if n ~= K.HUD.combo then return "combo " .. n .. (quiet and " (quiet)" or "") end end)
    spy(K.HUD, "SetComboSecret", function() return "combo <secret>" end)
    local attach = K.Plate.Attach
    K.Plate.Attach = function(self, ...)
        local was = self.attached
        local r = attach(self, ...)
        if was ~= self.attached then
            log(self.attached and "arc   on the target's nameplate (HUD pips hidden)" or "arc   hidden (HUD pips back)")
        end
        return r
    end
    spy(K.HUD, "Error", function() return "error flash" end)
    spy(K.HUD, "SetPalette", function(s) if s ~= K.HUD.stealth then return "palette " .. (s and "stealth" or "normal") end end)

    fire("ADDON_LOADED", "Kapow")
    fire("PLAYER_LOGIN")
    fire("PLAYER_ENTERING_WORLD", true, false)
    step(0.5)
end

local function power(kind)
    fire("UNIT_POWER_FREQUENT", "player", kind)
    fire("UNIT_POWER_UPDATE", "player", kind)
end
local function energy(v) G.energy = math.max(0, math.min(G.maxEnergy, v)); power("ENERGY") end
local function combo(v) G.cp = v; power("COMBO_POINTS") end
local function tick() energy(G.energy + 20) end
-- castFirst: whether the cast event arrives before the power change
-- The game's real cooldowns here differ from Kapow's built-in values on purpose (as if
-- talented), so the test shows which one the boxes follow.
local REAL_CD = { Kick = 8, Gouge = 10, ["Kidney Shot"] = 20, Feint = 10 }
-- Puts an aura on a unit, as if the game applied it.
local function aura(unit, name, dur)
    G.nextAura = G.nextAura + 1
    table.insert(G.auraList[unit], { id = G.nextAura, name = name, s = clock, t = dur })
    fire("UNIT_AURA", unit, {})
    return G.nextAura
end
local function cast(id, castFirst, cp)
    local name = NAMES[id] or ""
    if REAL_CD[name] then G.cds[name] = { s = clock, t = REAL_CD[name] } end
    local c = COSTS[name] or 0
    local function ev() fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-0", id) end
    if castFirst then ev() end
    if c > 0 then energy(G.energy - c) end
    if cp then combo(cp) end
    if not castFirst then ev() end
end

local function fight(label, hidden)
    say("")
    say("--- " .. label .. " ---")
    LOG = {}
    t0 = clock
    G.target, G.dead, G.plates = true, false, true
    fire("PLAYER_TARGET_CHANGED")
    fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    energy(100)
    G.stealth = true
    fire("UPDATE_STEALTH")
    cast(1784, true)
    step(1)
    -- opener
    G.secret = hidden
    G.combat = true
    fire("PLAYER_REGEN_DISABLED")
    G.stealth = false
    fire("UPDATE_STEALTH")
    G.auraList.target = {}
    cast(1833, false, 2)
    aura("target", "Cheap Shot", 4)
    step(0.8)
    tick() step(0.7)
    cast(1757, true, 3) -- rank 2 Sinister Strike: matched by name
    fire("UNIT_COMBAT", "target", "WOUND", "CRITICAL", 187, 1)
    step(0.5)
    fire("UI_ERROR_MESSAGE", 51, "Not enough energy")
    fire("UNIT_COMBAT", "target", "DODGE", "", 0, 1)
    step(0.8)
    tick() step(0.6)
    -- the target casts; kick it
    G.casting = true
    fire("UNIT_SPELLCAST_START", "target", "Cast-1", 133, 1)
    step(0.6)
    cast(1766, false)
    G.casting = false
    fire("UNIT_SPELLCAST_INTERRUPTED", "target", "Cast-1", 133)
    fire("UNIT_SPELLCAST_STOP", "target", "Cast-1", 133)
    step(0.8)
    tick() step(2) tick() step(0.3)
    cast(1776, true, 4) -- Gouge, with Improved Gouge making it 5.5s
    step(0.05)
    aura("target", "Gouge", 5.5)
    step(0.3)
    local gb = K.Timers:Get("aura:gouge")
    if not (gb and gb.bound) then fail("Gouge box did not take the game's timer") end
    local gt = gb and tostring(real(gb.chip.time.__text))
    if not (gt and (gt:find("^5%.") or gt:find("^4%.9"))) then fail("Gouge box shows " .. tostring(gt) .. ", expected the real ~5.2") end
    step(0.65)
    log("(Gouge breaks early)")
    for i, a in ipairs(G.auraList.target) do if a.name == "Gouge" then table.remove(G.auraList.target, i) break end end
    fire("UNIT_AURA", "target", {})
    step(0.1)
    if K.Timers:Get("aura:gouge") then fail("Gouge box stayed after the aura broke") end
    fire("UNIT_COMBAT", "player", "PARRY", "", 0, 1)
    step(0.7)
    tick() step(2) tick() step(0.2)
    cast(1757, false, 5)
    step(1.8)
    tick() step(0.3)
    cast(2098, false, 0) -- Eviscerate: points drop before the cast event
    step(1.7)
    tick() step(2) tick() step(0.3)
    combo(2)
    cast(6774, true, 0) -- Slice and Dice rank 2: cast event first
    aura("player", "Slice and Dice", 12)
    step(1.4)
    -- a Kidney Shot that misses: no stun appears, so its box goes away
    combo(3)
    tick()
    cast(8643, true, 0)
    step(1.5)
    log("(the target walks out of sight: its nameplate goes, then comes back)")
    G.plates = false
    fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    step(0.5)
    G.plates = true
    fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    step(0.5)
    -- stand around until energy caps, then stay capped for a while
    for _ = 1, 5 do tick() step(2) end
    step(3)
    -- the target dies
    G.dead = true
    fire("UNIT_HEALTH", "target")
    step(1)
    G.target = false
    fire("PLAYER_TARGET_CHANGED")
    G.combat = false
    G.secret = false
    fire("PLAYER_REGEN_ENABLED")
    energy(G.energy)
    step(0.5)
    -- sap the next one
    G.target, G.dead = true, false
    fire("PLAYER_TARGET_CHANGED")
    energy(100)
    G.auraList.target = {}
    aura("target", "Rupture", 30) -- already on it from earlier: not the Sap
    fire("PLAYER_TARGET_CHANGED")
    cast(6770, false) -- rank 1, so the built-in guess is 25s; the game says 45
    step(0.1)
    aura("target", "Sap", 45)
    step(1)
    G.target = false
    fire("PLAYER_TARGET_CHANGED")
    step(50)
    for _, l in ipairs(LOG) do say(l) end
    G.auraList = { player = {}, target = {} }
    G.cds = {}
end

-- In a party: effects that cannot be pinned on you stay off.
local function grouped()
    say("")
    say("--- in a group (expect: no CRIT!/DODGED!/K.O.!, DENIED! only for your own kick) ---")
    LOG = {}
    t0 = clock
    G.grouped = true
    G.target, G.dead, G.combat = true, false, true
    fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    energy(100)
    cast(1757, true, 1)
    fire("UNIT_COMBAT", "target", "WOUND", "CRITICAL", 300, 1)
    fire("UNIT_COMBAT", "target", "DODGE", "", 0, 1)
    step(1)
    log("(someone else interrupts as you kick)")
    G.casting = true
    fire("UNIT_SPELLCAST_START", "target", "Cast-2", 133, 1)
    step(0.3)
    cast(1766, false)
    G.casting = false
    fire("UNIT_SPELLCAST_INTERRUPTED", "target", "Cast-2", 133, "Player-1-0002")
    step(1)
    log("(an interrupt with no name on it)")
    cast(1776, true, 2)
    fire("UNIT_SPELLCAST_INTERRUPTED", "target", "Cast-3", 133)
    step(11)
    log("(your kick interrupts)")
    G.casting = true
    fire("UNIT_SPELLCAST_START", "target", "Cast-4", 133, 1)
    step(0.3)
    energy(100)
    cast(1766, false)
    G.casting = false
    fire("UNIT_SPELLCAST_INTERRUPTED", "target", "Cast-4", 133, "Player-1-0001")
    step(1)
    G.dead = true
    fire("UNIT_HEALTH", "target")
    step(1)
    G.grouped, G.combat, G.target = false, false, false
    fire("PLAYER_REGEN_ENABLED")
    fire("PLAYER_TARGET_CHANGED")
    step(25)
    for _, l in ipairs(LOG) do say(l) end
end

-- Energy trickling in continuously (+1 every 0.1s), readable and hidden: no tick effects,
-- and the number changes calmly.
local function trickle()
    say("")
    say("--- energy trickling in (expect: no ticks once trickling, number at most ~4 changes/s) ---")
    local shows = 0
    local orig = K.HUD.ShowNumber
    K.HUD.ShowNumber = function(self, ...) shows = shows + 1 return orig(self, ...) end
    for _, hidden in ipairs({ false, true }) do
        LOG = {}
        t0 = clock
        G.secret = hidden
        G.combat = hidden
        energy(10)
        step(3)
        shows = 0
        for _ = 1, 50 do
            G.energy = G.energy + 1
            power("ENERGY")
            step(0.1)
        end
        local ticks = 0
        for _, l in ipairs(LOG) do if l:find("tick ", 1, true) then ticks = ticks + 1 end end
        say(string.format("  %s: %d tick effects, number changed %d times in 5s", hidden and "hidden" or "readable", ticks, shows))
        if ticks > 3 then fail("trickling energy still shows ticks (" .. ticks .. ")") end
        if shows > 24 then fail("energy number changes too often (" .. shows .. " in 5s)") end
        -- spending still shows straight away
        shows = 0
        cast(1752, true)
        step(0.05)
        if shows == 0 then fail("energy number did not follow a spend") end
    end
    G.secret, G.combat = false, false
    K.HUD.ShowNumber = orig
end

-- What the target casts: the KICK IT! box names it and flags heals.
local function casts()
    say("")
    say("--- target casts (expect: name every time, HEAL!/BUFF! tags, no box for unkickable) ---")
    LOG = {}
    t0 = clock
    G.target, G.dead, G.combat, G.grouped = true, false, true, false
    G.cd = 0
    fire("PLAYER_TARGET_CHANGED")
    energy(100)
    local function try(id, hidden, noKick, label)
        log("(" .. label .. ")")
        G.secret, G.castID, G.castNoKick, G.castAt = hidden, id, noKick, clock
        G.casting = true
        fire("UNIT_SPELLCAST_START", "target", "Cast-9", id, 1)
        step(0.4)
        if not K.HUD.prompt.__shown and not noKick then fail("no KICK IT! box for " .. label) end
        G.casting = false
        fire("UNIT_SPELLCAST_STOP", "target", "Cast-9", id, 1)
        step(0.2)
    end
    try(133, false, false, "Fireball, readable")
    try(2050, false, false, "Lesser Heal, readable")
    try(168, false, false, "Frost Armor, readable")
    try(2050, true, false, "Lesser Heal, hidden")
    try(133, true, false, "Fireball, hidden")
    log("(Kick on cooldown: Gouge instead)")
    G.cds.Kick = { s = clock, t = 6 }
    K.Timers:Start("cd:kick", { label = "KICK", duration = 6, kind = "cd" })
    try(2050, false, false, "Lesser Heal, readable")
    log("(Kick and Gouge on cooldown, 2 combo points: Kidney Shot)")
    G.cds.Gouge = { s = clock, t = 6 }
    K.Timers:Start("cd:gouge", { label = "GOUGE", duration = 6, kind = "cd" })
    G.cp = 2
    fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
    try(2050, false, false, "Lesser Heal, readable")
    log("(nothing ready, no combo points: the box waits for Kick)")
    G.cp = 0
    fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
    G.casting, G.castID, G.castAt = true, 2050, clock
    fire("UNIT_SPELLCAST_START", "target", "Cast-9", 2050, 1)
    step(2.4)
    G.casting = false
    fire("UNIT_SPELLCAST_STOP", "target", "Cast-9", 2050, 1)
    step(3)
    log("(Kick is back mid-cast: the box switches to KICK IT!)")
    G.cds.Kick = { s = clock, t = 1 }
    K.Timers:Start("cd:kick", { label = "KICK", duration = 1, kind = "cd" })
    G.casting, G.castID, G.castAt = true, 133, clock
    fire("UNIT_SPELLCAST_START", "target", "Cast-9", 133, 1)
    step(1.5)
    G.casting = false
    fire("UNIT_SPELLCAST_STOP", "target", "Cast-9", 133, 1)
    step(0.3)
    try(133, false, true, "shielded Fireball, readable")
    try(2050, true, true, "shielded Lesser Heal, hidden")
    G.secret, G.combat, G.target, G.castNoKick = false, false, false, false
    fire("PLAYER_TARGET_CHANGED")
    step(1)
    for _, l in ipairs(LOG) do say(l) end
end

local function slash(msg)
    call("/kapow " .. msg, SlashCmdList.KAPOW, msg)
end

-- The page under Options > AddOns > Kapow: built, and every setting takes effect.
local function options()
    say("")
    say("--- options page ---")
    LOG = {}
    t0 = clock
    local cat = SETTINGS.cats[1]
    if not cat then
        fail("no options page registered" .. (K.Options.failed and (": " .. K.Options.failed) or ""))
        return
    end
    local items = {}
    for _, init in ipairs(cat.inits) do
        items[#items + 1] = init.kind .. ":" .. (init.setting and init.setting.key or init.name or "")
    end
    say("  " .. cat.name .. ": " .. table.concat(items, ", "))
    local S = SETTINGS.settings
    for _, key in ipairs({ "locked", "scale", "idle", "ticker", "pips", "arcY", "words", "fx", "hits", "prompt" }) do
        if not S[key] then fail("no setting for " .. key) end
    end
    S.scale:SetValue(1.4)
    if KapowHUD.__scale ~= 1.4 then fail("Size did not resize the HUD") end
    S.locked:SetValue(false)
    if not K.HUD.mover.__shown then fail("unlocking did not show the mover") end
    S.locked:SetValue(true)
    G.target, G.plates = true, true
    fire("PLAYER_TARGET_CHANGED")
    step(0.1)
    S.pips:SetValue("hud")
    if K.Plate.attached then fail("combo points stayed on the nameplate") end
    S.pips:SetValue("plate")
    if not K.Plate.attached then fail("combo points did not go back to the nameplate") end
    S.ticker:SetValue(false)
    K.HUD:SetTickClock(clock)
    if K.HUD.bolt.__shown then fail("tick timer still shown") end
    S.ticker:SetValue(true)
    S.words:SetValue(false)
    if KapowDB.words ~= false then fail("Ability bursts did not change the saved setting") end
    S.words:SetValue(true)
    slash("options")
    if SETTINGS.opened ~= 7 then fail("/kapow options did not open the page") end
    for _, init in ipairs(cat.inits) do
        if init.kind == "button" and init.name == "Try it out" then init.click() end
    end
    if not K.demo then fail("Play demo did not start the demo") end
    step(16)
    say("  every setting applied")
    for _, l in ipairs(LOG) do say(l) end
end

local function commands()
    say("")
    say("--- slash commands ---")
    LOG = {}
    t0 = clock
    slash("")
    slash("test")
    step(16.5)
    slash("unlock")
    local root = KapowHUD
    if root then
        call("OnDragStart", root.__scripts.OnDragStart, root)
        call("OnDragStop", root.__scripts.OnDragStop, root)
    else
        fail("KapowHUD frame was not created")
    end
    slash("lock")
    slash("scale 1.3")
    slash("scale 9")
    slash("idle 0")
    slash("idle 0.35")
    slash("fx 0.8")
    slash("fx 1")
    slash("pips hud")
    slash("pips both")
    slash("pips sideways")
    slash("pips plate")
    slash("ticker")
    slash("ticker")
    slash("arc 12")
    slash("arc 999")
    for _, c in ipairs({ "words", "words", "hits", "hits", "prompt", "prompt", "reset" }) do slash(c) end
    step(1)
    for _, l in ipairs(LOG) do say(l) end
end


--------------------------------------------------------------------------------
-- Snapshots: resolve the layout the addon built and list what would be drawn, so the
-- runner can paint it (tools/test.js --snap out.html).
--------------------------------------------------------------------------------
local LAYER_RANK = { BACKGROUND = 0, BORDER = 1, ARTWORK = 2, OVERLAY = 3, HIGHLIGHT = 4 }

local function scaleOf(o)
    local s, f = 1, o
    while f do
        if f.__scale then s = s * f.__scale end
        f = f.__parent
    end
    return s
end

local function alphaOf(o)
    local a, f = 1, o
    while f do
        if not f.__shown then return nil end
        local v = f.__v.Alpha
        if v and real(v[1]) then a = a * real(v[1]) end
        f = f.__parent
    end
    return a
end

local function anchor(l, b, r, t, point)
    local x = point:find("LEFT") and l or point:find("RIGHT") and r or (l + r) / 2
    local y = point:find("BOTTOM") and b or point:find("TOP") and t or (b + t) / 2
    return x, y
end

local function sizeOf(o, s)
    local sz = o.__v.Size
    local w, h = sz and sz[1] or 0, sz and sz[2] or 0
    if o.__kind == "FontString" and w == 0 then
        local font = o.__v.Font and o.__v.Font[2] or 12
        w, h = #tostring(real(o.__text) or "") * font * 0.5, font
    end
    return w * s, h * s
end

local function rect(o, depth)
    depth = depth or 0
    if o == UIParent or depth > 30 then return 0, 0, 1280, 720 end
    local s = scaleOf(o)
    local pts = o.__points
    local parent = o.__parent or UIParent
    if #pts == 0 then
        local l, b, r, t = rect(parent, depth + 1)
        return (l + r) / 2, (b + t) / 2, (l + r) / 2, (b + t) / 2
    end
    local pos = {}
    for _, p in ipairs(pts) do
        local l, b, r, t = rect(p.rel or parent, depth + 1)
        local x, y = anchor(l, b, r, t, p.relPoint)
        pos[p.point] = { x + p.x * s, y + p.y * s }
    end
    if pos.TOPLEFT and pos.BOTTOMRIGHT then
        return pos.TOPLEFT[1], pos.BOTTOMRIGHT[2], pos.BOTTOMRIGHT[1], pos.TOPLEFT[2]
    end
    local p = pts[1]
    local x, y = pos[p.point][1], pos[p.point][2]
    local w, h = sizeOf(o, s)
    local l = p.point:find("LEFT") and x or p.point:find("RIGHT") and x - w or x - w / 2
    local b = p.point:find("BOTTOM") and y or p.point:find("TOP") and y - h or y - h / 2
    return l, b, l + w, b + h
end

local function json(v)
    local t = type(v)
    if t == "number" then return string.format("%.3f", v) end
    if t == "string" then return '"' .. v:gsub('[\\"]', "\\%0") .. '"' end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" then return "null" end
    local out = {}
    if #v > 0 or next(v) == nil then
        for i = 1, #v do out[i] = json(v[i]) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do out[#out + 1] = '"' .. k .. '":' .. json(x) end
    return "{" .. table.concat(out, ",") .. "}"
end

local function artName(file)
    if type(file) == "number" then return "icon" end
    if type(file) ~= "string" then return nil end
    if file:find("WHITE8X8") then return "white" end
    return file:match("([^\\]+)$")
end

local function snapshot(label)
    local frames, byParent, items = {}, {}, {}
    for _, o in ipairs(ALL) do
        if (o.__kind == "Frame" or o.__kind == "StatusBar") and o ~= UIParent then
            frames[#frames + 1] = o
        elseif (o.__kind == "Texture" or o.__kind == "FontString") and o.__parent then
            byParent[o.__parent] = byParent[o.__parent] or {}
            table.insert(byParent[o.__parent], o)
        end
    end
    table.sort(frames, function(a, b)
        local la, lb = a:GetFrameLevel(), b:GetFrameLevel()
        if la ~= lb then return la < lb end
        return a.__id < b.__id
    end)
    for _, f in ipairs(frames) do
        local regs = byParent[f] or {}
        local function rank(r) return LAYER_RANK[r.__layer or "ARTWORK"] * 100 + (r.__sub or 0) end
        table.sort(regs, function(a, b)
            if rank(a) ~= rank(b) then return rank(a) < rank(b) end
            return a.__id < b.__id
        end)
        for _, r in ipairs(regs) do
            local a = alphaOf(r)
            if a and a > 0.004 then
                local l, b, rr, t
                local it = {}
                if r.__kind == "Texture" then
                    local tint = r.__v.VertexColor or { 1, 1, 1, 1 }
                    if r.__fill then
                        l, b, rr, t = rect(f)
                        local mm, val = f.__v.MinMaxValues or { 0, 1 }, real((f.__v.Value or { 0 })[1]) or 0
                        local frac = (val - mm[1]) / math.max(0.0001, mm[2] - mm[1])
                        if f.__timer then frac = durLeft(f.__timer) / math.max(0.0001, f.__timer.t) end
                        frac = math.max(0, math.min(1, frac))
                        rr = l + (rr - l) * frac
                        it.crop = frac
                        tint = f.__v.StatusBarColor or tint
                    else
                        l, b, rr, t = rect(r)
                    end
                    it.kind = "tex"
                    it.art = artName(r.__file)
                    if r.__color then
                        it.color = { r.__color[1], r.__color[2], r.__color[3] }
                        a = a * (r.__color[4] or 1)
                    end
                    it.tint = { tint[1], tint[2], tint[3] }
                    a = a * (tint[4] or 1)
                    it.blend = r.__v.BlendMode and r.__v.BlendMode[1] or "BLEND"
                    it.rot = r.__v.Rotation and r.__v.Rotation[1] or 0
                    if r.__mask then
                        local ml, mb, mr, mt = rect(r.__mask)
                        it.mask = { art = artName(r.__mask.__file), x = ml, y = mb, w = mr - ml, h = mt - mb }
                    end
                else
                    l, b, rr, t = rect(r)
                    local font = r.__v.Font or { "", 12, "" }
                    local c = r.__v.TextColor or { 1, 0.82, 0 }
                    it.kind = "text"
                    it.text = tostring(real(r.__text) or "")
                    it.size = font[2] * scaleOf(r)
                    it.flags = font[3] or ""
                    it.color = { c[1], c[2], c[3] }
                    it.rot = r.__v.Rotation and r.__v.Rotation[1] or 0
                    local p = r.__points[1] and r.__points[1].point or "CENTER"
                    it.align = p:find("LEFT") and "left" or p:find("RIGHT") and "right" or "center"
                end
                it.x, it.y, it.w, it.h, it.a = l, b, rr - l, t - b, a
                if it.kind == "text" and it.text == "" then it = nil end
                if it and (it.kind == "text" or (it.w > 0.05 and it.h > 0.05)) then items[#items + 1] = it end
            end
        end
    end
    return { label = label, items = items }
end

-- Catch reads of globals that do not exist (typos, APIs the mock does not provide).
local UNDEF = {}
setmetatable(_G, { __index = function(_, k)
    if not UNDEF[k] then
        UNDEF[k] = true
        UNDEF[#UNDEF + 1] = tostring(k)
    end
    return nil
end })

boot("ROGUE")
fight("fight, energy readable", false)
fight("fight, energy secret in combat", true)
grouped()
casts()
trickle()
commands()
options()
local counts = string.format("%d frames, %d textures, %d font strings", COUNT.frames, COUNT.textures, COUNT.fontstrings)

boot("WARRIOR")
say("")
say("--- not a rogue ---")
LOG = {}
t0 = clock
if KapowHUD then fail("HUD was built for a non-rogue at login") end
slash("test")
step(16.5)
slash("")
for _, l in ipairs(LOG) do say(l) end

local head = {}
if #ERRORS == 0 then
    head[#head + 1] = "PASS: no Lua errors (" .. counts .. ")"
else
    head[#head + 1] = "FAIL: " .. #ERRORS .. " error(s)"
    for i = 1, math.min(#ERRORS, 12) do head[#head + 1] = ERRORS[i] end
end
if #WARNED > 0 then
    head[#head + 1] = "warnings:"
    for _, w in ipairs(WARNED) do head[#head + 1] = "  " .. w end
end
table.sort(UNDEF)
head[#head + 1] = "globals read but not defined: " .. (#UNDEF > 0 and table.concat(UNDEF, ", ") or "none")
if not VERBOSE and #ERRORS > 0 then OUT = {} end
local result = table.concat(head, "\n") .. "\n" .. table.concat(OUT, "\n")

if SNAP then
    boot("ROGUE")
    G.target, G.plates = true, true
    fire("PLAYER_TARGET_CHANGED")
    slash("test")
    local shots, last = {}, 0
    for _, t in ipairs(SNAP) do
        step(t - last)
        last = t
        shots[#shots + 1] = snapshot(string.format("demo at %.1fs", t))
    end
    if #ERRORS > 0 then result = result .. "\nFAIL: errors while taking snapshots\n" .. table.concat(ERRORS, "\n") end
    result = result .. "\n@@SNAP@@\n" .. json(shots)
end
return result
