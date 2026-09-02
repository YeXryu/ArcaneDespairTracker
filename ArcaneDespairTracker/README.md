# Arcane Despair Tracker (ADT)

Addon for **World of Warcraft: Midnight** (Interface `120100`, patch 12.1.x).

ADT is for Arcane Mages who want to know exactly how long the game can refuse to give them
what they want. It tracks three things:

- **Arcane Blast dry streaks** — how many Blasts in a row fail to proc `Clearcasting`.
- **Arcane Barrage dry streaks** — how many Barrages in a row fail to proc `Prismatic Bolt!`.
- **Prismatic Bolt casts** — how many Bolts you actually cast during a fight.

The goal is not performance analysis. It is despair management.

Each streak gets its own escalating set of faces and sounds. A few unlucky casts are funny.
Then the clown starts looking worried. Then sad. Then you reach the point where there is no
clown left — just suffering.

Both the current streak and lifetime statistics are kept, with optional fight history and
chat summaries, and everything is configurable: thresholds, faces, sounds, sizes, colours and
behaviour. The dry streak resets the moment a proc lands; totals never reset on their own,
only `/adt reset` clears them. Chat output is off by default.

Because Midnight hides parts of your combat data from addons, ADT reads several available
signals instead of the combat log and refuses to guess when a proc cannot be observed. When
the game makes the answer unknowable you get a `?` instead of a number that would be fiction.

In short: track the streak, count the Bolts, watch the face deteriorate, and accept that the
game probably hates you.

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

## Seeing a proc land on a proc you already hold

This is the hard part of the whole addon, and worth a minute of your time.

Since patch 12.0 your own buffs are Secret Values to addons in combat. A proc arriving from
nothing still leaves traces an addon may read — Arcane Missiles becoming castable, Arcane
Blast being replaced on the bars. A proc landing while you are **already holding one** leaves
none of them: Missiles was already castable, the button was already replaced. Clearcasting
going 1 → 2, and a Prismatic Bolt landing on the Bolt you are saving for 12 Arcane Salvo
stacks, are both invisible that way — and between them that is most of your procs.

Two things can still see it, and ADT uses both — with one important caveat, measured on a live
client rather than assumed:

1. **Blizzard's Cooldown Manager.** Its item has to redraw when your proc changes, and it does
   that from untainted code. ADT hooks the item and uses the fact that it redrew — never the
   number on it, which is secret too. This is the one that works today.
2. **The aura instance list on `UNIT_AURA`.** `auraInstanceID` is flagged *NeverSecret*, and
   the event carries lists of which instances were added, updated and removed — so in
   principle an *update* to the instance you are holding is a reapplication, which is exactly
   what a proc is. **In practice a live 12.1 client returned all three lists as unreadable.**
   The detector is implemented, costs nothing, and switches itself on if Blizzard ever opens
   those lists up; until then it reports `lists not seen yet` and stays out of the way.

**What does not work, measured rather than assumed:** asking whether Prismatic Bolt can be
*cast*. Arcane Missiles is only castable while you hold Clearcasting, so it answers for that
proc — but a live client reported Prismatic Bolt castable while the Cooldown Manager entry for
the buff read `active false`, moments after the Bolt had been spent. `IsSpellUsable` answers a
different question there, so nothing leans on it.

**Recommended:** turn on the Cooldown Manager and put Clearcasting and Prismatic Bolt on one
of its tracked bars — Escape → Edit Mode → Cooldown Manager → *Tracked Buffs*. The two
detectors cover slightly different cases, and having both is how the counters stay honest
through a raid pull. When neither is available, ADT drops to signals that only see a proc
arriving from zero and stops counting Arcane Blasts whose outcome it cannot judge (the `?`).

Run **`/adt status`** to see what is actually doing the work:

```
   Arcane Barrage / Prismatic Bolt: counting
      aura: restricted | aura instance: live on instance 41207
      Cooldown Manager: live on BuffIconCooldownViewer, proc up: true
```

`live` is what you want on at least one of those two lines. `lists not seen yet` and
`hooked, not yet confirmed` mean the detector is armed but has had nothing to report — proc
once and they flip. `no Cooldown Manager item` means that proc is not on a tracked bar.

## First run

The first time you log in as an Arcane mage the addon walks you through four short steps:

