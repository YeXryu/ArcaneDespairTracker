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
    GetPlayerAuraBySpellID, hooks on Blizzard's own Cooldown Manager items,
    C_Spell.GetOverrideSpell, and - when none of those can see - on the casts
    that can only exist because a proc existed.

    WHAT THE PLAYER NEEDS SWITCHED ON: Blizzard's Cooldown Manager, with
    Clearcasting and Prismatic Bolt on one of its tracked bars (Edit Mode ->
    Cooldown Manager -> Tracked Buffs). That is the only signal that can see a
    proc landing while you are already holding one. Without it the addon still
    works, but falls back to weaker signals and stops counting Arcane Blasts
    whose outcome it cannot observe. /adt status says which one is in use.

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
local PREVIEW = { step = 3.6, hold = 3.3 }
local REFRESH_EPS = 0.05    -- any rise in expirationTime is a reapplication
local POLL_INTERVAL = 0.25  -- catches aura secrecy lifting, which fires no event
local USABLE_GATE = 1.2     -- a usability flip only counts this soon after a cast
-- Two signals this close describe the same proc. It has to cover the gap
-- between independent detectors reporting one event: the viewer hook answers
-- next frame, the 0.25s poll can be a whole tick behind it. Anything shorter
-- and one proc gets counted twice; anything much longer and two real procs a
-- global cooldown apart could merge, which they never are.
local SAME_INSTANT = 0.35
-- How long an aura whose spell id was sealed stays claimable as "the proc that
-- just landed". Long enough to survive the frame or two between the buff being
-- applied and a detector noticing, short enough not to adopt a stranger.
local ANON_ADD_TTL = 1.0
local DB_VERSION  = 5

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
-- Finding a proc's entry in Blizzard's Cooldown Manager
--
-- The digit it draws is a Secret Value in combat (measured: item.c3.Applications
-- came back <SECRET>), so nothing here tries to read a stack count. What we want
-- is the item frame itself: hooking it is how the proc engine sees a proc land
-- while the aura payload is sealed. See "Cooldown Manager proc detector" below.
----------------------------------------------------------------------
-- Every category, not a guessed pair. The tracked-buff category number is not
-- promised to stay put between patches, and an entry we cannot find is a
-- detector that silently does not exist. The frames below already restrict this
-- to buff bars, so a wide search costs nothing but is not allowed to go wrong.
local VIEWER_CATEGORIES = {}
do
    local seen = {}
    pcall(function()
        for _, value in pairs(Enum.CooldownViewerCategory) do
            if type(value) == "number" then seen[value] = true end
        end
    end)
    for i = 0, 12 do seen[i] = true end
    for value in pairs(seen) do table.insert(VIEWER_CATEGORIES, value) end
    table.sort(VIEWER_CATEGORIES)
end
-- Buff bars only. The Essential and Utility viewers hold *abilities*, and their
-- items redraw on every cooldown and global cooldown - reading one of those as
-- a proc detector produced signals that had nothing to do with any buff.
local VIEWER_FRAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

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
                        -- Deliberately not overrideSpellID. Prismatic Bolt is
                        -- the override on the Arcane Blast entry, so matching
                        -- that way handed back an ability item instead of the
                        -- buff - a frame that never hides and redraws on every
                        -- cooldown, which is not a proc detector at all.
                        if info.spellID == spellID then matched = true return end
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

-- The Cooldown Manager item that draws this cooldownID, plus the bar it lives
-- on. The bar matters: a Cooldown Manager the player has switched off in Edit
-- Mode hides every item, and that must not read as "the proc is gone".
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
                    if match then return item, parent, frameName end
                end
            end
        end
    end
    return nil
end

-- Is a spell castable right now? nil = unreadable.
-- Arcane Missiles usability is the last fallback, for clients where the Cooldown
-- Manager detector is unavailable. It can only ever reveal 0 -> 1 stacks.
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
        anyProcResets  = false,  -- any proc clears the strike, not just an earned one
        faceDelay      = 0,      -- the face is best instant; a lagging one looks broken
        soundDelay     = 0.4,    -- the sound waits, so a proc can cancel it
        soulPause      = true,   -- ignore Barrages cast during Arcane Soul
        soulDelay      = 17.4,   -- Arcane Soul lands this long after Arcane Surge
        soulDuration   = 4,      -- and lasts this long
        onboarded      = false,  -- the first-run walkthrough has been seen
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
-- The strike the face and the sound are allowed to react to. It lags the real
-- one by the grace delay, so a proc arriving just after the cast beats it.
local shameOk = { blast = 0, barrage = 0 }
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
local auraBlind   = {}      -- this aura was unreadable at the last poll
local learnedPBCasts = {}
local lastOverride
local missilesUsable        -- nil = unknown / unreadable
local lastAnyCast = 0       -- any player cast, used to gate the usability signal
local lastConsumedAt = { blast = 0, barrage = 0 }  -- when the proc was last spent

-- Cooldown Manager detector, one entry per counter.
--   item    the viewer item frame that draws this proc
--   hooked  our hooks are installed on it
--   proven  ... and Blizzard has actually called one, so it really is a signal
--   active  the item is showing, i.e. the proc is up (nil = cannot tell)
local viewer = {
    blast   = { kind = "blast",   hooked = false, proven = false },
    barrage = { kind = "barrage", hooked = false, proven = false },
}
local hookedViewerItems = setmetatable({}, { __mode = "k" })

-- Aura-instance detector state. Declared up here because the Cooldown Manager
-- path borrows from it: when a proc reappears and exactly one aura was added in
-- the same moment, that instance must be the one that just landed.
local knownInstance = {}       -- [kind] = the auraInstanceID we believe is ours
local anonymousAdds = nil      -- { ids = {...}, at = t } - added, spell id sealed
local instanceQueued = {}
local instanceReadable = false -- the game really does hand us those lists

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

    -- "all" is the walkthrough's placement step, which puts everything on screen
    -- at once so it can be dragged where it belongs in one pass.
    if placingKind == kind or placingKind == "all" then
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

    -- Not the live strike: the one that has survived the grace delay. A proc
    -- landing a moment after the cast rolls this back before it is ever drawn.
    local streak = math.min(DB.total[kind].streak, shameOk[kind] or 0)
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

    -- Every piece has its own fixed column, so going from 9 to 10 moves nothing
    -- but the digits themselves. The label, the "?" and the "proc" caption never
    -- shift, and the percentage keeps its right edge.
    local pbRow = rows[3]
    if pbRow then
        pbRow.label:SetText(L.CASTS_PREFIX .. L.STRIKE_SEP)
        pbRow.value:SetText(string.format("%s%d|r", Hex(DB.colors.calm), pbCasts))
        -- Where it sits is ApplyLayout's business; whether it exists at all is
        -- this one setting's, and it no longer depends on the row being shown.
        if DB.opts.showPBReset then pbRow.reset:Show() else pbRow.reset:Hide() end
    end

    for _, entry in ipairs({ { "blast", rows[1] }, { "barrage", rows[2] } }) do
        local kind, row = entry[1], entry[2]
        local t = DB.total[kind]

        row.label:SetText(L.STRIKE_PREFIX .. L.STRIKE_SEP)
        row.value:SetText(string.format("%s%d|r", StreakColor(t.streak), t.streak))

        -- Only Arcane Blast can pause, so only Arcane Blast gets the marker. It
        -- lives in its own column: appearing must not nudge the number.
        local mark = ""
        if kind == "blast" and DB.opts.pauseWhenBlind
           and DetectionLive and not DetectionLive(kind) then
            mark = Hex(DB.colors.mark) .. "?|r"
        end
        row.mark:SetText(mark)

        if DB.opts.showRate then
            row.rateLabel:SetText("|cff909090proc|r")
            row.rate:SetText(FormatPct(t.procs, t.casts))
            row.rateLabel:Show()
            row.rate:Show()
        else
            row.rateLabel:Hide()
            row.rate:Hide()
        end
    end

    UpdateShameAll()
end

-- Show one stage on screen at the size it would really be, for a few seconds.
local function PreviewTier(kind, i, seconds)
    seconds = seconds or PREVIEW.hold
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
local ShowSetup     -- the first-run walkthrough, defined further down

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

-- The third row is drawn for the Prismatic Bolt tally, for the RESET button, or
-- for both. The button keeps its own line rather than moving in with a
-- neighbour: switching the tally off should not shuffle the rest of the window.
local function ActiveRows()
    local list = { rows[1], rows[2] }
    if DB.opts.showPB or DB.opts.showPBReset then table.insert(list, rows[3]) end
    return list
end

local ROW_TEXTS = { "label", "value", "mark", "rateLabel", "rate" }

-- Set true whenever a column had to be guessed at instead of measured, which
-- happens on the very first layout: the font is not resolved yet, so
-- GetStringWidth answers 0. Guessing too narrow is what made the first-ever
-- frame wrap "STRIKE:" onto two lines and print the raw colour codes, so the
-- layout is simply run again a moment later, once the client can measure.
-- guessed  a column had to be estimated, so come back and measure properly
-- retries  how many times that has been tried, so it cannot loop for ever
-- cache    widths per font size: measured once and then remembered, because
--          re-measuring every layout is what gave a wrong answer room to
--          compound - a column that was right at this size is still right
local layoutState = { guessed = false, retries = 0, cache = {} }

-- Roughly how wide this many characters will be at this font size. Deliberately
-- an over-estimate: a column slightly too wide looks like a column, a column
-- slightly too narrow looks like a bug.
local function GuessWidth(chars, size)
    return math.ceil(chars * size * 0.62) + 4
end

