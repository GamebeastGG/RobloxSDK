--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientInfoHandler.lua
    
    Description:
        Module for managing reported client information and product pricing.
    
--]]

--= Root =--
local ClientInfoHandler = {
    Priority = 1000
}

--= Roblox Services =--

local MarketplaceService = game:GetService("MarketplaceService")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")
local ClientSessionPreservation = shared.GBMod("ClientSessionPreservation") ---@module ClientSessionPreservation

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientInfoRequestRemote = GetRemote("Function", "GetClientInfo")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")

--= Constants =--

local REQUIRED_KEYS = {
    device = true,
    deviceSubType = true,
    inputType = true,
}

--= Variables =--

local ProductInfoCache = {} :: {[number] : {PriceInRobux : number}}
local CurrentClientInfoCache = {} :: {[string] : any}
local PendingUpdate = false

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function ClientInfoHandler:UpdateClientInfo(key : string, value : any)
    if CurrentClientInfoCache[key] ~= value then
        CurrentClientInfoCache[key] = value
        ClientSessionPreservation:UpdateStoredData(key, value)

        for key in REQUIRED_KEYS do
            if not CurrentClientInfoCache[key] then
                return -- Will not send signal that client info is ready until all required keys are set
            end
        end

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

function ClientInfoHandler:GetClientInfo(key : string) : any
    return CurrentClientInfoCache[key]
end

--= Initializers =--
do
    for key, value in ClientSessionPreservation:GetStoredData() do
        ClientInfoHandler:UpdateClientInfo(key, value)
    end
end

function ClientInfoHandler:Init()
    ClientInfoRequestRemote.OnClientInvoke = function()
        return CurrentClientInfoCache
    end

    -- Geographic pricing
    ClientProductPriceRemote.OnClientInvoke = function(productId : number | string, productType : Enum.InfoType)
        if ProductInfoCache[productId] then
            return ProductInfoCache[productId]
        end

        local success, price = pcall(function()
            if productType == Enum.InfoType.Subscription then
                return MarketplaceService:GetSubscriptionProductInfoAsync(productId)
            else
                return MarketplaceService:GetProductInfoAsync(productId, productType)
            end
        end)


        if success then
            ProductInfoCache[productId] = price
            return price
        else
            return nil
        end
    end

    ClientInfoRemote.OnClientEvent:Connect(function(key : string, value : any)
        ClientInfoHandler:UpdateClientInfo(key, value)
    end)
end

--= Return Module =--
return ClientInfoHandler