1. **Welcome** — what it counts, and the one thing it needs from you: Blizzard's Cooldown
   Manager switched on with Clearcasting and Prismatic Bolt on a tracked buff bar.
2. **How you want it counted** — how to read the window, and the four choices that change what
   the numbers mean.
3. **Faces, sounds and where they sit** — with a test button for each counter's escalation,
   and the counter and both faces on screen at once so you can drag them into place in one pass.
4. **That is everything** — the commands worth knowing.

It waits until you are Arcane and out of combat, and it steps aside if a pull starts — teaching
someone to read a window they cannot see is pointless, and asking them to drag frames around
mid-fight is worse. Every window carries the addon's name, and closing it by any route —
finishing it, skipping it, or Escape — records that it has been seen, in the character's saved
variables, so an addon update never brings it back. **`/adt setup`** runs it again, as does
**Run setup again** in the settings panel.

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
  `/adt reset`: both strike counters, the totals, the fight history and this tally. The row and
  the button are independent — switch the row off and the button moves to the last row that is
  showing rather than disappearing with it.
- Every part of a row sits in its own fixed column — the label, the number, the `?` and the
  rate. Going from a strike of 9 to 10 moves the digits and nothing else; no text shuffles
  sideways as the numbers change. The columns are measured from the font once per text size
  and then remembered: a FontString that already has a width answers with *that* width when
  asked how wide its text is, so measuring a column that was already sized feeds on itself and
  creeps inwards a few pixels at a time until the labels read `STRI...`.
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

`/adt` (or right-click the window, `Escape` to close) opens a panel with everything worth
changing: window
visibility, lock, scale, the whole appearance section, what resets the strike, the faces and
their thresholds, the sound and how often it fires, a line per despair stage with See/Hear
buttons, the Prismatic Bolt row, and every colour — plus buttons to place the face, reset
statistics, open the fight history, print diagnostics and toggle debug logging. It is three
columns wide and scales itself down on a short screen. Sliders and checkboxes write straight
to the saved settings, so nothing needs a `/reload`.

## Pausing instead of guessing

Blizzard hides your own buffs from addons in combat. When a proc cannot be observed, the
addon **does not count the cast at all** — a cast it cannot judge tells it nothing, and
counting it would inflate the strike with casts that may well have procced. The grey-green
`?` next to a number means counting is paused for that counter right now.

**This applies to Arcane Blast only.** With either of the two detectors above running there is
almost nothing left to pause for: they see the first stack arrive *and* every proc landing on
top of a stack you already hold. Blast only pauses when the aura, the aura instance list, the
Cooldown Manager and Arcane Missiles usability all fail to answer the question.

**Arcane Barrage always counts.** Pausing it turned out to be actively wrong: you hold Prismatic
Bolt on purpose while Arcane Salvo builds toward 12 stacks, casting Arcane Missiles in the
meantime, and during Arcane Soul you spam Barrage whether or not a Bolt is already sitting
there. Holding the buff is a normal state in that rotation, not a brief blind spot, so pausing
threw the count away for whole burst windows. The Barrage row carries no `?`. It gets the same
two detectors as Blast, so a Bolt re-proccing onto one you are already holding — previously
invisible, and booked as a dry cast — is counted properly.

Turn the Blast behaviour off with **Pause Blast when procs hidden** in the settings if you
would rather have the old guessing.

### What resets the strike

By default, **only a proc the counted spell itself earned** clears the strike — the strict
reading of *"Arcane Blasts that did not proc Clearcasting"*. A Clearcasting off an Arcane
Explosion or an Arcane Orb is recorded but leaves the Blast strike alone.

Switch **Any proc resets the strike** on if you would rather the number answered *"how long
since this proc last showed up"*, whatever caused it.

Either way **the totals and the proc rate never move for a proc nothing earned.** With no
owning cast there is nothing to reclassify, so no dry cast is ever quietly turned into a proc.
The strike is a feel gauge; the percentage is the measurement.

## Arcane Soul

Barrages cast during Arcane Soul are left out of the count. **On by default**: the burst window
is a different rotation, and folding it into the same proc rate flatters or punishes the number
depending on how much of the fight was spent in it. Turn it off in **Skip Barrages in Arcane
Soul** to have those casts judged like any other.

