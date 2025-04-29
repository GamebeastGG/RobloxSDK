--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ServerClientInfoHandler.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ServerClientInfoHandler = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")
local Signal = shared.GBMod("Signal")
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local SignalTimeout = shared.GBMod("SignalTimeout") ---@module SignalTimeout

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")
local ClientInfoResolvedSignal = Signal.new()

--= Constants =--

local DEFAULT_INFO = {
    device = "unknown",
}

--= Variables =--

local ClientInfoCache = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function ServerClientInfoHandler:GetClientInfo(player : Player | number, key : string) : any
    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    if not player or not ClientInfoCache[player] or not ClientInfoCache[player][key] then
        return DEFAULT_INFO[key]
    end
    
    return ClientInfoCache[player][key]
end

function ServerClientInfoHandler:OnClientInfoResolved(player : Player, timeoutSeconds : number, callback : (timedout : boolean, info : { [string] : any }) -> nil)
    if ClientInfoCache[player] then
        callback(false, table.clone(ClientInfoCache[player]))
        return
    end

    local timeout = SignalTimeout.new(timeoutSeconds, ClientInfoResolvedSignal, function(resolvedPlayer : Player)
        return resolvedPlayer == player
    end)

    return timeout:Once(function(timedout : boolean, _, info : { [string] : any }?)
        if timedout or not info then
            callback(true, table.clone(DEFAULT_INFO))
        elseif info then
            callback(false, table.clone(info))
        end
    end)
end

-- Good way to tell if the client SDK is even initialized.
function ServerClientInfoHandler:IsClientInfoResolved(player : Player | number) : boolean
    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    return ClientInfoCache[player] ~= nil
end

function ServerClientInfoHandler:GetProductPriceForPlayer(player : Player | number, productId : number, productType : Enum.InfoType) : number?
    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    if not self:IsClientInfoResolved(player) then
        return nil
    end

    local success, result = pcall(function()
        return ClientProductPriceRemote:InvokeClient(player, productId, productType)
    end)

    if not success then
        return nil
    else
        return result
    end
end

--= Initializers =--
function ServerClientInfoHandler:Init()
    Players.PlayerRemoving:Connect(function(player : Player)
        ClientInfoCache[player] = nil
    end)

    ClientInfoRemote.OnServerEvent:Connect(function(player : Player, updatedData : { [string] : any })
        for key in pairs(updatedData) do
            if not DEFAULT_INFO[key] then
                return
            end
        end
 
        local isNew = false
        if not ClientInfoCache[player] then
            ClientInfoCache[player] = table.clone(DEFAULT_INFO)
            isNew = true
        end

        for key, value in pairs(updatedData) do
            ClientInfoCache[player][key] = value
        end

        if isNew then
            ClientInfoResolvedSignal:Fire(player, ClientInfoCache[player])
        end
    end)
end

--= Return Module =--
return ServerClientInfoHandler