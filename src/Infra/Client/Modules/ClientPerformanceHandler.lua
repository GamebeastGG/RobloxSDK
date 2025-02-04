--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientPerformanceHandler.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ClientPerformanceHandler = { }

--= Roblox Services =--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

local PerformanceRemote = GetRemote("Event", "Performance")

--= Constants =--

--= Variables =--

local LowestFps = 60

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function ClientPerformanceHandler:TakeSnapshot()
    local snapshot = {
        lowestFps = LowestFps,
        memory = Stats:GetTotalMemoryUsageMb(),
        ping = Players.LocalPlayer:GetNetworkPing(),
        networkReceive = Stats.DataReceiveKbps
    }

    LowestFps = 60

    return snapshot
end

--= Initializers =--
function ClientPerformanceHandler:Init()
    task.spawn(function()
        while task.wait(5) do
            PerformanceRemote:FireServer(nil, self:TakeSnapshot())
        end
    end)

    RunService.Heartbeat:Connect(function(delta)
        local fps = 1 / delta
        if fps < LowestFps then
            LowestFps = fps
        end
    end)
end

--= Return Module =--
return ClientPerformanceHandler