--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    InternalOverwolf.luau

    Description:
        Picks out players launched into the experience by an Overwolf launcher, from the launch data
        the launcher puts on the deep link (`roblox://placeId=<id>&launchData=<base64 JSON>`).
        LaunchDataResolver decodes it; this module keeps the Overwolf launches and hands them to
        the developer's callbacks.

        The launcher sends `{ source = "overwolf", placeId = "<id>", streak = <day>? }`. `streak` is
        the player's day in the launcher's daily play streak for this game, sent only while a streak
        campaign is running. Fields added by later launcher versions pass through unchanged.

--]]

--= Root =--
local InternalOverwolf = { }

--= Roblox Services =--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Types = require(script.Parent.Parent.Parent.Types) ---@module Types
local Utilities = require(script.Parent.Utilities) ---@module Utilities
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate
local LaunchDataResolver = require(script.Parent.LaunchDataResolver) ---@module LaunchDataResolver

--= Types =--

type OverwolfLaunchData = Types.OverwolfLaunchData

--= Object References =--

-- Fires (player, launchData) for each Overwolf launch
local LaunchDataSignal = Signal.new()
-- Fires (player) once a player's launch data has been read, Overwolf or not
local ResolvedSignal = Signal.new()

--= Constants =--

local OVERWOLF_SOURCE = "overwolf"
-- LaunchDataResolver retries for up to 5 seconds, so this only trips if the player leaves first
local RESOLVE_TIMEOUT = 15

--= Variables =--

local LaunchDataByPlayer = {} :: { [Player] : OverwolfLaunchData }
local ResolvedPlayers = {} :: { [Player] : boolean }

--= Internal Functions =--

local function DeepCopy<T>(value : T) : T
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, child in value :: any do
        copy[key] = DeepCopy(child)
    end
    return copy :: any
end

local function SetLaunchData(player : Player, launchData : OverwolfLaunchData?)
    if launchData then
        LaunchDataByPlayer[player] = launchData
    end

    ResolvedPlayers[player] = true
    ResolvedSignal:Fire(player)

    if launchData then
        LaunchDataSignal:Fire(player, launchData)
    end
end

--= API Functions =--

--[[
    Returns the Overwolf launch data in a decoded `launchData` value, or nil if it didn't come from
    an Overwolf launcher. Anyone can put launch data on a Roblox link, so the fields are only
    checked for shape: a `streak` that isn't a whole number of days is dropped rather than passed on.
]]
function InternalOverwolf:Normalize(launchData : any) : OverwolfLaunchData?
    if type(launchData) ~= "table" or launchData.source ~= OVERWOLF_SOURCE then
        return nil
    end

    local normalized = DeepCopy(launchData)

    if type(normalized.placeId) == "number" then
        normalized.placeId = tostring(normalized.placeId)
    elseif type(normalized.placeId) ~= "string" then
        normalized.placeId = nil
    end

    if normalized.streak ~= nil then
        local streak = tonumber(normalized.streak)
        if streak and streak >= 1 and streak % 1 == 0 and streak ~= math.huge then
            normalized.streak = streak
        else
            Utilities.GBWarn(`Ignoring invalid Overwolf streak in launch data: {tostring(normalized.streak)}`)
            normalized.streak = nil
        end
    end

    return normalized :: OverwolfLaunchData
end

function InternalOverwolf:OnLaunchData(callback : (player : Player, launchData : OverwolfLaunchData) -> ()) : RBXScriptConnection
    local connection = LaunchDataSignal:Connect(callback)

    -- Players whose launch data came in before this was connected
    for player, launchData in LaunchDataByPlayer do
        if player.Parent then
            task.spawn(callback, player, DeepCopy(launchData))
        end
    end

    return connection
end

function InternalOverwolf:GetLaunchDataAsync(player : Player) : OverwolfLaunchData?
    if not ResolvedPlayers[player] then
        local thread = coroutine.running()
        local finished = false
        local connection

        local function finish()
            if finished then
                return
            end

            finished = true
            connection:Disconnect()
            task.spawn(thread)
        end

        connection = ResolvedSignal:Connect(function(resolvedPlayer : Player)
            if resolvedPlayer == player then
                finish()
            end
        end)
        task.delay(RESOLVE_TIMEOUT, finish)

        coroutine.yield()
    end

    return DeepCopy(LaunchDataByPlayer[player])
end

function InternalOverwolf:SimulateLaunchData(player : Player, launchData : { [string] : any }?)
    assert(RunService:IsStudio(), "Overwolf:SimulateLaunchData can only be used in Studio.")
    assert(typeof(player) == "Instance" and player:IsA("Player"), "Overwolf:SimulateLaunchData expects a Player.")

    local simulated = DeepCopy(launchData or {}) :: { [string] : any }
    simulated.source = OVERWOLF_SOURCE
    if simulated.placeId == nil then
        simulated.placeId = tostring(game.PlaceId)
    end

    SetLaunchData(player, self:Normalize(simulated))
end

--= Initializers =--
function InternalOverwolf:Init()
    Utilities:OnPlayerAdded(function(player : Player)
        LaunchDataResolver:OnResolved(player, function(launchData)
            -- A simulated launch in Studio wins over the empty real one
            if ResolvedPlayers[player] or not player:IsDescendantOf(Players) then
                return
            end

            SetLaunchData(player, self:Normalize(launchData))
        end)
    end)

    ServerGate:OnPlayerRemoved(function(player : Player)
        LaunchDataByPlayer[player] = nil
        ResolvedPlayers[player] = nil
    end)
end

--= Return Module =--
return InternalOverwolf
