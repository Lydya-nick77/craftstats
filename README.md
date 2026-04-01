# craftstats

An Ashita v4 addon for tracking crafting outcomes, crafting history, and basic craft profitability.

## Features
- Tracks totals and percentages for:
  - Success
  - Break
  - HQ
  - NQ

  - Logs craft history entries with:
    - Timestamp
    - Recipe name / level
    - Effective skill
    - Result (Break/NQ/HQ1/HQ2/HQ3)
    - Craft cost / made item price
    - Lost items on breaks

- Includes item pricing import and merge behavior.

- Displays bonus breakdowns for:
  - Synthesis support
  - Moghancement
  - Gear

## Commands
- `/craftstats` - Toggle the window.
- `/craftstats reset` - Reset current session stats.


## Installation
1. Place the `craftstats` folder in your Ashita `addons` directory.
2. Load in-game with `/addon load craftstats`.

## Data Files
- Stats, history, and prices are persisted as JSON in the addon data path.

## Notes
- This addon is developed against Ashita v4 and may need packet-offset adjustments for different server implementations. This addon is tested for HorizonXI.
- The Bonus from Advance support will display +3, but if the addon is reloaded, it will display +1 after. The reason is both buffs use the same ID and the only way I could differentiate them is with the message when the buff is applied. Reloading the addon reset the check and fallback to +1.