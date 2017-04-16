# FF2Stats

FF2Stats is a plugin for Freak Fortress 2 that adds stats to bosses.

Requirements: default sql database is setup and srcds has permissions to create tables.

# Installation
* place ff2stats.smx inside `addons/sourcemod/plugins/` and have freak fortress 2 installed.
* place ff2stats.phrases in `addons/sourcemod/translations/`

# Commands
* `ff2stats` -> toggle personal boss stats (defaults to disabled, when on: boss stats are recorded and hp modifiers are calculated)
* `ff2clearstats` -> Clear stats for a specific boss

# ConVars
* `ff2stats_enabled` [Boolean] -> Enable/ disable ff2stats globally, defaults to enabled
