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
local ClientInfoChangedSignal = Signal.new()

--= Constants =--

local DEFAULT_INFO = {
    device = "unknown",
    friendsOnline = 0,
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

function ServerClientInfoHandler:GetDefaultInfo()
    return table.clone(DEFAULT_INFO)
end

function ServerClientInfoHandler:OnClientInfoResolved(player : Player, callback : (info : { [string] : any }) -> nil)
    if ClientInfoCache[player] then
        callback(table.clone(ClientInfoCache[player]))
        return
    end

    return ClientInfoResolvedSignal:Connect(function(resolvedPlayer : Player, clientInfo : { [string] : any })
        if resolvedPlayer == player then
            callback(table.clone(clientInfo))
        end
    end)
end

function ServerClientInfoHandler:OnClientInfoChanged(player : Player, callback : (key : string, value : any) -> nil) : RBXScriptConnection
    return ClientInfoChangedSignal:Connect(function(changedPlayer : Player, key : string, value : any)
        if changedPlayer == player then
            callback(key, value)
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
        local price = ClientProductPriceRemote:InvokeClient(player, productId, productType)
        assert(typeof(price) == "number" and price >= 0, "Invalid price from client")
        return price
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

    ClientInfoRemote.OnServerEvent:Connect(function(player : Player, updatedKey : string, updatedValue : any)
        if not updatedKey or not updatedValue then
            return
        end

        if DEFAULT_INFO[updatedKey] == nil then
            return
        end

        local isNew = false
        if not ClientInfoCache[player] then
            ClientInfoCache[player] = table.clone(DEFAULT_INFO)
            isNew = true
        end

        ClientInfoCache[player][updatedKey] = updatedValue
        ClientInfoChangedSignal:Fire(player, updatedKey, updatedValue)

        if isNew then
            ClientInfoResolvedSignal:Fire(player, ClientInfoCache[player])
        end
    end)
end

--= Return Module =--
return ServerClientInfoHandler