--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Heatmaps.lua
    
    Description:
        Public API for the Heatmaps module.
    
--]]

--= Root =--
local Heatmaps = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local Types = shared.GBMod("Types") ---@module Types
local InternalHeatmaps = shared.GBMod("InternalHeatmaps") ---@module InternalHeatmaps

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Heatmaps:RegisterHeatmap(heatmapName : string, positionA : Vector3, positionB : Vector3)
    return InternalHeatmaps:RegisterHeatmap(heatmapName, positionA, positionB)
end

function Heatmaps:AddHeatmapWaypoint(heatmapName : string, waypointName : string, position : Vector3, appearanceInfo : Types.HeatmapWaypointAppearanceInfo)
    return InternalHeatmaps:AddHeatmapWaypoint(heatmapName, waypointName, position, appearanceInfo)
end

--= Return Module =--
return Heatmaps