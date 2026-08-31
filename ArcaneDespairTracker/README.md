# Arcane Despair Tracker (ADT)

Addon for **World of Warcraft: Midnight** (Interface `120100`, patch 12.1.x).

Counts two things:

1. **Arcane Blast without a Clearcasting proc** — how many Blasts in a row (and in total) failed to proc `Clearcasting`.
2. **Arcane Barrage without a Prismatic Bolt proc** — how many Barrages in a row (and in total) failed to proc `Prismatic Bolt!`.

The dry streak resets the moment a proc lands. Totals never reset on their own —
only `/adt reset` clears them. Chat output is **off by default**; turn the after-fight
summary on with `/adt chat`.

## Install

1. Unpack the `ArcaneDespairTracker` folder into:
   - Windows: `World of Warcraft\_retail_\Interface\AddOns\`
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
2. The result must look like this:
   ```
   Interface/AddOns/ArcaneDespairTracker/ArcaneDespairTracker.toc
   Interface/AddOns/ArcaneDespairTracker/Core.lua
   ```
3. Restart the client (or `/reload` if it was already running).

## The window

```
   Arcane Despair Tracker
[i] STRIKE: 3       proc 21.8%
[i] STRIKE: 7        proc 7.7%
[i] CASTS: 12          [RESET]
```

Roughly 212 x 96 px by default, and every part of that is a setting.

- **STRIKE** is the current run of casts with no proc. Green, yellow from 5, orange at the
  clown threshold, red past the alert threshold. A `?` after the Arcane Blast number means
  Clearcasting cannot be seen right now and casts are not being counted — see below.
- **proc** is the real proc rate over everything counted since the last reset.
- Everything else — longest strike, casts with no proc, this fight's numbers — is in the
  **tooltip**. Hover a row; the tooltip anchors to that row and flips side near a screen edge.
- Counters clear at the start of every fight by default (**Reset everything each fight**);
  turn it off for running totals across a session. The fight log is kept either way.
- The third row is a plain tally of **Prismatic Bolts cast this fight** — no procs involved, so
  a small **RESET** button sits where the rate would be. It is a full reset, the same as
  `/adt reset`: both strike counters, the totals, the fight history and this tally. Both the row
  and the button can be switched off.
- **Left-drag** to move, **right-click** for the settings panel.

## Making it yours

The frame is not a fixed layout — it is recomputed from the settings every time one changes,
so nothing needs a `/reload`:

- **Title bar**, **Background** and **Border** are independent toggles. Turn all three off and
  you get a bare readout: icons and numbers, nothing else.
- **Background opacity** from fully transparent to solid.
- **Width**, **Icon size**, **Text size** and **Title size** in pixels, plus overall
  **Window scale** on top.
- Turning the title off leaves nothing obvious to grab, so the rows themselves drag the frame
  too — left-drag anywhere on it, right-click anywhere for the settings.

## Settings panel

`/adt` (or right-click the window) opens a panel with everything worth changing: window
visibility, lock, scale, the whole appearance section, the faces and their thresholds, the
sound and how often it fires, a line per despair stage with See/Hear buttons, the Prismatic
Bolt row, and every colour — plus buttons to place the face, reset statistics and print
diagnostics. It is three columns wide and scales itself down on a short screen. Sliders and
checkboxes write straight to the saved settings, so nothing needs a `/reload`.

## Pausing instead of guessing

Blizzard hides your own buffs from addons in combat. When a proc cannot be observed, the
addon **does not count the cast at all** — a cast it cannot judge tells it nothing, and
counting it would inflate the strike with casts that may well have procced. The grey-green
`?` next to a number means counting is paused for that counter right now.

**This applies to Arcane Blast only.** Blast pauses while the Clearcasting aura is secret and a
stack is already held, because a second stack changes nothing observable — with no stack held,
`IsSpellUsable(Arcane Missiles)` flipping still reveals the proc.

**Arcane Barrage always counts.** Pausing it turned out to be actively wrong: you hold Prismatic
Bolt on purpose while Arcane Salvo builds toward 12 stacks, casting Arcane Missiles in the
meantime, and during Arcane Soul you spam Barrage whether or not a Bolt is already sitting
there. Holding the buff is a normal state in that rotation, not a brief blind spot, so pausing
threw the count away for whole burst windows. A re-proc landing on a Bolt you are already
holding is invisible and that cast is booked as dry — an occasional undercount of procs is a
far smaller error than not counting at all. The Barrage row carries no `?`.

Turn the Blast behaviour off with **Pause Blast when procs hidden** in the settings if you
would rather have the old guessing.

## Arcane Soul

Optionally, Barrages cast during Arcane Soul can be left out of the count. **Off by default**,
because those casts can still proc — Arcane Salvo keeps building with every Barrage up to 25
stacks either way. It is there for anyone who would rather judge their luck outside the burst
window, not because the casts are somehow dead.

**Only the 4 s Soul window is skipped.** Arcane Soul lands a fixed 17.4 s after Arcane Surge,
so the timeline is:

```
Arcane Surge cast
|<-------------- 17.4s, counts as normal -------------->|<-- 4s, skipped -->|
```

The whole wait between the Surge and Soul landing is ordinary play and keeps counting — only
the four seconds Soul is actually up are left out.

The buff is an aura, so it is secret in combat like everything else. It is read when readable,
and otherwise placed from the cast, which is always visible — the fixed 17.4 s means no
guessing at where the window sits. Both numbers are sliders, and `/adt setid soultrigger <id>`
changes the spell that starts the clock. `/adt status` shows whether Soul is active, how far
off the next window is, and whether the aura is readable.

## The faces

**Each counter has its own set, thresholds, position, sizes and sounds.** The settings panel
has an **Editing: Arcane Blast / Arcane Barrage** button at the top of the Faces column that
switches the whole section — sliders, stage list and sound boxes — between the two.

### Arcane Blast — Clearcasting

From a strike of **3**, at 60 px, **growing 12 px a cast**, a new face every cast:

| Stage | Face | Sound |
|---|---|---|
| 1 | smug clown | bike horn |
| 2 | worried | slide whistle taking a dive |
| 3 | sad | sad trombone |
| 4 | openly crying — eyes squeezed shut, tears streaming, mouth wide | solo violin, minor and sorry for itself |
| 5 | nothing left — hollow eyes, heavy lids, one tear that never dried | funeral bell over a sub drop |

Stages 1-3 keep the clown; 4 and 5 drop it, because by then it is not funny any more.

### Arcane Barrage — Prismatic Bolt

An arcane-purple set of its own, so a glance tells you which counter is falling apart. From a
strike of **6**, a new face every **2** casts, and it starts on the other side of the screen:

| Stage | Face | Sound |
|---|---|---|
| 1 | confident, crystal shards intact | two flat blips |
| 2 | doubting | music box dying |
| 3 | pleading | sad trombone |
| 4 | sobbing | empty-room piano |
| 5 | shattered, cracks across the face | crystal breaking |

The shards floating around the head thin out stage by stage and are gone by the last one.

Four more ship unused, for when you want something bleaker — point a stage at
`x-flatline.ogg`, `x-empty-room-piano.ogg`, `x-rain-thunder.ogg` or `x-music-box.ogg`.

### Licensing

Every face and every sound here was **drawn and synthesised for this addon** and is released
under **CC0** — public domain, use them anywhere, no attribution needed. They are originals in
the spirit of the usual internet fare, not the recordings and images themselves, which are not
mine to redistribute.

If you would rather use someone else's royalty-free audio, drop it in yourself:
**freesound.org** filtered to CC0, **pixabay.com/sound-effects**, and **opengameart.org** all
carry usable material. Convert to `.ogg`, put it in `Media/`, and point the settings at it —
there is a per-stage override, so you can give each of the five its own file.

**A proc wipes the slate.** The face disappears the instant a proc lands and the escalation
starts again from stage one, rather than picking up where it left off.

**The face also goes away when the strike stops being real.** Clearcasting can proc off anything you
cast, so a Blast counter that is standing still is not a dry streak any more — the face hides
**3 seconds** after the last counted Arcane Blast, and comes back on the next one. Without that
it just sat on screen forever.

Drag it anywhere with the left mouse button; **Place face** in the settings pins it on screen
so you can position it before you ever hit a dry streak, and **Re-centre** puts it back.
Threshold, despair step, base size, growth and the hide delay are all sliders.

### The stage list

The settings panel gives every stage its own block: the face, the strike it starts at, how big
it will be on screen at that point, **See** / **Hear** buttons, and a box for the sound file.

That box is the only place sounds are chosen. **Leave it empty and the stage plays its own
file** — the grey line inside the box tells you which. Paste a path to override it, or type
`none` to silence that one stage while the others keep going. Hovering the box lists every file
that ships with the addon, so you do not have to go digging for the names. **Preview them all** walks through the whole escalation, face and sound together, one stage
every 3.6 s — the longest built-in sound runs about 3.5 s, so a faster pace would cut each one
off before you had heard it. The numbers on each line update live as you move the sliders.

Paths look like `Interface\AddOns\ArcaneDespairTracker\Media\mine.ogg`. WoW only plays
`.ogg` and `.mp3` from addons, so a `.wav` will not work. To swap a face, keep the
format: **uncompressed .tga, power-of-two dimensions** (the shipped ones are 64×64). WoW does
not load PNG from addons.

## Fight history

**Fight history** in the settings (or `/adt history`) opens a window listing the last 20
fights, newest first:

```
#   When       Length   Blast dry     Barrage dry   Bolts
1   2m ago     1:10     12 / 45  27%   9 / 10  10%   6
2   14m ago    0:48      6 / 22  27%   3 / 5   40%   2
```

Casts with no proc over total casts, the proc rate for each, and how many Prismatic Bolts you
cast in that fight. A fight is only logged once you have been out of combat for six seconds, so
one dungeon pull is one line rather than three. **Clear history** empties the log; the
per-fight counter reset leaves it alone.

`/adt history chat` still prints the short version into chat if you prefer it there.

## Colours

Every colour the addon draws is editable in the settings panel: the strike number at each
level (calm, warning, clown, alert), the `?` marker and the window title. Clicking a swatch
opens the standard colour picker, and cancelling puts the old colour back.

## Commands

| Command | What it does |
|---|---|
| `/adt` | open the settings panel |
| `/adt toggle` | show / hide the counter window |
| `/adt stats` | print totals |
| `/adt reset` | clear all counters and history |
| `/adt chat` | after-fight summary in chat — **off by default** |
| `/adt report party` | send totals to chat (`party`, `raid`, `say`, `instance_chat`) |
| `/adt history` | last 20 fights |
| `/adt lock` | lock / unlock dragging |
| `/adt scale 1.2` | window scale (0.5 – 2.0) |
| `/adt alert 10` | on-screen warning at a strike of 10 (`0` = off) |
| `/adt pb` | count a **Prismatic Bolt** cast as an Arcane Blast cast — **off by default** |
| `/adt anyspec` | show the window outside Arcane spec |
| `/adt status` | diagnostics: spell IDs, aura readability, learned override IDs |
| `/adt scan` | list your current buffs with their spell IDs |
| `/adt probe` | dump every avenue for reading a Clearcasting stack count |
| `/adt debug` | log every cast and proc to chat |
| `/adt setid pbaura 12345` | patch a spell ID live, no file editing |

Aliases: `/arcanedespair`, `/despair`.

## Why this is not a combat-log addon

Since **patch 12.0 Blizzard removed the combat log from addons**. Registering
`COMBAT_LOG_EVENT_UNFILTERED` now triggers `ADDON_ACTION_FORBIDDEN`, and on top of that
aura data can be a *Secret Value* during raid encounters, Mythic+ and rated PvP —
`UNIT_AURA` delivers a fully secret payload and the `C_UnitAuras` index/slot APIs raise a
Lua error when addons call them.

So ADT uses five independent signals and never touches the combat log:

| Signal | Source | Used for |
|---|---|---|
| **Casts** | `UNIT_SPELLCAST_SUCCEEDED` (unit-filtered to `player`) | counting Blasts and Barrages |
| **Proc auras** | `C_UnitAuras.GetPlayerAuraBySpellID` on `UNIT_AURA` | detecting a proc the moment it lands |
| **Spell usability** | `C_Spell.IsSpellUsable(Arcane Missiles)` on `SPELL_UPDATE_USABLE` | Clearcasting arriving from zero stacks |
| **Button override** | `C_Spell.GetOverrideSpell(Arcane Blast)` | Prismatic Bolt replacing Arcane Blast |
| **Proc consumption** | casting Arcane Missiles / Prismatic Bolt | last resort when everything else is unreadable |

The usability signal is the important one. Aura data is a *Secret Value* during combat, so
the aura engine can be blind exactly when you need it — but **Arcane Missiles is only
castable while you hold Clearcasting**, and `IsSpellUsable` is marked `AllowedWhenTainted`
and carries no secrecy annotation. So the moment Missiles becomes castable, Clearcasting
procced. That flip only counts as a proc if a cast happened in the last 1.2 s, which keeps
target swaps and mana changes from firing it.

Details that matter:

- **Clearcasting stacks (up to 3), so "is the buff up?" is not enough.** Each poll compares
  `auraInstanceID` (flagged **NeverSecret** by Blizzard), the stack count and the expiry time.
  A new stack on an existing buff, and a refresh at max stacks, both count as a fresh proc.
  Missing this was the bug that made the streak keep climbing through visible procs — and it
  also inflated the proc rate, because every Arcane Missiles cast with no matching proc on
  record was booked as a proc of its own.
- **At 3 of 3 stacks, a moved expiry time is the only evidence a proc happened.**
  `applications` cannot go to 4, so the stack comparison sees nothing.
  `expirationTime` is an absolute timestamp — it stays put while the buff ticks down — so any
  rise at all means reapplication. The tolerance is 0.05 s, not something generous: a proc
  landing a second after the buff went up only moves the expiry by about a second, and an
  earlier 0.5 s guard silently swallowed exactly those.
- Every aura read goes through `pcall` plus an `issecretvalue` test, so a secret value can
  never throw a Lua error into your UI.
- **Liveness is per-situation, not per-API.** The usability and override detectors only reveal
  a proc arriving from nothing: once you already hold a Clearcasting stack, Arcane Missiles is
  already castable, so a second stack flips nothing. Only reading the aura can see 1 → 2. So
  the addon counts itself blind whenever the aura is secret *and* a stack is already held —
  treating those detectors as live unconditionally is what stopped procs from counting when a
  stack was up, because it suppressed the one fallback that could still have found them.
- While blind, the consumption fallback attributes a recovered proc only if the last tracked
  cast was the spell that counter is about. If you cast a Barrage last, a Clearcasting that
  turns up is not credited to Arcane Blast.
- The engines are de-duplicated two ways: signals landing within 150 ms of each other are
  treated as one proc, and a counted-but-unconsumed proc holds a "credit" that the later
  consuming cast spends instead of counting again. Credits are dropped 0.5 s after the proc
  resource is seen to be gone — without that, a Clearcasting that expired unused would
  silently swallow the next real proc.
- Bookkeeping invariant: `casts == procs + dry`, always. The test suite asserts it after
  every scenario.
- A fight is not "one combat flag". Dropping combat between packs in a dungeon does not end
  the fight — it takes **6 seconds out of combat** for a fight to be finalised, so one pull
  produces one history entry instead of three.

### Attribution is ordered, not timed

A cast keeps its claim on the next proc **until the next Arcane cast is made** — there is no
wall-clock window. This matters because aura secrecy flips on and off mid-fight, so a proc
can only become visible a second after the cast that earned it. A timed window would drop
those; ordering does not, and it still refuses to credit a proc to an Arcane Blast when
another Arcane spell was cast in between.

Only spells that can actually proc Clearcasting break the claim. Trinkets fire as casts too
(`Light's Potential` and friends turn up in the cast stream), and letting those end the claim
threw away procs that belonged to the Blast right before them.

