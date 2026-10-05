-- JTS Tooltip (JTS Suite) - a clean replacement for the unit tooltip.
-- Written defensively for WoW: Forever, which can return "secret values" that
-- may be displayed but not compared or changed, so risky calls are pcall'd.

local ADDON = ...
local DB, currentUnit, previewUntil, settingsCategory
local PREFIX = "|cff33ff99JTS Tooltip:|r "
local settingObjs = {}

local DEFAULTS = {
    enabled = true, anchor = "BOTTOMRIGHT", offsetX = 0, offsetY = 0, scale = 1.0,
    hideBlizzard = true, mouseover = true, showTarget = true, hideEmpty = true,
    showPlayers = true, showNPCs = true, showPets = true, locked = false,
}

local ANCHORS = {
    { "CUSTOM", "Custom (drag to move)" }, { "CURSOR", "Follow mouse cursor" },
    { "TOPLEFT", "Top left" }, { "TOP", "Top" }, { "TOPRIGHT", "Top right" },
    { "LEFT", "Left" }, { "CENTER", "Center" }, { "RIGHT", "Right" },
    { "BOTTOMLEFT", "Bottom left" }, { "BOTTOM", "Bottom" },
    { "BOTTOMRIGHT", "Bottom right (default tooltip spot)" },
}
local VALID_ANCHOR = {}
for _, a in ipairs(ANCHORS) do VALID_ANCHOR[a[1]] = true end

local FACTION = {
    Alliance = { color = { 0.25, 0.55, 1.00 }, icon = "Interface\\FriendsFrame\\PlusManz-Alliance" },
    Horde    = { color = { 0.90, 0.15, 0.15 }, icon = "Interface\\FriendsFrame\\PlusManz-Horde" },
}
local GREY, GREEN, WHITE, RED = { 0.6, 0.6, 0.6 }, { 0.25, 1, 0.25 }, { 1, 1, 1 }, { 1, 0.2, 0.2 }

---------------------------------------------------------------------------
-- Safe helpers
---------------------------------------------------------------------------
local function isSecret(v)
    if not issecretvalue then return false end
    local ok, s = pcall(issecretvalue, v)
    return ok and s or false
end

-- Call fn safely; returns up to 3 results, or nothing on error
local function try(fn, ...)
    if not fn then return end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

-- Yes/no question asked safely (secret booleans count as "no")
local function truthy(fn, ...)
    if not fn then return false end
    local args = { ... }
    local ok, res = pcall(function() return fn(unpack(args)) and true or false end)
    return ok and res or false
end

local function plain(s) -- a normal, non-empty string?
    return type(s) == "string" and not isSecret(s) and s ~= ""
end

local function rgb(c) return c and { c.r, c.g, c.b } end

