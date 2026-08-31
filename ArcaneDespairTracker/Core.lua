--[[--------------------------------------------------------------------------
    Arcane Despair Tracker (ADT)
    World of Warcraft: Midnight (Interface 120100)

    Counts:
      * Arcane Blast   cast WITHOUT proccing Clearcasting
      * Arcane Barrage cast WITHOUT proccing Prismatic Bolt

    The dry streak resets the moment a proc lands. Totals never reset on their
    own - only /adt reset clears them.

    Midnight notes: COMBAT_LOG_EVENT_UNFILTERED is forbidden for addons since
    12.0 and aura data can be a Secret Value during encounters, M+ and rated
    PvP. Everything here is built on UNIT_SPELLCAST_SUCCEEDED, UNIT_AURA with
    GetPlayerAuraBySpellID, C_Spell.GetOverrideSpell, and - when aura data is
    unreadable - on the casts that can only exist because a proc existed.

    /adt help
----------------------------------------------------------------------------]]

local ADDON_NAME = ...

----------------------------------------------------------------------
-- Spell IDs (patchable at runtime with /adt setid <key> <id>)
----------------------------------------------------------------------
local ID = {
    blast    = 30451,       -- Arcane Blast
    barrage  = 44425,       -- Arcane Barrage
    missiles = 5143,        -- Arcane Missiles (consumes Clearcasting)
    ccAura   = 263725,      -- Clearcasting
    pbCast   = 1295924,     -- Prismatic Bolt (replaces Arcane Blast) - live 12.1 id
    pbAura   = 1295942,     -- Prismatic Bolt! (the proc buff)
    soulAura    = 451038,   -- Arcane Soul
    soulTrigger = 365350,   -- Arcane Surge, which leads into it
}

-- Other ids seen for the Prismatic Bolt cast (1295923 was the 12.1 PTR value).
-- Anything the override actually reports is learned at runtime and saved.
local EXTRA_PB_CASTS = { 1295923 }

-- The same proc answers to several spell ids. 79684 is what Blizzard's own
-- Cooldown Manager tracks Clearcasting under; 263725 is the player buff.
-- Rebuilt whenever /adt setid changes one of them, and extended at runtime by
-- whatever the Cooldown Manager turns out to be using.
local CC_AURA_IDS = { 263725, 79684 }
local PB_AURA_IDS = { 1295942 }

-- Only your own Arcane casts can proc Clearcasting, so only these end the
-- previous cast's claim on the next proc. A trinket firing (Light's Potential
-- and friends) shows up as a cast too, and must not steal a Blast's proc.
local CLAIM_BREAKERS = {
    [30451]   = true,   -- Arcane Blast
    [44425]   = true,   -- Arcane Barrage
    [5143]    = true,   -- Arcane Missiles
    [1449]    = true,   -- Arcane Explosion
    [153626]  = true,   -- Arcane Orb
    [365350]  = true,   -- Arcane Surge
    [321507]  = true,   -- Touch of the Magi
    [1295924] = true,   -- Prismatic Bolt
    [1295923] = true,
}

local ARCANE_SPEC_ID = 62

local BACK_WINDOW = 0.25    -- tolerance for a proc landing just before the cast
local FIGHT_GRACE = 6.0     -- seconds out of combat before a fight is over
local MAX_GAIN    = 3       -- sanity cap on procs detected in a single poll
local CREDIT_TTL  = {       -- how long a counted proc may sit unconsumed
    blast   = 22,           -- Clearcasting ~20s
    barrage = 62,           -- Prismatic Bolt! ~60s
}

-- The walkthrough pace. The longest built-in sound runs about 3.5 s, so a step
-- shorter than this cuts each stage off before you have heard it.
local PREVIEW_STEP = 3.6
local PREVIEW_HOLD = 3.3
local REFRESH_EPS = 0.05    -- any rise in expirationTime is a reapplication
local POLL_INTERVAL = 0.25  -- catches aura secrecy lifting, which fires no event
local USABLE_GATE = 1.2     -- a usability flip only counts this soon after a cast
local SAME_INSTANT = 0.15   -- two signals this close describe the same proc
local DB_VERSION  = 4

----------------------------------------------------------------------
-- Strings
----------------------------------------------------------------------
local L = {
    PREFIX        = "|cff8778ffADT|r",
    TITLE         = "Arcane Despair Tracker",
    BLAST_LABEL   = "Arcane Blast w/o Clearcasting",
    BARRAGE_LABEL = "Arcane Barrage w/o Prismatic Bolt",
    NO_DATA       = "no casts this fight",
    FIGHT         = "Fight summary",
    STRIKE_PREFIX = "|cffb0a8d0STRIKE|r",
    CASTS_PREFIX  = "|cffb0a8d0CASTS|r",
    STRIKE_SEP    = "|cff707070:|r",
    PB_LABEL      = "Prismatic Bolt casts",
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function Print(msg, ...)
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    print(L.PREFIX .. " " .. msg)
end

-- Secret Values: never compare or do arithmetic on a secret. Test first.
local function IsSecret(v)
    if issecretvalue then
        local ok, res = pcall(issecretvalue, v)
        return ok and res == true
    end
    return false
end

local function SpellTexture(spellID)
    local ok, tex = pcall(function()
        if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spellID) end
        return _G.GetSpellTexture and _G.GetSpellTexture(spellID) or nil
    end)
    return ok and tex or nil
end

local function SpellName(spellID)
    local ok, name = pcall(function()
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellID)
            return info and info.name or nil
        end
        return nil
    end)
    return (ok and name) or ("spell:" .. tostring(spellID))
end

local function CurrentSpecID()
    local getSpec     = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or _G.GetSpecialization
    local getSpecInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or _G.GetSpecializationInfo
    if not (getSpec and getSpecInfo) then return nil end
    local ok, id = pcall(function()
        local idx = getSpec()
        if not idx or idx < 1 then return nil end
        return (getSpecInfo(idx))
    end)
    return ok and id or nil
end

local function Hex(c)
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x",
        math.floor((c.r or 1) * 255 + 0.5),
        math.floor((c.g or 1) * 255 + 0.5),
        math.floor((c.b or 1) * 255 + 0.5))
end

local function FormatPct(procs, casts)
    if not casts or casts == 0 then return "-" end
    return string.format("%.1f%%", procs / casts * 100)
end

local function FormatDuration(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function InCombat()
    if UnitAffectingCombat then
        local ok, res = pcall(UnitAffectingCombat, "player")
        if ok then return res and true or false end
    end
    return false
end

----------------------------------------------------------------------
-- Aura reading (secret-safe)
--   returns { instance, stacks, expires } or nil, and a status string
--   status: "ok" | "absent" | "restricted" | "noapi"
----------------------------------------------------------------------
-- Is this spell's aura a Secret Value right this second? This is what lets us
-- tell "the buff is not there" apart from "we are not allowed to look", which
-- otherwise both come back as nothing.
local function AuraIsSecretNow(spellID)
    if not (C_Secrets and C_Secrets.ShouldSpellAuraBeSecret) then return false end
    local ok, res = pcall(C_Secrets.ShouldSpellAuraBeSecret, spellID)
    return ok and res == true
end

-- Every id for this proc is forbidden right now? Any single readable one is
-- enough to see stacks, and they can be flagged differently.
local function AllAuraIDsSecret(ids)
    for _, id in ipairs(ids) do
        if not AuraIsSecretNow(id) then return false end
    end
    return true
end

local function ReadAura(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil, "noapi" end

    local ok, res = pcall(function()
        local a = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
        if a == nil then return nil end

        local out = {}
        -- auraInstanceID is flagged NeverSecret, the rest may not be
        local inst = a.auraInstanceID
        if inst ~= nil and not IsSecret(inst) then out.instance = inst end
        local stacks = a.applications
        if stacks ~= nil and not IsSecret(stacks) then out.stacks = stacks end
        local expires = a.expirationTime
        if expires ~= nil and not IsSecret(expires) then out.expires = expires end
        return out
    end)

    if not ok then return nil, "restricted" end
    if res == nil then
        return nil, AuraIsSecretNow(spellID) and "restricted" or "absent"
    end
    return res, "ok"
end

----------------------------------------------------------------------
-- Blizzard's own Cooldown Manager as a stack-count source
--
-- Reading aura data is restricted, but Blizzard's Cooldown Manager *draws* the
-- stack count on screen from its own untainted code. C_CooldownViewer carries no
-- SecretWhen... annotation, and the number it renders is a plain FontString. So
-- we look up the viewer entry for the aura and read the digit it is showing.
-- Every step is wrapped: if any of it is secret or missing we just get nil.
----------------------------------------------------------------------
local VIEWER_CATEGORIES = { 2, 6 }   -- TrackedBuff, SpecAgnosticTracked
local VIEWER_FRAMES = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}
local STACK_TEXT_KEYS = { "Applications", "ApplicationsText", "Count", "CountText", "StackText" }

local VIEWER_RETRY = 3.0
local viewerIDCache = {}    -- [spellID] = { id = n } or { retryAt = t }

local function ViewerIDForSpell(spellID, learnInto)
    local cached = viewerIDCache[spellID]
    if cached then
        if cached.id then return cached.id end
        -- Never cache a miss forever: the Cooldown Manager is not populated yet
        -- at login, and the tracked set changes with talents.
        if GetTime() < cached.retryAt then return nil end
    end
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then return nil end

    local found
    for _, category in ipairs(VIEWER_CATEGORIES) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category)
        if ok and type(ids) == "table" then
            for _, id in ipairs(ids) do
                local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                if ok2 and type(info) == "table" then
                    local matched = false
                    pcall(function()
                        if info.spellID == spellID or info.overrideSpellID == spellID then
                            matched = true
                            return
                        end
                        if type(info.linkedSpellIDs) == "table" then
                            for _, s in ipairs(info.linkedSpellIDs) do
                                if s == spellID then matched = true return end
                            end
                        end
                    end)
                    if matched then
                        found = id
                        -- The viewer may track the proc under a different spell
                        -- id than the player buff. Remember it and read it too.
                        if learnInto then
                            pcall(function()
                                local primary = info.spellID
                                if type(primary) == "number" and not IsSecret(primary) then
                                    for _, existing in ipairs(learnInto) do
                                        if existing == primary then return end
                                    end
                                    table.insert(learnInto, primary)
                                end
                            end)
                        end
                        break
                    end
                end
            end
        end
        if found then break end
    end

    viewerIDCache[spellID] = found and { id = found } or { retryAt = GetTime() + VIEWER_RETRY }
    return found
end

-- Pull a small integer out of any FontString this frame is showing.
local function NumericTextOf(frame)
    local value
    pcall(function()
        for _, key in ipairs(STACK_TEXT_KEYS) do
            local fs = frame[key]
            if fs and fs.GetText then
                local n = tonumber(fs:GetText())
                if n and n >= 1 and n <= 20 then value = n return end
            end
        end
        if not frame.GetRegions then return end
        for _, region in ipairs({ frame:GetRegions() }) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString"
               and region.IsShown and region:IsShown() then
                local n = tonumber(region:GetText())
                if n and n >= 1 and n <= 20 then value = n return end
            end
        end
    end)
    return value
end

local function ViewerItemFor(cooldownID)
    for _, frameName in ipairs(VIEWER_FRAMES) do
        local parent = _G[frameName]
        if parent and parent.GetChildren then
            local ok, children = pcall(function() return { parent:GetChildren() } end)
            if ok then
                for _, item in ipairs(children) do
                    local match = false
                    pcall(function()
                        if item.cooldownID == cooldownID then match = true
                        elseif item.GetCooldownID and item:GetCooldownID() == cooldownID then match = true end
                    end)
                    if match then return item, frameName end
                end
            end
        end
    end
    return nil
end

-- Stack count as displayed by the Cooldown Manager, or nil.
-- Note Blizzard hides the digit at a single application, so "showing nothing"
-- means one stack when the buff is up at all.
local function ViewerStacks(spellID)
    local cooldownID = ViewerIDForSpell(spellID)
    if not cooldownID then return nil end

    local item, frameName = ViewerItemFor(cooldownID)
    if not item then return nil end

    local shown = false
    pcall(function() shown = item.IsShown and item:IsShown() or false end)
    if not shown then return nil end

    -- Only report a count we actually read. Defaulting to 1 here was a mistake:
    -- it pinned the believed stack count at 1 forever, which made every real
    -- stack change look like no change and suppressed the aura path entirely.
    local n = NumericTextOf(item)
    if not n then return nil end
    return n, frameName
end

