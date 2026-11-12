# Changelog

## 0.3.0

- Remove a catch: right-click an item in the panel's loot list (running session) or the zone window's item
  list (that zone, including finished sessions there) to stop it counting toward loot value and gold per hour.
  Asks first; a stack can lose one or all. Casts and catches are kept.

## 0.2.0

First public release.

- Fishing sessions start on your first cast: casts, catches, catch rate, loot value and gold per hour of actual
  fishing time (idle time and logouts are not counted), in a small movable panel in the default UI's look.
- Every catch is valued at its auction price (CraftProfit, Auctionator or TSM, net of the auction house cut) or
  its vendor price when that is higher or no auction price is known.
- Zone window (`/fish zones` or the Zones button): every zone you have fished with its fishing time, gold per
  hour, catch rate, best session, best spots and the items it drops with their drop rate and value.
- Session history (`/fish history`), Fishing skill-ups per session, automatic pause after 5 minutes without a cast.