**Casts and procs both.** A Bolt that lands inside the window is not counted either — the casts
that earned it are not in the denominator, so crediting it would clear a strike those casts
never paid for.

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
changes the spell that starts the clock. `/adt status` shows whether skipping is on, whether the window is
up right now, how far off the next one is, and whether the aura is readable.

## The faces

**Each counter has its own set, thresholds, position, sizes and sounds.** At the top of the
**Faces and sounds** column there are two buttons, *Arcane Blast* and *Arcane Barrage*, with
the selected one lit. They choose which counter the rest of that column — sliders, stage list,
sound boxes, the placement buttons — is editing. They do not switch anything on or off.

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

**The face and the sound have separate delays.** A cast and the proc it earned do not always
reach the addon in that order, and a proc can take a moment to become visible at all — so
whatever is still pending when a proc lands is cancelled. The two want different settings
though: a delayed *face* means watching the previous stage sit on screen and then swap, which
reads as a bug, so it defaults to **instant**. A delayed *sound* is simply one a proc gets to
cancel, and that defaults to **0.4 s**. Both are sliders under *Grace after a cast*.

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

**Fight history** in the settings panel opens a window listing the last 20 fights,
newest first:

```
#   When       Length   Blast dry     Barrage dry   Bolts
1   2m ago     1:10     12 / 45  27%   9 / 10  10%   6
2   14m ago    0:48      6 / 22  27%   3 / 5   40%   2
```

Casts with no proc over total casts, the proc rate for each, and how many Prismatic Bolts you
cast in that fight. A fight is only logged once you have been out of combat for six seconds, so
one dungeon pull is one line rather than three. **Clear history** empties the log; the
per-fight counter reset leaves it alone.

## Colours

Every colour the addon draws is editable in the settings panel: the strike number at each
level (calm, warning, clown, alert), the `?` marker and the window title. Clicking a swatch
opens the standard colour picker, and cancelling puts the old colour back.

## Commands

Anything that was only a second way to tick a box in the settings panel has been retired —
the panel is where settings live. What is left is what you would want in a macro, or what the
panel cannot do.

| Command | What it does |
|---|---|
| `/adt` | open the settings panel |
| `/adt toggle` | show / hide the counter window |
| `/adt reset` | clear all counters and history |
| `/adt report` | print your totals (add `party`, `raid`, `say` or `instance_chat` to send them) |
| `/adt setup` | run the first-time walkthrough again |

If something looks wrong:

| Command | What it does |
|---|---|
| `/adt status` | which detector is doing the work, spell IDs, learned override IDs, what each counter can see |
| `/adt probe` | dump what the Cooldown Manager is tracking, and which entry each counter found |
| `/adt scan` | list your current buffs with their spell IDs |
| `/adt debug` | log every cast and proc decision to chat |
| `/adt setid pbaura 12345` | patch a spell ID live, no file editing |

Aliases: `/arcanedespair`, `/despair`.

## Why this is not a combat-log addon

Since **patch 12.0 Blizzard removed the combat log from addons**. Registering
`COMBAT_LOG_EVENT_UNFILTERED` now triggers `ADDON_ACTION_FORBIDDEN`, and on top of that
aura data can be a *Secret Value* during raid encounters, Mythic+ and rated PvP —
`UNIT_AURA` delivers a fully secret payload and the `C_UnitAuras` index/slot APIs raise a
Lua error when addons call them.

So ADT uses these independent signals and never touches the combat log:

| Signal | Source | Used for |
|---|---|---|
| **Casts** | `UNIT_SPELLCAST_SUCCEEDED` (unit-filtered to `player`) | counting Blasts and Barrages |
| **Proc auras** | `C_UnitAuras.GetPlayerAuraBySpellID` on `UNIT_AURA` | detecting a proc the moment it lands |
| **Aura instance lists** | `updateInfo` on `UNIT_AURA` (`auraInstanceID` is NeverSecret) | a buff being reapplied — the proc that leaves no other trace |
| **Button override** | `C_Spell.GetOverrideSpell(Arcane Blast)` | Prismatic Bolt appearing from nothing, with nothing else switched on |
| **Cooldown Manager redraw** | hooks on the viewer item for each proc | the same, through Blizzard's own UI, when the instance is not known |
| **Spell usability** | `C_Spell.IsSpellUsable(Arcane Missiles)` on `SPELL_UPDATE_USABLE` | Clearcasting arriving from zero stacks. Prismatic Bolt was tried the same way and does not answer — see above |
| **Proc consumption** | casting Arcane Missiles / Prismatic Bolt | last resort when everything else is unreadable |