-- Is a spell castable right now? nil = unreadable.
-- Arcane Missiles is only castable while you hold Clearcasting, which makes this
-- a proc detector that needs no aura data at all.
local function ReadUsable(spellID)
    if not (C_Spell and C_Spell.IsSpellUsable) then return nil end
    local ok, usable = pcall(C_Spell.IsSpellUsable, spellID)
    if not ok or usable == nil or IsSecret(usable) then return nil end
    return usable and true or false
end

-- Which spell currently replaces Arcane Blast on the bars (nil = none).
-- Also reports whether the answer was readable at all, which is how we know
-- if the Prismatic Bolt detector is live.
local overrideReadable = false

local function BlastOverride()
    overrideReadable = false
    if not (C_Spell and C_Spell.GetOverrideSpell) then return nil end
    local ok, override = pcall(C_Spell.GetOverrideSpell, ID.blast)
    if not ok or override == nil or IsSecret(override) then return nil end
    overrideReadable = true
    if override == ID.blast then return nil end
    return override
end

----------------------------------------------------------------------
-- Data
----------------------------------------------------------------------
local function NewTracker()
    return { casts = 0, procs = 0, dry = 0, streak = 0, maxStreak = 0 }
end

local function Color(r, g, b) return { r = r, g = g, b = b } end

local DEFAULTS = {
    version = DB_VERSION,
    colors = {
        calm   = Color(0.25, 1.00, 0.25),   -- strike below the warning level
        warn   = Color(1.00, 0.82, 0.00),   -- from 5
        clown  = Color(1.00, 0.50, 0.25),   -- from the clown threshold
        alert  = Color(1.00, 0.25, 0.25),   -- past the alert threshold
        mark   = Color(0.25, 1.00, 0.25),   -- the "?" when counting is paused
        title  = Color(0.62, 0.55, 1.00),
    },
    shame = {
        blast = {
            enabled = true, at = 3, step = 1, timeout = 3,
            soundEnabled = true, every = 1, everyFinal = 3, soundFiles = {},
            point = "CENTER", x = -170, y = 0, size = 60, growth = 12, maxSize = 320,
        },
        barrage = {
            enabled = true, at = 6, step = 2, timeout = 4,
            soundEnabled = true, every = 2, everyFinal = 3, soundFiles = {},
            point = "CENTER", x = 170, y = 0, size = 60, growth = 10, maxSize = 320,
        },
    },
    ui = {
        point = "CENTER", x = 0, y = 180, scale = 1.0, shown = true, locked = false,
        width = 212, iconSize = 20, titleSize = 12, textSize = 13,
        showTitle = true, showBackground = true, showBorder = true, bgAlpha = 0.5,
    },
    opts = {
        countPrismatic = false,  -- a Prismatic Bolt cast counts as an Arcane Blast cast
        reportCombat   = false,  -- chat summary after a fight, off by default
        alertThreshold = 0,      -- 0 = off
        onlyArcane     = true,
        debug          = false,
        showRate       = true,   -- the "proc 21.8%" column
        showPB         = true,   -- third row: Prismatic Bolt casts
        showPBReset    = true,   -- the little RESET button on that row
        resetOnFight   = true,   -- clear every counter when a new fight starts
        clownEnabled   = true,   -- shame clown above the window
        clownAt        = 3,      -- strike at which it appears
        soundEnabled   = true,
        soundEvery     = 1,      -- casts between sounds past the threshold
        soundEveryFinal = 3,     -- ... and once the last stage is reached
        soundChannel   = "Master",
        tierStep       = 1,      -- casts between despair stages
        clownTimeout   = 3,      -- hide the face this long after the last Blast
        soundFiles     = {},     -- ["1".."5"] = your own .ogg, empty = that stage's own
        pauseWhenBlind = true,   -- do not count casts whose procs we cannot see
        soulPause      = false,  -- optionally ignore Barrages cast during Arcane Soul
        soulDelay      = 17.4,   -- Arcane Soul lands this long after Arcane Surge
        soulDuration   = 4,      -- and lasts this long
    },
    ids     = {},
    learnedPB = {},          -- override ids seen for Prismatic Bolt, kept across reloads
    total   = { blast = NewTracker(), barrage = NewTracker() },
    history = {},
}

local DB
local frame, rows

-- runtime state (never saved)
local combatStats, combatStart, inFight, fightEndsAt
local pendingCast           -- { kind } - the cast that owns the next proc we see
local lastBookedKind        -- survives the next cast; used by the blind fallback
local lastCastAt = { blast = 0, barrage = 0 }   -- when each counter last moved
local pbCasts = 0           -- Prismatic Bolts cast, this fight
local soulFrom, soulTo = 0, 0   -- cast-derived Arcane Soul window
local shameRun = { blast = 0, barrage = 0 }   -- bumped whenever a strike starts over
local shameLastKey = {}                       -- guards a repeat sound for one strike
local DetectionLive         -- forward declaration; the UI marks blind counters
local ResetStatsPublic      -- wired to ResetStats once it exists
local ResetStatsSilent      -- same, without the chat line
local ShowStatusPublic      -- wired to ShowStatus once it exists
local carry       = {}      -- proc seen before its cast event arrived
local maxSnapshot = {}      -- maxStreak before the last dry cast
local lastGain    = { blast = 0, barrage = 0 }
local credits     = { blast = {}, barrage = {} }
local auraState   = {}
local auraStatus  = { blast = "?", barrage = "?" }
local lastAuraSig = {}      -- debug: only log an aura poll when it changed
local learnedPBCasts = {}
local lastOverride
local missilesUsable        -- nil = unknown / unreadable
local lastAnyCast = 0       -- any player cast, used to gate the usability signal

local function Debug(msg, ...)
    if not (DB and DB.opts.debug) then return end
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    print("|cff777777ADT dbg:|r " .. msg)
end

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function ResetCombatStats()
    combatStats = { blast = NewTracker(), barrage = NewTracker() }
    combatStart = GetTime()
end
----------------------------------------------------------------------
-- Media
----------------------------------------------------------------------
local MEDIA = "Interface\\AddOns\\ArcaneDespairTracker\\Media\\"

-- Five stages of it going badly. Every face and every sound here was drawn and
-- synthesised for this addon, so nothing needs licensing - they are originals in
-- the spirit of the usual internet fare, not the recordings themselves.
local TIERS = {
    blast = {
        { face = "face1-smug.tga",    sound = "t1-honk.ogg",          label = "Smug clown" },
        { face = "face2-worried.tga", sound = "t2-slide-whistle.ogg", label = "Worried"    },
        { face = "face3-sad.tga",     sound = "t3-sad-trombone.ogg",  label = "Sad"        },
        { face = "face4-crying.tga",  sound = "t4-sad-violin.ogg",    label = "Crying"     },
        { face = "face5-void.tga",    sound = "t5-dirge.ogg",         label = "Void"       },
    },
    -- Prismatic Bolt gets its own arcane-purple set, so a glance tells you which
    -- counter is the one falling apart.
    barrage = {
        { face = "pb1.tga", sound = "b1-blip.ogg",            label = "Confident" },
        { face = "pb2.tga", sound = "x-music-box.ogg",        label = "Doubting"  },
        { face = "pb3.tga", sound = "t3-sad-trombone.ogg",    label = "Pleading"  },
        { face = "pb4.tga", sound = "x-empty-room-piano.ogg", label = "Sobbing"   },
        { face = "pb5.tga", sound = "b5-shatter.ogg",         label = "Shattered" },
    },
}

local SHAME_KINDS = { "blast", "barrage" }
local KIND_LABEL  = { blast = "Arcane Blast", barrage = "Arcane Barrage" }

-- The files that ship with the addon. Only used to list them in a tooltip now
-- that each stage points at a path of its own.
local SOUNDS = {
    { key = "honk",     label = "Clown honk",      short = "Honk",      file = MEDIA .. "t1-honk.ogg" },
    { key = "whistle",  label = "Slide whistle",   short = "Whistle",   file = MEDIA .. "t2-slide-whistle.ogg" },
    { key = "trombone", label = "Sad trombone",    short = "Trombone",  file = MEDIA .. "t3-sad-trombone.ogg" },
    { key = "violin",   label = "Violin + cello",  short = "Violin",    file = MEDIA .. "t4-sad-violin.ogg" },
    { key = "dirge",    label = "Funeral dirge",   short = "Dirge",     file = MEDIA .. "t5-dirge.ogg" },
    { key = "flatline", label = "Flatline",        short = "Flatline",  file = MEDIA .. "x-flatline.ogg" },
    { key = "piano",    label = "Empty-room piano", short = "Piano",    file = MEDIA .. "x-empty-room-piano.ogg" },
    { key = "rain",     label = "Rain and thunder", short = "Rain",     file = MEDIA .. "x-rain-thunder.ogg" },
    { key = "musicbox", label = "Music box dying", short = "Music box", file = MEDIA .. "x-music-box.ogg" },
    { key = "off",      label = "No sound",        short = "None"       },
}

local SOUND_CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }

local function Shame(kind) return DB.shame[kind] end

-- Which stage a strike has reached. Stage 1 begins at that counter's threshold
-- and every `step` further casts drops it one deeper.
local function TierFor(kind, streak)
    local cfg = Shame(kind)
    local at, step = cfg.at, math.max(1, cfg.step or 1)
    if at <= 0 or streak < at then return 0 end
    local tier = 1 + math.floor((streak - at) / step)
    local last = #TIERS[kind]
    if tier > last then tier = last end
    return tier
end

