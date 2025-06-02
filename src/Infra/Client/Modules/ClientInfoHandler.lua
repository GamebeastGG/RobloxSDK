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
local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")

--= Constants =--

--= Variables =--

local ProductInfoCache = {} :: {[number] : {PriceInRobux : number}}
local CurrentClientInfoCache = {} :: {[string] : any}
local FriendCache = {} :: {[number] : boolean}
local FriendsOnline = 0
local PendingUpdate = false
local CurrentInputType = nil

--= Public Variables =--

--= Internal Functions =--

local function UpdateClientInfo(key : string, value : any, force : boolean?)
    if CurrentClientInfoCache[key] ~= value or force then
        CurrentClientInfoCache[key] = value

        if PendingUpdate then
            return
        end

        PendingUpdate = true
        task.defer(function()
            PendingUpdate = false
            ClientInfoRemote:FireServer(CurrentClientInfoCache)
        end)
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

local function DetermineInputTypeString(InputEnum) 
    if InputEnum == Enum.UserInputType.Keyboard then
        return "keyboard"
    elseif InputEnum == Enum.UserInputType.Touch then
        return "touch"
    elseif string.match(tostring(InputEnum),"Gamepad") then
        return "gamepad"
    end
end

--= API Functions =--

function ClientInfoHandler:GetDeviceType() : (string, string)
    -- Determine device type
    local deviceType = "unknown"
    if UserInputService.VREnabled or VRService.VREnabled then
        deviceType = "vr"
    elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		deviceType = "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		deviceType = "console"
	elseif UserInputService.KeyboardEnabled then
		deviceType = "pc"
	end

    -- Determine device subtype
    local deviceSubType = "unknown"
    if deviceType == "mobile" then
        local camera = workspace.CurrentCamera
        if camera then
            local longestSide = math.max(camera.ViewportSize.X, camera.ViewportSize.Y)
            local shortestSide = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
            local aspectRatio = longestSide / shortestSide
            if aspectRatio > 1.8 then
                deviceSubType = "phone"
            elseif aspectRatio <= 1.7 then
                deviceSubType = "tablet"
            else -- Devices in this range can be either phone or tablet equally. Older devices share the 16:9 aspect ratio.
                deviceSubType = "phone" -- We'll assume phone for now, since phone users are more common.
            end
        end
    elseif deviceType == "console" then
        local imageUrl = UserInputService:GetImageForKeyCode(Enum.KeyCode.ButtonX)
        if string.find(imageUrl, "Xbox") then
            deviceSubType = "xbox"
        elseif string.find(imageUrl, "PlayStation") then
            deviceSubType = "playstation"
        else
            deviceSubType = "unknown"
        end
    elseif deviceType == "vr" then
        deviceSubType = "unknown" -- No reliable way to determine VR headset type in Roblox.
    elseif deviceType == "pc" then
        deviceSubType = "unknown" -- No reliable way to determine PC type in Roblox
    end

    return deviceType, deviceSubType
end



--= Initializers =--
function ClientInfoHandler:Init()
    local deviceType, deviceSubType = self:GetDeviceType()
    UpdateClientInfo("deviceSubType", deviceSubType)
    UpdateClientInfo("device", deviceType, true)

    -- Input type detection

    local function inputTypeChanged(inputType : string)
        if CurrentInputType ~= inputType then
            CurrentInputType = inputType
            UpdateClientInfo("inputType", CurrentInputType)
        end
    end

    if UserInputService.GamepadEnabled then
        inputTypeChanged("gamepad")
    elseif UserInputService.TouchEnabled then
        inputTypeChanged("touch")
    else
        inputTypeChanged("keyboard")
    end

    --// Detect CurrentInputType changes from 'LastInputType'
    UserInputService.LastInputTypeChanged:Connect(function(lastType)
        local newType = DetermineInputTypeString(lastType)
        if newType and newType ~= CurrentInputType then
            inputTypeChanged(newType)
        end
    end)

     UserInputService.InputChanged:Connect(function(InputObject)
        if InputObject.UserInputType == Enum.UserInputType.MouseMovement then
            inputTypeChanged("keyboard")
        end
    end)

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
end

--= Return Module =--
return ClientInfoHandler