The Cooldown Manager redraw is the important in-combat signal, and both counters use it.
Blizzard routes changes to a tracked aura instance through the item's `OnUnitAuraUpdatedEvent`
and the up/gone transition through `OnActiveStateChanged`, even when the payload and the stack
digit are secret to addons. ADT hooks those, waits one frame so `UNIT_SPELLCAST_SUCCEEDED` has
run, and then reads direction from what is pending: an Arcane Blast still waiting means a gain,
a just-cast Arcane Missiles means a consumption.

**Nothing relies on that hook until Blizzard has actually called it.** Installing a hook proves
nothing — if the client never routes anything through it, an addon that assumed otherwise would
sit there counting every cast as dry at a 0% proc rate and looking perfectly confident about it.
So the detector is only trusted once a callback has fired, and it is dropped again the moment
the item stops being readable (the bar switched off in Edit Mode, the proc pulled off the
tracked set, a talent change rebuilding the item). Until then, and after that, the older
signals do the work.

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
- **A buff that neither stacks nor carries a timer leaves no trace when it re-procs.**
  `Prismatic Bolt!` is one: the same instance, the same single application, no expiry to move.
  Reading the aura, even successfully, tells you nothing. Two things address it: the aura
  instance list reports that exact instance as *updated*, and the addon does not let a readable
  aura veto that signal when the aura demonstrably cannot express the change.
- **Every Cooldown Manager category is searched, not a guessed pair.** The tracked-buff
  category number is not promised to stay put between patches, and an entry the addon cannot
  find is a detector that silently does not exist. The buff-bar restriction below is what keeps
  the wide search safe.
- **Only buff bars, and only by buff id.** The Cooldown Manager also holds *ability* entries,
  and the Arcane Blast entry lists Prismatic Bolt as its override — so looking the Bolt up by
  its cast id matched the Arcane Blast button instead of the `Prismatic Bolt!` buff. That frame
  never hides and redraws on every cooldown, so it reported constantly and against the wrong
  counter. The lookup now searches the buff viewers only, matches on the buff's own id, and
  refuses an item another counter has already claimed. The cooldown swipe is no longer hooked
  at all for the same reason: a redraw is not a proc, and guessing that it was produced
  Clearcasting "procs" during Arcane Barrage sequences.
- **Spending a proc destroys the instance the detector was watching.** The replacement
  arrives in `addedAuras` with its spell id sealed, so there is nothing to match it against,
  and the instance detector would go blind for the rest of the pull — which is what made the
  fast Prismatic Bolt → Arcane Barrage combo miss refreshes while a slower one caught them.
  Whenever a proc is observed and exactly one aura turned up unlabelled in that same moment,
  that instance must be the one that landed, and it is adopted — by whichever detector saw the
  proc, not just one of them. Ambiguous batches are left alone. The pending identity is kept
  until it expires rather than until the next `UNIT_AURA`, because that event fires constantly
  in combat for every buff and debuff on you; clearing it there wiped the replacement Bolt's
  identity before anything could claim it, and cost every later refresh for the rest of the
  pull. That is what made the fast Prismatic Bolt → Arcane Barrage combo miss while a plain
  Barrage rotation kept working.
- **A proc coming back from nothing is never the proc being spent.** Spending cannot make a
  buff appear. So the "was this just consumed?" guard only applies to a signal arriving while
  the proc was already up; an appearance is always counted, even one landing in the same
  breath as the cast that spent the last one.
- **An "absent" aura read that an independent source contradicts is not an answer.** A live
  client returned nothing from `GetPlayerAuraBySpellID` while the secrecy check denied hiding
  anything, so "no buff" and "not allowed to look" were indistinguishable — and believing the
  former is how a counter concludes it can see everything while reading nothing at all: every
  cast books as dry and the strike never resets. Arcane Missiles or Prismatic Bolt being
  castable, or the Cooldown Manager item showing, all outrank it; the read is then treated as
  unreadable and the detectors that can see do the work.
