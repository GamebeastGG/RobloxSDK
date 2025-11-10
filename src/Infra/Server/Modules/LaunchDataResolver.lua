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

local DidResolveCache = {}
local LaunchDataCache = {}

--= Public Variables =--

--= Internal Functions =--

function ResolveData(player : Player, data : any)
    DidResolveCache[player] = true
    LaunchDataCache[player] = data

    LaunchDataResolvedSignal:Fire(player, data)
end

--= API Functions =--`

function LaunchDataResolver:OnResolved(player : Player, callback : (any) -> ()) : RBXScriptConnection?
    if DidResolveCache[player] then
        task.spawn(function()
            callback(LaunchDataCache[player])
        end)

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
            ResolveData(player, nil)
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
                ResolveData(player, launchDataJson)
                return
            else
                Utilities.GBLog("Failed to decode launch data JSON for player " .. player.Name .. ": " .. tostring(launchDataJson))
            end
        end

        ResolveData(player, nil)
    end)

    Players.PlayerRemoving:Connect(function(player : Player)
        task.defer(function()
            LaunchDataCache[player] = nil
            DidResolveCache[player] = nil
        end)
    end)
end

--= Return Module =--
return LaunchDataResolver