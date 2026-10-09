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

local Utilities = require(script.Parent.Utilities) ---@module Utilities
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate

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
        local rawLaunchData = joinData.LaunchData
        local attemptCount = 0

        while attemptCount < 10 and rawLaunchData == "" do
            task.wait(0.5)
            attemptCount += 1

            local latestJoinData = player:GetJoinData()
            rawLaunchData = latestJoinData.LaunchData
        end

        if rawLaunchData ~= "" then
            -- Attempt a base64 decode. The service is fetched here rather than at module scope so
            -- that an engine without it costs us base64 support, not the whole SDK: this module is
            -- required in a loop that has no error handling around it.
            local base64Decoded, launchDataBuffer = pcall(function()
                return game:GetService("EncodingService"):Base64Decode(buffer.fromstring(rawLaunchData))
            end)

            local function decodeJson(value : string)
                return pcall(function()
                    return HttpService:JSONDecode(value)
                end)
            end

            -- Prefer the decoded form, then fall back to the raw string. Launch data that happens
            -- to be base64-legal (a bare number, say) decodes to bytes that are not JSON, and
            -- taking the decode as final dropped data that parsed perfectly well as it was sent.
            local candidates = if base64Decoded
                then { buffer.tostring(launchDataBuffer), rawLaunchData }
                else { rawLaunchData }

            local lastError
            for _, candidate in candidates do
                local success, launchDataJson = decodeJson(candidate)
                if success then
                    ResolveData(player, launchDataJson)
                    return
                end

                lastError = launchDataJson
            end

            Utilities.GBLog("Failed to decode launch data JSON for player " .. player.Name .. ": " .. tostring(lastError))
        end

        ResolveData(player, nil)
    end)

    ServerGate:OnPlayerRemoved(function(player)
        LaunchDataCache[player] = nil
        DidResolveCache[player] = nil
    end)
end

--= Return Module =--
return LaunchDataResolver