-- One rule: whatever path is typed for this stage, or the stage's own file when
-- that box is empty. Typing "none" silences a single stage.
local function StageSoundFile(kind, tier)
    local set = TIERS[kind]
    tier = math.max(1, math.min(#set, tier or 1))
    local file = Shame(kind).soundFiles and Shame(kind).soundFiles[tostring(tier)]
    if file then
        file = file:gsub("^%s+", ""):gsub("%s+$", "")
        if file ~= "" then
            local lowered = file:lower()
            if lowered == "none" or lowered == "off" then return nil, true end
            return file
        end
    end
    return MEDIA .. set[tier].sound
end

local function PlayShameSound(kind, tier)
    local file, silenced = StageSoundFile(kind, tier)
    if silenced or not file then return end
    pcall(PlaySoundFile, file, DB.opts.soundChannel or "Master")
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local function ShouldShow()
    if not DB.ui.shown then return false end
    if DB.opts.onlyArcane then
        local spec = CurrentSpecID()
        if spec and spec ~= ARCANE_SPEC_ID then return false end
    end
    return true
end

local function StreakColor(streak)
    local c = DB.colors
    local threshold = DB.opts.alertThreshold
    if threshold > 0 and streak >= threshold then return Hex(c.alert) end
    local at = DB.shame.blast.at
    if at > 0 and streak >= at then return Hex(c.clown) end
    if streak >= 5 then return Hex(c.warn) end
    return Hex(c.calm)
end

-- Each counter gets its own face frame, so both can be on screen at once and be
-- dragged apart.
local shameFrames = {}
local placingKind              -- the counter whose face is pinned for placement
local previewKind, previewTier -- a stage being shown off
local previewUntil = 0

UpdateShamePublic = nil        -- assigned just below

local function CreateShameFrame(kind)
    local f = CreateFrame("Frame", "ArcaneDespairTrackerFace" .. kind, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not DB.ui.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        local cfg = Shame(kind)
        cfg.point, cfg.x, cfg.y = point, x, y
    end)

    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetAllPoints(f)
    f.tex:SetTexture(MEDIA .. TIERS[kind][1].face)

    local cfg = Shame(kind)
    f:ClearAllPoints()
    f:SetPoint(cfg.point, UIParent, cfg.point, cfg.x, cfg.y)
    f:SetSize(cfg.size, cfg.size)
    f:Hide()

    shameFrames[kind] = f
end

local function CreateShameFrames()
    for _, kind in ipairs(SHAME_KINDS) do CreateShameFrame(kind) end
end

local function UpdateShame(kind)
    local f = shameFrames[kind]
    if not f then return end
    local cfg = Shame(kind)

    if placingKind == kind then
        f.tex:SetTexture(MEDIA .. TIERS[kind][1].face)
        f:SetSize(cfg.size, cfg.size)
        f:Show()
        return
    end

    if previewKind == kind and previewTier then
        if GetTime() > previewUntil then
            previewKind, previewTier = nil, nil
        else
            local over = (previewTier - 1) * math.max(1, cfg.step)
            local size = math.min(cfg.size + over * cfg.growth, cfg.maxSize)
            f.tex:SetTexture(MEDIA .. TIERS[kind][previewTier].face)
            f:SetSize(size, size)
            f:Show()
            return
        end
    end

    local streak = DB.total[kind].streak
    local tier = TierFor(kind, streak)
    if not cfg.enabled or tier == 0 then f:Hide() return end

    -- A proc can come from anything you cast, so a counter that is standing
    -- still is not a strike any more.
    local timeout = cfg.timeout or 0
    if timeout > 0 and (GetTime() - (lastCastAt[kind] or 0)) > timeout then
        f:Hide()
        return
    end

    f.tex:SetTexture(MEDIA .. TIERS[kind][tier].face)
    local size = math.min(cfg.size + (streak - cfg.at) * cfg.growth, cfg.maxSize)
    f:SetSize(size, size)
    f:Show()
end

local function UpdateShameAll()
    for _, kind in ipairs(SHAME_KINDS) do UpdateShame(kind) end
end

UpdateShamePublic = UpdateShameAll

local function UpdateDisplay()
    if not frame then return end
    if not ShouldShow() then frame:Hide() return end
    frame:Show()

    local pbRow = rows[3]
    if pbRow then
        pbRow.main:SetText(string.format("%s%s %s%d|r",
            L.CASTS_PREFIX, L.STRIKE_SEP, Hex(DB.colors.calm), pbCasts))
        if DB.opts.showPB and DB.opts.showPBReset then
            pbRow.reset:Show()
        else
            pbRow.reset:Hide()
        end
    end

    for _, entry in ipairs({ { "blast", rows[1] }, { "barrage", rows[2] } }) do
        local kind, row = entry[1], entry[2]
        local t = DB.total[kind]

        -- Only Arcane Blast can pause, so only Arcane Blast gets the marker.
        local mark = ""
        if kind == "blast" and DB.opts.pauseWhenBlind
           and DetectionLive and not DetectionLive(kind) then
            mark = Hex(DB.colors.mark) .. "?|r"
        end

        row.main:SetText(string.format("%s%s %s%d|r%s",
            L.STRIKE_PREFIX, L.STRIKE_SEP, StreakColor(t.streak), t.streak, mark))

        if DB.opts.showRate then
            row.rate:SetText(string.format("|cff909090proc|r %s", FormatPct(t.procs, t.casts)))
            row.rate:Show()
        else
            row.rate:Hide()
        end
    end

    UpdateShameAll()
end

-- Show one stage on screen at the size it would really be, for a few seconds.
local function PreviewTier(kind, i, seconds)
    seconds = seconds or PREVIEW_HOLD
    previewKind, previewTier, previewUntil = kind, i, GetTime() + seconds
    UpdateShameAll()
    if C_Timer and C_Timer.After then
        C_Timer.After(seconds + 0.1, UpdateShameAll)
    end
end

local function RowTooltip(row)
    if not GameTooltip then return end

    if row.kind == "pb" then
        GameTooltip:SetOwner(row.hover, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", row.hover, "TOPRIGHT", 8, 0)
        GameTooltip:AddLine(row.label)
        GameTooltip:AddLine(row.tip, 0.8, 0.8, 0.8, true)
        GameTooltip:AddDoubleLine("Cast this fight", tostring(pbCasts), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("RESET clears every counter, not just this one.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Right-click the window for settings.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
        return
    end

    local t = DB.total[row.kind]
    local c = combatStats and combatStats[row.kind]

    GameTooltip:SetOwner(row.hover, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    -- Anchor to the row itself, on whichever side has room. Owning the frame and
    -- letting the tooltip pick a corner is what put it somewhere strange.
    local anchor = (frame:GetCenter() or 0) > (UIParent:GetWidth() or 0) / 2
    if anchor then
        GameTooltip:SetPoint("TOPRIGHT", row.hover, "TOPLEFT", -8, 0)
    else
        GameTooltip:SetPoint("TOPLEFT", row.hover, "TOPRIGHT", 8, 0)
    end

    GameTooltip:AddLine(row.label)
    GameTooltip:AddLine(row.tip, 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Current strike", tostring(t.streak), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Longest strike", tostring(t.maxStreak), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Casts with no proc",
        string.format("%d / %d", t.dry, t.casts), 0.7, 0.7, 0.7, 1, 0.5, 0.5)
    GameTooltip:AddDoubleLine("Procs", string.format("%d  (%s)", t.procs, FormatPct(t.procs, t.casts)),
        0.7, 0.7, 0.7, 0.5, 1, 0.5)
    if c and c.casts > 0 then
        GameTooltip:AddDoubleLine("This fight",
            string.format("%d / %d dry", c.dry, c.casts), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if row.kind == "blast" and DB.opts.pauseWhenBlind
       and DetectionLive and not DetectionLive(row.kind) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Clearcasting cannot be seen right now, so casts are", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("not being counted rather than guessed at.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click the window for settings.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local ShowOptions   -- defined with the options panel below

-- exposed so the settings panel and the test harness can force a redraw
UpdateDisplayPublic = UpdateDisplay
ApplyLayoutPublic = nil          -- assigned once ApplyLayout exists

-- Everything about the frame's size and chrome is settings-driven, so the layout
-- is recomputed rather than hard-coded.
local function SavePosition()
    local point, _, _, x, y = frame:GetPoint()
    DB.ui.point, DB.ui.x, DB.ui.y = point, x, y
end

local function StartFrameDrag()
    if not DB.ui.locked then frame:StartMoving() end
end

local function StopFrameDrag()
    frame:StopMovingOrSizing()
    SavePosition()
end

local function SetFontSize(fontString, size)
    if not fontString or not fontString.GetFont then return end
    local path, _, flags = fontString:GetFont()
    if path then pcall(fontString.SetFont, fontString, path, size, flags) end
end

local function ActiveRows()
    local list = { rows[1], rows[2] }
    if DB.opts.showPB then table.insert(list, rows[3]) end
    return list
end

local function ApplyLayout()
    if not frame or not rows then return end

    local pad   = 5
    local icon  = DB.ui.iconSize
    local rowH  = icon + 4
    local top   = pad

    if DB.ui.showTitle then
        SetFontSize(frame.title, DB.ui.titleSize)
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOP", frame, "TOP", 0, -pad)
        frame.title:Show()
        top = pad + DB.ui.titleSize + 4
    else
        frame.title:Hide()
    end

    -- hide everything first, then lay out only the rows that are switched on
    for _, row in ipairs(rows) do
        row.icon:Hide(); row.main:Hide(); row.hover:Hide()
        if row.rate then row.rate:Hide() end
        if row.reset then row.reset:Hide() end
    end

    local active = ActiveRows()
    for i, row in ipairs(active) do
        local y = -(top + (i - 1) * rowH)

        row.icon:Show(); row.main:Show(); row.hover:Show()
        row.icon:SetSize(icon, icon)
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", pad + 2, y)

        SetFontSize(row.main, DB.ui.textSize)

        row.main:ClearAllPoints()
        row.main:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)

        if row.rate then
            SetFontSize(row.rate, DB.ui.textSize - 1)
            row.rate:ClearAllPoints()
            row.rate:SetPoint("RIGHT", frame, "RIGHT", -(pad + 3), 0)
            row.rate:SetPoint("TOP", row.icon, "TOP", 0, -math.floor(icon / 2 - DB.ui.textSize / 2) - 1)
        end

        if row.reset then
            row.reset:SetFrameLevel(row.hover:GetFrameLevel() + 5)
            row.reset:ClearAllPoints()
            row.reset:SetPoint("RIGHT", frame, "RIGHT", -(pad + 2), 0)
            row.reset:SetPoint("TOP", row.icon, "TOP", 0, -math.floor(icon / 2 - 8))
            row.reset:SetSize(48, 18)
        end

        row.hover:ClearAllPoints()
        row.hover:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, y + 2)
        row.hover:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, y + 2)
        row.hover:SetHeight(rowH)
    end

    frame:SetWidth(DB.ui.width)
    frame:SetHeight(top + #active * rowH + pad - 2)

    local alpha = DB.ui.showBackground and DB.ui.bgAlpha or 0
    frame:SetBackdropColor(0, 0, 0, alpha)
    if DB.ui.showBorder then
        local c = DB.colors.title
        frame:SetBackdropBorderColor(c.r, c.g, c.b, 0.8)
    else
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

ApplyLayoutPublic = ApplyLayout

local function BuildRow(parent, kind, spellID, label, tip)
    local row = { kind = kind, label = label, tip = tip }

    row.icon = parent:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(SpellTexture(spellID))
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.main = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.main:SetJustifyH("LEFT")

    row.rate = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.rate:SetJustifyH("RIGHT")

    -- One hit area covering exactly this row, so the tooltip has a sane anchor.
    -- It also has to forward dragging, otherwise the rows would swallow it and
    -- with the title hidden there would be nothing left to grab.
    row.hover = CreateFrame("Frame", nil, parent)
    row.hover:EnableMouse(true)
    row.hover:RegisterForDrag("LeftButton")
    row.hover:SetScript("OnEnter", function() RowTooltip(row) end)
    row.hover:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row.hover:SetScript("OnDragStart", StartFrameDrag)
    row.hover:SetScript("OnDragStop", StopFrameDrag)
    row.hover:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and ShowOptions then ShowOptions() end
    end)

    return row
end

-- Third row: a plain tally of Prismatic Bolts you actually cast this fight.
-- No procs involved, so no rate column - a small RESET button sits there instead.
local function BuildPBRow(parent)
    local row = { kind = "pb", label = L.PB_LABEL,
                  tip = "Prismatic Bolts cast since the fight started." }

    row.icon = parent:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(SpellTexture(ID.pbCast) or SpellTexture(ID.pbAura)
                        or "Interface\\Icons\\Spell_Arcane_Blast")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.main = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.main:SetJustifyH("LEFT")

    row.reset = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    row.reset:SetText("RESET")
    row.reset:SetScript("OnClick", function()
        -- the same thing /adt reset does: every counter, not just this tally
        if ResetStatsPublic then ResetStatsPublic() end
    end)
    row.reset:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Reset everything")
        GameTooltip:AddLine("Clears both strike counters, the totals, the fight history "
            .. "and this tally - the same as /adt reset.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row.reset:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    row.hover = CreateFrame("Frame", nil, parent)
    row.hover:EnableMouse(true)
    row.hover:RegisterForDrag("LeftButton")
    row.hover:SetScript("OnEnter", function() RowTooltip(row) end)
    row.hover:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row.hover:SetScript("OnDragStart", StartFrameDrag)
    row.hover:SetScript("OnDragStop", StopFrameDrag)
    row.hover:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and ShowOptions then ShowOptions() end
    end)

    -- The hover strip is created after the button and covers the whole row, so
    -- by default it sits on top and eats the click. Lift the button above it.
    row.reset:SetFrameLevel(row.hover:GetFrameLevel() + 5)
    row.reset:SetToplevel(true)

    return row
end

local function CreateUI()
    frame = CreateFrame("Frame", "ArcaneDespairTrackerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(DB.ui.width, 80)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0, 0, 0, 0.65)
    frame:SetBackdropBorderColor(0.53, 0.47, 1, 0.8)

    frame:SetScript("OnDragStart", StartFrameDrag)
    frame:SetScript("OnDragStop", StopFrameDrag)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and ShowOptions then ShowOptions() end
    end)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetJustifyH("CENTER")
    frame.title:SetText(Hex(DB.colors.title) .. "Arcane Despair Tracker|r")

    rows = {
        BuildRow(frame, "blast", ID.blast, L.BLAST_LABEL,
            "Arcane Blasts cast in a row without proccing Clearcasting."),
        BuildRow(frame, "barrage", ID.barrage, L.BARRAGE_LABEL,
            "Arcane Barrages cast in a row without proccing Prismatic Bolt."),
        BuildPBRow(frame),
    }

    frame.rows = rows        -- handy for /adt debug and for the test harness

    frame:SetScale(DB.ui.scale)
    frame:ClearAllPoints()
    frame:SetPoint(DB.ui.point, UIParent, DB.ui.point, DB.ui.x, DB.ui.y)

    ApplyLayout()
    CreateShameFrames()
end

----------------------------------------------------------------------
-- Options panel
----------------------------------------------------------------------
local options

local function MakeCheck(parent, label, tooltip, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
    cb.refresh = function() cb:SetChecked(get() and true or false) end
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        UpdateDisplay()
        if options and options.refresh then options.refresh() end
    end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(label)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    return cb
end

local function MakeSlider(parent, label, x, y, minV, maxV, step, get, set, fmt)
    local sl = CreateFrame("Slider", "ADTSlider" .. label:gsub("%s", ""), parent, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y)
    sl:SetWidth(150)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    local caption = sl:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    caption:SetPoint("BOTTOMLEFT", sl, "TOPLEFT", 0, 2)
    sl.caption = caption
    local captionFmt = fmt or (label .. ": %d")
    sl.refresh = function()
        local v = get()
        sl:SetValue(v)
        caption:SetText(string.format(captionFmt, v))
    end
    sl:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 100 + 0.5) / 100
        if step >= 1 then value = math.floor(value + 0.5) end
        set(value)
        caption:SetText(string.format(captionFmt, value))
        UpdateDisplay()
    end)
    -- OptionsSliderTemplate ships Low/High/Text labels we do not want
    for _, key in ipairs({ "Low", "High", "Text" }) do
        local child = sl[key] or _G[(sl:GetName() or "") .. key]
        if type(child) == "table" and type(child.SetText) == "function" then
            pcall(child.SetText, child, "")
        end
    end
    return sl
end

local function MakeButton(parent, label, x, y, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetSize(width or 110, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeEditBox(parent, x, y, width, get, set)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y)
    eb:SetSize(width, 20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(200)
    eb.refresh = function() eb:SetText(get() or "") end
    local function commit(self)
        set((self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        self:ClearFocus()
    end
    eb:SetScript("OnEnterPressed", commit)
    eb:SetScript("OnEditFocusLost", commit)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); eb.refresh() end)
    return eb
end

local function MakeColorSwatch(parent, label, x, y, key)
    local sw = CreateFrame("Button", nil, parent)
    sw:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    sw:SetSize(18, 18)

    local border = sw:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(sw)
    border:SetColorTexture(0, 0, 0, 1)

    local fill = sw:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", sw, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -1, 1)

    local text = sw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", sw, "RIGHT", 6, 0)
    text:SetText(label)

    sw.refresh = function()
        local c = DB.colors[key] or { r = 1, g = 1, b = 1 }
        fill:SetColorTexture(c.r, c.g, c.b, 1)
    end

    local function apply(r, g, b)
        DB.colors[key] = { r = r, g = g, b = b }
        sw.refresh()
        UpdateDisplay()
        if frame and frame.title then
            frame.title:SetText(Hex(DB.colors.title) .. "Arcane Despair Tracker|r")
        end
    end

    sw:SetScript("OnClick", function()
        local c = DB.colors[key]
        local pr, pg, pb = c.r, c.g, c.b       -- snapshot for cancel
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = pr, g = pg, b = pb, hasOpacity = false,
                swatchFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    if r then apply(r, g, b) end
                end,
                cancelFunc = function() apply(pr, pg, pb) end,
            })
        else
            Print("this client has no colour picker frame available")
        end
    end)

    return sw
end

-- One block per despair stage: the face, what strike it starts at, how big it
-- gets there, buttons to see and hear it, and a box for your own .ogg. Leave the
-- box empty and the stage uses its own sound.
local function MakeTierBlock(parent, i, x, y, kindOf)
    local block = { }

    local line = CreateFrame("Frame", nil, parent)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    line:SetSize(280, 20)
    line:EnableMouse(true)

    local icon = line:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", line, "LEFT", 0, 0)
    icon:SetTexture(MEDIA .. TIERS[kindOf()][i].face)

    local text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetJustifyH("LEFT")

    local play = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    play:SetSize(38, 17)
    play:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    play:SetText("Hear")
    play:SetScript("OnClick", function() PlayShameSound(kindOf(), i) end)

    local show = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    show:SetSize(38, 17)
    show:SetPoint("RIGHT", play, "LEFT", -3, 0)
    show:SetText("See")
    show:SetScript("OnClick", function() PreviewTier(kindOf(), i) end)

    line:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local set = TIERS[kindOf()][i]
        GameTooltip:AddLine(string.format("Stage %d - %s", i, set.label))
        GameTooltip:AddLine("Its own sound is " .. set.sound, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, y - 20)
    box:SetSize(268, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(220)

    -- Blizzard's edit boxes have no placeholder, so this grey line sits inside
    -- the empty box and shows what the stage is falling back to.
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", box, "LEFT", 2, 0)
    hint:SetJustifyH("LEFT")
    local function stored()
        local files = Shame(kindOf()).soundFiles
        return (files and files[tostring(i)]) or ""
    end

    local function syncHint()
        hint:SetShown(stored() == "" and not box:HasFocus())
    end

    local function commit(self)
        local v = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        Shame(kindOf()).soundFiles[tostring(i)] = (v ~= "") and v or nil
        self:ClearFocus()
        syncHint()
    end

    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", commit)
    box:SetScript("OnEditFocusGained", function() hint:Hide() end)
    box:SetScript("OnTextChanged", syncHint)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(stored()); self:ClearFocus(); syncHint()
    end)
    box:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Sound for stage " .. i)
        GameTooltip:AddLine("Leave it empty to use this stage's own sound. Type |cffffffffnone|r "
            .. "to silence just this stage.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Shipped files, all under " .. MEDIA, 0.6, 0.6, 0.6, true)
        for _, entry in ipairs(SOUNDS) do
            if entry.file then
                GameTooltip:AddLine("   " .. entry.file:match("[^\\]+$"), 0.55, 0.55, 0.6)
            end
        end
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    block.refresh = function()
        local kind = kindOf()
        local cfg  = Shame(kind)
        local step = math.max(1, cfg.step)
        local strike = cfg.at + (i - 1) * step
        local size = math.min(cfg.size + (strike - cfg.at) * cfg.growth, cfg.maxSize)
        icon:SetTexture(MEDIA .. TIERS[kind][i].face)
        text:SetText(string.format("|cffffd100%d|r  %dpx", strike, size))
        hint:SetText("default: " .. TIERS[kind][i].sound)
        if not box:HasFocus() then box:SetText(stored()) end
        syncHint()
    end

    return block
end

local function CreateOptions()
    options = CreateFrame("Frame", "ArcaneDespairTrackerOptions", UIParent, "BackdropTemplate")
    options:SetSize(740, 846)
    options:SetPoint("CENTER")
    options:SetClampedToScreen(true)
    options:SetMovable(true)
    options:EnableMouse(true)
    options:RegisterForDrag("LeftButton")
    options:SetScript("OnDragStart", options.StartMoving)
    options:SetScript("OnDragStop", options.StopMovingOrSizing)
    options:SetFrameStrata("DIALOG")
    options:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    options:SetBackdropColor(0.04, 0.03, 0.06, 0.95)
    options:SetBackdropBorderColor(0.53, 0.47, 1, 0.9)
    options:Hide()

    -- a tall panel on a short screen would run off the bottom
    local screen = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 1080
    if screen and screen < 860 then options:SetScale(0.78) end

    local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", options, "TOP", 0, -12)
    title:SetText("|cff9d8cffArcane Despair Tracker|r")

    local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() options:Hide() end)

    local widgets = {}
    local function add(w) table.insert(widgets, w) return w end

    local function header(text, x, y)
        local fs = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", options, "TOPLEFT", x, y)
        fs:SetText("|cffffd100" .. text .. "|r")
    end

    local L1, L2, L3 = 16, 226, 440      -- three columns

    ------------------------------------------------ left: display
    header("Display", L1, -42)
    add(MakeCheck(options, "Show the window", nil, L1, -62,
        function() return DB.ui.shown end,
        function(v) DB.ui.shown = v; if not v and frame then frame:Hide() end end))
    add(MakeCheck(options, "Lock window and clown", "Stops left-drag from moving either one.", L1, -86,
        function() return DB.ui.locked end, function(v) DB.ui.locked = v end))
    add(MakeCheck(options, "Only in Arcane spec", nil, L1, -110,
        function() return DB.opts.onlyArcane end, function(v) DB.opts.onlyArcane = v end))
    add(MakeCheck(options, "Show proc rate", "The 'proc 21.8%' column on each row.", L1, -134,
        function() return DB.opts.showRate end, function(v) DB.opts.showRate = v end))

    ------------------------------------------------ left: appearance
    header("Appearance", L1, -164)
    add(MakeCheck(options, "Title bar", nil, L1, -184,
        function() return DB.ui.showTitle end,
        function(v) DB.ui.showTitle = v; ApplyLayout() end))
    add(MakeCheck(options, "Background", "Turn it off for a bare, frameless readout.", L1, -208,
        function() return DB.ui.showBackground end,
        function(v) DB.ui.showBackground = v; ApplyLayout() end))
    add(MakeCheck(options, "Border", nil, L1, -232,
        function() return DB.ui.showBorder end,
        function(v) DB.ui.showBorder = v; ApplyLayout() end))
    add(MakeSlider(options, "Background opacity", L1, -276, 0, 1, 0.05,
        function() return DB.ui.bgAlpha end,
        function(v) DB.ui.bgAlpha = v; ApplyLayout() end,
        "Background opacity: %.2f"))
    add(MakeSlider(options, "Width", L1, -316, 140, 420, 2,
        function() return DB.ui.width end,
        function(v) DB.ui.width = v; ApplyLayout() end,
        "Width: %d px"))
    add(MakeSlider(options, "Icon size", L1, -356, 12, 40, 1,
        function() return DB.ui.iconSize end,
        function(v) DB.ui.iconSize = v; ApplyLayout() end,
        "Icon size: %d px"))
    add(MakeSlider(options, "Text size", L1, -396, 8, 22, 1,
        function() return DB.ui.textSize end,
        function(v) DB.ui.textSize = v; ApplyLayout() end,
        "Text size: %d"))
    add(MakeSlider(options, "Title size", L1, -436, 8, 22, 1,
        function() return DB.ui.titleSize end,
        function(v) DB.ui.titleSize = v; ApplyLayout() end,
        "Title size: %d"))
    add(MakeSlider(options, "Window scale", L1, -476, 0.5, 2.0, 0.05,
        function() return DB.ui.scale end,
        function(v) DB.ui.scale = v; if frame then frame:SetScale(v) end end,
        "Window scale: %.2f"))

    ------------------------------------------------ left: counting
    header("Counting", L1, -504)
    add(MakeCheck(options, "Pause Blast when procs hidden",
        "Blizzard hides your buffs in combat. When a Clearcasting cannot be seen, the Arcane Blast cast is "
        .. "not counted at all instead of being guessed at - the '?' means counting is paused. "
        .. "Arcane Barrage always counts.", L1, -524,
        function() return DB.opts.pauseWhenBlind end, function(v) DB.opts.pauseWhenBlind = v end))
    add(MakeCheck(options, "Prismatic Bolt counts as Blast", nil, L1, -548,
        function() return DB.opts.countPrismatic end, function(v) DB.opts.countPrismatic = v end))
    add(MakeCheck(options, "Fight summary in chat", nil, L1, -572,
        function() return DB.opts.reportCombat end, function(v) DB.opts.reportCombat = v end))
    add(MakeCheck(options, "Reset everything each fight",
        "Every counter starts from zero when a new fight begins - both strikes, the totals, "
        .. "the proc rates and the Prismatic Bolt tally. Turn it off to keep running totals "
        .. "across a whole session.", L1, -596,
        function() return DB.opts.resetOnFight end, function(v) DB.opts.resetOnFight = v end))
    add(MakeCheck(options, "Skip Barrages in Arcane Soul",
        "Skips only the 4s Arcane Soul window itself. The 17.4s wait between casting Arcane "
        .. "Surge and Soul landing is ordinary play and keeps counting. Those casts can still "
        .. "proc - Arcane Salvo keeps building to 25 either way - so this is a matter of "
        .. "taste, not accuracy, and it is off by default.", L1, -620,
        function() return DB.opts.soulPause end, function(v) DB.opts.soulPause = v end))
    add(MakeSlider(options, "Soul lands after", L1, -664, 0, 30, 0.1,
        function() return DB.opts.soulDelay end,
        function(v) DB.opts.soulDelay = v end,
        "Wait after Surge: %.1fs"))
    add(MakeSlider(options, "Soul lasts", L1, -704, 1, 15, 0.5,
        function() return DB.opts.soulDuration end,
        function(v) DB.opts.soulDuration = v end,
        "Skipped window: %.1fs"))
    add(MakeSlider(options, "Alert at strike", L1, -744, 0, 30, 1,
        function() return DB.opts.alertThreshold end,
        function(v) DB.opts.alertThreshold = v end,
        "Alert at strike: %d  (0 = off)"))

    add(MakeButton(options, "Reset statistics", L1, -772, 130, function()
        if ResetStatsPublic then ResetStatsPublic() end
    end))
    add(MakeButton(options, "Diagnostics", L1, -798, 130, function()
        if ShowStatusPublic then ShowStatusPublic() end
    end))
    add(MakeButton(options, "Fight history", L1 + 138, -772, 130, function()
        if ShowHistoryPublic then ShowHistoryPublic() end
    end))

    ------------------------------------------------ right: faces, per counter
    local shameKind = "blast"
    local function kindOf() return shameKind end

    header("Faces", L2, -42)
    local kindBtn = add(MakeButton(options, "", L2, -62, 196, function()
        shameKind = (shameKind == "blast") and "barrage" or "blast"
        if options.refresh then options.refresh() end
    end))
    kindBtn.refresh = function()
        kindBtn:SetText("Editing: " .. KIND_LABEL[shameKind])
    end
    kindBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Which counter these settings apply to")
        GameTooltip:AddLine("Arcane Blast and Arcane Barrage each have their own faces, "
            .. "thresholds, sizes, sounds and screen position. Click to switch.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    kindBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    add(MakeCheck(options, "Enable the faces", nil, L2, -88,
        function() return Shame(kindOf()).enabled end,
        function(v) Shame(kindOf()).enabled = v; UpdateShameAll() end))
    add(MakeSlider(options, "Appears at strike", L2, -132, 2, 40, 1,
        function() return Shame(kindOf()).at end,
        function(v) Shame(kindOf()).at = v; UpdateShameAll() end,
        "Appears at strike: %d"))
    add(MakeSlider(options, "Despair step", L2, -172, 1, 10, 1,
        function() return Shame(kindOf()).step end,
        function(v) Shame(kindOf()).step = v; UpdateShameAll() end,
        "Next face every %d casts"))
    add(MakeSlider(options, "Base size", L2, -212, 24, 200, 4,
        function() return Shame(kindOf()).size end,
        function(v) Shame(kindOf()).size = v; UpdateShameAll() end,
        "Base size: %d px"))
    add(MakeSlider(options, "Growth per cast", L2, -252, 0, 40, 1,
        function() return Shame(kindOf()).growth end,
        function(v) Shame(kindOf()).growth = v; UpdateShameAll() end,
        "Growth per cast: %d px"))
    add(MakeSlider(options, "Hide after", L2, -292, 0, 30, 1,
        function() return Shame(kindOf()).timeout end,
        function(v) Shame(kindOf()).timeout = v; UpdateShameAll() end,
        "Hide %d s after the last cast"))

    local placeBtn = add(MakeButton(options, "", L2, -316, 110, function()
        placingKind = (placingKind == kindOf()) and nil or kindOf()
        UpdateShameAll()
        if options.refresh then options.refresh() end
    end))
    placeBtn.refresh = function()
        placeBtn:SetText(placingKind == kindOf() and "Done placing" or "Place face")
    end
    add(MakeButton(options, "Re-centre", L2 + 116, -316, 84, function()
        local cfg = Shame(kindOf())
        cfg.point, cfg.x, cfg.y = "CENTER", 0, 0
        local f = shameFrames[kindOf()]
        if f then
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end))

    ------------------------------------------------ right: sound
    header("Sound", L2, -352)
    add(MakeCheck(options, "Play a sound", nil, L2, -372,
        function() return Shame(kindOf()).soundEnabled end,
        function(v) Shame(kindOf()).soundEnabled = v end))
    add(MakeSlider(options, "Sound every N casts", L2, -416, 1, 10, 1,
        function() return Shame(kindOf()).every end,
        function(v) Shame(kindOf()).every = v end,
        "Sound every %d casts"))
    add(MakeSlider(options, "At the last stage", L2, -456, 1, 10, 1,
        function() return Shame(kindOf()).everyFinal end,
        function(v) Shame(kindOf()).everyFinal = v end,
        "At the last stage: every %d"))

    local channelBtn = add(MakeButton(options, "", L2, -480, 130, function()
        local idx = 1
        for n, name in ipairs(SOUND_CHANNELS) do
            if name == DB.opts.soundChannel then idx = n break end
        end
        DB.opts.soundChannel = SOUND_CHANNELS[(idx % #SOUND_CHANNELS) + 1]
        if options.refresh then options.refresh() end
        PlayShameSound(kindOf(), 1)
    end))
    channelBtn.refresh = function()
        channelBtn:SetText("Channel: " .. (DB.opts.soundChannel or "Master"))
    end
    channelBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Sound channel")
        GameTooltip:AddLine("Which volume slider in the game's audio settings controls these "
            .. "sounds. Shared by both counters.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    channelBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    add(MakeButton(options, "Test", L2 + 136, -480, 64, function()
        PlayShameSound(kindOf(), 1)
    end))

    ------------------------------------------------ far right: stage preview
    local stagesHeader = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    stagesHeader:SetPoint("TOPLEFT", options, "TOPLEFT", L3, -42)
    stagesHeader.refresh = function()
        stagesHeader:SetText("|cffffd100Despair stages - " .. KIND_LABEL[shameKind] .. "|r")
    end
    add(stagesHeader)

    local hint = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", options, "TOPLEFT", L3, -60)
    hint:SetText("strike / size on screen")
    for i = 1, #TIERS.blast do
        add(MakeTierBlock(options, i, L3, -78 - (i - 1) * 42, kindOf))
    end
    add(MakeButton(options, "Preview them all", L3, -292, 160, function()
        local kind = kindOf()
        for i = 1, #TIERS[kind] do
            local stage = i
            C_Timer.After((stage - 1) * PREVIEW_STEP, function()
                PreviewTier(kind, stage, PREVIEW_HOLD)
                if Shame(kind).soundEnabled then PlayShameSound(kind, stage) end
            end)
        end
    end))

    ------------------------------------------------ far right: the PB row
    header("Prismatic Bolt row", L3, -324)
    add(MakeCheck(options, "Show the cast counter", "A third row tallying Prismatic Bolts cast this fight.", L3, -344,
        function() return DB.opts.showPB end,
        function(v) DB.opts.showPB = v; ApplyLayout(); UpdateDisplay() end))
    add(MakeCheck(options, "Show its RESET button", nil, L3, -368,
        function() return DB.opts.showPBReset end,
        function(v) DB.opts.showPBReset = v; ApplyLayout(); UpdateDisplay() end))
    ------------------------------------------------ far right: colours
    header("Colours", L3, -402)
    local swatches = {
        { "Strike, calm",        "calm"  },
        { "Strike, warning",     "warn"  },
        { "Strike, clown level", "clown" },
        { "Strike, alert",       "alert" },
        { "The \"?\" marker",    "mark"  },
        { "Window title",        "title" },
    }
    for i, entry in ipairs(swatches) do
        add(MakeColorSwatch(options, entry[1], L3, -422 - (i - 1) * 22, entry[2]))
    end

    options:SetHeight(846)

    options.refresh = function()
        for _, w in ipairs(widgets) do
            if w.refresh then w.refresh() end
        end
    end
end

----------------------------------------------------------------------
-- Fight history window
----------------------------------------------------------------------
local historyFrame

local HIST_COLS = { idx = 10, when = 34, dur = 104, blast = 158, barrage = 272, pb = 396 }

local function Ago(stamp)
    if not stamp then return "-" end
    local secs = time() - stamp
    if secs < 60 then return "just now" end
    if secs < 3600 then return string.format("%dm ago", math.floor(secs / 60)) end
    if secs < 86400 then return string.format("%dh ago", math.floor(secs / 3600)) end
    return string.format("%dd ago", math.floor(secs / 86400))
end

local function CreateHistoryWindow()
    historyFrame = CreateFrame("Frame", "ArcaneDespairTrackerHistory", UIParent, "BackdropTemplate")
    historyFrame:SetSize(440, 452)
    historyFrame:SetPoint("CENTER", UIParent, "CENTER", 120, 0)
    historyFrame:SetClampedToScreen(true)
    historyFrame:SetMovable(true)
    historyFrame:EnableMouse(true)
    historyFrame:RegisterForDrag("LeftButton")
    historyFrame:SetScript("OnDragStart", historyFrame.StartMoving)
    historyFrame:SetScript("OnDragStop", historyFrame.StopMovingOrSizing)
    historyFrame:SetFrameStrata("DIALOG")
    historyFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    historyFrame:SetBackdropColor(0.04, 0.03, 0.06, 0.95)
    historyFrame:SetBackdropBorderColor(0.53, 0.47, 1, 0.9)
    historyFrame:Hide()

    local title = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", historyFrame, "TOP", 0, -12)
    title:SetText("|cff9d8cffFight history|r")

    local close = CreateFrame("Button", nil, historyFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() historyFrame:Hide() end)

    local function heading(text, x)
        local fs = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", x, -40)
        fs:SetText("|cffffd100" .. text .. "|r")
        return fs
    end
    heading("#",       HIST_COLS.idx)
    heading("When",    HIST_COLS.when)
    heading("Length",  HIST_COLS.dur)
    heading("Blast dry", HIST_COLS.blast)
    heading("Barrage dry", HIST_COLS.barrage)
    heading("Bolts",   HIST_COLS.pb)

    local rule = historyFrame:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.4, 0.38, 0.5, 0.5)
    rule:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 8, -56)
    rule:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -8, -56)
    rule:SetHeight(1)

    historyFrame.lines = {}
    for i = 1, 20 do
        local line = {}
        local y = -62 - (i - 1) * 18
        for _, key in ipairs({ "idx", "when", "dur", "blast", "barrage", "pb" }) do
            local fs = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", HIST_COLS[key], y)
            fs:SetJustifyH("LEFT")
            line[key] = fs
        end
        historyFrame.lines[i] = line
    end

    historyFrame.empty = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    historyFrame.empty:SetPoint("TOP", historyFrame, "TOP", 0, -110)
    historyFrame.empty:SetText("No fights recorded yet.")

    local clear = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
    clear:SetPoint("BOTTOMLEFT", historyFrame, "BOTTOMLEFT", 12, 12)
    clear:SetSize(120, 22)
    clear:SetText("Clear history")
    clear:SetScript("OnClick", function()
        wipe(DB.history)
        historyFrame.refresh()
    end)

    local note = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMRIGHT", historyFrame, "BOTTOMRIGHT", -12, 18)
    note:SetText("the last 20 fights, newest first")

    historyFrame.refresh = function()
        local n = #DB.history
        historyFrame.empty:SetShown(n == 0)
        for i, line in ipairs(historyFrame.lines) do
            local f = DB.history[i]
            if not f then
                for _, fs in pairs(line) do fs:SetText("") end
            else
                local b, r = f.blast, f.barrage
                line.idx:SetText("|cff808080" .. i .. "|r")
                line.when:SetText(Ago(f.time))
                line.dur:SetText(FormatDuration(f.dur))
                line.blast:SetText(string.format("%s%d|r / %d   %s",
                    Hex(DB.colors.alert), b.dry, b.casts, FormatPct(b.procs, b.casts)))
                line.barrage:SetText(string.format("%s%d|r / %d   %s",
                    Hex(DB.colors.alert), r.dry, r.casts, FormatPct(r.procs, r.casts)))
                line.pb:SetText(tostring(f.pb or "-"))
            end
        end
    end