local function classColor(classFile)
    if not plain(classFile) then return end
    return rgb(try(function()
        if C_ClassColor and C_ClassColor.GetClassColor then return C_ClassColor.GetClassColor(classFile) end
        return (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[classFile]
    end))
end

-- Returns reaction text, colour
local function reactionInfo(unit)
    local r = try(UnitReaction, unit, "player")
    if r == nil or isSecret(r) then return end
    local text = (r <= 2 and "Hostile") or (r == 3 and "Unfriendly") or (r == 4 and "Neutral") or "Friendly"
    return text, rgb(FACTION_BAR_COLORS and FACTION_BAR_COLORS[r])
end

-- A line of Blizzard's tooltip data for a unit (NPC title, "Bob's Pet", ...)
local function tooltipLine(unit, index)
    local data = C_TooltipInfo and try(C_TooltipInfo.GetUnit, unit)
    local line = data and data.lines and data.lines[index]
    return line and line.leftText
end

local CLASSIFICATION = { worldboss = " Boss", rareelite = " Rare Elite", elite = " Elite", rare = " Rare" }

-- Returns level text, colour (grey/green/yellow/orange/red like the game)
local function levelText(unit)
    local lvl = try(UnitLevel, unit)
    if lvl == nil or isSecret(lvl) then return lvl end
    local color = RED -- "??" skull level
    if lvl > 0 then
        local c = try(GetCreatureDifficultyColor or GetQuestDifficultyColor, lvl)
        color = type(c) == "table" and rgb(c) or nil
    end
    local cls = try(UnitClassification, unit)
    return ((lvl > 0) and tostring(lvl) or "??") .. (plain(cls) and CLASSIFICATION[cls] or ""), color
end

-- Full player name. On Forever, UnitName returns (firstName, surname) and
-- Blizzard's GetUnitName(unit, true) joins them the way the game does.
local function fullName(unit)
    local n = try(GetUnitName, unit, true)
    if n ~= nil then return n end
    local first, surname = try(UnitName, unit)
    local sep = Constants and Constants.CharacterNameSeparatorConsts
    if sep and plain(first) and plain(surname) then
        return first .. sep.CHARACTERNAME_SURNAME_SEPARATOR .. surname
    end
    return first
end

---------------------------------------------------------------------------
-- What kind of unit is it?
---------------------------------------------------------------------------
local function unitExists(u) return truthy(UnitExists, u) end

local function unitKind(u) -- "player", "companion", "pet", "npc" or nil
    if not unitExists(u) then return end
    if truthy(UnitIsPlayer, u) then return "player" end
    local ct = try(UnitCreatureType, u)
    if truthy(UnitIsBattlePetCompanion, u) or truthy(UnitIsBattlePet, u)
       or (plain(ct) and (ct == "Non-combat Pet" or ct == "Wild Pet") and truthy(UnitPlayerControlled, u)) then
        return "companion"
    end
    if truthy(UnitPlayerControlled, u) then return "pet" end
    return "npc"
end

local function kindAllowed(kind)
    if kind == "player" then return DB.showPlayers end
    if kind == "npc" then return DB.showNPCs end
    return (kind == "pet" or kind == "companion") and DB.showPets
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "JTS_TooltipFrame", UIParent, "BackdropTemplate")
frame:SetSize(290, 152)
frame:SetFrameStrata("TOOLTIP")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.85)
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
frame:Hide()

frame:SetScript("OnDragStart", function(self)
    if DB.anchor == "CUSTOM" and not DB.locked then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    DB.pos = { point, relPoint, x, y }
end)

local factionIcon = frame:CreateTexture(nil, "ARTWORK")
factionIcon:SetSize(28, 28)
factionIcon:SetPoint("TOPRIGHT", -8, -9)

local MAX_ROWS, ROW_H = 8, 19
local rows = {}
for i = 1, MAX_ROWS do
    local y = -12 - (i - 1) * ROW_H
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 12, y)
    label:SetWidth(66)
    label:SetJustifyH("LEFT")
    local value = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("TOPLEFT", 80, y)
    value:SetPoint("RIGHT", frame, "RIGHT", -40, 0) -- room for the faction crest
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)
    rows[i] = { label = label, value = value }
end

