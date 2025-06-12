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

local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module EngagementMarkers
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local PlayerStats = shared.GBMod("PlayerStats") ---@module PlayerStats
local Cleaner = shared.GBMod("Cleaner") ---@module Cleaner

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local FriendsInServerCache = {}

--= Public Variables =--

--= Internal Functions =--

local function CreateCacheEntry(player : Player) : { [string]: any }
    local newEntry = {
        LastClientUpdate = 0,
        Cleaner = Cleaner.new(),
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
        return totalTime + (os.clock() - cachedData.LastClientUpdate)
    else
        return totalTime
    end
end

--= Initializers =--
function SocialHandler:Init()
    local function playerAdded(player : Player)
        local cacheEntry = CreateCacheEntry(player)

        local joinData = player:GetJoinData()
        if joinData.ReferredByPlayerId and joinData.ReferredByPlayerId > 0 then
            EngagementMarkers:SDKMarker("JoinedUser", {
                userId = joinData.ReferredByPlayerId,
                isFriend = player:IsFriendsWith(joinData.ReferredByPlayerId),
            }, { player = player })
        end

        cacheEntry.Cleaner:GiveTask(ServerClientInfoHandler:OnClientInfoChanged(player, function(key, _)
            if key == "friendClockStart" then
                cacheEntry.LastClientUpdate = os.clock()
            end
        end))

        player.OnTeleport:Connect(function(teleportState)
            if teleportState == Enum.TeleportState.Started then
                PlayerStats:SetStat(player, "teleporting", true)
            elseif teleportState == Enum.TeleportState.Failed then
                PlayerStats:SetStat(player, "teleporting", false)
            end
        end)
    end

    Players.PlayerAdded:Connect(playerAdded)
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(playerAdded, player)
    end
	
    Players.PlayerRemoving:Connect(function(player)
        if FriendsInServerCache[player] then
            FriendsInServerCache[player].Cleaner:Destroy()
        end
    end)
end

--= Return Module =--
return SocialHandler