--!strict
--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	AssignmentContext.luau

	Description:
		Builds the evaluation context sent with experiment assignment requests
		(`context` / `sharedContext` in the v2 endpoints). `roblox` holds standard
		properties, gathered only when targeting requires them. `properties` holds
		developer-defined ones set through the public Experiments service.

--]]

--= Root =--
local AssignmentContext = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local Utilities = require(script.Parent.Parent.Utilities)
local LocalizationCache = require(script.Parent.Parent.LocalizationCache) ---@module LocalizationCache
local ServerClientInfoHandler = require(script.Parent.Parent.ServerClientInfoHandler) ---@module ServerClientInfoHandler
local ServerGate = require(script.Parent.Parent.ServerGate) ---@module ServerGate

--= Types =--

export type PropertyScalar = string | number | boolean
export type PropertyValue = PropertyScalar | { PropertyScalar }
export type PropertyMap = { [string]: PropertyValue }

export type Context = {
	roblox: { [string]: any }?,
	properties: PropertyMap?,
}

--= Constants =--

--[[
	Version of the evaluation context schema sent with assignment requests.
]]
local CONTEXT_SCHEMA_VERSION = 1

--[[
	Backend limits on developer-defined properties. A request breaking any of them is rejected
	whole, failing every player in the batch, so they are enforced when a property is set.
]]
local MAX_LIST_PROPERTY_ITEMS = 100
local MAX_PROPERTY_NAME_LENGTH = 128
local MAX_PROPERTIES = 100

--[[
	How long to wait for context callbacks to finish, before skipping them
	and proceeding with assignment without their result.
]]
local MAX_CALLBACK_DURATION = 6

--[[
	A value the player's client reports, waiting at most MAX_CALLBACK_DURATION for it. Nil until
	the client reports, rather than the "unknown" default, so targeting never mistakes a missing
	value for a real one.
]]
local function GetClientReportedInfo(player: Player, key: string): any
	ServerClientInfoHandler:WaitUntilClientInfoResolved(player, MAX_CALLBACK_DURATION)
	if not ServerClientInfoHandler:IsClientInfoResolved(player) then
		return nil
	end
	return ServerClientInfoHandler:GetClientInfo(player, key)
end

--[[
	Getters for standard player properties that targeting requires. They may yield, but past
	`MAX_CALLBACK_DURATION` the request goes out without their result. placeId/placeVersion
	travel in the shared context instead.
]]
local PLAYER_PROPERTY_GETTERS: { [string]: (player: Player) -> any } = {
	inputType = function(player)
		return GetClientReportedInfo(player, "inputType")
	end,
	device = function(player)
		return GetClientReportedInfo(player, "device")
	end,
	deviceSubType = function(player)
		return GetClientReportedInfo(player, "deviceSubType")
	end,
	country = function(player)
		return LocalizationCache:GetRegionId(player)
	end,
	language = function(player)
		return LocalizationCache:GetLocaleId(player)
	end,
}

--[[
	Player properties only the client can report, missing from the context until it does.
]]
local CLIENT_REPORTED_PROPERTIES: { [string]: true } = {
	inputType = true,
	device = true,
	deviceSubType = true,
}

--[[
	Getters for standard server properties that targeting requires. placeId/placeVersion
	travel in the shared context.
]]
local SERVER_PROPERTY_GETTERS: { [string]: () -> any } = {}

--[[
	Standard properties every request carries in its shared context (see GetShared), so nothing
	is gathered per unit for them.
]]
local SHARED_ROBLOX_PROPERTIES: { [string]: true } = {
	placeId = true,
	placeVersion = true,
}

--[[
	Namespaces of a required property's context path (`roblox.inputType`, `properties.accountTier`).
	`unit.*` paths are resolved by the backend, so the SDK sends nothing for them.
]]
local ROBLOX_NAMESPACE = "roblox"
local PROPERTIES_NAMESPACE = "properties"

--= Variables =--

--[[
	Developer-defined properties, per player and for the server.
]]
local PropertiesByPlayer: { [Player]: PropertyMap } = {}
local ServerProperties: PropertyMap = {}

--= Internal Functions =--

--[[
	Runs the given callbacks in parallel, bounded by `MAX_CALLBACK_DURATION`.

	@canyield
]]
local function runBounded(callbacks: { () -> () })
	Utilities.waitForAnyCall({
		function()
			Utilities.waitForAllCalls(callbacks)
		end,
		function()
			task.wait(MAX_CALLBACK_DURATION)
		end,
	})
end

--[[
	Splits a property path like `roblox.inputType` into namespace and key. Only the first dot
	splits, since developer-defined keys may contain dots.
]]
local function splitPropertyPath(path: string): (string?, string)
	local namespace, key = string.match(path, "^([^%.]+)%.(.+)$")
	if not namespace or not key then
		return nil, path
	end
	return namespace, key
end

