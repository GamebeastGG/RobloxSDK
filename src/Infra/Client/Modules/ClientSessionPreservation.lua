--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    ClientSessionPreservation.luau

    Description:
        
]]

--= Root =--
local ClientSessionPreservation = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

--= Dependencies =--

local Signal = shared.GBMod("Signal") ---@module Signal
local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

--= Constants =--

local PRESERVED_KEYS = {
    sessionId = true,
    joinTime = true,
    friendClockStart = true,
    hasFriendsOnline = true,
    totalFriendPlaytime = true
}

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function ClientSessionPreservation:UpdateStoredData(key : string, value : any)
    if PRESERVED_KEYS[key] == nil then
        return
    end

    local sessionInfo = self:GetStoredData()
    sessionInfo[key] = value

    TeleportService:SetTeleportSetting("GAMEBEAST_SESSION", sessionInfo)
end

function ClientSessionPreservation:GetStoredData() : { [string]: any }
    return TeleportService:GetTeleportSetting("GAMEBEAST_SESSION") or {}
end

--= Return Module =--
return ClientSessionPreservation