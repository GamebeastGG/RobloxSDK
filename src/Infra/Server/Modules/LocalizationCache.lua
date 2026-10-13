--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    LocalizationCache.lua

    Description:
        Caches players' region and locale IDs.

        The engine lookups yield, for seconds for a player who just joined, so
        callers that must not yield (engagement markers) use OnResolved. Each
        field is cached on its own, and a failed lookup is not cached.

--]]

--= Root =--
local LocalizationCache = { }

--= Roblox Services =--

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

--= Dependencies =--

local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local Utilities = require(script.Parent.Utilities) ---@module Utilities
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate

--= Types =--

export type Localization = {
    localeId : string,
    regionId : string,
}

--= Object References =--

-- Fires (player, field, value), with a nil value when the engine lookup failed.
local ResolvedSignal = Signal.new()

--= Constants =--

local function ConvertLocaleToISO(localeId : string) : string
    local locale = string.split(localeId, "-")
    return string.lower(locale[1])
end

-- Both yield, and either can fail for a player who just joined
local FIELD_LOOKUPS : { [string] : (player : Player) -> string } = {
    localeId = function(player)
        return ConvertLocaleToISO(LocalizationService:GetTranslatorForPlayerAsync(player).LocaleId)
    end,
    regionId = function(player)
        return LocalizationService:GetCountryRegionForPlayerAsync(player)
    end,
}

-- Stands in for a field the engine never gave us. Never cached, so the next caller tries again.
local UNKNOWN = "unknown"

--= Variables =--

local Cache = ServerGate:GetCache()
-- Lookups in flight, per player and field, so concurrent callers share one engine call.
local Resolving = {}

--= Public Variables =--

--= Internal Functions =--

local function GetCachedField(player : Player, field : string) : string?
    local cached = Cache[player]
    return cached and cached[field]
end

--[[
    A started lookup always fires the signal for its field, success or not, so no waiter is left hanging.
]]
local function ResolveField(player : Player, field : string)
    if GetCachedField(player, field) then
        return
    end

    local inFlight = Resolving[player]
    if inFlight and inFlight[field] then
        return
    end

    if not inFlight then
        inFlight = {}
        Resolving[player] = inFlight
    end
    inFlight[field] = true

    task.spawn(function()
        local value = Utilities.promiseReturn(1, function()
            return FIELD_LOOKUPS[field](player)
        end)

        inFlight[field] = nil
        if next(inFlight) == nil and Resolving[player] == inFlight then
            Resolving[player] = nil
        end

        -- Only successes are cached, so one failure doesn't pin the player to "unknown" for the session
        if value ~= nil then
            if not Cache[player] then
                -- Refused by the cache once the player has left, hence the nil check below
                Cache[player] = {}
            end

            local entry = Cache[player]
            if entry then
                entry[field] = value
            end
        end

        ResolvedSignal:Fire(player, field, value)
    end)
end

--[[
    Resolves one field, yielding until the lookup comes back.

    @canyield
]]
local function WaitForField(player : Player, field : string) : string
    local cached = GetCachedField(player, field)
    if cached then
        return cached
    end

    local thread = coroutine.running()
    local didResolve = false
    local resolvedValue = nil

    local connection; connection = ResolvedSignal:Connect(function(resolvedPlayer : Player, resolvedField : string, value : string?)
        if resolvedPlayer ~= player or resolvedField ~= field then
            return
        end

        connection:Disconnect()
        didResolve = true
        resolvedValue = value

        if coroutine.status(thread) == "suspended" then
            coroutine.resume(thread)
        end
    end)

    ResolveField(player, field)

    if not didResolve then
        coroutine.yield()
    end

    return resolvedValue or UNKNOWN
end

--= API Functions =--

--[[
    Calls back with both fields once resolved. If both are cached, the callback runs before this
    returns and nil is returned; otherwise returns the waiting connection.
]]
function LocalizationCache:OnResolved(player : Player | number, callback : (localization : Localization) -> ()) : RBXScriptConnection?
    player = Utilities.resolvePlayerObject(player)

    if not player then
        callback({ localeId = UNKNOWN, regionId = UNKNOWN })
        return nil
    end

    local values = {}
    local pending = {}
    local pendingCount = 0

    for field in FIELD_LOOKUPS do
        local cached = GetCachedField(player, field)
        if cached then
            values[field] = cached
        else
            pending[field] = true
            pendingCount += 1
        end
    end

    if pendingCount == 0 then
        callback({ localeId = values.localeId, regionId = values.regionId })
        return nil
    end

    local connection; connection = ResolvedSignal:Connect(function(resolvedPlayer : Player, field : string, value : string?)
        if resolvedPlayer ~= player or not pending[field] then
            return
        end

        pending[field] = nil
        pendingCount -= 1
        values[field] = value or UNKNOWN

        if pendingCount == 0 then
            connection:Disconnect()
            callback({ localeId = values.localeId, regionId = values.regionId })
        end
    end)

    -- Collected first: starting a lookup must not mutate what is being iterated
    local toResolve = {}
    for field in pending do
        table.insert(toResolve, field)
    end

    for _, field in toResolve do
        ResolveField(player, field)
    end

    return connection
end

--[[
    Resolves both fields, yielding until they have come back.

    @canyield
]]
function LocalizationCache:Get(player : Player | number) : Localization
    local thread = coroutine.running()
    local resolved : Localization? = nil

    self:OnResolved(player, function(localization : Localization)
        resolved = localization

        if coroutine.status(thread) == "suspended" then
            coroutine.resume(thread)
        end
    end)

    if not resolved then
        coroutine.yield()
    end

    return resolved :: Localization
end

--[[
    @canyield
]]
function LocalizationCache:GetRegionId(player : Player | number) : string
    player = Utilities.resolvePlayerObject(player)
    if not player then
        return UNKNOWN
    end

    return WaitForField(player, "regionId")
end

--[[
    @canyield
]]
function LocalizationCache:GetLocaleId(player : Player | number) : string
    player = Utilities.resolvePlayerObject(player)
    if not player then
        return UNKNOWN
    end

    return WaitForField(player, "localeId")
end

--= Initializers =--

--= Return Module =--
return LocalizationCache