-- list = { { "Label", text, color }, ... }
local function fillRows(list)
    local n = math.min(#list, MAX_ROWS)
    for i, row in ipairs(rows) do
        local item = list[i]
        row.label:SetShown(i <= n)
        row.value:SetShown(i <= n)
        if i <= n then
            local text, color = item[2], item[3]
            if text == nil then text, color = "—", GREY end
            if type(color) ~= "table" then color = WHITE end
            row.label:SetText(item[1] .. ":")
            row.value:SetText(text) -- SetText accepts secret values
            row.value:SetTextColor(color[1], color[2], color[3])
        end
    end
    frame:SetHeight(20 + math.max(n, 1) * ROW_H)
end

-- Shows the crest; returns faction name, colour
local function setFaction(unit)
    local fFile, fLocal = try(UnitFactionGroup, unit)
    local f = plain(fFile) and FACTION[fFile]
    factionIcon:SetShown(f and true or false)
    if f then
        factionIcon:SetTexture(f.icon)
        return fLocal or fFile, f.color
    end
end

---------------------------------------------------------------------------
-- Rows for each kind of unit
---------------------------------------------------------------------------
local function ownerOf(unit)
    if truthy(UnitIsUnit, unit, "pet") then return fullName("player") end
    local line = tooltipLine(unit, 2)
    if line == nil or isSecret(line) then return line end
    return line:match("^(.+)'s ") or line
end

-- Who the unit is targeting. Returns text, colour.
local function targetOf(unit)
    local t = unit .. "target"
    if not unitExists(t) then return "None", GREY end
    if truthy(UnitIsUnit, t, "player") then return "You", RED end
    if truthy(UnitIsPlayer, t) then
        local _, classFile = try(UnitClass, t)
        return fullName(t), classColor(classFile)
    end
    local _, rColor = reactionInfo(t)
    return (try(UnitName, t)), rColor
end

-- Note: a call placed last in a { } row passes ALL its returns (text and colour).
-- Wrap it in ( ) when only the first return is wanted.
local BUILDERS = {}

function BUILDERS.player(unit)
    local className, classFile = try(UnitClass, unit)
    local guild, rank = try(GetGuildInfo, unit)
    local cc = classColor(classFile)
    local faction, fColor = setFaction(unit)
    local guildRow = { "Guild", "No guild", GREY }
    if guild ~= nil and (isSecret(guild) or guild ~= "") then
        guildRow = { "Guild", isSecret(guild) and guild or ("<" .. guild .. ">"), fColor or GREEN }
    else
        rank = nil
    end
    return {
        { "Name", fullName(unit), cc },
        { "Level", levelText(unit) },
        guildRow,
        { "Rank", rank },
        { "Race", (try(UnitRace, unit)) },
        { "Class", className, cc },
        { "Faction", faction, fColor },
        { "Target", targetOf(unit) },
    }
end

function BUILDERS.npc(unit)
    local reaction, rColor = reactionInfo(unit)
    local faction, fColor = setFaction(unit)
    local list = { { "Name", (try(UnitName, unit)), rColor } }
    local title = tooltipLine(unit, 2)
    if title ~= nil and (isSecret(title) or not title:find(LEVEL or "Level", 1, true)) then
        list[#list + 1] = { "Title", title, GREEN }
    end
    list[#list + 1] = { "Type", (try(UnitCreatureType, unit)) }
    list[#list + 1] = { "Level", levelText(unit) }
    list[#list + 1] = { "Reaction", reaction, rColor }
    if faction then list[#list + 1] = { "Faction", faction, fColor } end
    list[#list + 1] = { "Target", targetOf(unit) }
    return list
end

function BUILDERS.pet(unit)
    local _, rColor = reactionInfo(unit)
    local faction, fColor = setFaction(unit)
    return {
        { "Name", (try(UnitName, unit)), rColor },
        { "Owner", ownerOf(unit) },
        { "Type", (try(UnitCreatureFamily, unit)) or (try(UnitCreatureType, unit)) },
        { "Level", levelText(unit) },
        { "Faction", faction, fColor },
        { "Target", targetOf(unit) },
    }
end

function BUILDERS.companion(unit)
    local faction, fColor = setFaction(unit)
    return {
        { "Name", (try(UnitName, unit)), WHITE },
        { "Owner", ownerOf(unit) },
        { "Type", "Companion pet" },
        { "Faction", faction, fColor },
    }
end

---------------------------------------------------------------------------
-- Positioning
---------------------------------------------------------------------------
local function positionAtCursor()
    local x, y = GetCursorPosition()
    local s = frame:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s + 18 + DB.offsetX, y / s - 18 + DB.offsetY)
end

local function applyLayout()
    local a = DB.anchor
    frame:SetScale(DB.scale)
    frame:EnableMouse(a == "CUSTOM") -- otherwise never block world mouseover
    frame:ClearAllPoints()
    if a == "CUSTOM" then
        local p = DB.pos or { "CENTER", "CENTER", 300, 100 }
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    elseif a == "CURSOR" then
        positionAtCursor()
    else -- screen preset, kept a little in from the edges (bottom ones clear the action bars)
        local x = a:find("LEFT") and 20 or a:find("RIGHT") and -20 or 0
        local y = a:find("TOP") and -20 or a:find("BOTTOM") and 140 or 0
        frame:SetPoint(a, UIParent, a, x + DB.offsetX, y + DB.offsetY)
    end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function pickUnit()
    for _, u in ipairs({ DB.mouseover and "mouseover", DB.showTarget and "target" }) do
        local k = u and unitKind(u)
        if k and kindAllowed(k) then return u, k end
    end
end

local function refresh()
    if not DB then return end
    local unit, kind = pickUnit()
    if not unit and previewUntil then unit, kind = "player", "player" end
    currentUnit = unit
    if unit then
        fillRows(BUILDERS[kind](unit))
    else
        factionIcon:Hide()
        fillRows({ { "Name" } })
    end
    local show = DB.enabled and (unit ~= nil or not DB.hideEmpty)
    frame:SetShown(show)
    if show and DB.anchor == "CURSOR" then positionAtCursor() end
end

local function preview()
    previewUntil = GetTime() + 4
    refresh()
end

local acc, sinceRefresh = 0, 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if DB.anchor == "CURSOR" then positionAtCursor() end
    acc = acc + elapsed
    if acc < 0.1 then return end
    sinceRefresh, acc = sinceRefresh + acc, 0
    if previewUntil and GetTime() > previewUntil then
        previewUntil = nil
        refresh()
    elseif currentUnit == "mouseover" and not unitExists("mouseover") then
        refresh()
    elseif currentUnit and sinceRefresh >= 0.5 then
        sinceRefresh = 0
        refresh() -- keeps the Target row current as they switch targets
    end
end)

---------------------------------------------------------------------------
-- Hide Blizzard's default unit tooltip
---------------------------------------------------------------------------
local function hideIfNeeded(tt)
    if not (DB and DB.enabled and DB.hideBlizzard and DB.mouseover) then return end
    local ok, _, unit = pcall(tt.GetUnit, tt)
    if not ok or unit == nil then return end -- not a unit tooltip
    if isSecret(unit) then unit = "mouseover" end
    local kind = unitKind(unit)
    if kind and kindAllowed(kind) then tt:Hide() end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
   and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
        if tt ~= GameTooltip then return end
        hideIfNeeded(tt)
        if C_Timer then C_Timer.After(0, function() hideIfNeeded(GameTooltip) end) end
    end)
end
GameTooltip:HookScript("OnShow", hideIfNeeded)

---------------------------------------------------------------------------
-- Options panel (Esc > Options > AddOns > JTS Tooltip)
---------------------------------------------------------------------------
local function onSettingChanged()
    applyLayout()
    preview()
end

-- { type, key, name, tooltip, [slider min, max, step, format] }
local OPTIONS = {
    { "check", "enabled", "Enable", "Turn the JTS tooltip on or off." },
    { "anchor", "anchor", "Anchor", "Where the tooltip appears. 'Custom' lets you drag it anywhere; 'Follow mouse cursor' sticks it to your pointer." },
    { "slider", "offsetX", "Horizontal offset", "Nudge the tooltip left or right (not used for Custom).", -400, 400, 5, "%d" },
    { "slider", "offsetY", "Vertical offset", "Nudge the tooltip up or down (not used for Custom).", -400, 400, 5, "%d" },
    { "slider", "scale", "Scale", "Size of the tooltip.", 0.5, 2.0, 0.05, "%.2f" },
    { "check", "locked", "Lock position", "Stops the tooltip being dragged when the anchor is Custom." },
    { "check", "hideBlizzard", "Hide Blizzard tooltip", "Hide the default game tooltip for units this addon shows." },
    { "check", "mouseover", "Show on mouseover", "Show whatever you hover over." },
    { "check", "showTarget", "Show target when not hovering", "Fall back to your current target when you're not hovering a unit." },
    { "check", "hideEmpty", "Hide when nothing is selected", "Hide the tooltip when there is no unit to show." },
    { "check", "showPlayers", "Show players", "Show info for players." },
    { "check", "showNPCs", "Show NPCs", "Show info for NPCs and creatures." },
    { "check", "showPets", "Show pets & companions", "Show info for combat pets and non-combat companion pets." },
}

local function buildSettings()
    local category = Settings.RegisterVerticalLayoutCategory("JTS Tooltip")
    local VarType = { check = Settings.VarType.Boolean, slider = Settings.VarType.Number, anchor = Settings.VarType.String }

    for _, o in ipairs(OPTIONS) do
        local kind, key, name, tip = o[1], o[2], o[3], o[4]
        local variable = "JTS_Tooltip_" .. key
        local s = Settings.RegisterAddOnSetting(category, variable, key, DB, VarType[kind], name, DEFAULTS[key])
        if s.SetValueChangedCallback then
            s:SetValueChangedCallback(onSettingChanged)
        elseif Settings.SetOnValueChangedCallback then
            Settings.SetOnValueChangedCallback(variable, onSettingChanged)
        end
        settingObjs[key] = s

        if kind == "check" then
            Settings.CreateCheckbox(category, s, tip)
        elseif kind == "slider" then
            local opts = Settings.CreateSliderOptions(o[5], o[6], o[7])
            if opts.SetLabelFormatter and MinimalSliderWithSteppersMixin then
                opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
                    function(v) return string.format(o[8], v) end)
            end
            Settings.CreateSlider(category, s, opts, tip)
        else
            Settings.CreateDropdown(category, s, function()
                local c = Settings.CreateControlTextContainer()
                for _, a in ipairs(ANCHORS) do c:Add(a[1], a[2]) end
                return c:GetData()
            end, tip)
        end
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

-- Change a setting from a slash command, keeping the options panel in sync
local function setOption(key, value)
    local s = settingObjs[key]
    if not (s and s.SetValue and pcall(s.SetValue, s, value)) then DB[key] = value end
    onSettingChanged()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_GUILD_UPDATE",
                     "UNIT_NAME_UPDATE", "UNIT_FACTION", "UNIT_LEVEL", "UNIT_TARGET" }) do
    frame:RegisterEvent(e)
end

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        JTS_TooltipDB = JTS_TooltipDB or {}
        DB = JTS_TooltipDB
        -- Carry over settings from early test builds
        if DB.shown ~= nil then DB.enabled, DB.shown = DB.shown, nil end
        if DB.anchor == nil and DB.pos then DB.anchor = "CUSTOM" end
        for k, v in pairs(DEFAULTS) do
            if type(DB[k]) ~= type(v) then DB[k] = v end
        end
        if not VALID_ANCHOR[DB.anchor] then DB.anchor = DEFAULTS.anchor end

        local ok, err = pcall(buildSettings)
        if not ok then
            print(PREFIX .. "options panel unavailable on this client, use /jtstt help. (" .. tostring(err) .. ")")
        end
        applyLayout()
        refresh()
        self:UnregisterEvent("ADDON_LOADED")
    elseif DB and not (event:find("^UNIT_") and arg1 ~= currentUnit) then
        refresh() -- UNIT_ events only matter for the unit being shown
    end
end)

