--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SocialHandler.luau
	
	Description:
        Handles tracking social interactions between players in the server.

--]]

--= Root =--

local SocialHandler = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local EngagementMarkers = require(script.Parent.Parent.EngagementMarkers) ---@module EngagementMarkers
local ServerClientInfoHandler = require(script.Parent.Parent.ServerClientInfoHandler) ---@module ServerClientInfoHandler
local PlayerStats = require(script.Parent.Parent.PlayerStats) ---@module PlayerStats
local ServerGate = require(script.Parent.Parent.ServerGate) ---@module ServerGate

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local FriendsInServerCache = ServerGate:GetCache()

--= Public Variables =--

--= Internal Functions =--

local function CreateCacheEntry(player : Player) : { [string]: any }
    local newEntry = {
        LastClientUpdate = 0,
    }

    FriendsInServerCache[player] = newEntry

    return newEntry
end

--= API Functions =--

function SocialHandler:GetTotalFriendPlaytime(player : Player) : number?
    local cachedData = FriendsInServerCache[player]
    if cachedData == nil or ServerClientInfoHandler:IsClientInfoResolved(player) == false then
        return nil
    end
    
    FriendsInServerCache[player] = nil
    
    local hasFriendsOnline = ServerClientInfoHandler:GetClientInfo(player, "hasFriendsOnline")
    local totalTime = ServerClientInfoHandler:GetClientInfo(player, "totalFriendPlaytime")

    if hasFriendsOnline then
        return totalTime + (os.time() - cachedData.LastClientUpdate)
    else
        return totalTime
    end
end

--= Initializers =--
function SocialHandler:Init()
    ServerGate:OnPlayerAdded(function(player : Player, cleaner)
        local cacheEntry = CreateCacheEntry(player)

        cleaner:Add(ServerClientInfoHandler:OnClientInfoChanged(player, function(key, _)
            if key == "friendClockStart" then
                cacheEntry.LastClientUpdate = os.time()
            end
        end))

        local activeTeleportCount = 0
        cleaner:Add(player.OnTeleport:Connect(function(teleportState, placeId)
            if teleportState == Enum.TeleportState.RequestedFromServer then
                PlayerStats:SetStat(player, "teleporting_to", placeId)
                activeTeleportCount += 1
            elseif teleportState == Enum.TeleportState.Failed then
                activeTeleportCount -= 1
                if activeTeleportCount <= 0 then
                    PlayerStats:SetStat(player, "teleporting_to", nil)
                end
            end
        end))
    end)
end

--= Return Module =--
return SocialHandler