### Aura secrecy flips mid-fight, and nothing announces it

`ShouldAurasBeSecret()` goes true and false repeatedly during a single pull. Two consequences
the addon has to handle:

- A restricted read is **not** the same as "no buff", even though both come back as nothing.
  `C_Secrets.ShouldSpellAuraBeSecret` tells them apart, so while restricted the last known
  stack count is frozen rather than erased. Without that, regaining sight at 3 stacks would
  read as three fresh procs.
- The game fires **no event** when secrecy lifts, so a 0.25 s ticker is what notices. That is
  also what recovers a stack-up that happened while blind: if no cast intervened, the proc is
  still attributed to the Blast that earned it.

### The stack count is unreadable in combat — measured, not assumed

Every avenue was tested in a live 12.1 client with `/adt probe`:

| Avenue | Result |
|---|---|
| `applications` via `GetPlayerAuraBySpellID` | `restricted` — the whole aura reads as nothing |
| `GetAuraApplicationDisplayCount` | annotated `SecretWhenUnitAuraRestricted` |
| index / slot / instance getters | Lua error while auras are secret |
| `GetSpellCharges(Arcane Missiles)` | `nil` |
| `IsSpellUsable(Arcane Missiles)` | **readable** — but boolean, so 0 ↔ ≥1 only |
| Cooldown Manager's displayed digit | `item.c3.Applications = "<SECRET>"` |

