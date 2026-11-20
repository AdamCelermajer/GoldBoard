# Gold Board

A gold-making companion for **WoW Forever**, in two parts that work together:

- **`GoldBoard/`** is the in-game addon. It records your gold over time, every auction house buy, sale, post, cancel and expiry, and a copy of each Auctionator full scan. It shows the dashboard's signals in item tooltips ("sells for", "buy below", trend, what you paid for the ones you hold) and in a small panel beside the auction house.
- **`board/`** runs on your PC. Every few hours it downloads TradeSkillMaster's free public price files for your auction houses, keeps every version, and builds a local dashboard: deals, price history per item, cheap and expensive hours, your ledger and holdings. It writes the signals the addon shows in game.

```
 In game                                    On your PC
┌────────────────────────┐  saved file   ┌──────────────────────────┐
│ GoldBoard addon        │ ────────────▶ │ board: dashboard         │
│ gold, buys, sales,     │  (/reload or  │ ledger, profit, holdings │
│ Auctionator scans      │   logout)     │ + TSM prices and history │
│                        │ ◀──────────── │                          │
│ tooltips, AH panel     │ SignalsData   │ writes buy below/sell at │
└────────────────────────┘  .lua         └──────────────────────────┘
```

Nothing here buys, posts or clicks for you: you trade with Auctionator as usual.

## Install

**Addon:** copy the `GoldBoard` folder into `World of Warcraft\_forever_\Interface\AddOns\`. It works on its own; with **Auctionator** it also records posts and full scans, and with **Syndicator** (comes with Baganator) it knows how many of an item you hold across characters.

**Dashboard** (Windows, needs [Node.js](https://nodejs.org) 18 or newer, no other packages):

1. Copy the `board` folder anywhere on your PC.
2. Pick your auction houses: edit `SOURCES` at the top of `board/collect.js`. The ids are the ones in the address bar of your realm's page on tradeskillmaster.com (for example `forever/eu/roleplay-alliance`). The ones shipped are EU Roleplay-Alliance and Normal-Alliance plus EU-wide sales data.
3. Run `board\install_task.ps1` in PowerShell once: a Windows task then runs the collector every 30 minutes, hidden. After a day it measures how often TSM really updates (every 3 hours on Forever so far) and switches to that.
4. Double-click `board\Gold Board.cmd`: it opens the dashboard at http://localhost:8787, keeps it up to date, and rebuilds the Ledger whenever the game saves the addon's data.

The dashboard finds your game folder by itself in the usual install places. If yours is elsewhere, set the `GOLDBOARD_WOW` environment variable, or create `board/config.local.json` with `{ "wow": "E:\\Games\\World of Warcraft" }` (the folder that holds `_forever_`).

Remove the task with `Unregister-ScheduledTask -TaskName 'TSM Forever Collector' -Confirm:$false`.

## In game

- `/gb` shows or hides the panel at the auction house: your items with the gain if you sold now, and the best buys at the last TSM update. Click a row to search it in Auctionator.
- `/gb ah roleplay-alliance` sets which auction house's prices this realm uses (the default is `roleplay-alliance`).
- `/gb tooltip` turns the tooltip lines off or on, `/gb status` says what has been recorded.

Signals load at login and `/reload`; your trades reach the dashboard after a `/reload` or logout.

## How prices are read

- **Sells for** is the lowest of the item's TSM market value on your auction house, its 60-day price and its real EU-wide sale price, so profits are counted on the safe side.
- **Buy below** leaves 15% after the 5% auction cut.
- **Could sell at now** (for what you hold) is never above the cheapest listing: an item whose listings keep getting undercut doesn't show a profit it can't make.
- "Sold per day" and "sale rate" are EU-wide (TSM publishes no per-auction-house sales).

## Data and privacy

- Prices come only from TSM's public files (https://tradeskillmaster.com/public-data), which TSM offers for automated use. The dashboard never scrapes tradeskillmaster.com itself; item pages only link to it.
- Item tooltips on the dashboard load from Wowhead's tooltip service, one item at a time as you look at it.
- Everything else stays on your PC: the collected prices (`board/data/`), your ledger and the built page are not uploaded anywhere and are excluded from this repository.
- The addon keeps only counts of sellers in its scans, never their names.

## Files

- `GoldBoard/`: the addon (`Core.lua` saved data and gold, `Ledger.lua` trades, `Scans.lua` Auctionator scans, `Signals.lua` + `SignalsData.lua` dashboard signals, `Tooltip.lua`, `Panel.lua`).
- `board/collect.js`: downloads TSM's files, keeps each new version, sets the check interval, builds the page.
- `board/ledger.js`: reads the addon's saved data, keeps the ledger, writes `SignalsData.lua` into the installed addon.
- `board/dashboard.js` + `dashboard.template.html`: the dashboard.
- `board/luadata.js`: reads WoW SavedVariables files (a parser, nothing is executed). `board/wow.js`: finds the game folder.
- `board/serve.js`, `Gold Board.cmd`: the local web page. `install_task.ps1`, `run-hidden.vbs`: the scheduled task.
