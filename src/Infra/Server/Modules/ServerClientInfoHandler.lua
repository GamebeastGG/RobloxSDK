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
local Schema = shared.GBMod("Schema") ---@module Schema

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")
local ClientInfoResolvedSignal = Signal.new()
local ClientInfoChangedSignal = Signal.new()

--= Constants =--

local DefaultInfo = Schema.new({
    inputType = {
        default = "unknown",
        type = "string",
    },
    device = {
        default = "unknown",
        type = "string",
    },
    deviceSubType = {
        default = "unknown",
        type = "string",
    },
    -- Preserved
    sessionId = {
        default = nil,
        type = "string",
    },
    joinTime = {
        default = nil,
        type = "number",
    },
    totalFriendPlaytime = {
        default = 0,
        type = "number",
    },
    hasFriendsOnline = {
        default = false,
        type = "boolean",
    }
})

--= Variables =--

local ClientInfoCache = {}

--= Public Variables =--

--= Internal Functions =--

local function UpdateClientInfoCache(player : Player, updatedInfo : { [string] : any })
    local isNew = false
    if not ClientInfoCache[player] then
        ClientInfoCache[player] = DefaultInfo:GetDefault()
        isNew = true
    end

    for updatedKey, updatedValue in pairs(updatedInfo) do
        if not DefaultInfo:HasKey(updatedKey) then
            return
        end

        local currentValue = ClientInfoCache[player][updatedKey]
        if currentValue == updatedValue then
            continue
        end

        ClientInfoCache[player][updatedKey] = updatedValue
        ClientInfoChangedSignal:Fire(player, updatedKey, updatedValue)
    end

    if isNew then
        ClientInfoResolvedSignal:Fire(player, ClientInfoCache[player])
    end
end

--= API Functions =--

function ServerClientInfoHandler:GetClientInfo(player : Player | number, key : string) : any
    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    if not player or not ClientInfoCache[player] or ClientInfoCache[player][key] == nil then
        return DefaultInfo:GetDefaultForKey(key)
    end
    
    return ClientInfoCache[player][key]
end

function ServerClientInfoHandler:OnClientInfoResolved(player : Player, callback : (info : { [string] : any }) -> nil)
    if self:IsClientInfoResolved(player) then
        callback(table.clone(ClientInfoCache[player]))
        return
    end

    local connection
    connection = ClientInfoResolvedSignal:Connect(function(resolvedPlayer : Player, clientInfo : { [string] : any })
        if resolvedPlayer == player then
            connection:Disconnect()

            if clientInfo then
                callback(table.clone(clientInfo))
            end
        end
    end)

    return connection
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
    assert(player, "Player must be provided to check client info resolution.")

    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    return ClientInfoCache[player] ~= nil
end

--[[
    If the specific player's client info hasn't resolved, yields until it
    resolves.

    @canyield
]]
function ServerClientInfoHandler:WaitUntilClientInfoResolved(player: Player, timeout: number?)
    if ServerClientInfoHandler:IsClientInfoResolved(player) then
        return
    end

    local thread = coroutine.running()
    local timeoutThread: thread? = nil
    local didResume = false

    -- Listen for resolution to trigger resumption
    local resolveListener = self:OnClientInfoResolved(player, function ()
        if not didResume then
            didResume = true
            coroutine.resume(thread)
        end
    end)

    -- Listen for timeout to trigger early resumption
    if timeout then
        timeoutThread = task.delay(timeout, function ()
            if not didResume then
                timeoutThread = nil
                didResume = true
                coroutine.resume(thread)
            end
        end)
    end

    -- Wait until info resolves, or timeout is reached
    coroutine.yield()

    -- Clean up triggers before returning control
    resolveListener:Disconnect()
    if timeoutThread then
        task.cancel(timeoutThread)
    end
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

function ServerClientInfoHandler:UpdateClientData(player : Player | number, key : string, value : any)
    if typeof(player) == "number" then
        player = Players:GetPlayerByUserId(player)
    end

    self:OnClientInfoResolved(player, function()
        if not player.Parent then
            return -- Player is not in the game, do not update cache
        end

        --UpdateClientInfoCache(player, {[key] = value}, true) -- We actually want the client to send this back to us.
        ClientInfoRemote:FireClient(player, key, value)
    end)
end

--= Initializers =--
function ServerClientInfoHandler:Init()
    Players.PlayerRemoving:Connect(function(player : Player)
        ClientInfoResolvedSignal:Fire(player, nil)
        task.defer(function()
            ClientInfoCache[player] = nil
        end)
    end)

    ClientInfoRemote.OnServerEvent:Connect(UpdateClientInfoCache)
end

--= Return Module =--
return ServerClientInfoHandler