--!strict
--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	AssignmentContext.luau

	Description:
		Builds the evaluation context sent with experiment assignment requests
		(the `context` / `sharedContext` objects of the v2 endpoints).

		A context has two sections:
		- `roblox`: standard properties (device, locale, place, ...) gathered by
		  the SDK itself, only when experiment targeting requires them.
		- `properties`: developer-defined properties set through the public
		  Experiments service, stored here per player and for the server.

--]]

--= Root =--
local AssignmentContext = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local LocalizationCache = shared.GBMod("LocalizationCache") ---@module LocalizationCache
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local ServerGate = shared.GBMod("ServerGate") ---@module ServerGate

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
	Backend limit on the number of items in a list-valued property.
]]
local MAX_LIST_PROPERTY_ITEMS = 100

--[[
	How long to wait for context callbacks to finish, before skipping them
	and proceeding with assignment without their result.
]]
local MAX_CALLBACK_DURATION = 6

--[[
	When experiments have filters that require player properties, these
	callbacks are ran to retrieve and include that context in assignment
	requests.

	These callbacks can yield, but ideally should not yield for too long. If a
	callback yields for longer than `MAX_CALLBACK_DURATION` seconds, the
	assignment request will proceed without its result.

	placeId/placeVersion are omitted here because they are sent in the request's
	shared context instead.
]]
local PLAYER_PROPERTY_GETTERS: { [string]: (player: Player) -> any } = {
	inputType = function(player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "inputType")
	end,
	device = function(player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "device")
	end,
	deviceSubType = function(player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "deviceSubType")
	end,
	country = function(player)
		return LocalizationCache:GetRegionId(player)
	end,
	language = function(player)
		return LocalizationCache:GetLocaleId(player)
	end,
}

--[[
	When experiments have filters that require server properties, these
	callbacks are ran to retrieve and include that context in assignment
	requests. (placeId/placeVersion travel in the shared context.)
]]
local SERVER_PROPERTY_GETTERS: { [string]: () -> any } = {}

--[[
	Standard properties every request already carries in its shared context (see GetShared), so
	targeting on them needs nothing gathered per unit.
]]
local SHARED_ROBLOX_PROPERTIES: { [string]: true } = {
	placeId = true,
	placeVersion = true,
}

--[[
	The context namespaces a required property can be read from. Targeting names each property by
	its full context path (`roblox.inputType`, `properties.accountTier`), and the namespace decides
	where the SDK finds the value. `unit.*` paths (`unit.isNewUser`) are resolved by the backend
	from the unit itself, so the SDK has nothing to send for them.
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
	Splits a required property path into its context namespace and the key within it, e.g.
	`roblox.inputType` into "roblox" and "inputType". Only the first dot separates them, since a
	developer-defined property key may contain dots of its own.
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
	Checks that a property value matches what the backend accepts: a string,
	finite number, boolean, or a list of those with at most
	`MAX_LIST_PROPERTY_ITEMS` items. Returns a reason when invalid.
]]
local function validatePropertyValue(value: any): (boolean, string?)
	if isScalar(value) then
		return true, nil
	end

	if type(value) ~= "table" then
		return false, `unsupported type "{typeof(value)}"`
	end

	local itemCount = 0
	for key, item in value do
		itemCount += 1
		if key ~= itemCount then
			return false, "tables must be lists (sequential numeric keys)"
		end
		if not isScalar(item) then
			return false, `list item {itemCount} has unsupported type "{typeof(item)}"`
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
	Merges developer-defined properties for a player (nil values are not
	representable in a table; use SetPlayerProperty to clear one).
	Returns whether anything changed.
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
	Returns the shared context for a bulk assignment request: facts every unit in
	the batch shares (this place, and the server's developer-defined properties).
	Per-unit context values win over these per key.
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
	Gathers per-player evaluation context: the standard properties required by
	experiment targeting, plus the player's developer-defined properties.
	Players who resolve no context are omitted from the result.

	@canyield
]]
function AssignmentContext:GetForPlayers(playerIds: { number }, requiredProperties: { string }): { [number]: Context }
	local robloxContextByPlayerId: { [number]: { [string]: any } } = {}
	local retrievalCallbacks: { () -> () } = {}

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
	for playerId, robloxContext in robloxContextByPlayerId do
		local player = Players:GetPlayerByUserId(playerId)
		local context = buildContext(robloxContext, if player then PropertiesByPlayer[player] else nil)
		if context then
			contextByPlayerId[playerId] = context
		end
	end

	return contextByPlayerId
end

--[[
	Gathers server evaluation context: the standard properties required by
	experiment targeting, plus the server's developer-defined properties.
	Returns nil when nothing resolves.

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
