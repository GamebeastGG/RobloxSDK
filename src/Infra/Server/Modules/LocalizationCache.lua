--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    LocalizationCache.lua
    
    Description:
        Caches localization data for players, such as region and locale IDs.
    
--]]

--= Root =--
local LocalizationCache = { }

--= Roblox Services =--

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local Cache = {}

--= Public Variables =--

--= Internal Functions =--

local function ConvertLocaleToISO(localeId : string) : string
    local locale = string.split(localeId, "-")
    return string.lower(locale[1])
end

--= API Functions =--

--[[
    @canyield
]]
function LocalizationCache:GetRegionId(player : Player | number)
    player = Utilities.resolvePlayerObject(player)

    if not Cache[player] then
        Cache[player] = {}
    end

    if Cache[player].regionId then
        return Cache[player].regionId
    end

    local regionId = Utilities.promiseReturn(1, function()
        return LocalizationService:GetCountryRegionForPlayerAsync(player)
    end)

    if Cache[player] then
        Cache[player].regionId = regionId
    end

    return regionId or "unknown"
end

--[[
    @canyield
]]
function LocalizationCache:GetLocaleId(player : Player | number)
    player = Utilities.resolvePlayerObject(player)

    if not Cache[player] then
        Cache[player] = {}
    end

    if Cache[player].localeId then
        return Cache[player].localeId
    end

    local localeId = Utilities.promiseReturn(1, function()
        return ConvertLocaleToISO(LocalizationService:GetTranslatorForPlayerAsync(player).LocaleId)
    end)

    if Cache[player] then
        Cache[player].localeId = localeId
    end

    return localeId or "unknown"
end

--= Initializers =--
function LocalizationCache:Init()
    Players.PlayerRemoving:Connect(function(player : Player)
        Cache[player] = nil
    end)
end

--= Return Module =--
return LocalizationCache