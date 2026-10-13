# [Gamebeast](https://gamebeast.gg/) Roblox SDK
*Documentation: https://docs.gamebeast.gg/*

This SDK is intended for use with the Roblox platform.

## What is Gamebeast?
Gamebeast specializes in providing real-time analytics and tools for user engagement, allowing developers to make data-driven decisions to enhance their games.

From the Gamebeast dashboard, developers can automatically detect player pain points and make live updates to their experience. By making adjustments that are seamless to their users, the experience is optimized for engagement, boosting developer revenue.


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

Values must be strings, numbers, booleans, or lists of one of those types (up to 100 items). A player or the server can have up to 100 properties, with names up to 128 characters; the SDK warns and ignores anything outside these limits, which Gamebeast would otherwise reject for the whole server. Set player properties as soon as their data loads: assignment is requested shortly after join, and changing a property afterwards re-resolves that player's assignments.

Relevant `sdkSettings`:
- `markerFlushRate`: seconds between engagement marker batch flushes (default 10, minimum 1).
- `statusPollRate`: seconds between change-detection polls (default 30, minimum 5). During an incident Gamebeast can ask servers to poll less often, never more.
- `assignmentRefreshRate`: seconds between re-requesting experiment assignments for all players and the server (default 30, minimum 10). This is how a dashboard change like a manual group reassignment reaches players already in game.
- `serverReportRate`: seconds between server state reports with player counts and performance (default 30, minimum 10, maximum 45). Player counts are built per minute, so a report has to land every minute.

In Studio, any rate you leave out of `sdkSettings` defaults faster, so dashboard edits show up quickly while you test: `markerFlushRate` 2s, `statusPollRate` 5s, `assignmentRefreshRate` 10s and `serverReportRate` 10s. Rates you set yourself are used as given, in Studio and in live servers.

## Changing settings at runtime
The `sdkSettings` passed to `Setup` can be changed on a running SDK with `UpdateSettings`. Settings left out of the table keep their current value, and nothing is applied unless every setting given is valid:

```lua
Gamebeast:UpdateSettings({ statusPollRate = 120, sdkDebugEnabled = true })
```

Changes apply within a few seconds. `environment` and `customUrl` can only be set in `Setup`, since they decide which backend the SDK talks to.

## Installation
To get started with Gamebeast, sign up at https://dashboard.gamebeast.gg/

Gamebeast can be installed directly to Roblox Studio through our Roblox Plugin, or via Roblox focused package managers such as Wally. 

Please visit https://docs.gamebeast.gg/Roblox/Installation for more details.

## Running the tests
Tests live in `tests/` and run under [TestEZ](https://github.com/Roblox/testez) inside Studio. TestEZ is a dev dependency managed by [Forest](https://forest.dev/), mounted at `tests/DevPackages`, so install it once with `forest install` and sync the place with Rojo (`rojo serve`, using the default project). Then press play, switch to the server context, and set the `RunServerTest` or `RunClientTest` attribute on `TestRunnerRemote` in ReplicatedStorage to run them.
