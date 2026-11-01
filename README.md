# FishLog

A small companion for fishing: it starts a session when you cast, counts casts and catches, values
every catch (auction price when a price addon is installed, vendor price otherwise) and shows gold per
hour of actual fishing time in a small movable panel. Finished sessions go into a history you can print
with `/fish history`.

## Install

Download the release zip and extract it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end
up with `...\Interface\AddOns\FishLog\FishLog.toc`. Type `/reload` (or start the game) and make sure FishLog is
enabled in the AddOns list.

No other addon is needed. With **CraftProfit**, **Auctionator** or **TradeSkillMaster** installed, catches are
valued at auction prices instead of vendor prices.

## Using it

1. Cast your line. A session starts on the first Fishing cast (chat: "session started in <zone>") and the
   panel appears. `/fish autostart off` if you prefer to start by hand.
2. Fish. Each cast counts; each fishing loot window counts as a catch and its items are added to the list.
3. Stop with the **Stop** button or `/fish stop`. The summary is printed and the session is saved to history.

The panel (drag it anywhere, `/fish lock` to pin it) is built from the default UI's own frame templates, so
it looks like any other small Blizzard window:

| Part | Meaning |
|---|---|
| Title bar | "FishLog" and the standard close button |
| Zone line | where the session started (more zones are listed as you move) |
| Status line | Running (green), Paused (gold) or the last session's numbers (gray); active fishing time at the right (pauses are not counted) |
| Casts | Fishing casts this session |
| Catches | loot windows from fishing, with the catch rate in green |
| Loot value | sum of every catch (`+N?` = items whose price is not known yet) |
| Gold / hour | loot value / active time, shown once a minute has passed |
| Fishing skill row | current skill, points gained this session in green |
| Loot list | items sorted by total value: name, `xN` count, value (`v` = vendor-priced); hover for the tooltip |

Buttons: **Start / Stop**, **Pause / Resume**, **Reset** (discard the running session without saving it),
**Zones** (the zone window below).

### Zone window

`/fish zones` or the **Zones** button. Left: every zone you have fished, with total fishing time and gold per
hour (click **Zone**, **Time** or **Gold/h** to sort; the zone you are fishing now is green). Click a zone to see:

| Part | Meaning |
|---|---|
| Sessions, last fished | how many sessions fished there, and when (or "fishing here now") |
| Fishing time | active time in the zone, pauses and travel excluded |
| Gold / hour | loot value / fishing time in the zone |
| Loot value | every item looted there at **current** prices, plus coin (`+N?` = items with no known price yet) |
| Catches | fishing loot windows there, with the catch rate (catches / casts) |
| Catches / hour, Per catch | catch speed and average value of one catch |
| Best session | best gold / hour of one session that fished 10+ minutes there (valued when it ended) |
| Fishing skill | skill range you had while fishing there |
| Coin looted, Best spots | coin from fishing loot; the subzones with the most catches |
| Item list | Item, Count (quantity), Drop (share of catches that had it), Value (count x current price, `v` = vendor) |

The running session is included live. Totals are lifetime (not limited to the 50 history records). Sessions
from before v0.2.0 are rebuilt from the history once: those list only their top 15 items, and the window says so.
`/fish zones <name>` opens a zone directly (prefix match), `/fish zones forget <zone>` deletes its totals.

### Idle pausing

When you stop casting for 5 minutes the session pauses itself and credits only the time up to your last
cast or catch (plus 20 seconds). The next cast resumes it. `/fish idle <minutes>` changes the limit,
`/fish idle 0` turns it off. A session left running over a logout is treated the same way at login, so
time away from the game never inflates the hour count.

### Values

Order tried for an auction price: CraftProfit (which itself resolves Auctionator / TSM / its own scan),
then Auctionator, then TSM. When none is installed or the item is unknown to them, the vendor sell price
is used; the vendor price also wins when it is higher than the auction price. Auction prices are shown
net of the 5% auction house cut (`/fish cut off`, `/fish cut 10` to change it). `/fish source vendor`
forces vendor prices only.

### Slash commands

```
/fish                    toggle the panel
/fish start|stop|pause|resume|reset
/fish status             session numbers, event counters (for debugging), price source, saved-variable state
/fish history [n]        last n finished sessions
/fish zones [zone]       zone window (optionally opened on a zone)
/fish zones forget <zone>  delete a zone's saved totals
/fish zones demo         preview the zone window with made-up zones (toggle, never saved)
/fish autostart on|off   start on the first cast (default on)
/fish idle <minutes>     idle pause (default 5, 0 = never)
/fish cut on|off|<pct>   auction house cut applied to AH values (default on, 5%)
/fish source auto|craftprofit|auctionator|tsm|vendor
/fish rows <n>           loot lines in the panel (default 10)
/fish lock|unlock        panel dragging
/fish debug              debug chat lines (prints every channelled spell ID and every loot line)
```

## Notes for the WoW Forever beta

- Forever is in beta and its API can change between builds. If something breaks after a patch, report it with
  the output of `/fish status`.

## Help, bugs and ideas

Discord: https://discord.gg/hbJXz7qqpJ (#addon-help, #bug-reports, #suggestions).

## License

MIT. Made by Vystery.