end

local function ShowHistoryWindow()
    if not historyFrame then
        local ok, err = pcall(CreateHistoryWindow)
        if not ok or not historyFrame then
            Print("could not build the history window: %s", tostring(err))
            historyFrame = nil
            return
        end
    end
    historyFrame.refresh()
    if historyFrame:IsShown() then historyFrame:Hide() else historyFrame:Show() end
end
ShowHistoryPublic = ShowHistoryWindow

ShowOptions = function()
    if not options then
        -- If a Blizzard template ever goes missing, say so instead of erroring.
        local ok, err = pcall(CreateOptions)
        if not ok or not options then
            Print("could not build the settings panel: %s", tostring(err))
            Print("all settings are still available as commands - see |cffffff00/adt help|r")
            options = nil
            return
        end
    end
    options.refresh()
    if options:IsShown() then options:Hide() else options:Show() end
end

----------------------------------------------------------------------
-- Alert
----------------------------------------------------------------------
-- The clown is visual, this is the audible half: starts at the clown threshold
-- and repeats every N casts while the strike keeps growing.
local function ShameCheck(kind, streak)
    local cfg = Shame(kind)
    if not cfg.soundEnabled then return end
    local at = cfg.at
    if at <= 0 or streak < at then return end

    local tier  = TierFor(kind, streak)
    local every = math.max(1, cfg.every or 1)
    if tier >= #TIERS[kind] then
        -- the bottom of the pit repeats forever, so it gets its own cadence
        every = math.max(1, cfg.everyFinal or every)
    end
    if (streak - at) % every ~= 0 then return end

    local key = (shameRun[kind] or 0) .. ":" .. streak
    if shameLastKey[kind] == key then return end
    shameLastKey[kind] = key
    PlayShameSound(kind, tier)