---------------------------------------------------------------------------
-- Slash commands (also a fallback if the options panel can't load)
---------------------------------------------------------------------------
local function msg(text) print(PREFIX .. text) end

-- command = { setting to flip, message when on, message when off }
local TOGGLES = {
    toggle   = { "enabled", "enabled.", "disabled." },
    lock     = { "locked", "position locked.", "position unlocked - set anchor to custom and drag to move." },
    blizzard = { "hideBlizzard", "Blizzard tooltip hidden for units.", "Blizzard tooltip shown." },
}

SLASH_JTSTOOLTIP1 = "/jtstt"
SlashCmdList.JTSTOOLTIP = function(input)
    local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local t = TOGGLES[cmd]
    if t then
        setOption(t[1], not DB[t[1]])
        msg(DB[t[1]] and t[2] or t[3])
    elseif cmd == "" and settingsCategory and pcall(Settings.OpenToCategory, settingsCategory:GetID()) then
        -- options panel opened
    elseif cmd == "anchor" and VALID_ANCHOR[arg:upper():gsub("%s", "")] then
        setOption("anchor", (arg:upper():gsub("%s", "")))
        msg("anchored to " .. arg .. ".")
    elseif cmd == "reset" then
        DB.pos = nil
        setOption("offsetX", 0)
        setOption("offsetY", 0)
        msg("position reset.")
    elseif cmd == "preview" then
        preview()
    else
        msg("/jtstt - open options    /jtstt preview - show for 4 seconds")
        msg("/jtstt toggle - on/off    /jtstt lock - lock/unlock    /jtstt reset - reset position")
        msg("/jtstt blizzard - hide/show Blizzard's tooltip")
        msg("/jtstt anchor <cursor|custom|topleft|top|topright|left|center|right|bottomleft|bottom|bottomright>")
    end
end
