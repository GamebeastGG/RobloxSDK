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

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local FriendsInServerCache = {}

--= Public Variables =--

--= Internal Functions =--

local function CreateCacheEntry(player : Player) : { [string]: any }
    local newEntry = {
        Timestamp = tick(),
        TotalTime = 0,
        FriendInServer = false,
        UpdatedByClient = false,
        _connection = nil
    }

    FriendsInServerCache[player] = newEntry

    return newEntry
end

--= API Functions =--

function SocialHandler:GetTotalFriendPlaytime(player : Player) : number?
    local cachedData = FriendsInServerCache[player]
    if not cachedData or cachedData.UpdatedByClient == false then
        return nil
    end

    FriendsInServerCache[player] = nil

    if cachedData.FriendInServer then
        return cachedData.TotalTime + (tick() - cachedData.Timestamp)
    else
        return cachedData.TotalTime
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
            }, { player = player })
        end

        cacheEntry._connection = ServerClientInfoHandler:OnClientInfoChanged(player, function(key, value)
            if key == "friendsOnline" then
                local hasFriendsInServer = value > 0

                if cacheEntry.UpdatedByClient == false and hasFriendsInServer then
                    local joinedAt = PlayerStats:GetStat(player, "session_length")
                    cacheEntry.TotalTime += (tick() - joinedAt)
                end

                cacheEntry.UpdatedByClient = true

                if hasFriendsInServer == false and cacheEntry.FriendInServer == true then
                    cacheEntry.TotalTime += (tick() - cacheEntry.Timestamp)
                elseif hasFriendsInServer == true and cacheEntry.FriendInServer == false then
                    cacheEntry.Timestamp = tick()
                end

                cacheEntry.FriendInServer = hasFriendsInServer
            end
        end)

        --NOTE: Disabled since large servers with lots of players joining will result in too many HTTP requests.
        --[[ Look for friends
        for _, potentialFriend in ipairs(Players:GetPlayers()) do
            if potentialFriend ~= player and (player:IsFriendsWith(potentialFriend.UserId) or player.UserId < 0) then
                FriendStatusUpdated(player, potentialFriend, true)
                FriendStatusUpdated(potentialFriend, player, true)
            end

            if player.Parent == nil then
                return
            end
        end

        local cachedData = FriendsInServerCache[player]
        if cachedData and #cachedData.Friends > 0 then
            
            --NOTE: This prevents sending a marker for every friend in the server. ie: you join a game with 100 friends, we'd send 100 markers.
            EngagementMarkers:SDKMarker("JoinedFriend", {
                friendUserId = cachedData.Friends[1].UserId,
                friendsInServer = #cachedData.Friends,
            }, { player = player })
        end]]
    end

    Players.PlayerAdded:Connect(playerAdded)
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(playerAdded, player)
    end
	
    Players.PlayerRemoving:Connect(function(player)
        if FriendsInServerCache[player] then
            FriendsInServerCache[player]._connection:Disconnect()
        end
    end)

end

--= Return Module =--
return SocialHandler