-- How wide is this string in the font the row is actually using?
--
-- Two things have to be undone before asking, and forgetting them is what made
-- the labels creep inwards until they read "STRI...". A FontString that already
-- has an explicit width answers with that width, so measuring a column, setting
-- it, and measuring again next time feeds on itself and shrinks a little every
-- pass. And the size must be applied first, or the answer describes whatever
-- font the row happened to be using before.
local function MeasureText(fs, sample, chars, size)
    local fallback = GuessWidth(chars, size)
    if not (fs and fs.SetText and fs.GetStringWidth) then
        layoutState.guessed = true
        return fallback
    end

    local keep = fs.GetText and fs:GetText() or nil
    local ok, w = pcall(function()
        SetFontSize(fs, size)
        if fs.SetWidth then fs:SetWidth(0) end   -- 0 = size to the text
        fs:SetText(sample)
        return fs:GetStringWidth()
    end)
    if keep ~= nil then pcall(fs.SetText, fs, keep) end

    if ok and type(w) == "number" and w > 1 then return math.ceil(w) + 6 end
    layoutState.guessed = true
    return fallback
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
        row.icon:Hide(); row.hover:Hide()
        for _, key in ipairs(ROW_TEXTS) do
            if row[key] then row[key]:Hide() end
        end
        if row.reset then row.reset:Hide() end
    end

    local ts = DB.ui.textSize
    local active = ActiveRows()

    -- One set of column widths for every row, measured from the font so the
    -- columns are as tight as they can be without the contents ever moving.
    local cols = layoutState.cache[ts]
    if not cols then
        layoutState.guessed = false
        local first = active[1]
        cols = {
            label = first and MeasureText(first.label, "STRIKE:", 7, ts) or 0,
            value = first and MeasureText(first.value, "888",     3, ts) or 0,
            mark  = first and MeasureText(first.mark,  "?",       1, ts) or 0,
            proc = 0, pct = 0,
        }
        for _, row in ipairs(active) do
            if row.rate then
                cols.proc = MeasureText(row.rateLabel, "proc",   4, ts - 1)
                cols.pct  = MeasureText(row.rate,      "100.0%", 6, ts - 1)
                break
            end
        end
        -- Only a set of widths the client could actually measure is worth
        -- keeping; an estimate is replaced when the retry below measures again.
        if not layoutState.guessed then layoutState.cache[ts] = cols end
    end
    local labelW, valueW, markW = cols.label, cols.value, cols.mark
    local procW, pctW = cols.proc, cols.pct


    for i, row in ipairs(active) do
        local y   = -(top + (i - 1) * rowH)
        local mid = y - icon / 2            -- the row's vertical centre line
        local textX = pad + 2 + icon + 7

        -- The row can be present purely to hold the button.
        local counted = not (row.kind == "pb" and not DB.opts.showPB)

        row.hover:Show()
        if counted then row.icon:Show() else row.icon:Hide() end
        row.icon:SetSize(icon, icon)
        row.icon:ClearAllPoints()
        row.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", pad + 2, y)

        -- Each column is anchored to the frame, never to the text beside it, so
        -- nothing can be pushed along by a neighbour growing a digit.
        local columns = {
            { row.label, textX,                        labelW },
            { row.value, textX + labelW + 5,           valueW },
            { row.mark,  textX + labelW + 5 + valueW,  markW  },
        }
        for _, col in ipairs(columns) do
            local fs, x, w = col[1], col[2], col[3]
            SetFontSize(fs, ts)
            fs:SetWidth(w)
            fs:SetJustifyH("LEFT")
            -- One line, always. A wrapped label is what turned "STRIKE:" into
            -- two rows with the raw colour escape showing on the second.
            if fs.SetWordWrap then fs:SetWordWrap(false) end
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", frame, "TOPLEFT", x, mid)
            if counted then fs:Show() else fs:Hide() end
        end

        if row.rate then
            for _, col in ipairs({ { row.rateLabel, pad + 3 + pctW + 4, procW },
                                   { row.rate,      pad + 3,            pctW  } }) do
                local fs, inset, w = col[1], col[2], col[3]
                SetFontSize(fs, ts - 1)
                fs:SetWidth(w)
                fs:SetJustifyH("RIGHT")
                if fs.SetWordWrap then fs:SetWordWrap(false) end
                fs:ClearAllPoints()
                fs:SetPoint("RIGHT", frame, "TOPRIGHT", -inset, mid)
            end
        end

        if row.reset and DB.opts.showPBReset then
            row.reset:SetFrameLevel(row.hover:GetFrameLevel() + 5)
            row.reset:ClearAllPoints()
            row.reset:SetPoint("RIGHT", frame, "TOPRIGHT", -(pad + 2), mid)
            row.reset:SetSize(48, 18)
            row.reset:Show()
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

    -- At login the font is not resolved yet and every column had to be guessed.
    -- Come back in a moment and measure properly, so the first frame the player
    -- ever sees settles into the right shape by itself.
    if layoutState.guessed and layoutState.retries < 20 and C_Timer and C_Timer.After then
        layoutState.retries = layoutState.retries + 1
        C_Timer.After(0.2, function()
            ApplyLayoutPublic()
            UpdateDisplay()
        end)
    end
end

ApplyLayoutPublic = ApplyLayout

local function BuildRow(parent, kind, spellID, label, tip)
    local row = { kind = kind, label = label, tip = tip }

    row.icon = parent:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(SpellTexture(spellID))
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Five fixed columns rather than one string: see ApplyLayout.
    row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.mark  = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.rateLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.rate      = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")

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

    row.label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.mark  = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")

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

-- Columns sit 220 px apart, so anything sitting in one gets a little less than
-- that to draw in and cannot spill into its neighbour.
local COLUMN_TEXT_W = 200