local function isScalar(value: any): boolean
	local valueType = type(value)
	if valueType == "string" or valueType == "boolean" then
		return true
	end
	if valueType == "number" then
		-- NaN and infinities cannot be encoded as JSON
		return value == value and value ~= math.huge and value ~= -math.huge
	end
	return false
end

--[[
	Checks a property value against what the backend accepts. Returns a reason when invalid.
]]
local function validatePropertyValue(value: any): (boolean, string?)
	if isScalar(value) then
		return true, nil
	end

	if type(value) ~= "table" then
		return false, `unsupported type "{typeof(value)}"`
	end

	local itemCount = 0
	local listType: string? = nil
	for key, item in value do
		itemCount += 1
		if key ~= itemCount then
			return false, "tables must be lists (sequential numeric keys)"
		end
		if not isScalar(item) then
			return false, `list item {itemCount} has unsupported type "{typeof(item)}"`
		end

		-- The backend rejects mixed lists, containsAny over them has no stable meaning
		listType = listType or type(item)
		if type(item) ~= listType then
			return false, `lists must hold one type of value, but item {itemCount} is a {type(item)} in a list of {listType}s`
		end
	end

	if itemCount > MAX_LIST_PROPERTY_ITEMS then
		return false, `lists may have at most {MAX_LIST_PROPERTY_ITEMS} items`
	end

	return true, nil
end

--[[
	Sets (or clears, when `value` is nil) a single property in a store.
	Returns whether the store changed.
]]
local function setProperty(store: PropertyMap, key: any, value: any, subjectLabel: string): boolean
	if type(key) ~= "string" or #key == 0 then
		Utilities.GBWarn(`Experiment property keys must be non-empty strings ({subjectLabel}).`)
		return false
	end

	if #key > MAX_PROPERTY_NAME_LENGTH then
		Utilities.GBWarn(`Ignoring experiment property "{string.sub(key, 1, 32)}..." ({subjectLabel}): names may be at most {MAX_PROPERTY_NAME_LENGTH} characters.`)
		return false
	end

	if value == nil then
		if store[key] == nil then
			return false
		end
		store[key] = nil
		return true
	end

	local isValid, reason = validatePropertyValue(value)
	if not isValid then
		Utilities.GBWarn(`Ignoring experiment property "{key}" ({subjectLabel}): {reason}.`)
		return false
	end

	if Utilities.primativeDeepEqual(store[key], value) then
		return false
	end

	-- Only adding a property can break the limit; replacing one can't
	if store[key] == nil then
		local propertyCount = 0
		for _ in store do
			propertyCount += 1
		end
		if propertyCount >= MAX_PROPERTIES then
			Utilities.GBWarn(`Ignoring experiment property "{key}" ({subjectLabel}): at most {MAX_PROPERTIES} properties can be set.`)
			return false
		end
	end

	-- Copy lists so later mutation by the caller cannot desync the store
	store[key] = if type(value) == "table" then table.clone(value) else value
	return true
end

local function copyProperties(store: PropertyMap): PropertyMap
	local copy: PropertyMap = {}
	for key, value in store do
		copy[key] = if type(value) == "table" then table.clone(value) else value
	end
	return copy
end

--[[
	Assembles a context from its sections, omitting empty ones so they are never
	serialized as JSON arrays. Returns nil when nothing remains.
]]
local function buildContext(robloxContext: { [string]: any }?, properties: PropertyMap?): Context?
	local context: Context = {}

	if robloxContext and next(robloxContext) ~= nil then
		context.roblox = robloxContext
	end
	if properties and next(properties) ~= nil then
		context.properties = copyProperties(properties)
	end

	return if next(context) ~= nil then context else nil
end

--= API Functions =--

--[[
	Merges developer-defined properties for a player. Use SetPlayerProperty to clear one,
	since a table can't hold nil. Returns whether anything changed.
]]
function AssignmentContext:SetPlayerProperties(player: Player, properties: { [string]: any }): boolean
	if player.Parent == nil then
		return false
	end

	local store = PropertiesByPlayer[player]
	if not store then
		store = {}
		PropertiesByPlayer[player] = store
	end

	local didChange = false
	for key, value in properties do
		if setProperty(store, key, value, `player {player.UserId}`) then
			didChange = true
		end
	end
	return didChange
end

--[[
	Sets or clears (when `value` is nil) a single developer-defined property
	for a player. Returns whether anything changed.
]]
function AssignmentContext:SetPlayerProperty(player: Player, key: string, value: any): boolean
	if player.Parent == nil then
		return false
	end

	local store = PropertiesByPlayer[player]
	if not store then
		if value == nil then
			return false
		end
		store = {}
		PropertiesByPlayer[player] = store
	end

	return setProperty(store, key, value, `player {player.UserId}`)
end

function AssignmentContext:GetPlayerProperties(player: Player): PropertyMap
	return copyProperties(PropertiesByPlayer[player] or {})
end

