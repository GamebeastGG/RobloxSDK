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

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local FriendsInServerCache = {}

--= Public Variables =--

--= Internal Functions =--

local function CreateCacheEntry(player : Player)
    FriendsInServerCache[player] = {
        Timestamp = tick(),
        TotalTime = 0,
        Friends = {},
    }
end

local function FriendStatusUpdated(player : Player, friend : Player, friendJoin : boolean)
    if player.Parent == nil or FriendsInServerCache[player] == nil then return end

    local cachedData = FriendsInServerCache[player]
    local friendIndex = table.find(cachedData.Friends, friend)
    
    if friendJoin and not friendIndex then
        table.insert(cachedData.Friends, friend)

        if #cachedData.Friends == 1 then
            cachedData.Timestamp = tick()
        end
    elseif friendJoin == false and friendIndex then
        table.remove(cachedData.Friends, friendIndex)
        
        if #cachedData.Friends == 0 then
            cachedData.TotalTime += tick() - cachedData.Timestamp
        end
    end
end

--= API Functions =--

function SocialHandler:GetTotalFriendPlaytime(player : Player) : number
    local cachedData = FriendsInServerCache[player]
    if not cachedData then
        return 0
    end

    FriendsInServerCache[player] = nil

    if #cachedData.Friends > 0 then
        return cachedData.TotalTime + (tick() - cachedData.Timestamp)
    else
        return cachedData.TotalTime
    end
end

--= Initializers =--
function SocialHandler:Init()
    local function playerAdded(player : Player)
        CreateCacheEntry(player)

        local joinData = player:GetJoinData()
        if joinData.ReferredByPlayerId and joinData.ReferredByPlayerId > 0 then
            EngagementMarkers:SDKMarker("JoinedUser", {
                userId = joinData.ReferredByPlayerId,
            }, { player = player })
        end

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
        for _, potentialFriend in ipairs(Players:GetPlayers()) do
            if potentialFriend == player then
                continue
            end

            FriendStatusUpdated(player, potentialFriend, false)
            FriendStatusUpdated(potentialFriend, player, false)
        end
    end)

end

--= Return Module =--
return SocialHandler