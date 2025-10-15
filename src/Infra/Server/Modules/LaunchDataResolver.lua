--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    LaunchDataResolver.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local LaunchDataResolver = { }

--= Roblox Services =--

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities
local Signal = shared.GBMod("Signal") ---@module Signal

--= Types =--

--= Object References =--

local LaunchDataResolvedSignal = Signal.new()

--= Constants =--

--= Variables =--

local LaunchDataCache = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--`

function LaunchDataResolver:OnResolved(player : Player, callback : (any) -> ()) : RBXScriptConnection?
    if LaunchDataCache[player] then
        callback(LaunchDataCache[player])
        return nil
    end

    local connection; connection = LaunchDataResolvedSignal:Connect(function(targetPlayer : Player, launchData)
        if player ~= targetPlayer then return end

        connection:Disconnect()
        callback(launchData)
    end)

    return connection
end

--= Initializers =--
function LaunchDataResolver:Init()
    Utilities:OnPlayerAdded(function(player : Player)

        if RunService:IsStudio() then
            LaunchDataResolvedSignal:Fire(player, nil)
            return
        end

        local joinData = player:GetJoinData()
        local launchData = joinData.LaunchData
        local attemptCount = 0

        while attemptCount < 10 and launchData == "" do
            task.wait(0.5)
            attemptCount += 1

            local latestJoinData = player:GetJoinData()
            launchData = latestJoinData.LaunchData
        end

        if launchData ~= "" then
            local success, launchDataJson = pcall(function()
                return HttpService:JSONDecode(launchData)
            end)

            if success then
                LaunchDataCache[player] = launchDataJson
                LaunchDataResolvedSignal:Fire(player, launchDataJson)
                return
            else
                Utilities.GBLog("Failed to decode launch data JSON for player " .. player.Name .. ": " .. tostring(launchDataJson))
            end
        end

        LaunchDataResolvedSignal:Fire(player, nil)

    end)

    Players.PlayerRemoving:Connect(function(player : Player)
        task.defer(function()
            LaunchDataCache[player] = nil
        end)
    end)
end

--= Return Module =--
return LaunchDataResolver