--[[
	Merges developer-defined properties for the server. Returns whether anything changed.
]]
function AssignmentContext:SetServerProperties(properties: { [string]: any }): boolean
	local didChange = false
	for key, value in properties do
		if setProperty(ServerProperties, key, value, "server") then
			didChange = true
		end
	end
	return didChange
end

--[[
	Sets or clears (when `value` is nil) a single developer-defined property
	for the server. Returns whether anything changed.
]]
function AssignmentContext:SetServerProperty(key: string, value: any): boolean
	return setProperty(ServerProperties, key, value, "server")
end

function AssignmentContext:GetServerProperties(): PropertyMap
	return copyProperties(ServerProperties)
end

--[[
	Shared context for a bulk assignment request: this place and the server's
	developer-defined properties. Per-unit context values win over these per key.
]]
function AssignmentContext:GetShared(): { [string]: any }
	local sharedContext: { [string]: any } = {
		roblox = {
			placeId = game.PlaceId,
			placeVersion = game.PlaceVersion,
		},
		schemaVersion = CONTEXT_SCHEMA_VERSION,
	}

	if next(ServerProperties) ~= nil then
		sharedContext.properties = copyProperties(ServerProperties)
	end

	return sharedContext
end

--[[
	Gathers per-player evaluation context. Players who resolve no context are omitted.

	Also returns players whose client hadn't reported in when targeting needs a client-reported
	property, so their assignment can be requested again once it does.

	@canyield
]]
function AssignmentContext:GetForPlayers(playerIds: { number }, requiredProperties: { string }): ({ [number]: Context }, { Player })
	local robloxContextByPlayerId: { [number]: { [string]: any } } = {}
	local retrievalCallbacks: { () -> () } = {}

	local needsClientInfo = false
	for _, path in requiredProperties do
		local namespace, key = splitPropertyPath(path)
		if namespace == ROBLOX_NAMESPACE and CLIENT_REPORTED_PROPERTIES[key] then
			needsClientInfo = true
			break
		end
	end

	for _, playerId in playerIds do
		local player = Players:GetPlayerByUserId(playerId)
		if not player then
			continue
		end

		local robloxContext: { [string]: any } = {}
		robloxContextByPlayerId[playerId] = robloxContext

		local playerProperties = PropertiesByPlayer[player]
		for _, path in requiredProperties do
			local namespace, key = splitPropertyPath(path)

			if namespace == ROBLOX_NAMESPACE then
				local getter = PLAYER_PROPERTY_GETTERS[key]
				if getter then
					table.insert(retrievalCallbacks, function()
						robloxContext[key] = getter(player)
					end)
				elseif not SHARED_ROBLOX_PROPERTIES[key] then
					Utilities.GBLog(`Experiment targeting requires "{path}", which this SDK does not report for players`)
				end
			elseif namespace == PROPERTIES_NAMESPACE then
				-- Server properties travel as shared context, so they cover a player who has no value of their own
				if (not playerProperties or playerProperties[key] == nil) and ServerProperties[key] == nil then
					Utilities.GBLog(`Experiment targeting requires property "{key}" which is not set for player {playerId}`)
				end
			end
		end
	end

	runBounded(retrievalCallbacks)

	local contextByPlayerId: { [number]: Context } = {}
	local playersAwaitingClientInfo: { Player } = {}
	for playerId, robloxContext in robloxContextByPlayerId do
		local player = Players:GetPlayerByUserId(playerId)
		local context = buildContext(robloxContext, if player then PropertiesByPlayer[player] else nil)
		if context then
			contextByPlayerId[playerId] = context
		end

		if player and needsClientInfo and not ServerClientInfoHandler:IsClientInfoResolved(player) then
			table.insert(playersAwaitingClientInfo, player)
		end
	end

	return contextByPlayerId, playersAwaitingClientInfo
end

--[[
	Gathers server evaluation context. Returns nil when nothing resolves.

	@canyield
]]
function AssignmentContext:GetForServer(requiredProperties: { string }): Context?
	local robloxContext: { [string]: any } = {}
	local retrievalCallbacks: { () -> () } = {}

	for _, path in requiredProperties do
		local namespace, key = splitPropertyPath(path)

		if namespace == ROBLOX_NAMESPACE then
			local getter = SERVER_PROPERTY_GETTERS[key]
			if getter then
				table.insert(retrievalCallbacks, function()
					robloxContext[key] = getter()
				end)
			elseif not SHARED_ROBLOX_PROPERTIES[key] then
				Utilities.GBLog(`Experiment targeting requires "{path}", which this SDK does not report for servers`)
			end
		elseif namespace == PROPERTIES_NAMESPACE and ServerProperties[key] == nil then
			Utilities.GBLog(`Experiment targeting requires server property "{key}" which is not set`)
		end
	end

	runBounded(retrievalCallbacks)

	return buildContext(robloxContext, ServerProperties)
end

--= Initializers =--
do
	ServerGate:OnPlayerRemoved(function(player: Player)
		PropertiesByPlayer[player] = nil
	end)
end

--= Return Module =--
return AssignmentContext
