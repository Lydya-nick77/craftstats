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

- Recipes book
  - Recipes per skill and level range
  - List the ingredients needed
  - Show how many ingredients are in inventory

## Commands
- `/craftstats` - Toggle the window.
- `/craftstats reset` - Reset current session stats.
- `/craftstats scale <value>` - Set UI scale (range `0.75` to `2.25`). Example: `/craftstats scale 1.6`
- `/craftstats scale +` - Increase UI scale by `0.10`.
- `/craftstats scale -` - Decrease UI scale by `0.10`.
- `/craftstats scale auto` - Use automatic resolution-based scaling (recommended for 4K).


## Installation
1. Place the `craftstats` folder in your Ashita `addons` directory.
2. Load in-game with `/addon load craftstats`.

## Data Files
- Stats, history, and prices are persisted as JSON in the addon data path.
- UI scale options are persisted per character profile in `config/addons/craftstats/profiles/<Character>/settings.json`.

## Notes
- This addon is developed against Ashita v4 and may need packet-offset adjustments for different server implementations. This addon is tested for HorizonXI.
- The Bonus from Advance support will display +3, but if the addon is reloaded, it will display +1 after. The reason is both buffs use the same ID and the only way I could differentiate them is with the message when the buff is applied. Reloading the addon reset the check and fallback to +1.