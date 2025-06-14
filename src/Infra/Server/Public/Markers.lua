--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Markers.lua
    
    Description:
        Server-side API for sending engagement markers.
    
--]]

--= Root =--
local Markers = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module EngagementMarkers
local PurchaseAnalytics = shared.GBMod("PurchaseAnalytics") ---@module PurchaseAnalytics

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Markers:SendMarker(markerType : string, value : any | {[string] : any}, position : Vector3?)
    EngagementMarkers:FireMarker(markerType, value, {position = position})
end

function Markers:SendPlayerMarker(player : Player, markerType : string, value : any | {[string] : any}, position : Vector3?)
    EngagementMarkers:FireMarker(markerType, value, {player = player, position = position})
end

-- Sends an internal Purchase marker for dev products.
function Markers:SendNewPurchaseGrantedMarker(recieptInfo : {[string] : number | string}, position : Vector3?)
    if not Players:GetPlayerByUserId(recieptInfo.PlayerId) then
        return false
    end

    task.spawn(function()
        PurchaseAnalytics:DevProductPurchased(true, recieptInfo.PlayerId, recieptInfo.ProductId, position)
    end)
end

--= Return Module =--
return Markers