- **A Cooldown Manager entry is checked against the aura, and set aside if it lies.** Measured
  on a live client: the Prismatic Bolt entry reported the proc gone while the aura, readable
  moments later, had been holding it the whole time. That is worse than having no entry at all
  — believing it wipes the counted proc's credit, erases the tracked aura instance, and
  convinces the counter it can see. So whenever the aura is readable it is the truth, and an
  entry that keeps contradicting it is dropped. Nothing is hard-coded per counter: the
  Clearcasting entry agrees with the aura and keeps its job.
- **When a counter is genuinely blind, spending the proc is what proves it existed.** Casting
  Prismatic Bolt with no counted proc on record means one was there, and if the last tracked
  cast was an Arcane Barrage, that Barrage earned it. The strike resets when you spend the
  Bolt rather than when it lands — one cast later than ideal, and exactly how Clearcasting has
  always behaved for Arcane Blast.
- **Nothing is trusted before it has proved itself.** Both of the detectors above are only
  allowed to retire the weaker fallbacks once the game has actually handed them something —
  a hook that was called, a list that was readable. A detector that is installed but silent
  would otherwise look exactly like a detector that is working and seeing no procs, and the
  addon would sit there reporting a 0% proc rate with complete confidence.
- **Sight returning is not a proc.** Secrecy lifts mid-fight and the buff that comes into view
  arrived at some point while nothing could look at it. The first readable poll after a blind
  stretch resynchronises silently instead of counting a gain; otherwise whichever cast happened
  to be pending would be handed a free proc.
- **Liveness is per-situation, not per-API.** A readable aura or a hooked Clearcasting viewer
  can observe every gain. Missiles usability only reveals a proc arriving from nothing, so it
  is not considered sufficient while a stack is already held.
- While blind, the consumption fallback attributes a recovered proc only if the last tracked
  cast was the spell that counter is about. If you cast a Barrage last, a Clearcasting that
  turns up is not credited to Arcane Blast.
- Casting Arcane Missiles with no stored Clearcasting credit proves that a gain was missed,
  usually because the stack was gained and consumed before the Cooldown Manager processed its
  queued update. This resets the Blast streak without changing Blast's proc-rate totals.
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

Every avenue was tested in a live 12.1 client:

| Avenue | Result |
|---|---|
| `applications` via `GetPlayerAuraBySpellID` | `restricted` — the whole aura reads as nothing |
| `GetAuraApplicationDisplayCount` | annotated `SecretWhenUnitAuraRestricted` |
| index / slot / instance getters | Lua error while auras are secret |
| `GetSpellCharges(Arcane Missiles)` | `nil` |
| `IsSpellUsable(Arcane Missiles)` | **readable** — but boolean, so 0 ↔ ≥1 only |
| Cooldown Manager's displayed digit | `item.c3.Applications = "<SECRET>"` |
| Cooldown Manager's aura-instance update | **hookable** — fires when the tracked proc changes |

The displayed digit remains unreadable, but the addon does not need it. ADT hooks the viewer's
aura-instance update, waits for cast events from the same frame to settle, and then uses the
pending spell to distinguish an Arcane Blast gain from an Arcane Missiles consumption.

The WeakAuras team reached the same wall and announced they will not ship a Midnight version,
citing exactly this: your own buffs are hidden from addons.

**What this means in practice.** A proc landing while you already hold one is seen through the
Cooldown Manager redraw. If the Cooldown Manager is switched off, or Blizzard changes how it
works, the Arcane Blast row shows a grey `?` rather than counting casts it cannot judge — and
`/adt status` says so in words.

One useful discovery from the same probing: the Cooldown Manager tracks Clearcasting under spell
**79684**, with 263725 only linked to it. Both are polled now, and any id the Cooldown Manager
turns out to use is learned at runtime.

`/adt status` breaks the state down per counter — whether the aura is readable right now,
whether the Cooldown Manager hook is missing, installed, confirmed or live, and whether the
counter is therefore counting or blind. `/adt debug` then prints every cast and every proc
decision with the reason behind it.

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

0. **The strike never moves, or the proc rate looks absurd** — check the Cooldown Manager
   first. `/adt status` should say `live` for both counters; if it says `no Cooldown Manager
   item`, put Clearcasting and Prismatic Bolt on a tracked bar (see the top of this file).
1. `/adt status` — confirms the spell IDs resolve to the right names, reports whether aura
   reads come back `ok` / `absent` / `restricted`, gives the Secret Value level of each proc
   aura (`NeverSecret` / `AlwaysSecret` / `ContextuallySecret`), and says per counter whether
   the Cooldown Manager hook is missing, installed, confirmed or live. Run it once in the open
   world and once mid-pull — the difference tells you which engine is actually doing the work.
