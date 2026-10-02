--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    LocalizationCache.lua

    Description:
        Caches localization data for players, such as region and locale IDs.

        The engine lookups behind it yield, and for a player who just joined they
        can take seconds, so callers on a path that must not yield (engagement
        markers) use OnResolved and fill their fields in once it comes back.

        Each field is looked up and cached on its own: a caller that only needs
        the region never waits on the translator, and a lookup that failed is
        retried by the next caller rather than cached as unknown.

--]]

--= Root =--
local LocalizationCache = { }

--= Roblox Services =--

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

--= Dependencies =--

local Signal = shared.GBMod("Signal") ---@module Signal
local Utilities = shared.GBMod("Utilities") ---@module Utilities
local ServerGate = shared.GBMod("ServerGate") ---@module ServerGate

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

-- The engine lookup behind each field. Both yield, and either can fail for a player who just joined.
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
    Starts the lookup for one field, unless it is already cached or in flight. Always ends in a signal
    for that field, successful or not, so a caller waiting on it is never left hanging.
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

        -- Only successes are cached; caching a failure would pin the player to "unknown" for their
        -- whole session, which reaches every marker and every country/language experiment filter.
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
    Starts whichever lookups are missing and hands the callback both fields once they have all come
    back. Already cached, the callback runs before this returns and there is no connection to hold;
    otherwise the connection waiting for them is returned, for callers to clean up with.
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