That last one was the promising idea: Blizzard's own Cooldown Manager draws the stack count
from untainted code, and `C_CooldownViewer` carries no secrecy annotation. But the FontString
it draws into holds a Secret Value, so `GetText()` gives a secret, not a number. The lookup
code is kept for `/adt probe` and wiring it back in is two lines if Blizzard ever unseals it.

The WeakAuras team reached the same wall and announced they will not ship a Midnight version,
citing exactly this: your own buffs are hidden from addons.

**What this means in practice.** A Clearcasting proc landing while you already hold a stack is
not observable at the moment it happens. It is recovered when you spend the stacks — each
Arcane Missiles cast beyond the procs already counted reveals one that was missed — or when
you leave combat and the aura becomes readable again. When a counter is in that state the
window shows a grey `?` after the number, because a count that cannot see procs is too high,
and it should say so rather than look certain.

One useful discovery from the same probe: the Cooldown Manager tracks Clearcasting under spell
**79684**, with 263725 only linked to it. Both are polled now, and any id the Cooldown Manager
turns out to use is learned at runtime.

`/adt status` breaks the state down per detector — whether each aura is readable right now,
whether a stack is held, whether each counter is therefore live or blind, and which spell was
tracked last. `/adt debug` then prints every cast and every proc decision with its reason.