end

local function FireAlert(kind, streak)
    local threshold = DB.opts.alertThreshold
    if threshold <= 0 or streak < threshold then return end
    if streak % threshold ~= 0 then return end

    local text = string.format("%s: %d", (kind == "blast") and L.BLAST_LABEL or L.BARRAGE_LABEL, streak)
    if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1.0, 0.3, 0.3, 1.0) end
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
end

----------------------------------------------------------------------
-- Counting
----------------------------------------------------------------------
local function Trackers(kind)
    return { DB.total[kind], combatStats[kind] }
end

local function PruneCredits(kind)
    local ttl, now = CREDIT_TTL[kind], GetTime()
    local list = credits[kind]
    for i = #list, 1, -1 do
        if now - list[i] > ttl then table.remove(list, i) end
    end
end

-- The proc resource is visibly gone, so no counted-but-unconsumed proc can still
-- be outstanding. Delayed, because the consuming cast and the buff vanishing
-- arrive in the same instant and either one can be first.
local function ExpireCredits(kind, stillGone)
    C_Timer.After(0.5, function()
        if stillGone() and #credits[kind] > 0 then
            Debug("%s proc resource gone, dropping %d stale credit(s)", kind, #credits[kind])
            wipe(credits[kind])
        end
    end)
end

-- The cast we already booked as dry turned out to have procced.
-- A proc wipes the slate: the face goes away at once and the escalation starts
-- from stage one next time, rather than picking up where it left off.
local function ResetShame(kind)
    shameRun[kind] = (shameRun[kind] or 0) + 1   -- a new run may sound the same strike again
    shameLastKey[kind] = nil
    if UpdateShamePublic then UpdateShamePublic() end
end

local function ConvertLastDryToProc(kind, source)
    local snap = maxSnapshot[kind]
    for i, t in ipairs(Trackers(kind)) do
        if t.dry > 0 then
            t.dry   = t.dry - 1
            t.procs = t.procs + 1
        end
        t.streak = 0
        -- that cast was not dry after all, so it must not hold the record
        if snap and snap[i] and t.maxStreak > snap[i] then t.maxStreak = snap[i] end
    end
    maxSnapshot[kind] = nil
    ResetShame(kind)
    Debug("proc counted for %s (via %s)", kind, source or "?")
    UpdateDisplay()
end

-- `procced` means the aura event beat the cast event to us.
local function RegisterCast(kind, procced)
    if procced then
        maxSnapshot[kind] = nil
    else
        maxSnapshot[kind] = { DB.total[kind].maxStreak, combatStats[kind].maxStreak }
    end

    for _, t in ipairs(Trackers(kind)) do
        t.casts = t.casts + 1
        if procced then
            t.procs  = t.procs + 1
            t.streak = 0
        else
            t.dry    = t.dry + 1
            t.streak = t.streak + 1
            if t.streak > t.maxStreak then t.maxStreak = t.streak end
        end
    end

    if procced then
        pendingCast = nil
        ResetShame(kind)
        Debug("cast booked as PROC: %s", kind)
    else
        FireAlert(kind, DB.total[kind].streak)
        ShameCheck(kind, DB.total[kind].streak)
        Debug("cast booked as dry: %s (streak %d)", kind, DB.total[kind].streak)

        -- This cast now owns the claim on the next proc we see. No timer: the
        -- claim ends when the next cast is made, not after N seconds. Aura data
        -- can go dark and come back, so a wall-clock window would drop procs
        -- that are still unambiguously this cast's.
        pendingCast = { kind = kind }
    end
end

-- Arcane Soul is optional to exclude, not a correctness fix: Arcane Salvo keeps
-- building with every Barrage up to 25 stacks, so those casts are still rolling.
-- Some people would rather judge their luck outside the burst window all the
-- same, so this is here and switched off by default.
--
-- The buff is an aura, so it is secret in combat like everything else. The
-- fallback is the same trick used throughout: casts are visible, and Arcane Soul
-- lands a fixed 17.4s after Arcane Surge and runs for 4s, so the cast alone is
-- enough to place the window exactly.
local function SoulActive()
    if not DB.opts.soulPause then return false end
    local _, status = ReadAura(ID.soulAura)
    if status == "ok" then return true, "aura" end
    local now = GetTime()
    if now >= soulFrom and now < soulTo then return true, "window" end
    return false
end

local function BookCast(kind)
    -- Blast only. If we cannot see a Clearcasting land, the cast tells us nothing
    -- and counting it would inflate the strike. Barrage is deliberately excluded:
    -- Prismatic Bolt is held on purpose while Arcane Salvo builds, and during
    -- Arcane Soul you spam Barrage whether or not a Bolt is already sitting
    -- there, so "the buff is up" is a normal state, not a blind spot worth
    -- pausing for. Better to count those casts than to stop counting for a
    -- whole burst window.
    if kind == "blast" and DB.opts.pauseWhenBlind
       and DetectionLive and not DetectionLive(kind) then
        Debug("cast ignored: %s procs are not observable right now", kind)
        return
    end

    if kind == "barrage" then
        local soul, how = SoulActive()
        if soul then
            Debug("barrage ignored: Arcane Soul is up (via %s), so no Salvo is consumed", how)
            return
        end
    end

    local carried = carry[kind]
    local procced = (carried ~= nil) and (GetTime() - carried) <= BACK_WINDOW
    carry[kind] = nil
    lastBookedKind = kind
    lastCastAt[kind] = GetTime()
    RegisterCast(kind, procced)
end

-- A proc was observed directly: aura gained/stacked, or Arcane Blast overridden.
local function OnProcObserved(kind, source, skipDedupe)
    local now = GetTime()

    -- Several signals describe the same proc (aura gain, usability flip, button
    -- override). Whichever arrives first wins; the rest are the same event.
    -- skipDedupe is for a genuine multi-stack gain seen in one poll.
    if not skipDedupe and (now - (lastGain[kind] or 0)) < SAME_INSTANT then
        Debug("duplicate %s proc signal ignored (via %s)", kind, source or "?")
        return
    end

    lastGain[kind] = now
    PruneCredits(kind)
    table.insert(credits[kind], now)
    while #credits[kind] > MAX_GAIN do table.remove(credits[kind], 1) end

    if pendingCast and pendingCast.kind == kind then
        pendingCast = nil
        ConvertLastDryToProc(kind, source)
    else
        -- No cast of ours is waiting on a proc. Either the cast event has not
        -- reached us yet (carry it forward), or this proc came from some other
        -- spell - a Barrage, a Prismatic Bolt, anything. In that case it is
        -- deliberately ignored: the counter is "Arcane Blasts that did not proc",
        -- so a proc no Arcane Blast earned must not clear the streak.
        carry[kind] = now
        Debug("proc observed with no pending %s cast (via %s) - not attributed", kind, source or "?")
    end
end

-- Can we still see procs the moment they land? If yes, a consumption tells us
-- nothing new and must never be used to attribute a proc to a cast.
-- Can we see a proc land *in the situation we are in right now*? Probed fresh,
-- never cached, because this changes the moment you pull a boss.
--
-- The subtlety that matters: the usability and override detectors only reveal a
-- proc arriving from nothing. Once you already hold a Clearcasting stack,
-- Arcane Missiles is already castable, so a second stack flips nothing. Treating
-- those detectors as "live" unconditionally is what stopped procs from counting
-- when a stack was already up - the consumption fallback was suppressed for a
-- proc that nothing else could ever have seen.
DetectionLive = function(kind)
    if kind == "blast" then
        -- reading the aura is the only way to see a stack go 1 -> 2
        if not AllAuraIDsSecret(CC_AURA_IDS) then return true end
        -- aura is secret: usability covers 0 -> 1 only
        return missilesUsable == false
    end

    if not AllAuraIDsSecret(PB_AURA_IDS) then return true end
    BlastOverride()                     -- refreshes overrideReadable
    return overrideReadable and lastOverride == nil
end

-- A cast that is only possible because a proc existed. Last-resort evidence,
-- used only while every live detector is blind.
local function OnProcConsumed(kind, source)
    PruneCredits(kind)
    local list = credits[kind]
    if #list > 0 then
        table.remove(list, 1)          -- already counted, do not count it twice
        Debug("consumed a proc that was already counted: %s", kind)
        return
    end

    if DetectionLive(kind) then
        -- We were watching and saw no proc land on one of our casts, so this proc
        -- belonged to something else. Guessing here is what used to reset the
        -- streak for procs Arcane Blast never earned.
        Debug("consumed an unseen %s proc, but detection is live - not attributed", kind)
        return
    end

    if kind == "blast" and DB.opts.pauseWhenBlind then
        -- Blast casts made while blind were never counted, so there is nothing
        -- to convert and nothing to guess about.
        Debug("consumed an unseen %s proc while blind, but counting was paused", kind)
        return
    end

    -- Blind. The proc is real but we never saw it land, so the best available
    -- evidence is which of our tracked spells was cast last. If that was not the
    -- spell this counter is about, stay out of it.
    if lastBookedKind ~= kind then
        Debug("consumed an unseen %s proc while blind, but the last tracked cast was %s - not attributed",
            kind, tostring(lastBookedKind))
        return
    end

    Debug("consumed an unseen %s proc while blind (via %s) - attributing it", kind, source or "?")
    ConvertLastDryToProc(kind, source)
end

----------------------------------------------------------------------
-- Aura / override polling
----------------------------------------------------------------------
-- The same proc can live under more than one spell id: Blizzard's Cooldown
-- Manager tracks Clearcasting as 79684 while the player buff answers to 263725.
-- Try them all and take the first that actually reads. "restricted" beats
-- "absent", because being forbidden to look is not the same as nothing there.
local function ReadAuraAny(ids)
    local restricted = false
    for _, id in ipairs(ids) do
        local state, status = ReadAura(id)
        if status == "ok" then return state, "ok", id end
        if status == "restricted" then restricted = true end
    end
    return nil, restricted and "restricted" or "absent", nil
end

local function PollAura(key, ids, kind, source)
    local state, status, hitID = ReadAuraAny(ids)
    local via = hitID and ("aura:" .. hitID) or "aura"

    -- The Cooldown Manager draws the stack count, but measuring in a live client
    -- showed that FontString is itself a Secret Value (item.c3.Applications came
    -- back <SECRET>). ViewerStacks is kept for /adt probe only - if Blizzard ever
    -- unseals it, wiring it back in here is a two-line change.
    if state == nil and status == "restricted"
       and kind == "blast" and missilesUsable == false then
        -- nothing readable, but the proc resource is provably gone
        status, via = "absent", "usable"
    end

    auraStatus[kind] = status

    -- Still restricted with no substitute: freeze what we last knew. Erasing it
    -- would make regaining sight at 3 stacks look like three fresh procs.
    if status == "restricted" then
        if lastAuraSig[key] ~= "restricted" then
            lastAuraSig[key] = "restricted"
            Debug("%s aura restricted and no substitute source - holding last known state", kind)
        end
        return
    end

    local prev = auraState[key]
    local gains = 0

    if state then
        local stacks = state.stacks or 1
        if not prev or not prev.present then
            gains = stacks                                  -- freshly applied
        elseif prev.instance and state.instance and prev.instance ~= state.instance then
            gains = stacks                                  -- reapplied from scratch
        elseif state.stacks and prev.stacks and state.stacks > prev.stacks then
            gains = state.stacks - prev.stacks              -- another stack: another proc
        elseif state.expires and prev.expires and state.expires > prev.expires + REFRESH_EPS then
            -- expirationTime is an absolute timestamp: it stays put while the buff
            -- ticks down, so ANY increase means the aura was reapplied. At 3 of 3
            -- Clearcasting stacks this is the only evidence a proc happened at all.
            gains = 1
        end
        auraState[key] = {
            present  = true,
            instance = state.instance,
            stacks   = state.stacks,
            expires  = state.expires,
        }
    else
        -- "absent" is a real answer; "restricted" only means we cannot see it
        if prev and prev.present and status == "absent" then
            ExpireCredits(kind, function()
                local _, s2 = ReadAuraAny(ids)
                return s2 == "absent"
            end)
        end
        auraState[key] = { present = false }
    end

    if gains > MAX_GAIN then gains = MAX_GAIN end

    -- Log only when the picture actually changed; this runs 4x a second.
    if DB and DB.opts.debug then
        local sig = string.format("%s/%s/%s/%d", status, via, tostring(state and state.stacks), gains)
        if sig ~= lastAuraSig[key] then
            lastAuraSig[key] = sig
            Debug("%s aura via %s -> %s, stacks=%s, gains=%d",
                kind, via, status, tostring(state and state.stacks or "-"), gains)
        end
    end

    for i = 1, gains do OnProcObserved(kind, source, i > 1) end
end

local function PollOverride()
    local override = BlastOverride()
    if override and override ~= lastOverride then
        if not learnedPBCasts[override] then
            learnedPBCasts[override] = true
            DB.learnedPB[tostring(override)] = true
            Debug("learned Prismatic Bolt cast id: %d (%s)", override, SpellName(override))
        end
        if auraStatus.barrage ~= "ok" then
            OnProcObserved("barrage", "override")
        end
    end
    lastOverride = override
end

-- Aura data is a Secret Value during combat, encounters, M+ and rated PvP, so the
-- aura engine can be blind exactly when it matters. Arcane Missiles becoming
-- castable is the same information arriving through a door that stays open.
local function PollMissilesUsable()
    local usable = ReadUsable(ID.missiles)
    if usable == nil then
        missilesUsable = nil        -- unreadable: this detector is blind
        return
    end

    local prev = missilesUsable
    missilesUsable = usable

    if prev == false and usable == true then
        if GetTime() - lastAnyCast <= USABLE_GATE then
            OnProcObserved("blast", "missiles-usable")
        else
            Debug("Arcane Missiles became usable with no recent cast - ignored")
        end
    elseif prev == true and usable == false then
        ExpireCredits("blast", function() return missilesUsable == false end)
    end
end

local function PollAll()
    PollAura("cc", CC_AURA_IDS, "blast",   "clearcasting-aura")
    PollAura("pb", PB_AURA_IDS, "barrage", "prismatic-aura")
    PollMissilesUsable()
    PollOverride()
end

----------------------------------------------------------------------
-- Casts
----------------------------------------------------------------------
local function IsPrismaticCast(spellID)
    return spellID == ID.pbCast or learnedPBCasts[spellID] == true
end

local function IsBlastCast(spellID)
    if spellID == ID.blast then return true end
    if IsPrismaticCast(spellID) then return DB.opts.countPrismatic end
    return false
end

local function OnCast(spellID)
    if type(spellID) ~= "number" or IsSecret(spellID) then
        Debug("cast id unusable (secret or nil)")
        return
    end
    Debug("cast: %d (%s)", spellID, SpellName(spellID))

    if spellID == ID.soulTrigger then
        soulFrom = GetTime() + (DB.opts.soulDelay or 0)
        soulTo   = soulFrom + (DB.opts.soulDuration or 0)
        Debug("Arcane Soul expected in %.1fs, lasting %.1fs",
            DB.opts.soulDelay or 0, DB.opts.soulDuration or 0)
    end

    -- An Arcane cast ends the previous cast's claim on the next proc: without
    -- this, an Arcane Explosion proccing Clearcasting would be credited to the
    -- Arcane Blast before it. Anything that cannot proc Clearcasting at all -
    -- trinkets, potions, racials - leaves the claim standing.
    if CLAIM_BREAKERS[spellID] or learnedPBCasts[spellID] then
        pendingCast = nil
    else
        Debug("cast %d cannot proc Clearcasting - claim left standing", spellID)
    end

    if IsPrismaticCast(spellID) then
        pbCasts = pbCasts + 1
        OnProcConsumed("barrage", "prismatic-bolt-cast")
    elseif spellID == ID.missiles then
        OnProcConsumed("blast", "arcane-missiles-cast")
    end

    if spellID == ID.barrage then BookCast("barrage") end
    if IsBlastCast(spellID)    then BookCast("blast")   end

    UpdateDisplay()
end

----------------------------------------------------------------------
-- Fight tracking (grace period so one dungeon pull is one fight)
----------------------------------------------------------------------
local function TrackerLine(label, t)
    if t.casts == 0 then return string.format("%s: %s", label, L.NO_DATA) end
    return string.format("%s -> casts: %d | procs: %d | |cffff8080no proc: %d|r | longest dry streak: %d | rate: %s",
        label, t.casts, t.procs, t.dry, t.maxStreak, FormatPct(t.procs, t.casts))
end

local function FinalizeFight()
    inFight, fightEndsAt = false, nil

    local b, r = combatStats.blast, combatStats.barrage
    if b.casts == 0 and r.casts == 0 then return end

    table.insert(DB.history, 1, {
        time    = time(),
        dur     = GetTime() - (combatStart or GetTime()),
        pb      = pbCasts,
        blast   = { casts = b.casts, procs = b.procs, dry = b.dry, maxStreak = b.maxStreak },
        barrage = { casts = r.casts, procs = r.procs, dry = r.dry, maxStreak = r.maxStreak },
    })
    while #DB.history > 20 do table.remove(DB.history) end

    if DB.opts.reportCombat then
        Print("%s (%s)", L.FIGHT, FormatDuration(GetTime() - (combatStart or GetTime())))
        print("   " .. TrackerLine(L.BLAST_LABEL, b))
        print("   " .. TrackerLine(L.BARRAGE_LABEL, r))
    end
end

local function OnCombatStart()
    fightEndsAt = nil
    if inFight then return end          -- same pull, just re-engaged
    inFight = true
    ResetCombatStats()
    if DB.opts.resetOnFight and ResetStatsSilent then
        ResetStatsSilent()          -- every counter, not just this fight's
    end
    Debug("fight started")
end

local function OnCombatEnd()
    if not inFight then return end
    local deadline = GetTime() + FIGHT_GRACE
    fightEndsAt = deadline
    C_Timer.After(FIGHT_GRACE + 0.1, function()
        if fightEndsAt ~= deadline then return end   -- combat resumed, or already handled
        if InCombat() then fightEndsAt = nil return end
        FinalizeFight()
    end)
end

----------------------------------------------------------------------
-- Reports
----------------------------------------------------------------------
local function StripColors(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function ReportTotals(channel)
    local b, r = DB.total.blast, DB.total.barrage
    if channel then
        SendChatMessage(StripColors("Arcane Despair Tracker - " .. TrackerLine(L.BLAST_LABEL, b)), channel)
        SendChatMessage(StripColors("Arcane Despair Tracker - " .. TrackerLine(L.BARRAGE_LABEL, r)), channel)
    else
        Print("Totals:")
        print("   " .. TrackerLine(L.BLAST_LABEL, b))
        print("   " .. TrackerLine(L.BARRAGE_LABEL, r))
        print(string.format("   current dry streaks -> Blast: %d, Barrage: %d", b.streak, r.streak))
    end
end

local function ResetStats(silent, keepHistory)
    DB.total.blast, DB.total.barrage = NewTracker(), NewTracker()
    -- The per-fight reset keeps the fight log: a record of past fights that
    -- clears itself every fight would be no record at all.
    if not keepHistory then wipe(DB.history) end
    wipe(credits.blast)
    wipe(credits.barrage)
    wipe(carry)
    pendingCast = nil
    wipe(maxSnapshot)
    for _, kind in ipairs(SHAME_KINDS) do
        shameRun[kind] = (shameRun[kind] or 0) + 1
        shameLastKey[kind] = nil
    end
    pbCasts = 0
    ResetCombatStats()
    UpdateDisplay()
    if not silent then Print("Statistics reset.") end
end
ResetStatsPublic = ResetStats
ResetStatsSilent = function() ResetStats(true, true) end

----------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------
local SECRECY_LEVEL = { [0] = "NeverSecret", [1] = "AlwaysSecret", [2] = "ContextuallySecret" }

local function TryCall(fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, res = pcall(fn, ...)
    if not ok then return "error" end
    return tostring(res)
end

local function AuraSecrecy(spellID)
    if not C_Secrets then return "C_Secrets unavailable" end
    local level = "n/a"
    if type(C_Secrets.GetSpellAuraSecrecy) == "function" then
        local ok, res = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
        if ok then level = SECRECY_LEVEL[res] or tostring(res) end
    end
    return string.format("%s, secret right now: %s", level,
        TryCall(C_Secrets.ShouldSpellAuraBeSecret, spellID))
end

local function ShowStatus()
    Print("diagnostics:")
    print(string.format("   build interface: %s", tostring(select(4, GetBuildInfo()))))
    print(string.format("   spec id: %s (Arcane = %d)", tostring(CurrentSpecID()), ARCANE_SPEC_ID))
    for _, key in ipairs({ "blast", "barrage", "missiles", "ccAura", "pbCast", "pbAura" }) do
        print(string.format("   id.%s = %d (%s)", key, ID[key], SpellName(ID[key])))
    end
    local cc, ccStatus = ReadAura(ID.ccAura)
    local pb, pbStatus = ReadAura(ID.pbAura)
    print(string.format("   Clearcasting aura: %s%s", ccStatus,
        cc and string.format(" (stacks %s)", tostring(cc.stacks)) or ""))
    print(string.format("   Prismatic Bolt aura: %s%s", pbStatus,
        pb and string.format(" (stacks %s)", tostring(pb.stacks)) or ""))
    print(string.format("   Clearcasting secrecy: %s", AuraSecrecy(ID.ccAura)))
    print(string.format("   Prismatic Bolt secrecy: %s", AuraSecrecy(ID.pbAura)))
    if C_Secrets then
        print(string.format("   auras secret globally: %s | secret restrictions: %s",
            TryCall(C_Secrets.ShouldAurasBeSecret), TryCall(C_Secrets.HasSecretRestrictions)))
    end
    print(string.format("   Arcane Missiles usable: %s (this is the aura-free Clearcasting signal)",
        tostring(ReadUsable(ID.missiles))))
    if C_Secrets then
        print(string.format("   cooldowns secret: %s", TryCall(C_Secrets.ShouldCooldownsBeSecret)))
    end
    -- probes: if either of these ever tracks Clearcasting stacks it would close
    -- the one remaining blind spot, so it is worth being able to see them.
    if C_Spell then
        print(string.format("   Missiles cast count: %s | charges: %s",
            TryCall(C_Spell.GetSpellCastCount, ID.missiles),
            TryCall(C_Spell.GetSpellCharges, ID.missiles)))
    end
    print(string.format("   Arcane Blast override: %s", tostring(BlastOverride())))
    local learned = {}
    for id in pairs(learnedPBCasts) do table.insert(learned, id) end
    print(string.format("   learned override cast ids: %s", #learned > 0 and table.concat(learned, ", ") or "none"))
    print(string.format("   Blast detection: %s   (aura readable: %s | stack held: %s)",
        DetectionLive("blast") and "|cff40ff40live|r" or "|cffff8080blind -> falling back to consumption|r",
        tostring(not AuraIsSecretNow(ID.ccAura)), tostring(missilesUsable)))
    print(string.format("   Barrage detection: %s   (aura readable: %s | buff held: %s)",
        DetectionLive("barrage") and "|cff40ff40live|r" or "|cffff8080blind -> falling back to consumption|r",
        tostring(not AuraIsSecretNow(ID.pbAura)), tostring(lastOverride ~= nil)))
    print(string.format("   last tracked cast: %s", tostring(lastBookedKind)))
    local soul, how = SoulActive()
    local now = GetTime()
    local when
    if now < soulFrom then when = string.format("in %.1fs", soulFrom - now)
    elseif now < soulTo then when = string.format("%.1fs left", soulTo - now)
    else when = "not expected" end
    print(string.format("   Arcane Soul: %s%s | %s | aura %s",
        soul and "|cff40ff40active|r" or "no", how and (" (" .. how .. ")") or "",
        when, AuraSecrecy(ID.soulAura)))
    print(string.format("   in fight: %s | chat summary: %s | debug: %s",
        inFight and "yes" or "no",
        DB.opts.reportCombat and "on" or "off",
        DB.opts.debug and "ON" or "off"))
end

-- Walks a frame tree and reports every FontString it finds, shown or not, so we
-- can locate where the Cooldown Manager keeps the stack digit. Shallow scans
-- miss it when the text lives on a nested sub-frame.
local DumpFontStrings
DumpFontStrings = function(frame, path, depth, out)
    if depth > 4 or #out >= 40 then return end
    pcall(function()
        if frame.GetRegions then
            for i, region in ipairs({ frame:GetRegions() }) do
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    local raw = region.GetText and region:GetText()
                    local text = IsSecret(raw) and "<SECRET>" or tostring(raw)
                    if text ~= "nil" and text ~= "" then
                        local shown = (region.IsShown and region:IsShown()) and "" or " [hidden]"
                        table.insert(out, string.format("%s r%d = %q%s", path, i, text, shown))
                    end
                end
            end
        end
        -- named sub-objects are where Blizzard usually puts the count
        for _, key in ipairs(STACK_TEXT_KEYS) do
            local fs = frame[key]
            if fs and fs.GetText then
                local raw = fs:GetText()
                local text = IsSecret(raw) and "<SECRET>" or tostring(raw)
                table.insert(out, string.format("%s.%s = %q", path, key, text))
            end
        end
        if frame.GetChildren then
            for i, child in ipairs({ frame:GetChildren() }) do
                DumpFontStrings(child, path .. ".c" .. i, depth + 1, out)
            end
        end
    end)
end

-- Dumps every avenue for reading a Clearcasting stack count, so one command in
-- the game answers what the documentation does not.
local function ProbeStackSources()
    Print("probing stack-count sources for %s:", SpellName(ID.ccAura))

    print(string.format("   aura read: %s", (select(2, ReadAura(ID.ccAura)))))
    local st = ReadAura(ID.ccAura)
    print(string.format("   aura stacks: %s", tostring(st and st.stacks or "-")))
    print(string.format("   Missiles usable: %s", tostring(ReadUsable(ID.missiles))))

    if C_Spell then
        print(string.format("   GetSpellCastCount(Missiles): %s", TryCall(C_Spell.GetSpellCastCount, ID.missiles)))
        print(string.format("   GetSpellCastCount(Clearcasting): %s", TryCall(C_Spell.GetSpellCastCount, ID.ccAura)))
        print(string.format("   GetSpellCharges(Missiles): %s", TryCall(C_Spell.GetSpellCharges, ID.missiles)))
    end

    if not C_CooldownViewer then
        print("   C_CooldownViewer: not present")
    else
        print(string.format("   viewer available: %s", TryCall(C_CooldownViewer.IsCooldownViewerAvailable)))
        local id = ViewerIDForSpell(ID.ccAura)
        print(string.format("   viewer cooldownID for Clearcasting: %s", tostring(id)))
        if id then
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
            if ok and type(info) == "table" then
                for _, key in ipairs({ "spellID", "buffSlot", "hasAura", "selfAura", "charges", "isKnown", "isInvisible" }) do
                    print(string.format("      info.%s = %s", key, TryCall(function() return info[key] end)))
                end
            end
            local stacks, frameName = ViewerStacks(ID.ccAura)
            print(string.format("   viewer displayed stacks: %s (from %s)", tostring(stacks), tostring(frameName)))

            local item, owner = ViewerItemFor(id)
            if item then
                local out = {}
                DumpFontStrings(item, "item", 1, out)
                print(string.format("   text inside the Clearcasting item (%s):", tostring(owner)))
                if #out == 0 then
                    print("      (no FontStrings found at all)")
                else
                    for _, line in ipairs(out) do print("      " .. line) end
                end
            else
                print("   no viewer item frame matched that cooldownID")
            end
        end
    end

    print(string.format("   aura ids tried: %s", table.concat(CC_AURA_IDS, ", ")))
    for _, id in ipairs(CC_AURA_IDS) do
        local st2, status2 = ReadAura(id)
        print(string.format("      %d (%s): %s, stacks=%s, secretNow=%s", id, SpellName(id), status2,
            tostring(st2 and st2.stacks or "-"), tostring(AuraIsSecretNow(id))))
    end

    -- what frames actually exist, and every number they are showing
    for _, frameName in ipairs(VIEWER_FRAMES) do
        local parent = _G[frameName]
        if not parent then
            print(string.format("   %s: absent", frameName))
        else
            local ok, children = pcall(function() return { parent:GetChildren() } end)
            local numbers, count = {}, 0
            if ok then
                for _, item in ipairs(children) do
                    count = count + 1
                    local n = NumericTextOf(item)
                    if n then table.insert(numbers, tostring(n)) end
                end
            end
            print(string.format("   %s: %d items, numbers shown: %s", frameName, count,
                #numbers > 0 and table.concat(numbers, ",") or "none"))
        end
    end

    print("   |cffffff00Run this with 2 or 3 Clearcasting stacks up, in combat.|r")
end

ShowStatusPublic = ShowStatus

local function ScanBuffs()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
        Print("aura scanning API unavailable.")
        return
    end
    Print("current player buffs:")
    local shown = 0
    for i = 1, 40 do
        local ok, id, name, stacks = pcall(function()
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not a then return nil end
            return a.spellId, a.name, a.applications
        end)
        if not ok then
            print("   |cffff8080aura data is restricted right now|r (try outside an encounter / M+)")
            return
        end
        if not id then break end
        if IsSecret(id) then
            print(string.format("   %d) <secret>", i))
        else
            print(string.format("   %d) %s = %s (stacks %s)", i, tostring(id), tostring(name), tostring(stacks)))
        end
        shown = shown + 1
    end
    if shown == 0 then print("   (none)") end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
local function ShowHelp()
    Print("commands:")
    print("   |cffffff00/adt|r - open the settings panel (or right-click the window)")
    print("   |cffffff00/adt toggle|r - show / hide the counter window")
    print("   |cffffff00/adt stats|r - print totals")
    print("   |cffffff00/adt reset|r - clear all counters and history")
    print("   |cffffff00/adt chat|r - after-fight summary in chat (off by default)")
    print("   |cffffff00/adt report party|r (or raid / say) - send totals to chat")
    print("   |cffffff00/adt history|r - open the fight history window (add |cffffff00chat|r for the text version)")
    print("   |cffffff00/adt lock|r - lock / unlock dragging")
    print("   |cffffff00/adt scale 1.2|r - window scale (0.5 - 2.0)")
    print("   |cffffff00/adt alert 10|r - warn on a dry streak of 10 (0 = off)")
    print("   |cffffff00/adt pb|r - count a Prismatic Bolt cast as an Arcane Blast cast (off by default)")
    print("   |cffffff00/adt anyspec|r - show the window outside Arcane spec")
    print("   |cffffff00/adt status|r - diagnostics: spell ids, aura readability")
    print("   |cffffff00/adt scan|r - list your current buffs with spell ids")
    print("   |cffffff00/adt probe|r - dump every way of reading a Clearcasting stack count")
    print("   |cffffff00/adt debug|r - log every cast and proc to chat")
    print("   |cffffff00/adt setid pbaura 12345|r - patch a spell id (blast, barrage, missiles, ccaura, pbcast, pbaura)")
end

local function ShowHistory()
    if #DB.history == 0 then Print("no fights recorded yet.") return end
    Print("recent fights (newest first):")
    for i, f in ipairs(DB.history) do
        print(string.format("   %d) %s | Blast %d/%d dry | Barrage %d/%d dry",
            i, FormatDuration(f.dur), f.blast.dry, f.blast.casts, f.barrage.dry, f.barrage.casts))
    end
end

local ID_MAP = { blast = "blast", barrage = "barrage", missiles = "missiles",
                 ccaura = "ccAura", pbcast = "pbCast", pbaura = "pbAura",
                 soulaura = "soulAura", soultrigger = "soulTrigger" }

local function HandleCommand(input)
    input = (input or ""):lower()
    local cmd, arg = input:match("^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "config" or cmd == "options" then
        ShowOptions()

    elseif cmd == "toggle" then
        DB.ui.shown = not DB.ui.shown
        UpdateDisplay()
        if not DB.ui.shown and frame then frame:Hide() end

    elseif cmd == "show" then
        DB.ui.shown = true; UpdateDisplay()

    elseif cmd == "hide" then
        DB.ui.shown = false; if frame then frame:Hide() end

    elseif cmd == "reset" then
        ResetStats()

    elseif cmd == "stats" then
        ReportTotals(nil)

    elseif cmd == "report" then
        local channel
        if arg == "party" or arg == "raid" or arg == "say" or arg == "instance_chat" then
            channel = arg:upper()
        end
        ReportTotals(channel)

    elseif cmd == "history" then
        if arg == "chat" then
            ShowHistory()
        elseif ShowHistoryPublic then
            ShowHistoryPublic()
        else
            ShowHistory()
        end

    elseif cmd == "lock" then
        DB.ui.locked = not DB.ui.locked
        Print("dragging: %s", DB.ui.locked and "locked" or "unlocked")

    elseif cmd == "scale" then
        local v = tonumber(arg)
        if v and v >= 0.5 and v <= 2 then
            DB.ui.scale = v
            if frame then frame:SetScale(v) end
            Print("scale: %.2f", v)
        else
            Print("give a value between 0.5 and 2.0")
        end

    elseif cmd == "alert" then
        local v = tonumber(arg)
        if v and v >= 0 then
            DB.opts.alertThreshold = math.floor(v)
            Print(v == 0 and "alert off." or string.format("alert at a dry streak of %d.", math.floor(v)))
            UpdateDisplay()
        else
            Print("give a number (0 = off)")
        end

    elseif cmd == "chat" or cmd == "combat" then
        DB.opts.reportCombat = not DB.opts.reportCombat
        Print("after-fight summary in chat: %s", DB.opts.reportCombat and "on" or "off")

    elseif cmd == "pb" then
        DB.opts.countPrismatic = not DB.opts.countPrismatic
        Print("Prismatic Bolt counts as an Arcane Blast cast: %s", DB.opts.countPrismatic and "yes" or "no")

    elseif cmd == "anyspec" then
        DB.opts.onlyArcane = not DB.opts.onlyArcane
        Print("window limited to Arcane spec: %s", DB.opts.onlyArcane and "yes" or "no")
        UpdateDisplay()

    elseif cmd == "status" then
        ShowStatus()

    elseif cmd == "scan" then
        ScanBuffs()

    elseif cmd == "probe" then
        ProbeStackSources()

    elseif cmd == "debug" then
        DB.opts.debug = not DB.opts.debug
        Print("debug logging: %s", DB.opts.debug and "ON" or "off")

    elseif cmd == "setid" then
        local key, value = arg:match("^(%a+)%s+(%d+)$")
        value = tonumber(value)
        local field = key and ID_MAP[key]
        if field and value then
            ID[field] = value
            DB.ids[field] = value
            if field == "ccAura" then CC_AURA_IDS[1] = value end
            if field == "pbAura" then PB_AURA_IDS[1] = value end
            wipe(auraState)
            wipe(viewerIDCache)
            Print("id.%s set to %d (%s)", field, value, SpellName(value))
        else
            Print("usage: /adt setid <blast|barrage|missiles|ccaura|pbcast|pbaura|soulaura|soultrigger> <spellID>")
        end

    else
        ShowHelp()
    end
end

SLASH_ARCANEDESPAIRTRACKER1 = "/adt"
SLASH_ARCANEDESPAIRTRACKER2 = "/arcanedespair"
SLASH_ARCANEDESPAIRTRACKER3 = "/despair"
SlashCmdList["ARCANEDESPAIRTRACKER"] = HandleCommand

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end

        local raw = ArcaneDespairTrackerDB or {}
        local prevVersion = (raw.opts ~= nil) and (raw.version or 1) or nil  -- nil = fresh install
        ArcaneDespairTrackerDB = CopyDefaults(raw, DEFAULTS)
        DB = ArcaneDespairTrackerDB
        if prevVersion then
            -- these two used to default the other way round
            if prevVersion < 2 then DB.opts.reportCombat = false end
            if prevVersion < 3 then DB.opts.countPrismatic = false end
        end
        DB.version = DB_VERSION

        for field, value in pairs(DB.ids) do
            if type(value) == "number" then ID[field] = value end
        end
        for _, id in ipairs(EXTRA_PB_CASTS) do learnedPBCasts[id] = true end
        for key in pairs(DB.learnedPB) do
            local id = tonumber(key)
            if id then learnedPBCasts[id] = true end
        end
        ResetCombatStats()

    elseif event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        if class ~= "MAGE" then
            self:UnregisterAllEvents()
            return
        end

        CreateUI()
        UpdateDisplay()

        -- No COMBAT_LOG_EVENT_UNFILTERED: registering it triggers
        -- ADDON_ACTION_FORBIDDEN since patch 12.0.
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("SPELLS_CHANGED")
        self:RegisterEvent("SPELL_UPDATE_USABLE")

        PollAll()

        -- Aura secrecy switches on and off mid-fight and the game fires no event
        -- when it lifts, so a light ticker is the only way to notice that we can
        -- see again. Four cheap API reads; nothing allocates.
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(POLL_INTERVAL, function()
                PollAll()
                UpdateShameAll()   -- the faces have to time out on their own
            end)
        end

        Print("loaded. |cffffff00/adt help|r for commands.")

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        lastAnyCast = GetTime()      -- gate for the usability signal
        OnCast(spellID)

    elseif event == "UNIT_AURA" then
        PollAll()

    elseif event == "SPELL_UPDATE_USABLE" then
        PollMissilesUsable()

    elseif event == "SPELLS_CHANGED" then
        PollOverride()

    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()

    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
        UpdateShameAll()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        wipe(auraState)
        PollAll()
        UpdateDisplay()
    end
end)
