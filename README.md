# [Gamebeast](https://gamebeast.gg/) Roblox SDK
*Documentation: https://docs.gamebeast.gg/*

This SDK is intended for use with the Roblox platform.

## What is Gamebeast?
Gamebeast specializes in providing real-time analytics and tools for user engagement, allowing developers to make data-driven decisions to enhance their games.

From the Gamebeast dashboard, developers can automatically detect player pain points and make live updates to their experience. By making adjustments that are seamless to their users, the experience is optimized for engagement - creating a boost in developer revenue.


Some of the key features Gamebeast provides include:
- **Remote Configurations**: Easily manage and update configurations in real-time without needing to push new game versions.
- **Engagement Markers**: Track player interactions and events to understand how players are engaging with your experience.
- **User Management**: Simplified user management to easily track and manage players in your experience.
- **Experiments**: Run A/B tests to optimize your experience based on player behavior.
- **Funnels**: Visualize player flow through your experience to identify drop-off points and optimize player retention.
- **Heatmaps**: Visualize player interactions and engagement hotspots in your experience.


## Configurations & Experiments (SDK v2)
Configurations are fetched in bulk on startup and kept fresh by polling for changes. Every config path begins with the configuration's alias or name:

```lua
local Configs = Gamebeast:GetService("Configs")
local spawnRate = Configs:Get({"MyConfig", "spawn", "rate"})
```

Experiments are applied on top of their base configuration as changesets, evaluated per server and per player. Assignments can be read through the Experiments service (`GetAssignmentsForPlayer`, `GetServerAssignments`).

### Targeting properties
Experiments can target players or servers on properties you define. Set them through the Experiments service and they are sent as `context.properties` with assignment requests. The SDK gathers standard Roblox properties (device, input type, country, language, place) on its own.

```lua
local Experiments = Gamebeast:GetService("Experiments")

-- Per player (merged per key; pass nil to a single-property setter to clear it)
Experiments:SetPlayerProperties(player, { vip = true, level = 12, tags = { "beta", "founder" } })
Experiments:SetPlayerProperty(player, "level", 13)

-- Per server (also sent as shared context for player assignments; a player's own value wins)
Experiments:SetServerProperties({ region = "eu", mode = "ranked" })
```

Values must be strings, numbers, booleans, or lists of those (up to 100 items). Set player properties as soon as their data loads: assignment is requested shortly after join, and changing a property afterwards re-resolves that player's assignments.

Relevant `sdkSettings`:
- `markerFlushRate` — seconds between engagement marker batch flushes (default 10).
- `statusPollRate` — seconds between change-detection polls (default 30).

## Installation
To get started with Gamebeast, sign up at https://dashboard.gamebeast.gg/

Gamebeast can be installed directly to Roblox Studio through our Roblox Plugin, or via Roblox focused package managers such as Wally. 

Please visit https://docs.gamebeast.gg/Roblox/Installation for more details.