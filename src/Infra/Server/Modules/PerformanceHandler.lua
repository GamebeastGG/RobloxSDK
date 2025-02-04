--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    PerformanceHandler.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local PerformanceHandler = { }

--= Roblox Services =--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

local PerformanceRemote = GetRemote("Event", "Performance")

--= Constants =--

local PING_SPIKE_THRESHOLD = 100
local FPS_DROP_THRESHOLD = 15

--= Variables =--

local ServerFps = 60
local PlayerPerformanceCache = {}
local LastPerformanceDataCache = {} :: {
    [Player] : {
        timestamp : number,
        data : {
            lowestFps : number,
            networkReceive : number,
            memory : number,
            ping : number
        }
    }
}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

--= Initializers =--
function PerformanceHandler:Init()
    PerformanceRemote.OnServerEvent:Connect(function(player, data)
        local userId = player.UserId
        if not PlayerPerformanceCache[userId] then
            PlayerPerformanceCache[userId] = {
                events = {},
                snapshots = {}
            }
        end

        local cacheData = PlayerPerformanceCache[userId]

        local function makeEvent()
            table.insert(cacheData.events, {
                timestamp = os.time(),
                --TODO: Add more data
            })
        end

        
        if LastPerformanceDataCache[player] then
            local lastData = LastPerformanceDataCache[player]
            local timeDiff = tick() - lastData.timestamp

            -- Check for ping spikes
            if timeDiff > 5 + (PING_SPIKE_THRESHOLD/1000) then
                local pingSpikeMs = (timeDiff - 5) * 1000
                --TODO: Create a ping spike event
            end

            -- FPS drop
            local fpsDelta = lastData.data.lowestFps - data.lowestFps
            if fpsDelta > FPS_DROP_THRESHOLD then
                
                --TODO: Create a fps drop event
            end

            -- Track memory growth
        end

        LastPerformanceDataCache[player] = {
            timestamp = tick(),
            data = data
        }

        data.timestamp = os.time()
        table.insert(cacheData.snapshots, data)
    end)

    RunService.Heartbeat:Connect(function(deltaTime)
        ServerFps = 1/deltaTime
    end)

    Players.PlayerRemoving:Connect(function(player)
        LastPerformanceDataCache[player] = nil
        -- We do not clear PlayerPerformanceCache because we want to keep track of the player's performance data even after they leave?
    end)
end

--= Return Module =--
return PerformanceHandler