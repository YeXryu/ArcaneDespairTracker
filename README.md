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

In short: track the streak, count the Bolts, watch the face deteriorate, and accept that the
game probably hates you.

## Install

Unpack the `ArcaneDespairTracker` folder into `Interface/AddOns/`, so that
`Interface/AddOns/ArcaneDespairTracker/ArcaneDespairTracker.toc` exists, then restart the
client or `/reload`. Settings are saved per character.

## What you need switched on

**Blizzard's Cooldown Manager, with Clearcasting and Prismatic Bolt on a tracked bar**
(Edit Mode → Cooldown Manager → Tracked Buffs).

Midnight forbids addons the combat log and seals aura data as Secret Values in encounters,
M+ and rated PvP. Blizzard's own Cooldown Manager is still allowed to see through that, so
ADT reads its entries — that is the only signal that can catch a proc landing on a proc you
are already holding, which is exactly what a Prismatic Bolt refresh is.

Without it the addon still runs on weaker signals, but it will stop counting rather than
guess. `/adt status` says which detector is doing the work.

## The window

```
   Arcane Despair Tracker
[i] STRIKE: 3       proc 21.8%
[i] STRIKE: 7        proc 7.7%
[i] CASTS: 12          [RESET]
```

- **STRIKE** — casts in a row with no proc. Green, yellow from 5, orange at the face
  threshold, red past the alert threshold.
- **proc %** — the real proc rate over everything counted since the last reset.
- **?** — that proc cannot be observed right now, so those casts are left out instead of
  guessed at. An honest gap beats a plausible number.
- **CASTS** — Prismatic Bolts cast this fight, with a RESET button.

Hover a row for the longest strike, the totals and this fight's numbers. Left-drag to move it,
right-click for the settings.

## First run

Four short steps: a welcome that names the Cooldown Manager requirement, how to read the
window plus the four choices that change what the numbers mean, faces and sounds with a test
button per counter and everything on screen to drag into place, and a closing page of
commands. It waits until you are Arcane and out of combat, and steps aside if a pull starts.

Closing it by any route records that it has been seen, so an addon update does not bring it
back. **`/adt setup`** runs it again, as does **Run setup again** in the settings.

## Settings

`/adt`, or right-click the window; `Escape` closes it. Three columns covering the window's
appearance, what resets the strike, the faces and their thresholds, sounds and how often they
fire, per-stage sound files, the Prismatic Bolt row, every colour, and buttons for statistics,
fight history and diagnostics. Everything applies immediately — nothing needs a `/reload`.

Defaults worth knowing: counters reset each fight, only a counter's own proc clears its
strike, casts the addon cannot judge are left out, and Barrages cast during Arcane Soul are
skipped — casts and procs alike, since the burst window is a different rotation.

## Commands

Anything that was only a second way to tick a box has been retired; the panel is where
settings live.

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
| `/adt status` | which detector is doing the work, and what each counter can see |
| `/adt probe` | dump what the Cooldown Manager is tracking, and which entry each counter found |
| `/adt scan` | list your current buffs with their spell IDs |
| `/adt debug` | log every cast and proc decision to chat |
| `/adt setid pbaura 12345` | patch a spell ID live, no file editing |

Aliases: `/arcanedespair`, `/despair`.

## When it cannot tell

Clearcasting stacks to three, and Midnight will not let an addon read a stack count in
combat. A fourth proc landing on three stacks changes nothing an addon is allowed to see. ADT
does not pretend otherwise: while a proc is unobservable those casts are marked `?` and left
out of both the strike and the proc rate. Turn **Count casts I cannot judge** on if you would
rather have the bigger, less trustworthy number.

Fight history keeps the last 20 fights with per-fight dry counts and proc rates. A fight is
logged once you have been out of combat for six seconds, so one dungeon pull is one line.

## If something looks wrong

1. **The strike never moves, or the proc rate looks absurd** — `/adt status` should say `live`
   for both counters. `no Cooldown Manager item` means that proc is not on a tracked bar.
2. `/adt probe` — every Cooldown Manager entry that could matter, and which one each counter
   resolved to. This is what answers "why does that counter say it has no entry".
3. `/adt debug`, then cast — every cast, every proc counted, and the reason for anything
   ignored, with the detector that made the call named.
4. `/adt scan` outside an encounter with the buff up gives you the real aura spell ID to feed
   into `/adt setid`.

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

The Prismatic Bolt cast ID is learned automatically from `C_Spell.GetOverrideSpell` and saved
across reloads, so an unknown override still gets counted.

## Notes

- Data is saved per character; every mage keeps its own statistics.
- A Prismatic Bolt cast does not touch the Arcane Blast counter unless you turn on
  **Prismatic Bolt counts as Blast**.
- Totals and streaks never reset by themselves. Only `/adt reset` clears them.
- The addon only runs on a Mage; on any other class it registers no events at all.

## Credits

Written by **iamRudy**, with big thanks to **Viktor**.