## Spell IDs (patch 12.1)

| Spell | ID | Key for `/adt setid` |
|---|---|---|
| Arcane Blast | 30451 | `blast` |
| Arcane Barrage | 44425 | `barrage` |
| Arcane Missiles | 5143 | `missiles` |
| Clearcasting (player buff) | 263725 | `ccaura` |
| Clearcasting (as the Cooldown Manager tracks it) | 79684 | — |
| Prismatic Bolt (the cast that replaces Arcane Blast) | 1295924 | `pbcast` |
| Prismatic Bolt! (the proc buff) | 1295942 | `pbaura` |

If a patch changes any of these, `/adt setid <key> <id>` fixes it without touching files.
1295923 (the PTR value) is also accepted. The Prismatic Bolt cast ID is **learned automatically** from
`C_Spell.GetOverrideSpell` and saved across reloads, so an unknown override still gets counted.

## If something looks wrong

1. `/adt status` — confirms the spell IDs resolve to the right names, reports whether aura
   reads come back `ok` / `absent` / `restricted`, gives the Secret Value level of each proc
   aura (`NeverSecret` / `AlwaysSecret` / `ContextuallySecret`) and shows whether the
   usability signal is readable. Run it once in the open world and once mid-pull — the
   difference tells you which engine is actually doing the work.
2. `/adt debug` then cast a few spells — every cast ID and every proc decision is printed.
3. `/adt scan` outside an encounter, with the buff up — gives you the real aura spell ID
   to feed into `/adt setid`.

## Notes

- Data is saved per character, so every mage keeps its own statistics.
- A Prismatic Bolt cast does **not** touch the Arcane Blast counter. It replaces Arcane Blast
  on the bars, so if you want it counted as Blast fishing, turn it on with `/adt pb`.
- **Only a proc an Arcane Blast actually earned resets the Blast streak.** Clearcasting can
  also proc off a Barrage or a Prismatic Bolt; those are recorded but deliberately ignored
  here, because the counter means "Arcane Blasts that did not proc Clearcasting". A proc is
  attributed to a cast only if it lands within 0.6 s of it (or 0.25 s before, when the event
  order is reversed).
- The totals and the streak never reset by themselves. Only `/adt reset` clears them.
- The addon only runs on a Mage; on any other class it registers no events at all.
