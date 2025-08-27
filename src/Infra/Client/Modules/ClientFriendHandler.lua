--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientFriendHandler.lua
    
    Description:
        No description provided.
    
--]]


--= Root =--
local ClientFriendHandler = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local ClientInfoHandler = shared.GBMod("ClientInfoHandler") ---@module ClientInfoHandler

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local FriendCache = {} :: {[number] : boolean}
local FriendsOnline = 0

--= Public Variables =--

--= Internal Functions =--

local function UpdateFriendCache()
    local foundFriendsOnline = 0
    local success, errorMessage = pcall(function() -- Minimizes internal HTTP requests
        local friendsList = Players:GetFriendsAsync(Players.LocalPlayer.UserId)
        
        while true do
            local list = friendsList:GetCurrentPage()
            for _, friend in ipairs(list) do
                if Players:GetPlayerByUserId(friend.Id) then
                    foundFriendsOnline += 1
                end
                FriendCache[friend.Id] = true
            end

            if friendsList.IsFinished then
                break
            else
                friendsList:AdvanceToNextPageAsync()
            end
        end
    end)

    -- client only sends initial total time and friends online count

    local hasFriendsOnline = ClientInfoHandler:GetClientInfo("hasFriendsOnline") or false

    if hasFriendsOnline == true and foundFriendsOnline <= 0 then
        ClientInfoHandler:UpdateClientInfo("totalFriendPlaytime", (ClientInfoHandler:GetClientInfo("totalFriendPlaytime") or 0) + os.time() - (ClientInfoHandler:GetClientInfo("friendClockStart")))
    elseif foundFriendsOnline > 0 and hasFriendsOnline == false then
        ClientInfoHandler:UpdateClientInfo("friendClockStart", os.time())
    end

    FriendsOnline = foundFriendsOnline
    ClientInfoHandler:UpdateClientInfo("hasFriendsOnline", FriendsOnline > 0)

    return success, errorMessage
end

--= API Functions =--

--= Initializers =--
function ClientFriendHandler:Init()
    task.spawn(function()
        Players.PlayerAdded:Connect(function(player : Player)
            if FriendCache[player.UserId] then
                FriendsOnline += 1
            end
        end)

        Players.PlayerRemoving:Connect(function(player : Player)
            if FriendCache[player.UserId] then
                FriendsOnline -= 1
            end
        end)

        UpdateFriendCache()
        while task.wait(60 * 10) do
            UpdateFriendCache()
        end
    end)
end

--= Return Module =--
return ClientFriendHandler