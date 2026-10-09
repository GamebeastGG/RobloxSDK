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

local GetRemote = require(script.Parent.Parent.Parent.Shared.Modules.GetRemote)
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal)
local GBRequests = require(script.Parent.GBRequests) ---@module GBRequests
local SignalTimeout = require(script.Parent.Parent.Parent.Shared.Modules.SignalTimeout) ---@module SignalTimeout
local Schema = require(script.Parent.Parent.Parent.Shared.Modules.Schema) ---@module Schema
local Utilities = require(script.Parent.Utilities) ---@module Utilities
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")
local ClientInfoRequestRemote = GetRemote("Function", "GetClientInfo")
local ClientProductPriceRemote = GetRemote("Function", "GetProductPrice")
-- Neither signal copies its arguments per listener. Every pending marker listens for its player's
-- info to resolve, so each join copied the info once per pending marker in the server. Listeners
-- receive a clone (OnClientInfoResolved) or a validated scalar (OnClientInfoChanged).
local ClientInfoResolvedSignal = Signal.new({ copyArguments = false })
local ClientInfoChangedSignal = Signal.new({ copyArguments = false })

--= Constants =--

-- Longest string a client may report for any client info value
local MAX_CLIENT_STRING_LENGTH = 64

-- Shortest time between two client info updates applied for one player. Each one fans out to a
-- listener per player in the server, so a client spamming the remote multiplied its cost by the
-- player count. Reports inside the window are coalesced and the newest applied when it ends; the
-- client always sends its full info, so nothing is lost.
local MIN_CLIENT_INFO_INTERVAL = 0.5

-- The values the backend's targeting knows for each client-reported field
local CLIENT_INFO_VOCABULARIES = {
    inputType = { keyboard = true, gamepad = true, touch = true, unknown = true },
    device = { mobile = true, console = true, pc = true, vr = true, unknown = true },
    deviceSubType = { tablet = true, phone = true, xbox = true, playstation = true, unknown = true },
}

-- HttpService:GenerateGUID(false), e.g. 8f0e2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b
local SESSION_ID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

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
    },
    friendClockStart = {
        default = nil,
        type = "number",
    }
})

--= Variables =--

local ClientInfoCache = ServerGate:GetCache()
-- Per player: when an info report was last applied, and the newest one waiting for its window
local ClientInfoThrottleByPlayer = ServerGate:GetCache()

--= Public Variables =--

--= Internal Functions =--

--[[
    Whether a value reported by a client may be stored. The client is untrusted, and these values
    reach a lot: device and input type go into the experiment assignment request, which covers every
    player in the server, so one bad value used to have the whole request rejected; all of them are
    stamped on the player's markers; and the numbers feed session arithmetic on the way out.
]]
local function IsValidClientInfo(key : string, value : any) : boolean
    if not DefaultInfo:MatchesType(key, value) then
        return false
    end

    if type(value) == "number" then
        -- NaN and infinities can't be encoded as JSON, and break the session arithmetic
        return value == value and value ~= math.huge and value ~= -math.huge
    end

    if type(value) == "string" then
        if #value > MAX_CLIENT_STRING_LENGTH then
            return false
        end

        local vocabulary = CLIENT_INFO_VOCABULARIES[key]
        if vocabulary then
            return vocabulary[value] == true
        end

        if key == "sessionId" then
            -- The SDK generates these with GenerateGUID; anything else did not come from it
            return string.match(value, SESSION_ID_PATTERN) ~= nil
        end
    end

    return true
end

local function UpdateClientInfoCache(player : Player, updatedInfo : { [string] : any })
    if type(updatedInfo) ~= "table" then
        return
    end

    local isNew = false
    if not ClientInfoCache[player] then
        ClientInfoCache[player] = DefaultInfo:GetDefault()
        isNew = true
    end

    for updatedKey, updatedValue in pairs(updatedInfo) do
        if type(updatedKey) ~= "string" or not DefaultInfo:HasKey(updatedKey) then
            continue
        end

        -- Dropped rather than stored; the previous (or default) value stands
        if not IsValidClientInfo(updatedKey, updatedValue) then
            continue
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

-- Handles a client's info report, applying at most one per MIN_CLIENT_INFO_INTERVAL per player
local function OnClientInfoReported(player : Player, updatedInfo : any)
    if type(updatedInfo) ~= "table" then
        return
    end

    local throttle = ClientInfoThrottleByPlayer[player]
    if not throttle then
        throttle = { lastApplied = -math.huge, pending = nil }
        ClientInfoThrottleByPlayer[player] = throttle
    end

    local remaining = MIN_CLIENT_INFO_INTERVAL - (os.clock() - throttle.lastApplied)
    if remaining <= 0 then
        throttle.lastApplied = os.clock()
        UpdateClientInfoCache(player, updatedInfo)
        return
    end

    -- Inside the window: keep only the newest report, and apply it when the window ends
    local isScheduled = throttle.pending ~= nil
    throttle.pending = updatedInfo
    if not isScheduled then
        task.delay(remaining, function()
            local pending = throttle.pending
            throttle.pending = nil
            if pending and player.Parent then
                throttle.lastApplied = os.clock()
                UpdateClientInfoCache(player, pending)
            end
        end)
    end
end

--= API Functions =--

-- Whether a client-reported value would be accepted for `key`; values that aren't are dropped.
function ServerClientInfoHandler:IsValidClientInfo(key : string, value : any) : boolean
    return DefaultInfo:HasKey(key) and IsValidClientInfo(key, value)
end

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

function ServerClientInfoHandler:GetProductInfoForPlayer(player : Player | number, productId : number, productType : Enum.InfoType) : {[string] : any}?
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

    Utilities:OnPlayerAdded(function(player)
        local success, clientInfo = pcall(function()
            return ClientInfoRequestRemote:InvokeClient(player)
        end)

        if success and clientInfo then
            UpdateClientInfoCache(player, clientInfo)
        end
    end)

    Players.PlayerRemoving:Connect(function(player : Player)
        ClientInfoResolvedSignal:Fire(player, nil)
    end)

    ClientInfoRemote.OnServerEvent:Connect(OnClientInfoReported)
end

--= Return Module =--
return ServerClientInfoHandler