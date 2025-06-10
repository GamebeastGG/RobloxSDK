--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientInfoHandler.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ClientInfoHandler = { }

--= Roblox Services =--

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")
local SessionPreservationRemote = GetRemote("Event", "SessionPreservation")

--= Constants =--

--= Variables =--

local ProductInfoCache = {} :: {[number] : {PriceInRobux : number}}
local CurrentClientInfoCache = {} :: {[string] : any}
local FriendCache = {} :: {[number] : boolean}
local FriendsOnline = 0

--= Public Variables =--

--= Internal Functions =--

local function UpdateClientInfo(key : string, value : any, force : boolean?)
    if CurrentClientInfoCache[key] ~= value or force then
        CurrentClientInfoCache[key] = value
        ClientInfoRemote:FireServer(key, value)
    end
end

local function UpdateFriendCache()
    local foundFriendsOnline = 0
    local success, errorMessage = pcall(function() -- Minimizes internal HTTP requests
        local friendsList = Players:GetFriendsAsync(Players.LocalPlayer.UserId)
        
        repeat
            local list = friendsList:GetCurrentPage()
            for _, friend in ipairs(list) do
                if Players:GetPlayerByUserId(friend.Id) then
                    foundFriendsOnline += 1
                end
                FriendCache[friend.Id] = true
            end

            if not friendsList.IsFinished then
                friendsList:AdvanceToNextPageAsync()
            end
        until friendsList.IsFinished
    end)

    FriendsOnline = foundFriendsOnline
    UpdateClientInfo("friendsOnline", FriendsOnline)
end

--= API Functions =--

function ClientInfoHandler:GetDeviceType() : string
    if UserInputService.VREnabled or VRService.VREnabled then
        return "vr"
    elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "console"
	elseif UserInputService.KeyboardEnabled then
		return "pc"
	else
		return "unknown"
	end
end

--= Initializers =--
function ClientInfoHandler:Init()
    UpdateClientInfo("device", self:GetDeviceType(), true)
    UpdateClientInfo("preservedSessionData", TeleportService:GetTeleportSetting("GAMEBEAST_SESSION") or "")

    -- Friends online
    task.spawn(function()
        Players.PlayerAdded:Connect(function(player : Player)
            if FriendCache[player.UserId] then
                FriendsOnline += 1
                UpdateClientInfo("friendsOnline", FriendsOnline)
            end
        end)

        Players.PlayerRemoving:Connect(function(player : Player)
            if FriendCache[player.UserId] then
                FriendsOnline -= 1
                UpdateClientInfo("friendsOnline", FriendsOnline)
            end
        end)

        UpdateFriendCache()
        while task.wait(60 * 10) do
            UpdateFriendCache()
        end
    end)

    -- Geographic pricing
    ClientProductPriceRemote.OnClientInvoke = function(productId : number, productType : Enum.InfoType) : number
        if ProductInfoCache[productId] then
            return ProductInfoCache[productId]
        end

        local success, price = pcall(function()
            return MarketplaceService:GetProductInfo(productId, productType)
        end)

        if success then
            ProductInfoCache[productId] = price
            return price.PriceInRobux
        else
            return nil
        end
    end

    -- Session ID resolution
    SessionPreservationRemote.OnClientEvent:Connect(function(sessionInfo : {[string] : any})
        TeleportService:SetTeleportSetting("GAMEBEAST_SESSION", sessionInfo)
    end)
end

--= Return Module =--
return ClientInfoHandler