2. `/adt probe` — every Cooldown Manager entry that could matter, which frame holds it, and
   the entry each counter resolved to. This is the command that answers "why does that counter
   say it has no Cooldown Manager entry".
3. `/adt debug` then cast a few spells — every cast, every proc counted, and the reason for
   every cast or signal that was ignored, with the detector that made each call named.
4. `/adt scan` outside an encounter, with the buff up — gives you the real aura spell ID
   to feed into `/adt setid`.

## Changelog

### 6.17.0 — the command list is not a second settings panel

- **Ten slash commands retired.** `stats`, `chat`, `pb`, `anyspec`, `lock`, `scale`, `alert`,
  `history`, `show` and `hide` were each a second way to tick a box or move a slider that the
  panel already owns, and a help screen with nineteen entries hides the five that matter.
  `/adt stats` still answers, as an alias for `/adt report`. Everything else lives in `/adt`.
- **`/adt trace` and the machinery behind it are gone.** It existed to answer one question —
  which Cooldown Manager method Blizzard actually calls when an aura is applied — by hooking
  every function on the item and reporting which ones fired. It answered it
  (`TriggerAuraAppliedAlert`), that answer is now in the code, and a command that installs 250
  hooks is not something to leave lying around afterwards.
- **The debug log is quiet again.** Three lines that fired continuously are gone: one per
  Cooldown Manager callback, one per `UNIT_AURA` payload, one per item `OnShow`. What is left
  is decisions — each cast booked, each proc counted, and the reason for every cast or signal
  that was ignored.
- Help is now in two groups: what you use, and what to run when something looks wrong.

### 6.16.0 — a shorter walkthrough, and Arcane Soul left out by default

- **The walkthrough is four windows instead of six.** The old first two are one welcome page:
  what this counts, the Cooldown Manager requirement (which used to be buried in the *last*
  window, where it was no use to anyone), and a warning about what you have signed up for.
  Faces, sounds and placement are one page instead of two, with a **test button per counter**
  so you can hear each escalation on its own. The last page is the commands and a send-off.
- **Every window carries the addon's name.** A dialog headed only *Faces and sounds* does not
  say who is talking to you.
- **Finishing it sticks.** Closing the walkthrough by *any* route — Finish, Skip, Escape,
  `/reload` — records that it has been seen, in the character's saved variables, which an
  addon update does not touch. Only combat taking it away brings it back. Previously Escape
  recorded nothing and it returned at the next login.
- **Barrages during Arcane Soul are skipped by default**, with a migration that switches it on
  for existing profiles. The burst window is a different rotation, and folding it into the
  same proc rate flatters or punishes the number depending on how much of the fight was spent
  in it.
- **Fixed: a proc landing inside the Soul window was still counted while its casts were not.**
  It cleared a strike those casts never paid for, and could reach back and convert the last
  Barrage from *before* the window into a proc it had not earned. Casts and procs are now
  skipped together or not at all.
- `/adt status` distinguishes *skipping is off* from *skipping is on, window not up*. Both
  used to print `Arcane Soul: no`, which read as "the buff is not up" and made the setting
  look inert.
- Settings credits read **Author: iamRudy — big thanks to Viktor**.

## Notes

- Data is saved per character, so every mage keeps its own statistics.
- A Prismatic Bolt cast does **not** touch the Arcane Blast counter. It replaces Arcane Blast
  on the bars, so if you want it counted as Blast fishing, turn on **Prismatic Bolt counts as
  Blast** in the settings panel.
- **Only a counter's own proc clears its strike, by default.** If the counted spell owns the
  proc, its dry result is converted into a proc in the totals too. Switch **Any proc resets
  the strike** on and a proc from the other spell clears the visible strike as well — the
  totals are left alone either way, so they still describe Arcane Blast and Arcane Barrage
  accurately. A cast
  keeps ownership until another eligible Arcane cast occurs; a proc signal arriving before its
  cast event can be carried forward for 0.25 seconds.
- The totals and the streak never reset by themselves. Only `/adt reset` clears them.
- The addon only runs on a Mage; on any other class it registers no events at all.

## Credits

Written by **iamRudy**, with big thanks to **Viktor**.
