--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Overwolf.luau

    Description:
        Public API module for Overwolf Service. Lets an experience react to players who were
        launched into it by an Overwolf launcher, such as granting daily streak rewards.

--]]

--= Root =--
local Overwolf = { }

--= Roblox Services =--

--= Dependencies =--

local Types = require(script.Parent.Parent.Parent.Types) ---@module Types
local InternalOverwolf = require(script.Parent.Parent.Modules.InternalOverwolf) ---@module InternalOverwolf

--= Types =--

type OverwolfLaunchData = Types.OverwolfLaunchData

--= API Functions =--

--[[
    Calls `callback(player, launchData)` once for every player launched by an Overwolf launcher,
    including players already in the server. Players who joined any other way never trigger it.
    Launch data can be put on a link by anyone, so treat it as a claim from the player: a returning
    player sends the same `streak` on every launch that day, so record what you've granted.
]]
function Overwolf:OnLaunchData(callback : (player : Player, launchData : OverwolfLaunchData) -> ()) : RBXScriptConnection
    assert(type(callback) == "function", "Overwolf:OnLaunchData expects a callback function.")
    return InternalOverwolf:OnLaunchData(callback)
end

--[[
    Yields until the player's launch data has been read (a few seconds at most after they join), then
    returns it, or nil if the player wasn't launched by an Overwolf launcher.
]]
function Overwolf:GetLaunchDataAsync(player : Player) : OverwolfLaunchData?
    return InternalOverwolf:GetLaunchDataAsync(player)
end

--[[
    Studio only. Studio never has launch data, so this treats the player as launched by an Overwolf
    launcher with the given fields, firing `OnLaunchData` callbacks. `source` is set for you and
    `placeId` defaults to the current place: `Overwolf:SimulateLaunchData(player, { streak = 3 })`.
]]
function Overwolf:SimulateLaunchData(player : Player, launchData : { [string] : any }?)
    InternalOverwolf:SimulateLaunchData(player, launchData)
end

--= Return Module =--
return Overwolf