local function MakeCheck(parent, label, tooltip, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    -- Bounded to the column, so a long label wraps or trims instead of running
    -- underneath whatever is in the next one.
    text:SetWidth(COLUMN_TEXT_W)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
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
    caption:SetPoint("BOTTOMLEFT", sl, "TOPLEFT", 0, 5)
    caption:SetWidth(COLUMN_TEXT_W)
    caption:SetJustifyH("LEFT")
    caption:SetWordWrap(false)
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
    options:SetSize(790, 812)
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
    -- Solid. A settings panel you can read the dungeon through is a settings
    -- panel you cannot read.
    options:SetBackdropColor(0.045, 0.04, 0.065, 1)
    options:SetBackdropBorderColor(0.53, 0.47, 1, 0.9)
    options:Hide()

    -- a tall panel on a short screen would run off the bottom
    local screen = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 1080
    if screen and screen < 860 then options:SetScale(0.78) end

    local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", options, "TOP", 0, -13)
    title:SetText("|cff9d8cffArcane Despair Tracker|r")

    local titleRule = options:CreateTexture(nil, "ARTWORK")
    titleRule:SetTexture("Interface\\Buttons\\WHITE8X8")
    titleRule:SetColorTexture(0.53, 0.47, 1, 0.35)
    titleRule:SetPoint("TOPLEFT", options, "TOPLEFT", 12, -36)
    titleRule:SetPoint("TOPRIGHT", options, "TOPRIGHT", -12, -36)
    titleRule:SetHeight(1)

    -- Escape closes it, like every other panel in the game.
    if type(UISpecialFrames) == "table" then
        local listed = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "ArcaneDespairTrackerOptions" then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, "ArcaneDespairTrackerOptions") end
    end

    local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() options:Hide() end)

    local widgets = {}
    local function add(w) table.insert(widgets, w) return w end

    -- A heading with a rule under it. Without the rule the three columns read as
    -- one long list of controls and the sections stop being sections.
    local function header(text, x, y)
        local fs = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", options, "TOPLEFT", x, y)
        fs:SetText("|cffffd100" .. text .. "|r")

        local rule = options:CreateTexture(nil, "ARTWORK")
        rule:SetColorTexture(1, 0.82, 0, 0.22)
        rule:SetPoint("TOPLEFT", options, "TOPLEFT", x, y - 15)
        rule:SetWidth(COLUMN_TEXT_W + 14)
        rule:SetHeight(1)
    end

    local L1, L2, L3 = 16, 246, 476      -- three columns

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
        "Midnight hides your buffs in combat. ADT reads them through Blizzard's Cooldown Manager "
        .. "instead - that needs the Cooldown Manager switched on with Clearcasting on a tracked bar "
        .. "(Edit Mode -> Cooldown Manager). If no signal is available at all, an ambiguous Arcane "
        .. "Blast is not counted rather than guessed at, and '?' says so. Arcane Barrage always counts.",
        L1, -524,
        function() return DB.opts.pauseWhenBlind end, function(v) DB.opts.pauseWhenBlind = v end))
    add(MakeCheck(options, "Any proc resets the strike",
        "On: the strike answers 'how long since this proc last showed up', so a Clearcasting off an "
        .. "Arcane Explosion or Orb clears it too - which is what the faces really react to. "
        .. "Off: only a proc the counted spell itself earned clears it, the strict reading of "
        .. "'Arcane Blasts that did not proc Clearcasting'. Either way the totals and the proc rate "
        .. "only ever count procs an actual Blast or Barrage earned.", L1, -548,
        function() return DB.opts.anyProcResets end, function(v) DB.opts.anyProcResets = v end))
    add(MakeCheck(options, "Prismatic Bolt counts as Blast", nil, L1, -572,
        function() return DB.opts.countPrismatic end, function(v) DB.opts.countPrismatic = v end))
    add(MakeCheck(options, "Fight summary in chat", nil, L1, -596,
        function() return DB.opts.reportCombat end, function(v) DB.opts.reportCombat = v end))
    add(MakeCheck(options, "Reset everything each fight",
        "Every counter starts from zero when a new fight begins - both strikes, the totals, "
        .. "the proc rates and the Prismatic Bolt tally. Turn it off to keep running totals "
        .. "across a whole session.", L1, -620,
        function() return DB.opts.resetOnFight end, function(v) DB.opts.resetOnFight = v end))
    add(MakeCheck(options, "Skip Barrages in Arcane Soul",
        "On by default. Skips only the 4s Arcane Soul window itself, casts and procs alike - "
        .. "the 17.4s wait between casting Arcane Surge and Soul landing is ordinary play and "
        .. "keeps counting. Turn it off to have the burst window judged like any other casts.",
        L1, -644,
        function() return DB.opts.soulPause end, function(v) DB.opts.soulPause = v end))
    add(MakeSlider(options, "Soul lands after", L1, -688, 0, 30, 0.1,
        function() return DB.opts.soulDelay end,
        function(v) DB.opts.soulDelay = v end,
        "Wait after Surge: %.1fs"))
    add(MakeSlider(options, "Soul lasts", L1, -728, 1, 15, 0.5,
        function() return DB.opts.soulDuration end,
        function(v) DB.opts.soulDuration = v end,
        "Skipped window: %.1fs"))
    add(MakeSlider(options, "Alert at strike", L1, -768, 0, 30, 1,
        function() return DB.opts.alertThreshold end,
        function(v) DB.opts.alertThreshold = v end,
        "Alert at strike: %d  (0 = off)"))


    ------------------------------------------------ right: faces, per counter
    local shameKind = "blast"
    local function kindOf() return shameKind end

    -- The two counters keep entirely separate faces, thresholds, sizes, sounds
    -- and screen positions, so this whole column belongs to one of them at a
    -- time. A single "Editing: ..." button hid that: it read as a label, and
    -- there was nothing to say the other half existed. Two buttons, the active
    -- one lit, plus a line saying what they do.
    header("Faces and sounds", L2, -42)
    local kindNote = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    kindNote:SetPoint("TOPLEFT", options, "TOPLEFT", L2, -64)
    kindNote:SetWidth(COLUMN_TEXT_W + 14)
    kindNote:SetJustifyH("LEFT")
    if kindNote.SetWordWrap then kindNote:SetWordWrap(false) end
    kindNote:SetText("These settings edit:")

    local kindBtns = {}
    -- 108 + 108 + a hair of gap fits the column, and "Arcane Barrage" fits 108.
    for i, entry in ipairs({ { "blast", 0 }, { "barrage", 110 } }) do
        local kind, dx = entry[1], entry[2]
        local btn = add(MakeButton(options, KIND_LABEL[kind], L2 + dx, -80, 108, function()
            shameKind = kind
            if options.refresh then options.refresh() end
        end))
        btn:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Edit the " .. KIND_LABEL[kind] .. " face")
            GameTooltip:AddLine("Each counter has its own faces, thresholds, sizes, sounds "
                .. "and place on screen. Switching here changes which one the rest of this "
                .. "column is editing - it does not turn anything on or off.",
                0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        btn.refresh = function()
            local on = (shameKind == kind)
            btn:SetText(on and ("|cffffd100" .. KIND_LABEL[kind] .. "|r") or KIND_LABEL[kind])
            if btn.SetAlpha then btn:SetAlpha(on and 1.0 or 0.55) end
        end
        kindBtns[i] = btn
    end

    add(MakeCheck(options, "Enable the faces", nil, L2, -104,
        function() return Shame(kindOf()).enabled end,
        function(v) Shame(kindOf()).enabled = v; UpdateShameAll() end))
    add(MakeSlider(options, "Appears at strike", L2, -148, 2, 40, 1,
        function() return Shame(kindOf()).at end,
        function(v) Shame(kindOf()).at = v; UpdateShameAll() end,
        "Appears at strike: %d"))
    add(MakeSlider(options, "Despair step", L2, -188, 1, 10, 1,
        function() return Shame(kindOf()).step end,
        function(v) Shame(kindOf()).step = v; UpdateShameAll() end,
        "Next face every %d casts"))
    add(MakeSlider(options, "Base size", L2, -228, 24, 200, 4,
        function() return Shame(kindOf()).size end,
        function(v) Shame(kindOf()).size = v; UpdateShameAll() end,
        "Base size: %d px"))
    add(MakeSlider(options, "Growth per cast", L2, -268, 0, 40, 1,
        function() return Shame(kindOf()).growth end,
        function(v) Shame(kindOf()).growth = v; UpdateShameAll() end,
        "Growth per cast: %d px"))
    add(MakeSlider(options, "Hide after", L2, -308, 0, 30, 1,
        function() return Shame(kindOf()).timeout end,
        function(v) Shame(kindOf()).timeout = v; UpdateShameAll() end,
        "Hide %d s after the last cast"))

    local placeBtn = add(MakeButton(options, "", L2, -332, 110, function()
        placingKind = (placingKind == kindOf()) and nil or kindOf()
        UpdateShameAll()
        if options.refresh then options.refresh() end
    end))
    placeBtn.refresh = function()
        placeBtn:SetText(placingKind == kindOf() and "Done placing" or "Place face")
    end
    add(MakeButton(options, "Re-centre", L2 + 116, -332, 84, function()
        local cfg = Shame(kindOf())
        cfg.point, cfg.x, cfg.y = "CENTER", 0, 0
        local f = shameFrames[kindOf()]
        if f then
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end))

    ------------------------------------------------ right: sound
    header("Sound", L2, -368)
    add(MakeCheck(options, "Play a sound", nil, L2, -388,
        function() return Shame(kindOf()).soundEnabled end,
        function(v) Shame(kindOf()).soundEnabled = v end))
    add(MakeSlider(options, "Sound every N casts", L2, -432, 1, 10, 1,
        function() return Shame(kindOf()).every end,
        function(v) Shame(kindOf()).every = v end,
        "Sound every %d casts"))
    add(MakeSlider(options, "At the last stage", L2, -472, 1, 10, 1,
        function() return Shame(kindOf()).everyFinal end,
        function(v) Shame(kindOf()).everyFinal = v end,
        "At the last stage: every %d"))

    local channelBtn = add(MakeButton(options, "", L2, -496, 130, function()
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

    add(MakeButton(options, "Test", L2 + 136, -496, 64, function()
        PlayShameSound(kindOf(), 1)
    end))

    -- Both of these apply to either counter, so they sit outside the per-counter
    -- block above. They are separate because they want different answers: a
    -- delayed face means watching the previous stage sit on screen and then swap,
    -- while a delayed sound is simply one that a proc gets to cancel.
    header("Grace after a cast", L2, -532)
    add(MakeSlider(options, "Face delay", L2, -572, 0, 2, 0.05,
        function() return DB.opts.faceDelay end,
        function(v) DB.opts.faceDelay = v; UpdateShameAll() end,
        "Face delay: %.2fs  (0 = instant)"))
    add(MakeSlider(options, "Sound delay", L2, -612, 0, 2, 0.05,
        function() return DB.opts.soundDelay end,
        function(v) DB.opts.soundDelay = v end,
        "Sound delay: %.2fs"))
    local graceNote = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    graceNote:SetPoint("TOPLEFT", options, "TOPLEFT", L2, -640)
    graceNote:SetWidth(COLUMN_TEXT_W + 14)
    graceNote:SetJustifyH("LEFT")
    graceNote:SetText("A proc landing inside the window cancels whatever is still waiting. "
        .. "A delayed face just looks broken, so leave it at 0.")

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
            C_Timer.After((stage - 1) * PREVIEW.step, function()
                PreviewTier(kind, stage, PREVIEW.hold)
                if Shame(kind).soundEnabled then PlayShameSound(kind, stage) end
            end)
        end
    end))

    ------------------------------------------------ far right: the PB row
    header("Prismatic Bolt row", L3, -324)
    add(MakeCheck(options, "Show the cast counter", "A third row tallying Prismatic Bolts cast this fight.", L3, -344,
        function() return DB.opts.showPB end,
        function(v) DB.opts.showPB = v; ApplyLayout(); UpdateDisplay() end))
    add(MakeCheck(options, "Show its RESET button",
        "Clears every counter, not just the Prismatic Bolt tally. With the row above "
        .. "switched off the button moves to the last row that is showing, so it is "
        .. "still there.", L3, -368,
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
        add(MakeColorSwatch(options, entry[1], L3, -426 - (i - 1) * 22, entry[2]))
    end

    ------------------------------------------------ far right: tools
    -- These lived at the bottom of the first column, which made it run a head
    -- taller than the other two for no reason.
    header("Tools", L3, -566)
    add(MakeButton(options, "Run setup again", L3, -590, 130, function()
        options:Hide()
        if ShowSetup then ShowSetup() end
    end))
    add(MakeButton(options, "Reset statistics", L3, -616, 130, function()
        if ResetStatsPublic then ResetStatsPublic() end
    end))
    add(MakeButton(options, "Fight history", L3, -642, 130, function()
        if ShowHistoryPublic then ShowHistoryPublic() end
    end))
    add(MakeButton(options, "Diagnostics", L3, -668, 130, function()
        if ShowStatusPublic then ShowStatusPublic() end
    end))
    add(MakeCheck(options, "Debug logging",
        "Prints every cast and every proc decision to chat, including which detector "
        .. "made the call. Useful once, noisy forever - leave it off.", L3, -696,
        function() return DB.opts.debug end, function(v) DB.opts.debug = v end))

    local credits = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credits:SetPoint("BOTTOM", options, "BOTTOM", 0, 8)
    credits:SetText("Author: iamRudy  |cff5a5a66-|r  big thanks to Viktor")

    options:SetHeight(812)

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
            Print("the counter itself is unaffected - see |cffffff00/adt help|r for what can "
                .. "still be done from chat")
            options = nil
            return
        end
    end
    options.refresh()
    if options:IsShown() then options:Hide() else options:Show() end
end

----------------------------------------------------------------------
-- First-run walkthrough
--
-- Six short steps. The parts worth spending someone's attention on are what the
-- numbers in the window actually mean, the three choices that change how casts
-- are counted, and putting the three movable pieces where they belong - that
-- last one otherwise means finding three different buttons in the settings.
--
-- It waits for Arcane and for combat to end before appearing: teaching someone
-- to read a window they cannot see is pointless, and asking them to drag things
-- around mid-pull is worse.
----------------------------------------------------------------------
-- One table rather than two locals: this file is close to Lua's ceiling of 200
-- of them in a chunk, and a walkthrough is not worth spending two on.
local setupUI = {}

setupUI.build = function()
    local setup = CreateFrame("Frame", "ArcaneDespairTrackerSetup", UIParent, "BackdropTemplate")
    setup:SetSize(540, 450)
    setup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    setup:SetFrameStrata("DIALOG")
    setup:SetClampedToScreen(true)
    setup:SetMovable(true)
    setup:EnableMouse(true)
    setup:RegisterForDrag("LeftButton")
    setup:SetScript("OnDragStart", setup.StartMoving)
    setup:SetScript("OnDragStop", setup.StopMovingOrSizing)
    setup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
    })
    setup:SetBackdropColor(0.045, 0.04, 0.065, 1)
    setup:SetBackdropBorderColor(0.53, 0.47, 1, 0.9)
    setup:Hide()

    -- The addon's own name on every step, not just the first: a window that says
    -- only "Faces and sounds" gives no clue what is talking to you.
    local brand = setup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    brand:SetPoint("TOP", setup, "TOP", 0, -12)
    brand:SetText("|cff9d8cffArcane Despair Tracker|r")

    local title = setup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", setup, "TOP", 0, -36)

    local counter = setup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    counter:SetPoint("TOPRIGHT", setup, "TOPRIGHT", -16, -16)

    local rule = setup:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.53, 0.47, 1, 0.35)
    rule:SetPoint("TOPLEFT", setup, "TOPLEFT", 14, -56)
    rule:SetPoint("TOPRIGHT", setup, "TOPRIGHT", -14, -56)
    rule:SetHeight(1)

    local body = setup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", setup, "TOPLEFT", 20, -68)
    body:SetWidth(500)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")

    -- Controls are rebuilt for each step and parked off to the side otherwise;
    -- creating frames once and reusing them keeps this from leaking widgets.
    setup.parts = {}
    local function part(key, builder)
        if not setup.parts[key] then setup.parts[key] = builder() end
        return setup.parts[key]
    end

    local back = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
    back:SetSize(90, 24)
    back:SetPoint("BOTTOMLEFT", setup, "BOTTOMLEFT", 16, 14)
    back:SetText("Back")

    local next = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
    next:SetSize(110, 24)
    next:SetPoint("BOTTOMRIGHT", setup, "BOTTOMRIGHT", -16, 14)

    local skip = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
    skip:SetSize(90, 24)
    skip:SetPoint("BOTTOM", setup, "BOTTOM", 0, 14)
    skip:SetText("Skip")

    -- One question, two answers, the recommended one marked. Two buttons read
    -- better than a checkbox here: the recommendation is visible without having
    -- to work out which way round the tick means.
    local function choice(key, y, question, left, right, get, set)
        local block = part(key, function()
            local q = setup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            q:SetPoint("TOPLEFT", setup, "TOPLEFT", 20, y)
            -- Wide and tall enough for the longest label; the first pass at this
            -- had the recommendation running off the end of its own button.
            local a = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
            a:SetSize(245, 26)
            a:SetPoint("TOPLEFT", setup, "TOPLEFT", 20, y - 18)
            local b = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
            b:SetSize(245, 26)
            b:SetPoint("TOPLEFT", setup, "TOPLEFT", 275, y - 18)
            -- A question is three widgets, so it carries the same Show and Hide
            -- the single-widget parts have and the step switcher stays simple.
            local blk = { q = q, a = a, b = b }
            function blk:Show() self.q:Show() self.a:Show() self.b:Show() end
            function blk:Hide() self.q:Hide() self.a:Hide() self.b:Hide() end
            return blk
        end)

        block.q:SetText(question)
        local function paint()
            local on = get()
            block.a:SetText(on and ("|cffffd100" .. left .. "|r") or left)
            block.b:SetText((not on) and ("|cffffd100" .. right .. "|r") or right)
            if block.a.SetAlpha then block.a:SetAlpha(on and 1 or 0.55) end
            if block.b.SetAlpha then block.b:SetAlpha(on and 0.55 or 1) end
        end
        block.a:SetScript("OnClick", function() set(true); paint() end)
        block.b:SetScript("OnClick", function() set(false); paint() end)
        paint()
        block:Show()
        return block
    end

    local function toggle(key, y, label, get, set)
        local cb = part(key, function()
            local c = CreateFrame("CheckButton", nil, setup, "UICheckButtonTemplate")
            c:SetSize(24, 24)
            c:SetPoint("TOPLEFT", setup, "TOPLEFT", 20, y)
            c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            c.text:SetPoint("LEFT", c, "RIGHT", 2, 1)
            return c
        end)
        cb.text:SetText(label)
        cb:SetChecked(get() and true or false)
        cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        cb:Show()
        return cb
    end

    local function button(key, x, y, w, label, onClick)
        local b = part(key, function()
            local btn = CreateFrame("Button", nil, setup, "UIPanelButtonTemplate")
            btn:SetPoint("TOPLEFT", setup, "TOPLEFT", x, y)
            return btn
        end)
        b:SetSize(w, 26)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        b:Show()
        return b
    end

    -- Runs one counter's whole escalation past you, faces and sound together, so
    -- "test the strike" means the same thing here as it will in a real pull.
    local function runStrikeDemo(kind)
        for i = 1, #TIERS[kind] do
            C_Timer.After((i - 1) * PREVIEW.step, function()
                PreviewTier(kind, i, PREVIEW.hold)
                if Shame(kind).soundEnabled then PlayShameSound(kind, i) end
            end)
        end
    end

    local steps = {
        {
            title = "Welcome",
            bodyH = 320,
            text = "Thanks for downloading. This counts the |cffffd100Arcane Blasts|r that "
                .. "did not proc Clearcasting and the |cffffd100Arcane Barrages|r that did "
                .. "not proc Prismatic Bolt, and keeps score of the dry run.\n\n"
                .. "|cffff8040One thing it needs first.|r Midnight hides your own buffs from "
                .. "addons in combat, so the addon reads them through Blizzard's "
                .. "|cffffd100Cooldown Manager|r. Switch it on and put |cffffd100Clearcasting|r "
                .. "and |cffffd100Prismatic Bolt|r on a tracked buff bar - without that, "
                .. "procs land where the addon cannot see them.\n\n"
                .. "It will not make the procs come. It will keep an exact and unflattering "
                .. "record of how long they have not.\n\n"
                .. "A short setup follows - four steps, and you can skip it at any point.",
            build = function()
                DB.ui.shown = true
                UpdateDisplay()
            end,
        },
        {
            title = "How you want it counted",
            bodyH = 90,
            text = "Your counter is on screen now. |cffffd100STRIKE|r is casts in a row with "
                .. "no proc, |cffffd100proc %|r your real rate since the last reset, "
                .. "|cffffd100?|r means that proc cannot be seen right now so the cast is "
                .. "left out rather than guessed at, and |cffffd100CASTS|r counts the "
                .. "Prismatic Bolts you cast. Hover a row for more, right-click it for the "
                .. "settings.\n\nFour choices decide what the numbers mean:",
            build = function()
                choice("c1", -160, "Counters each fight, or running totals?",
                    "Each fight (recommended)", "Keep running",
                    function() return DB.opts.resetOnFight end,
                    function(v) DB.opts.resetOnFight = v end)
                choice("c2", -220, "What clears the strike?",
                    "Only its own proc (recommended)", "Any proc at all",
                    function() return not DB.opts.anyProcResets end,
                    function(v) DB.opts.anyProcResets = not v end)
                choice("c3", -280, "Casts the addon cannot judge?",
                    "Leave them out (recommended)", "Count them anyway",
                    function() return DB.opts.pauseWhenBlind end,
                    function(v) DB.opts.pauseWhenBlind = v end)
                choice("c4", -340, "Barrages cast during Arcane Soul?",
                    "Skip them (recommended)", "Count them too",
                    function() return DB.opts.soulPause end,
                    function(v) DB.opts.soulPause = v end)
            end,
        },
        {
            title = "Faces, sounds and where they sit",
            bodyH = 84,
            text = "As a strike grows, a face appears and gets worse, with a sound to match "
                .. "and a separate set per counter. Try one, then drag the counter window "
                .. "and the two faces wherever you want them - the faces are at their "
                .. "starting size and grow with the strike, so leave them room.",
            build = function()
                DB.ui.shown, DB.ui.locked = true, false
                placingKind = "all"
                UpdateDisplay()
                UpdateShameAll()
                toggle("t1", -160, "Show the faces", function()
                    return DB.shame.blast.enabled
                end, function(v)
                    DB.shame.blast.enabled, DB.shame.barrage.enabled = v, v
                    UpdateShameAll()
                end)
                toggle("t2", -188, "Play the sounds", function()
                    return DB.shame.blast.soundEnabled
                end, function(v)
                    DB.shame.blast.soundEnabled, DB.shame.barrage.soundEnabled = v, v
                end)
                button("b1", 20, -224, 245, "Test Arcane Blast strike", function()
                    runStrikeDemo("blast")
                end)
                button("b2", 275, -224, 245, "Test Arcane Barrage strike", function()
                    runStrikeDemo("barrage")
                end)
                button("b3", 20, -258, 245, "Centre everything", function()
                    DB.ui.point, DB.ui.x, DB.ui.y = "CENTER", 0, 180
                    if frame then
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
                    end
                    for _, kind in ipairs(SHAME_KINDS) do
                        local cfg = Shame(kind)
                        cfg.point, cfg.x, cfg.y = "CENTER", 0, 0
                        local f = shameFrames[kind]
                        if f then
                            f:ClearAllPoints()
                            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                        end
                    end
                end)
            end,
            leave = function()
                placingKind = nil
                UpdateShameAll()
            end,
        },
        {
            title = "That is everything",
            text = "|cffffd100/adt|r opens the settings, and there is a great deal more in "
                .. "there: every colour, the size of everything, per-stage sounds, a log of "
                .. "your last twenty fights.\n\n"
                .. "|cffffd100/adt setup|r runs this walkthrough again.\n"
                .. "|cffffd100/adt help|r lists the rest.\n\n"
                .. "That is the lot. Have fun out there - and may your strike stay short.",
        },
    }

    local at = 1

    local function show(step)
        for _, w in pairs(setup.parts) do w:Hide() end
        local s = steps[at]
        if s and s.leave and step ~= at then s.leave() end
        at = math.max(1, math.min(#steps, step))
        s = steps[at]

        title:SetText("|cffffd100" .. s.title .. "|r")
        counter:SetText(string.format("Step %d of %d", at, #steps))
        body:SetText(s.text)
        body:SetHeight(s.bodyH or (s.build and 120 or 320))
        if s.build then s.build() end

        back:SetShown(at > 1)
        skip:SetShown(at < #steps)
        next:SetText(at == #steps and "Finish" or "Next")
    end

    -- Saved the moment the walkthrough is done with, and saved in the character's
    -- SavedVariables, which an addon update does not touch. The version stamp is
    -- what a later release would read if it ever wanted to show something new;
    -- the flag alone is enough to keep this one from coming back.
    local function markDone()
        DB.opts.onboarded = true
        -- Read from the .toc rather than written out here, so the two cannot
        -- drift apart. No file-level local for it: this chunk is at Lua's
        -- ceiling of 200 of them and a version string is not worth one.
        local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        if meta then
            local ok, v = pcall(meta, ADDON_NAME, "Version")
            if ok and type(v) == "string" and v ~= "" then
                DB.opts.onboardedVersion = v
            end
        end
    end

    local function finish()
        local s = steps[at]
        if s and s.leave then s.leave() end
        markDone()
        setup:Hide()
        ApplyLayout()
        UpdateDisplay()
    end

    back:SetScript("OnClick", function() show(at - 1) end)
    skip:SetScript("OnClick", finish)
    next:SetScript("OnClick", function()
        if at == #steps then finish() else show(at + 1) end
    end)
    -- Closing the window by any other route - Escape, /reload, the pull starting -
    -- still counts as having seen it, except when combat took it away, which is
    -- the one case that gets it back. Otherwise it reappears every login.
    setup:SetScript("OnHide", function()
        local s = steps[at]
        if s and s.leave then s.leave() end
        if not setupUI.interrupted then markDone() end
    end)

    -- Escape closes it too, and closing it counts as done (see OnHide above).
    if type(UISpecialFrames) == "table" then
        local listed = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "ArcaneDespairTrackerSetup" then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, "ArcaneDespairTrackerSetup") end
    end

    setup.start = function() show(1) setup:Show() end
    setupUI.frame = setup
end

-- Shown once, and only when it can actually be followed.
function MaybeShowSetup()
    if not DB or DB.opts.onboarded then return end
    if DB.opts.onlyArcane and CurrentSpecID() ~= ARCANE_SPEC_ID then return end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return end
    if setupUI.frame and setupUI.frame:IsShown() then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            if DB.opts.onboarded then return end
            if UnitAffectingCombat and UnitAffectingCombat("player") then return end
            ShowSetup()
        end)
    else
        ShowSetup()
    end
end

ShowSetup = function()
    if not setupUI.frame then
        local ok, err = pcall(setupUI.build)
        if not ok or not setupUI.frame then
            Print("could not build the walkthrough: %s", tostring(err))
            setupUI.frame = nil
            return
        end
    end
    setupUI.frame.start()
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

-- Cast events and proc signals do not arrive in a fixed order, and a proc can
-- take a moment to become visible at all. Reacting to a dry cast the instant it
-- lands is what makes a face flash up on a Blast that actually procced.
--
-- The face and the sound want different answers to that, which is why they have
-- separate delays. A delayed face is worse than no delay at all: the frame keeps
-- drawing the previous stage until the timer expires, so you watch the old
-- picture sit there and then swap - the face is best left instant. The sound is
-- the one that benefits, because an escalating honk over a proc is the thing
-- that actually grates.
--
-- Either way a proc inside the window cancels what is pending: ResetShame bumps
-- shameRun, and these checks refuse to fire for a run already superseded.
local function ShameLater(kind, run, streak)
    local function stillCurrent()
        if (shameRun[kind] or 0) ~= run then return false end   -- a proc got there first
        return DB.total[kind].streak == streak                  -- the strike moved on
    end

    local function after(delay, fn)
        if (delay or 0) <= 0 or not (C_Timer and C_Timer.After) then
            fn()
        else
            C_Timer.After(delay, fn)
        end
    end

    after(DB.opts.faceDelay, function()
        if not stillCurrent() then return end
        shameOk[kind] = streak
        if UpdateShamePublic then UpdateShamePublic() end
    end)

    after(DB.opts.soundDelay, function()
        if not stillCurrent() then return end
        ShameCheck(kind, streak)
    end)
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
    shameOk[kind] = 0                            -- cancels anything still in its grace period
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
        ShameLater(kind, shameRun[kind] or 0, DB.total[kind].streak)
        Debug("cast booked as dry: %s (streak %d)", kind, DB.total[kind].streak)

        -- This cast now owns the claim on the next proc we see. No timer: the
        -- claim ends when the next cast is made, not after N seconds. Aura data
        -- can go dark and come back, so a wall-clock window would drop procs
        -- that are still unambiguously this cast's.
        pendingCast = { kind = kind }
    end
end

-- A proc landed, but no cast of ours owns it - it came off an Arcane Explosion,
-- an Orb, a Barrage, or it was recovered after the fact from a consumption.
--
-- With "any proc resets the strike" on, the number on screen answers "how long
-- since this proc last showed up", which is what the escalating faces are really
-- reacting to. The totals stay honest either way: with no owner there is nothing
-- to reclassify, so no dry cast is ever turned into a proc here.
local function ResetStreakForAnyGain(kind, source)
    if not DB.opts.anyProcResets then return end
    for _, t in ipairs(Trackers(kind)) do t.streak = 0 end
    maxSnapshot[kind] = nil
    ResetShame(kind)
    Debug("%s strike reset by a proc it did not earn (via %s)", kind, source or "?")
    UpdateDisplay()
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
local function OnProcObserved(kind, source, skipDedupe, settled)
    local now = GetTime()

    -- If the Barrages inside Arcane Soul are not being counted, the Bolts they
    -- proc cannot be counted either. Crediting them meant the proc rate rose off
    -- casts that were never in the denominator, and worse, the retro-conversion
    -- below would reach back and turn the last Barrage before the window into a
    -- proc it never earned.
    if kind == "barrage" and SoulActive() then
        Debug("barrage proc ignored (via %s): Arcane Soul is up and its casts are not counted",
            source or "?")
        return false
    end

    -- Several signals describe the same proc (aura gain, usability flip, button
    -- override). Whichever arrives first wins; the rest are the same event.
    -- skipDedupe is for a genuine multi-stack gain seen in one poll.
    if not skipDedupe and (now - (lastGain[kind] or 0)) < SAME_INSTANT then
        Debug("duplicate %s proc signal ignored (via %s)", kind, source or "?")
        return false
    end

    lastGain[kind] = now

    -- A proc just landed and we do not know which aura instance it is, because
    -- spending the last one destroyed that knowledge and the replacement came in
    -- with its spell id sealed. If exactly one unlabelled aura turned up in the
    -- same moment, it is this one. Doing it here rather than inside any single
    -- detector means whichever of them saw the proc can relearn the instance -
    -- otherwise casting Prismatic Bolt left the instance detector blind for the
    -- rest of the pull, and only a plain Arcane Barrage rotation kept working.
    if knownInstance[kind] == nil and anonymousAdds
       and #anonymousAdds.ids == 1 and now - anonymousAdds.at < ANON_ADD_TTL then
        knownInstance[kind] = anonymousAdds.ids[1]
        anonymousAdds = nil
        Debug("%s aura instance relearned as %s (via %s)",
            kind, tostring(knownInstance[kind]), source or "?")
    end

    PruneCredits(kind)
    table.insert(credits[kind], now)
    while #credits[kind] > MAX_GAIN do table.remove(credits[kind], 1) end

    if pendingCast and pendingCast.kind == kind then
        pendingCast = nil
        ConvertLastDryToProc(kind, source)
    else
        -- No tracked cast owns this proc. A signal that may still be waiting for
        -- its cast event is carried forward briefly; a settled one (the Cooldown
        -- Manager path already waited a frame for casts) is not.
        if not settled then carry[kind] = now end
        ResetStreakForAnyGain(kind, source)
        Debug("proc observed with no pending %s cast (via %s) - not attributed", kind, source or "?")
    end
    return true
end

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

----------------------------------------------------------------------
-- Cooldown Manager proc detector
--
-- Stack digits and timestamps are secret in combat, but Blizzard's own Cooldown
-- Manager still has to redraw when your proc changes, and it does that from
-- untainted code. Changes to an aura instance it already tracks run through the
-- item's OnUnitAuraUpdatedEvent; the 0 <-> up transition runs through
-- OnActiveStateChanged. Hooking those tells us a proc landed without ever
-- looking at a value we are not allowed to read - including the case nothing
-- else can see, a proc landing on top of a stack you are already holding.
--
-- The callback is deferred one frame. By then UNIT_SPELLCAST_SUCCEEDED has run,
-- so a pending Arcane Blast marks a gain, and a fresh Arcane Missiles marks a
-- consumption. Direction without a stack count.
--
-- IN-GAME REQUIREMENT: the player must have Blizzard's Cooldown Manager enabled
-- with the proc on one of its bars (Edit Mode -> Cooldown Manager -> Tracked
-- Buffs). If it is off, nothing here can be hooked and the addon falls back to
-- the weaker signals - which is why every use of this is gated on `proven`.
----------------------------------------------------------------------
-- Names taken from a live client by hooking every method on the item and seeing
-- which ones fire. These say "the tracked aura was just applied" outright, with
-- no reading of any value and no inferring from a redraw:
--   OnUnitAuraAddedEvent   the game telling the item its aura appeared
--   TriggerAuraAppliedAlert what plays the Cooldown Manager's buff-gain sound
--   OnAuraInstanceInfoSet  the item being handed the new aura instance
-- Arcane Barrage only, per the rule that a working counter is left alone.
local VIEWER_AURA_METHODS = {
    -- fired for any change to the tracked aura, both counters
    change = { "OnUnitAuraUpdatedEvent", "OnActiveStateChanged" },
    -- "it was applied", said outright. Exactly one method survives here, and the
    -- two that did not are worth naming:
    --   OnAuraInstanceInfoSet   part of the item's ordinary refresh sweep,
    --                           alongside RefreshData and RefreshAuraInstance
    --   OnUnitAuraAddedEvent    named for the event it handles, not for what it
    --                           found: a live log had it firing twice per aura
    --                           update, continuously, while the same Bolt was
    --                           held throughout and no alert ever fired
    -- Both cleared the strike on Barrages that had procced nothing. A method
    -- name is not a promise about what causes the call.
    gain = { "TriggerAuraAppliedAlert" },
    gone = { "TriggerAuraRemovedAlert", "OnAuraInstanceInfoCleared" },
}
local VIEWER_RESCAN  = 5.0   -- items are rebuilt on talent and Edit Mode changes

local function ViewerAuraIDs(kind)
    return (kind == "blast") and CC_AURA_IDS or PB_AURA_IDS
end

-- Which spell ids might the Cooldown Manager have filed this proc under? Buff
-- ids only. Casting ids are deliberately excluded: Prismatic Bolt's cast id
-- belongs to an ability entry, and searching for it is how the detector ended
-- up hooked to the Arcane Blast button instead of the Prismatic Bolt! buff.
local function ViewerLookupIDs(kind)
    -- A copy: the lookup below learns new ids into the very list it is handed,
    -- and growing a table while iterating it is nobody's idea of clear code.
    local out = {}
    for _, id in ipairs(ViewerAuraIDs(kind)) do out[#out + 1] = id end
    return out
end

-- true = the proc is up, false = it is gone, nil = we cannot tell.
-- nil is the important one: if the whole bar is hidden, every item on it is
-- hidden too, and reading that as "no proc" would be worse than saying so.
local function ViewerActive(v)
    if not (v and v.item) then return nil end

    -- First: the Cooldown Manager's own record of whether the tracked aura is
    -- up. It comes from C_CooldownViewer rather than from a frame, so it answers
    -- even when the item neither hides nor calls anything - the state a live log
    -- left the Prismatic Bolt item in. Arcane Barrage only: the Clearcasting
    -- side reports through its callbacks already, and a working counter is not
    -- somewhere to go changing what "the proc is up" means.
    if v.kind == "barrage" and v.cooldownID
       and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local okInfo, has = pcall(function()
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(v.cooldownID)
            -- Written out, because "cond and info.hasAura or nil" turns a
            -- perfectly good false into nil - and false, "the proc is gone", is
            -- the answer this whole function exists to be able to give.
            if type(info) ~= "table" then return nil end
            return info.hasAura
        end)
        if okInfo and has ~= nil and not IsSecret(has) then
            return has and true or false
        end
    end

    local ok, shown = pcall(function()
        if v.owner and v.owner.IsShown and not v.owner:IsShown() then return nil end
        if v.item.IsActive then return v.item:IsActive() end
        if v.item.IsShown then return v.item:IsShown() end
        return nil
    end)
    if not ok or shown == nil or IsSecret(shown) then return nil end
    return shown and true or false
end

-- Is this detector something we may actually rely on? Installed hooks are not
-- enough - Blizzard has to have called one - and the item has to still be
-- readable, so switching the Cooldown Manager off mid-session hands the work
-- back to the fallbacks instead of going quietly blind.
local function ViewerLive(kind)
    local v = viewer[kind]
    if not (v and v.hooked and v.proven) then return false end
    if v.trusted == false then return false end
    return ViewerActive(v) ~= nil
end

-- Could the aura itself show a re-proc? Only if it stacks, or carries a
-- duration that would move. Prismatic Bolt! does neither: one application, and
-- a fresh one on top of it leaves the same instance with the same everything.
-- For a buff like that the Cooldown Manager redraw is the only evidence there
-- is, so a readable aura must not be allowed to veto it.
local function AuraCanShowRefresh(state)
    if not state then return false end
    if (state.stacks or 1) > 1 then return true end
    return (state.expires or 0) > 0
end

local function ObserveViewerProc(kind, source)
    -- Where the aura can express the change, let it own the decision, so a late
    -- redraw cannot count the same proc twice.
    local state, status = ReadAuraAny(ViewerAuraIDs(kind))
    if status == "ok" and AuraCanShowRefresh(state) then
        Debug("%s signal ignored: the aura can show this itself (%s)", kind, source or "?")
        return false
    end
    return OnProcObserved(kind, source, false, true)
end

-- Spending the proc redraws and re-fires everything too. That is only what
-- happened if the spending cast is still the most recent thing we saw: a cast
-- made after it re-opens the window for a genuine new proc.
local function JustSpent(kind)
    local spent = lastConsumedAt[kind] or 0
    return GetTime() - spent < BACK_WINDOW and spent >= (lastCastAt[kind] or 0)
end

local function QueueViewerSignal(kind, item, source, fromHook, isGain)
    local v = viewer[kind]
    if not v or item ~= v.item or v.queued then return end
    v.queued = true

    -- For Arcane Blast, only Blizzard calling one of our hooks counts as proof:
    -- watching the item can never see a second Clearcasting stack land on the
    -- first, so it must not be allowed to retire the fallbacks or clear the
    -- "counting is paused" mark on a counter that abstains for exactly that
    -- reason. Prismatic Bolt does not stack, so for Barrage seeing the item
    -- appear and disappear IS the whole question - and gating it on a callback
    -- that never comes is what took away its "the proc is gone" substitute.
    if (fromHook or kind == "barrage") and not v.proven then
        v.proven = true
        Debug("%s Cooldown Manager detector proven live (%s)", kind, tostring(v.ownerName))
    end

    local function settle()
        v.queued = false
        if item ~= v.item then return end
        v.active = ViewerActive(v)

        -- These two fire on every redraw, so they only speak up when the reason
        -- changes. Otherwise a busy pull buries everything else in the log.
        local function skip(why)
            if v.lastSkip ~= why then
                v.lastSkip = why
                Debug("%s viewer change ignored: %s", kind, why)
            end
        end

        -- A signal that says "applied" outright needs none of the reasoning
        -- below: it is not a redraw to be interpreted, it is the game naming the
        -- event. It also must not be vetoed by the item's own active state,
        -- which on this client is exactly the thing that cannot be trusted.
        if isGain then
            v.wasActive, v.lastSkip = true, nil
            -- Guard against the item reporting an aura it already had, at login
            -- or on entering the world, when no cast of ours could have earned it.
            if GetTime() - lastAnyCast > USABLE_GATE then
                return skip("an aura was applied, but no cast of ours preceded it")
            end
            return ObserveViewerProc(kind, source)
        end

        -- Went from up to gone: that is the proc being spent or expiring.
        if v.active == false then
            v.wasActive = false
            return skip("the proc went away, it did not land")
        end

        -- Came back from nothing. Spending cannot make a proc appear, so this is
        -- a new one however recently the old one was used. This is the fast
        -- Prismatic Bolt -> Arcane Barrage case: the Bolt is spent and a fresh
        -- one lands inside the same breath, and a plain "was it just spent?"
        -- timer threw it away whenever the earning cast had yet to be reported.
        local reappeared = (v.wasActive == false)
        v.wasActive = true

        if not reappeared and JustSpent(kind) then
            return skip("the proc was just spent")
        end
        v.lastSkip = nil

        ObserveViewerProc(kind, source)
    end

    if C_Timer and C_Timer.After then C_Timer.After(0, settle) else settle() end
end

-- Forward declaration: the hooks below fire long after this file has loaded,
-- but they must close over the real local, not a global that never existed.
local NoteViewerActive

local function HookViewerItem(kind, item, state)
    local function hookMethod(owner, method, flag, handler)
        if state[flag] then return end
        local exists = false
        pcall(function() exists = type(owner[method]) == "function" end)
        if not exists then return end
        local ok = pcall(hooksecurefunc, owner, method, handler)
        if ok then state[flag] = true end
    end

    for _, method in ipairs(VIEWER_AURA_METHODS.change) do
        -- Not logged here. These fire several times per aura update, and what
        -- came of one is logged where the decision is made, with the method
        -- named in the source. Whether Blizzard calls them at all is what
        -- /adt status answers.
        hookMethod(item, method, method, function()
            QueueViewerSignal(kind, item, "cooldown-viewer", true)
        end)
    end

    -- The cooldown swipe is deliberately NOT hooked. It restarts for reasons
    -- that have nothing to do with a proc landing, and a live log showed it
    -- firing during a Prismatic Bolt into Arcane Barrage sequence and being
    -- reported against Clearcasting. A buff being reapplied with nothing visible
    -- changing is the aura-instance detector's job, and it does it without
    -- guessing at what a redraw meant.

    -- The proc dropping off is not a proc, but it does retire any credit still
    -- waiting to be spent, and it is what makes the next arrival an arrival.
    local function markGone(changed)
        local v = viewer[kind]
        if changed ~= nil and changed ~= v.item then return end
        v.wasActive = false
        -- The item's own answer is taken only when it agrees that the proc is
        -- gone. Forcing it to false instead would be undone by the next poll on
        -- an item that always reports itself shown, and a false that flips back
        -- to true is indistinguishable from an arrival.
        if ViewerActive(v) == false then v.active = false end
        ExpireCredits(kind, function() return ViewerActive(viewer[kind]) ~= true end)
    end

    hookMethod(item, "OnUnitAuraRemovedEvent", "OnUnitAuraRemovedEvent", markGone)

    -- The methods the game calls to say the aura was applied or removed, rather
    -- than to redraw something. Arcane Barrage only: the Clearcasting counter
    -- reports correctly through the change callbacks above and is left alone.
    if kind == "barrage" then
        for _, method in ipairs(VIEWER_AURA_METHODS.gain) do
            hookMethod(item, method, method, function()
                viewer[kind].alertSeen = true
                QueueViewerSignal(kind, item, "cooldown-viewer:" .. method, true, true)
            end)
        end
        for _, method in ipairs(VIEWER_AURA_METHODS.gone) do
            hookMethod(item, method, method, markGone)
        end
    end

    if not state.scripts and item.HookScript then
        local ok = pcall(function()
            -- The item becoming visible IS the proc arriving. Some items are
            -- shown without OnActiveStateChanged ever being called, so this is
            -- not merely a state note.
            item:HookScript("OnShow", function(shown)
                if shown ~= viewer[kind].item then return end
                NoteViewerActive(kind, ViewerActive(viewer[kind]))
            end)
            item:HookScript("OnHide", markGone)
        end)
        if ok then state.scripts = true end
    end
end

-- Record what the item is showing, and treat hidden -> shown as a proc landing.
--
-- This is the detector that does not depend on Blizzard calling anything. A live
-- log had the Clearcasting item reporting through OnActiveStateChanged while the
-- Prismatic Bolt item, hooked and confirmed on the same bar, stayed silent for
-- the whole sequence - so waiting to be told was never going to be enough.
-- Looking is: the item is hidden while the proc is gone and shown while it is
-- up, and that reads correctly even in the middle of an encounter.
-- Deliberately Arcane Barrage only. The Clearcasting side already reports
-- through Blizzard's callbacks on this client and counts correctly, so it gets
-- no new source of procs: an extra detector on a counter that works can only
-- introduce double counting, never fix anything. Blast still tracks the item's
-- visibility here, it just does not treat it as a proc.
NoteViewerActive = function(kind, active)
    local v = viewer[kind]
    local prev = v.active
    v.active = active

    -- Every change of "is the proc up", logged once per change. This is the line
    -- that separates "the addon never saw the proc" from "it saw it and did not
    -- credit it" - two failures that look identical on screen and need
    -- completely different fixes.
    if active ~= prev then
        Debug("%s proc is %s (Cooldown Manager)", kind,
            active == true and "|cff40ff40UP|r"
            or active == false and "|cffff8080gone|r" or "unreadable")
    end

    if active == false then
        v.wasActive = false
    elseif active == true and prev == false and v.item and kind == "barrage"
           and v.trusted ~= false then
        QueueViewerSignal(kind, v.item, "cooldown-viewer-poll")
    end
end

local function EnsureViewerHook(kind)
    local v, now = viewer[kind], GetTime()

    -- This runs four times a second, so the full lookup is rate limited and the
    -- common path is one cheap look at what the item is currently showing.
    if now < (v.checkedAt or 0) + VIEWER_RESCAN then
        if v.item then NoteViewerActive(kind, ViewerActive(v)) end
        return v.hooked
    end
    v.checkedAt = now

    -- The item is gone: talents changed, or the player pulled the proc off the
    -- tracked set. Forget everything about it rather than keeping a stale frame
    -- that would answer questions it can no longer answer.
    local candidates = ViewerLookupIDs(kind)

    local function forget()
        if v.item then Debug("%s Cooldown Manager item disappeared", kind) end
        if not v.missWarned then
            v.missWarned = true
            Debug("%s has no Cooldown Manager entry (looked for %s)",
                kind, table.concat(candidates, ", "))
        end
        v.item, v.owner, v.ownerName = nil, nil, nil
        v.hooked, v.proven, v.announced, v.active = false, false, false, nil
        for _, spellID in ipairs(candidates) do viewerIDCache[spellID] = nil end
        return false
    end

    if not hooksecurefunc then return forget() end

    local cooldownID
    for _, spellID in ipairs(candidates) do
        cooldownID = ViewerIDForSpell(spellID, ViewerAuraIDs(kind))
        if cooldownID then break end
    end
    if not cooldownID then return forget() end

    local item, owner, ownerName = ViewerItemFor(cooldownID)
    if not item then return forget() end

    -- Two counters must never end up on one item. If that happens the lookup has
    -- gone wrong, and the item's callbacks would all be reported against
    -- whichever kind hooked it first - which is precisely how a Prismatic Bolt
    -- redraw turned up in the log as a Clearcasting proc.
    for otherKind, other in pairs(viewer) do
        if otherKind ~= kind and other.item == item then
            Debug("%s Cooldown Manager lookup landed on the %s item - ignoring it",
                kind, otherKind)
            return forget()
        end
    end

    if item ~= v.item then
        -- A rebuilt item has none of our hooks and has proven nothing yet.
        v.item, v.owner, v.ownerName = item, owner, ownerName
        v.hooked, v.proven, v.announced, v.wasActive = false, false, false, nil
        v.missWarned, v.trusted, v.disagreed = false, nil, 0
    end
    v.cooldownID = cooldownID
    NoteViewerActive(kind, ViewerActive(v))
    if v.wasActive == nil and v.active ~= nil then v.wasActive = v.active end

    local state = hookedViewerItems[item]
    if not state then
        state = {}
        hookedViewerItems[item] = state
    end
    HookViewerItem(kind, item, state)

    v.hooked = state.OnUnitAuraUpdatedEvent == true and state.OnActiveStateChanged == true
    if v.hooked and not v.announced then
        v.announced = true
        Debug("%s Cooldown Manager item hooked (%s)", kind, tostring(ownerName))
    end
    return v.hooked
end

----------------------------------------------------------------------
-- Aura-instance detector
--
-- This is the Clearcasting rule - "the buff was reapplied, so it procced" -
-- taken off the aura payload, which is secret, and onto the one part of it that
-- is not. UNIT_AURA carries an updateInfo table listing the auraInstanceIDs
-- that were added, updated and removed, and auraInstanceID is flagged
-- NeverSecret. So even when every value inside the aura is sealed, the game
-- still tells us "this exact aura instance just changed".
--
-- All we need is to know which instance is ours. That is learned whenever the
-- aura reads normally - out of combat, or any moment secrecy lifts - and from
-- addedAuras when the spell id on it happens to be readable. Once we have it,
-- a reapplication of a buff that neither stacks nor carries a timer, which is
-- exactly Prismatic Bolt!, becomes visible with no Cooldown Manager involved.
----------------------------------------------------------------------
local function QueueInstanceSignal(kind, source)
    if instanceQueued[kind] then return end
    instanceQueued[kind] = true

    local function settle()
        instanceQueued[kind] = nil
        if JustSpent(kind) then
            Debug("%s aura-instance change ignored: the proc was just spent", kind)
            return
        end
        ObserveViewerProc(kind, source)
    end

    if C_Timer and C_Timer.After then C_Timer.After(0, settle) else settle() end
end

-- Reading anything out of a secret payload throws, so every step is wrapped and
-- an unreadable field simply means this detector says nothing.
local function SafeField(tbl, key)
    local ok, value = pcall(function() return tbl[key] end)
    if not ok or value == nil or IsSecret(value) then return nil end
    return value
end

local function InstanceIn(list, wanted)
    if type(list) ~= "table" then return false end
    local found = false
    pcall(function()
        for _, id in ipairs(list) do
            if id == wanted then found = true return end
        end
    end)
    return found
end

local function OnAuraUpdate(updateInfo)
    if type(updateInfo) ~= "table" then return end
    -- A full update carries no instance lists; the ordinary poll handles it.
    if SafeField(updateInfo, "isFullUpdate") == true then return end

    -- New auras sometimes arrive with a readable spell id. That is the cheapest
    -- chance to learn which instance belongs to which proc.
    local added = SafeField(updateInfo, "addedAuras")
    if type(added) == "table" then
        local anon = {}
        pcall(function()
            for _, aura in ipairs(added) do
                local spellID  = SafeField(aura, "spellId")
                local instance = SafeField(aura, "auraInstanceID")
                if instance and not spellID then
                    -- The instance id is readable but the spell it belongs to is
                    -- not. Kept for a moment: if a proc is seen to appear right
                    -- now and this was the only aura added, it must be this one.
                    anon[#anon + 1] = instance
                elseif spellID and instance then
                    for _, kind in ipairs(SHAME_KINDS) do
                        for _, id in ipairs(ViewerAuraIDs(kind)) do
                            if id == spellID then
                                knownInstance[kind] = instance
                                QueueInstanceSignal(kind, "aura-instance-added")
                            end
                        end
                    end
                end
            end
        end)
        -- Only ever replaced by a batch that had something in it. An empty
        -- addedAuras must not wipe this: UNIT_AURA fires constantly in combat
        -- for every buff and debuff on you, so clearing it here threw away the
        -- replacement Bolt's identity before anything had a chance to claim it.
        if #anon > 0 then anonymousAdds = { ids = anon, at = GetTime() } end
    end

    local updated = SafeField(updateInfo, "updatedAuraInstanceIDs")
    local removed = SafeField(updateInfo, "removedAuraInstanceIDs")

    -- Same rule as the Cooldown Manager hook: nothing leans on this detector
    -- until the game has actually handed us one of these lists.
    if not instanceReadable
       and (type(updated) == "table" or type(removed) == "table" or type(added) == "table") then
        instanceReadable = true
        Debug("aura instance lists are readable - the instance detector is live")
    end

    for _, kind in ipairs(SHAME_KINDS) do
        local mine = knownInstance[kind]
        if mine then
            if InstanceIn(removed, mine) then
                knownInstance[kind] = nil
                ExpireCredits(kind, function() return knownInstance[kind] == nil end)
                Debug("%s aura instance %s removed", kind, tostring(mine))
            elseif InstanceIn(updated, mine) then
                -- The instance we hold was changed in place. For Clearcasting
                -- that is another stack; for Prismatic Bolt! it is a fresh Bolt
                -- on top of the one you were saving. Either way: a proc.
                Debug("%s aura instance %s updated - treating as a proc", kind, tostring(mine))
                QueueInstanceSignal(kind, "aura-instance-updated")
            end
        end
    end
end

-- Can we see a proc land *in the situation we are in right now*? Probed fresh,
-- never cached, because this changes the moment you pull a boss. If we can, a
-- later consumption tells us nothing new and must not be used to attribute a
-- proc to a cast.
--
-- The subtlety that matters: usability and the button override only reveal a
-- proc arriving from nothing. Once you already hold the proc, Arcane Missiles is
-- already castable and Arcane Blast is already overridden, so the next one flips
-- nothing. Treating those as "live" unconditionally is what stopped procs from
-- counting while a stack was up. The Cooldown Manager detector is the one that
-- sees that case, so it is checked in between.
local function InstanceLive(kind)
    return instanceReadable and knownInstance[kind] ~= nil
end

DetectionLive = function(kind)
    local _, status = ReadAuraAny(ViewerAuraIDs(kind))
    if status ~= "restricted" then return true end      -- exact stack deltas
    if ViewerLive(kind) then return true end            -- gains on top of a held proc
    if InstanceLive(kind) then return true end          -- ... and so does this

    if kind == "blast" then
        return missilesUsable == false                  -- 0 -> 1 only
    end
    BlastOverride()                                     -- refreshes overrideReadable
    return overrideReadable and lastOverride == nil     -- 0 -> 1 only
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

    -- Spending a proc nothing counted proves one existed - usually gained and
    -- spent inside the same moment, before any detector could report it. That
    -- much is certain; which cast earned it is not, so the fallbacks below only
    -- ever touch the strike unless the evidence is good enough to reclassify.
    local recovered = (source or "consumed") .. "-recovered"

    if DetectionLive(kind) then
        Debug("consumed an unseen %s proc while detection is live - strike only", kind)
        ResetStreakForAnyGain(kind, recovered)
        return
    end

    if kind == "blast" and DB.opts.pauseWhenBlind then
        -- Blast casts made while blind were never counted, so there is nothing
        -- to convert and nothing to guess about.
        Debug("consumed an unseen %s proc while blind, but counting was paused", kind)
        ResetStreakForAnyGain(kind, recovered)
        return
    end

    -- Blind. The proc is real but we never saw it land, so the best available
    -- evidence is which of our tracked spells was cast last. If that was not the
    -- spell this counter is about, stay out of the totals.
    if lastBookedKind ~= kind then
        Debug("consumed an unseen %s proc while blind, but the last tracked cast was %s - strike only",
            kind, tostring(lastBookedKind))
        ResetStreakForAnyGain(kind, recovered)
        return
    end

    Debug("consumed an unseen %s proc while blind (via %s) - attributing it", kind, source or "?")
    ConvertLastDryToProc(kind, source)
end

----------------------------------------------------------------------
-- Aura / override polling
----------------------------------------------------------------------
-- Is this proc up right now according to something that is not the aura API?
-- Arcane Barrage only, for the same reason as the appearance poll above: the
-- Clearcasting side reads "restricted" in combat on this client, so it never
-- reaches the contradiction below, and a counter that works is not somewhere to
-- go changing what "absent" means.
local function ProcLooksUp(kind)
    if kind ~= "barrage" then return false end
    if viewer[kind].trusted == false then return false end
    return ViewerActive(viewer[kind]) == true
end

local function PollAura(key, ids, kind, source)
    local state, status, hitID = ReadAuraAny(ids)
    local via = hitID and ("aura:" .. hitID) or "aura"

    -- Check the Cooldown Manager entry against the truth whenever the truth is
    -- available. Measured on a live client: the Prismatic Bolt entry reported
    -- the proc gone while the aura, readable moments later, had it up the whole
    -- time - so it is not a detector, it is a machine for producing false
    -- negatives. Believing one wipes credits, erases the tracked instance and
    -- convinces the counter it can see, which is worse than having no entry at
    -- all.
    --
    -- Only this direction is judged - the aura holding the proc while the entry
    -- says gone - and only when it persists, because a single frame of the item
    -- not having caught up yet is not a lie. Nothing is hard-coded per counter:
    -- an entry that tells the truth keeps its job.
    if status == "ok" and state ~= nil then
        local v = viewer[kind]
        -- Not "v.item and ViewerActive(v) or nil": that turns the false we are
        -- looking for into nil, and false is the entire point of this check.
        local seen
        if v.item then seen = ViewerActive(v) end
        if seen == false then
            v.disagreed = (v.disagreed or 0) + 1
            if v.disagreed >= 3 and v.trusted ~= false then
                v.trusted = false
                Debug("%s Cooldown Manager entry keeps saying the proc is gone while "
                    .. "the aura is holding it - setting the entry aside", kind)
            end
        elseif seen == true then
            v.disagreed = 0
            if v.trusted == nil then
                v.trusted = true
                Debug("%s Cooldown Manager entry agrees with the aura", kind)
            end
        end
    end

    -- The payload is sealed, but "is it up at all" can still be answered: the
    -- Cooldown Manager hides the item when the proc is gone, and Arcane Missiles
    -- stops being castable when Clearcasting is.
    if state == nil and status == "restricted" then
        if ViewerLive(kind) and viewer[kind].active == false then
            status, via = "absent", "cooldown-viewer"
        elseif kind == "blast" and not ViewerLive(kind) and missilesUsable == false then
            status, via = "absent", "usable-fallback"
        end
    end

    -- The other direction, and the more dangerous one. "Absent" from a
    -- by-spell-id read looks like a real answer, so the addon happily concludes
    -- it can see everything - while in fact it is reading nothing at all, every
    -- cast books as dry and the strike never resets. An independent source
    -- saying the proc IS up outranks that: Arcane Missiles or Prismatic Bolt
    -- being castable, or the Cooldown Manager item showing. Treat the read as
    -- what it is, unreadable, and let the detectors that can see do the work.
    if status == "absent" and ProcLooksUp(kind) then
        status, via = "restricted", "contradicted"
    end

    auraStatus[kind] = status

    -- Whenever the aura can be read at all, remember which instance is ours.
    -- That is what lets the instance detector work later, once it cannot. An
    -- "absent" here includes the substitutes above, and they are trustworthy:
    -- the Cooldown Manager item is hidden, or Arcane Missiles has stopped being
    -- castable. Keeping a stale instance would let the detector claim it can
    -- see a proc that is no longer there to change.
    if state and state.instance then
        knownInstance[kind] = state.instance
    elseif status == "absent" then
        knownInstance[kind] = nil
    end

    -- Still restricted with no substitute: freeze what we last knew. Erasing it
    -- would make regaining sight at 3 stacks look like three fresh procs.
    if status == "restricted" then
        auraBlind[key] = true
        if lastAuraSig[key] ~= "restricted" then
            lastAuraSig[key] = "restricted"
            -- Say why, not just that. "No substitute" has several causes and
            -- they need completely different fixes; this is the line a live log
            -- always contains, so it is the one worth making answer the question.
            local v = viewer[kind]
            Debug("%s aura restricted, no substitute - viewer: item %s, hooked %s, confirmed %s, "
                .. "active %s | castable %s",
                kind, v.item and tostring(v.cooldownID) or "none",
                tostring(v.hooked), tostring(v.proven), tostring(ViewerActive(v)),
                tostring(kind == "blast" and missilesUsable or "n/a"))
        end
        return
    end

    -- First readable poll after a blind stretch. Whatever is there now may have
    -- arrived at any point while we could not look, and the detectors that were
    -- watching have already had their say, so this is a resynchronisation and
    -- not a proc. Counting it here is how sight returning turns into a phantom.
    if auraBlind[key] then
        auraBlind[key] = nil
        auraState[key] = state and {
            present = true, instance = state.instance,
            stacks = state.stacks, expires = state.expires,
        } or { present = false }
        Debug("%s aura readable again - resynchronised without counting", kind)
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
    if override ~= lastOverride then
        Debug("Arcane Blast override %s -> %s",
            tostring(lastOverride), tostring(override))
    end
    if override and override ~= lastOverride then
        if not learnedPBCasts[override] then
            learnedPBCasts[override] = true
            DB.learnedPB[tostring(override)] = true
            Debug("learned Prismatic Bolt cast id: %d (%s)", override, SpellName(override))
        end
        -- The override only ever reveals the Bolt appearing from nothing, which
        -- the other detectors also see - but it is the one signal that needs no
        -- Cooldown Manager and no known aura instance, so it is left switched on
        -- and the duplicate is dropped by the same-instant guard instead.
        if auraStatus.barrage ~= "ok" then
            OnProcObserved("barrage", "override")
        end
    end
    lastOverride = override
end

-- Arcane Missiles usability: the fallback for clients where the Cooldown Manager
-- item does not exist or has never actually called one of our hooks.
local function PollMissilesUsable()
    local usable = ReadUsable(ID.missiles)
    if usable == nil then
        missilesUsable = nil        -- unreadable: this detector is blind
        return
    end

    local prev = missilesUsable
    missilesUsable = usable

    if not ViewerLive("blast") and prev == false and usable == true then
        if GetTime() - lastAnyCast <= USABLE_GATE then
            OnProcObserved("blast", "missiles-usable")
        else
            Debug("Arcane Missiles became usable with no recent cast - ignored")
        end
    elseif prev == true and usable == false then
        ExpireCredits("blast", function() return missilesUsable == false end)
    end
end

-- Prismatic Bolt's castability was tried as a detector and does not work: a live
-- client reported it castable while the Cooldown Manager entry for the buff read
-- active false, moments after the Bolt had been spent. IsSpellUsable answers a
-- different question than "am I holding one", so nothing may lean on it - and
-- while it was wired in, it silently cancelled the Barrage substitute below.

local function PollAll()
    EnsureViewerHook("blast")
    EnsureViewerHook("barrage")
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
    -- Repeated skip reasons are logged once so a busy pull stays readable, but
    -- each new cast starts a new situation worth hearing about again.
    for _, v in pairs(viewer) do v.lastSkip = nil end

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
    elseif pendingCast then
        Debug("cast %d cannot proc Clearcasting - %s keeps its claim", spellID, pendingCast.kind)
    end

    -- Spending a proc is also what stops the Cooldown Manager redraw that follows
    -- from being mistaken for a new one.
    if IsPrismaticCast(spellID) then
        pbCasts = pbCasts + 1
        lastConsumedAt.barrage = GetTime()
        -- Prismatic Bolt! does not stack, so casting it always removes the buff.
        -- Recording that from the cast rather than waiting for the Cooldown
        -- Manager to admit it means the next Bolt is recognised as a fresh
        -- arrival even if the item never reported going away.
        viewer.barrage.wasActive = false
        OnProcConsumed("barrage", "prismatic-bolt-cast")
    elseif spellID == ID.missiles then
        lastConsumedAt.blast = GetTime()
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
        shameOk[kind] = 0
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

-- One line per counter: which engine is doing the work right now, and whether
-- the Cooldown Manager detector - the only one that sees a proc landing on a
-- proc you already hold - is available at all.
local function DetectorLine(kind, label)
    local v = viewer[kind]
    local hook
    if not v.item then
        hook = "|cffff8080no Cooldown Manager item|r"
    elseif not v.hooked then
        hook = "|cffff8080item found, hooks refused|r"
    elseif not v.proven then
        hook = "|cffffcc00hooked, not yet confirmed|r"
    else
        hook = string.format("|cff40ff40live|r on %s, proc up: %s",
            tostring(v.ownerName), tostring(ViewerActive(v)))
    end

    local v2 = viewer[kind]
    if v2.item then
        hook = hook .. string.format(" | cooldownID %s", tostring(v2.cooldownID))
    end

    local instance
    if not instanceReadable then
        instance = "|cffffcc00lists not seen yet|r"
    elseif knownInstance[kind] then
        instance = "|cff40ff40live|r on instance " .. tostring(knownInstance[kind])
    else
        instance = "readable, but this proc's instance is unknown"
    end

    -- Per id, because "absent" and "restricted" mean completely different things
    -- and one id answering where another does not is the normal case.
    local reads = {}
    for _, id in ipairs(ViewerAuraIDs(kind)) do
        local st, why = ReadAura(id)
        table.insert(reads, string.format("%d=%s%s", id, why,
            st and st.stacks and (" x" .. tostring(st.stacks)) or ""))
    end

    local _, status = ReadAuraAny(ViewerAuraIDs(kind))
    print(string.format("   %s: %s", label,
        DetectionLive(kind) and "|cff40ff40counting|r"
                             or "|cffff8080blind -> falling back to consumption|r"))
    print(string.format("      aura: %s (%s) | aura instance: %s",
        status, table.concat(reads, ", "), instance))
    print(string.format("      Cooldown Manager: %s", hook))
end

local function ShowStatus()
    Print("diagnostics:")
    print(string.format("   build interface: %s | spec id: %s (Arcane = %d)",
        tostring(select(4, GetBuildInfo())), tostring(CurrentSpecID()), ARCANE_SPEC_ID))

    for _, key in ipairs({ "blast", "barrage", "missiles", "ccAura", "pbCast", "pbAura" }) do
        print(string.format("   id.%s = %d (%s)", key, ID[key], SpellName(ID[key])))
    end
    local learned = {}
    for id in pairs(learnedPBCasts) do table.insert(learned, id) end
    print(string.format("   learned override cast ids: %s | Blast override now: %s",
        #learned > 0 and table.concat(learned, ", ") or "none", tostring(BlastOverride())))

    print(string.format("   secrecy -> Clearcasting: %s | Prismatic Bolt: %s",
        AuraSecrecy(ID.ccAura), AuraSecrecy(ID.pbAura)))
    if C_Secrets then
        print(string.format("   auras secret globally: %s | secret restrictions: %s",
            TryCall(C_Secrets.ShouldAurasBeSecret), TryCall(C_Secrets.HasSecretRestrictions)))
    end

    DetectorLine("blast", "Arcane Blast / Clearcasting")
    DetectorLine("barrage", "Arcane Barrage / Prismatic Bolt")
    print(string.format("      Arcane Missiles castable: %s | last tracked cast: %s",
        tostring(missilesUsable), tostring(lastBookedKind)))

    local soul, how = SoulActive()
    local now = GetTime()
    local when
    if now < soulFrom then when = string.format("in %.1fs", soulFrom - now)
    elseif now < soulTo then when = string.format("%.1fs left", soulTo - now)
    else when = "not expected" end
    -- "no" on its own read as "the buff is not up" whether or not the option was
    -- even switched on, which is how you end up unsure whether the tick box does
    -- anything. Say which of the two it is.
    local soulState
    if not DB.opts.soulPause then
        soulState = "|cff9d9d9dskipping is off|r"
    elseif soul then
        soulState = "|cff40ff40active - casts and procs are being skipped|r"
                    .. (how and (" (" .. how .. ")") or "")
    else
        soulState = "skipping is on, window not up"
    end
    print(string.format("   Arcane Soul: %s | %s", soulState, when))

    print(string.format("   in fight: %s | chat summary: %s | debug: %s",
        inFight and "yes" or "no",
        DB.opts.reportCombat and "on" or "off",
        DB.opts.debug and "ON" or "off"))

    if not (viewer.blast.proven and viewer.barrage.proven) and not instanceReadable then
        print("   |cffffcc00Tip:|r no detector can see a proc landing on one you already hold. "
            .. "Switch on Blizzard's Cooldown Manager with Clearcasting and Prismatic Bolt on a "
            .. "tracked bar (Edit Mode -> Cooldown Manager -> Tracked Buffs).")
    end
end

-- Everything the Cooldown Manager will tell us about itself, in one paste. When
-- a detector reports "no entry" this is the command that says why: the category
-- it is filed under, whether the frame exists, and what the items think their
-- cooldownIDs are.
local function ProbeViewer()
    Print("Cooldown Manager dump:")
    if not C_CooldownViewer then
        print("   C_CooldownViewer: not present")
        return
    end
    print(string.format("   available: %s", TryCall(C_CooldownViewer.IsCooldownViewerAvailable)))

    local wanted = { [ID.ccAura] = "Clearcasting", [ID.pbAura] = "Prismatic Bolt!",
                     [ID.pbCast] = "Prismatic Bolt (cast)" }
    for _, category in ipairs(VIEWER_CATEGORIES) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category)
        if ok and type(ids) == "table" and #ids > 0 then
            print(string.format("   category %d: %d entries", category, #ids))
            for _, id in ipairs(ids) do
                local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                if ok2 and type(info) == "table" then
                    local spellID = TryCall(function() return info.spellID end)
                    local override = TryCall(function() return info.overrideSpellID end)
                    local linked = {}
                    pcall(function()
                        if type(info.linkedSpellIDs) == "table" then
                            for _, s in ipairs(info.linkedSpellIDs) do
                                table.insert(linked, tostring(s))
                            end
                        end
                    end)
                    local hasAura = TryCall(function() return info.hasAura end)
                    local note = wanted[tonumber(spellID) or -1]
                    -- only print what could matter, or a whole category is noise
                    if note or wanted[tonumber(override) or -1] or #linked > 0 then
                        print(string.format("      id %s -> spell %s%s | override %s | linked %s | hasAura %s",
                            tostring(id), tostring(spellID), note and (" <" .. note .. ">") or "",
                            tostring(override),
                            #linked > 0 and table.concat(linked, ",") or "none",
                            tostring(hasAura)))
                    end
                end
            end
        end
    end

    for _, frameName in ipairs(VIEWER_FRAMES) do
        local parent = _G[frameName]
        if not parent then
            print(string.format("   %s: absent", frameName))
        else
            local shown = TryCall(function() return parent:IsShown() end)
            local okC, children = pcall(function() return { parent:GetChildren() } end)
            local list = {}
            if okC then
                for _, item in ipairs(children) do
                    local cid = TryCall(function()
                        if item.cooldownID ~= nil then return item.cooldownID end
                        if item.GetCooldownID then return item:GetCooldownID() end
                        return nil
                    end)
                    table.insert(list, tostring(cid))
                end
            end
            print(string.format("   %s: shown %s, %d items -> %s", frameName,
                tostring(shown), #list, #list > 0 and table.concat(list, ",") or "none"))
        end
    end

    for _, kind in ipairs(SHAME_KINDS) do
        local v = viewer[kind]
        print(string.format("   %s: cooldownID %s on %s, hooked %s, confirmed %s",
            kind, tostring(v.cooldownID), tostring(v.ownerName),
            tostring(v.hooked), tostring(v.proven)))
    end
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
-- Everything on this list is either something you would want in a macro, or
-- something the settings panel cannot do. Anything that was only a second way to
-- tick a box in the panel has been taken out: the panel is where settings live.
local function ShowHelp()
    Print("commands:")
    print("   |cffffff00/adt|r - open the settings panel (or right-click the window)")
    print("   |cffffff00/adt toggle|r - show / hide the counter window")
    print("   |cffffff00/adt reset|r - clear all counters and history")
    print("   |cffffff00/adt report|r - print your totals (add |cffffff00party|r, |cffffff00raid|r or |cffffff00say|r to send them)")
    print("   |cffffff00/adt setup|r - run the first-time walkthrough again")
    print("   |cffffff00everything else|r - in the settings panel: scale, alert, faces, sounds, history, colours")
    print(" ")
    print("   |cff9d9d9dif something looks wrong:|r")
    print("   |cffffff00/adt status|r - which detector is doing the work, and what it can see")
    print("   |cffffff00/adt probe|r - dump what the Cooldown Manager is tracking")
    print("   |cffffff00/adt scan|r - list your current buffs with their spell ids")
    print("   |cffffff00/adt debug|r - log every cast and proc decision to chat")
    print("   |cffffff00/adt setid pbaura 12345|r - patch a spell id (blast, barrage, missiles, ccaura, pbcast, pbaura)")
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

    elseif cmd == "reset" then
        ResetStats()

    elseif cmd == "report" or cmd == "stats" then
        local channel
        if arg == "party" or arg == "raid" or arg == "say" or arg == "instance_chat" then
            channel = arg:upper()
        end
        ReportTotals(channel)

    elseif cmd == "setup" then
        if ShowSetup then ShowSetup() end

    elseif cmd == "status" then
        ShowStatus()

    elseif cmd == "scan" then
        ScanBuffs()

    elseif cmd == "probe" then
        ProbeViewer()

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
            wipe(auraBlind)
            wipe(viewerIDCache)
            -- a different aura means a different Cooldown Manager item
            for _, v in pairs(viewer) do
                v.item, v.owner, v.ownerName = nil, nil, nil
                v.hooked, v.proven, v.announced, v.checkedAt = false, false, false, 0
            end
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
            -- Skipping the Soul window is now the default, and an existing
            -- profile has the old default written into it, so it needs saying
            -- outright rather than left to CopyDefaults.
            if prevVersion < 5 then DB.opts.soulPause = true end
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

        -- The walkthrough waits: teaching someone to read a window they cannot
        -- see is pointless, so it holds until they are Arcane and out of combat.
        -- MaybeShowSetup is called again on spec change and on leaving combat.
        MaybeShowSetup()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        lastAnyCast = GetTime()      -- gate for the usability signal
        OnCast(spellID)

    elseif event == "UNIT_AURA" then
        -- The payload is mostly secret, but the instance id lists inside it are
        -- not, and they are what reveals a buff being reapplied.
        local _, updateInfo = ...
        OnAuraUpdate(updateInfo)
        PollAll()

    elseif event == "SPELL_UPDATE_USABLE" then
        PollMissilesUsable()

    elseif event == "SPELLS_CHANGED" then
        PollOverride()

    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()
        -- Nobody wants to be dragging frames around during a pull.
        if setupUI.frame and setupUI.frame:IsShown() then
            -- Flagged first: the frame's OnHide reads this to tell "combat took
            -- it away" from "the player is done with it".
            setupUI.interrupted = true
            setupUI.frame:Hide()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
        UpdateShameAll()
        if setupUI.interrupted then
            setupUI.interrupted = nil
            if ShowSetup then ShowSetup() end
        else
            MaybeShowSetup()
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        MaybeShowSetup()
        wipe(auraState)
        wipe(auraBlind)
        wipe(knownInstance)
        -- A fresh world means a fresh look at what this client will hand us. The
        -- flag re-latches on the first aura change that carries readable lists.
        instanceReadable, anonymousAdds = false, nil
        -- A spec or zone change rebuilds the Cooldown Manager, so anything we
        -- learned about its entries has to be looked up again.
        wipe(viewerIDCache)
        for _, v in pairs(viewer) do v.checkedAt = 0 end
        PollAll()
        UpdateDisplay()
    end
end)
