--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    LocalizationCache.lua
    
    Description:
        Caches localization data for players, such as region and locale IDs.

        The engine lookups behind it yield, and for a player who just joined they
        can take seconds, so callers on a path that must not yield (engagement
        markers) use OnResolved and fill their fields in once it comes back.
    
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

local ResolvedSignal = Signal.new()

--= Constants =--

-- Stands in for either field when the engine never gave us one.
local UNKNOWN = "unknown"

--= Variables =--

local Cache = ServerGate:GetCache()
-- Players whose lookups are in flight, so concurrent callers share one pair of engine calls.
local Resolving = {}

--= Public Variables =--

--= Internal Functions =--

local function ConvertLocaleToISO(localeId : string) : string
    local locale = string.split(localeId, "-")
    return string.lower(locale[1])
end

-- Runs both engine lookups in parallel and caches the result, so waiting on localization costs the
-- slower of the two rather than both. Always fires, even for a player who left mid-lookup: callers
-- hold markers open until it does.
local function ResolveForPlayer(player : Player)
    if Resolving[player] or Cache[player] then
        return
    end

    Resolving[player] = true

    task.spawn(function()
        local localeId, regionId

        Utilities.waitForAllCalls({
            function()
                localeId = Utilities.promiseReturn(1, function()
                    return ConvertLocaleToISO(LocalizationService:GetTranslatorForPlayerAsync(player).LocaleId)
                end)
            end,
            function()
                regionId = Utilities.promiseReturn(1, function()
                    return LocalizationService:GetCountryRegionForPlayerAsync(player)
                end)
            end,
        })

        local localization : Localization = {
            localeId = localeId or UNKNOWN,
            regionId = regionId or UNKNOWN,
        }

        Resolving[player] = nil
        -- Dropped by the cache if the player has already left
        Cache[player] = localization

        ResolvedSignal:Fire(player, localization)
    end)
end

--= API Functions =--

--[[
    Starts the player's localization lookups if they haven't started, and hands the result to the
    callback. Already cached, the callback runs before this returns and there is no connection to
    hold; otherwise the connection waiting for it is returned, for callers to clean up with.
]]
function LocalizationCache:OnResolved(player : Player | number, callback : (localization : Localization) -> ()) : RBXScriptConnection?
    player = Utilities.resolvePlayerObject(player)

    if not player then
        callback({ localeId = UNKNOWN, regionId = UNKNOWN })
        return nil
    end

    local cached = Cache[player]
    if cached then
        callback(cached)
        return nil
    end

    local connection; connection = ResolvedSignal:Connect(function(resolvedPlayer : Player, localization : Localization)
        if resolvedPlayer ~= player then
            return
        end

        connection:Disconnect()
        callback(localization)
    end)

    ResolveForPlayer(player)

    return connection
end

--[[
    @canyield
]]
function LocalizationCache:Get(player : Player | number) : Localization
    local resolved : Localization? = nil
    local thread = coroutine.running()

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
    return self:Get(player).regionId
end

--[[
    @canyield
]]
function LocalizationCache:GetLocaleId(player : Player | number) : string
    return self:Get(player).localeId
end

--= Initializers =--

--= Return Module =--
return LocalizationCache
