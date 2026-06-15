--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    ServerGate.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ServerGate = { }

--= Roblox Services =--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Signal = shared.GBMod("Signal") ---@module Signal
local Cleaner = shared.GBMod("Cleaner") ---@module Cleaner

--= Types =--

--= Object References =--

local PlayerRemovingSignal = Signal.new()

--= Constants =--

--= Variables =--

local PlayerCache = {}
local CacheObjects = {}
local PlayerMaids = {}

--= Public Variables =--

--= Internal Functions =--

local function MakeCacheObject()
    local newMeta; newMeta = {
        RawData = {},
        __index = function(_, key)
            assert(type(key) == "userdata", "PlayerCache keys must be a Player object")
            
            if PlayerCache[key] then
                PlayerCache[key].LastFetch = os.clock()
            end

            return newMeta.RawData[key]
        end,
        __newindex = function(_, key, value)
            assert(type(key) == "userdata", "PlayerCache keys must be a Player object")

            if not key.Parent then --NOTE: Prevent caching data for players that have left
                return
            end

            newMeta.RawData[key] = value
        end
    }

    table.insert(CacheObjects, newMeta)

    return setmetatable({}, newMeta)
end

--= API Functions =--

function ServerGate:GetCache()
    return MakeCacheObject()
end

function ServerGate:OnPlayerAdded(callback : (Player, any) -> ())
    local function add(player)
        if not PlayerMaids[player] then
            PlayerMaids[player] = Cleaner.new()
        end

        task.spawn(callback, player, PlayerMaids[player])
    end

    for _, player in Players:GetPlayers() do
		add(player)
    end

	return Players.PlayerAdded:Connect(add)
end

function ServerGate:OnPlayerRemoved(callback : (Player) -> ())
    return PlayerRemovingSignal:Connect(callback)
end

--= Initializers =--
do
    Players.PlayerRemoving:Connect(function(player)
        PlayerCache[player] = {
            LastFetch = os.clock()
        }
    end)

    RunService.Heartbeat:Connect(function()
        for player, cacheData in PlayerCache do
            if os.clock() - cacheData.LastFetch > 5 then
                PlayerCache[player] = nil

                for _, cacheObject in CacheObjects do
                    cacheObject.RawData[player] = nil
                end

                if PlayerMaids[player] then
                    PlayerMaids[player]:Destroy()
                    PlayerMaids[player] = nil
                end

                PlayerRemovingSignal:Fire(player)
            end
        end
    end)
end

--= Return Module =--
return ServerGate