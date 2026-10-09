--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	InternalConfigs.luau

	Description:
		Internal module for managing configuration data across the server and clients.
		Holds every configuration for the environment, keyed by id, and resolves
		consumer paths whose first segment is the configuration's alias or name.

--]]

--= Root =--
local InternalConfigs = { }

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local GetRemote = shared.GBMod("GetRemote")
local Signal = shared.GBMod("Signal")
local SignalConnection = shared.GBMod("SignalConnection")

--= Types =--

export type ConfigEntry = {
	id : number,
	name : string?,
	alias : string?,
	hash : string,
	updatedAt : string?,

	-- Unevaluated configuration document from the backend
	base : { [string] : any },
	-- Per-config privacy paths
	privacy : { { string } },

	-- Evaluated server view (base + server experiment changesets), frozen
	serverView : { [string] : any }?,
	-- Sparse per-player evaluated views; absent players fall back to the server view
	viewByPlayer : { [Player] : { [string] : any } },
}

--= Object References =--

local GetConfigRemoteFunc = GetRemote("Function", "Get")
local ConfigChangedRemote = GetRemote("Event", "ConfigChanged")
-- Neither signal copies its arguments per listener: a game can hold hundreds of config subscriptions,
-- and each used to receive its own deep copy of the configuration on every fire. Listeners only read
-- them, and the old configs a change carries are frozen before they are shared.
local ConfigReadySignal = Signal.new({ copyArguments = false })
local BatchConfigUpdatedSignal = Signal.new({ copyArguments = false })

--= Constants =--

--= Variables =--

local ConfigsReady = false
local ActiveConfigs = {} :: { [number] : ConfigEntry }
-- Consumer path identifiers resolve alias first, then name, then id (as a string)
local ConfigIdByIdentifier = {} :: { [string] : number }

--= Public Variables =--

--= Internal Functions =--

local function RebuildIdentifierMap()
	table.clear(ConfigIdByIdentifier)

	-- Insertion order determines resolution priority: later writes win
	for configId in ActiveConfigs do
		ConfigIdByIdentifier[tostring(configId)] = configId
	end
	for configId, entry in ActiveConfigs do
		if entry.name then
			ConfigIdByIdentifier[entry.name] = configId
		end
	end
	for configId, entry in ActiveConfigs do
		if entry.alias then
			ConfigIdByIdentifier[entry.alias] = configId
		end
	end
end

local function ResolveConfigId(identifier : string) : number?
	return ConfigIdByIdentifier[tostring(identifier)]
end

local function GetIdentifierForEntry(entry : ConfigEntry) : string
	return entry.alias or entry.name or tostring(entry.id)
end

local function IsPathPrivate(path : {string}, privatePaths: {{string}}) : boolean
	for _, privacyPath in privatePaths do
		if #privacyPath > #path then
			continue
		end

		local match = true
		for index, pathSegment in ipairs(path) do -- a, d
			if privacyPath[index] == nil then
				return true
			elseif pathSegment ~= privacyPath[index] then
				match = false
				break
			end
		end

		if match then
			return true
		end
	end

	return false
end

local function FilterConfigForClient(path : {string}, config : {[string] : any}, privacyConfig: {{string}}) : {[string] : any}
	local configCopy = if typeof(config) == "table"
		then Utilities.recursiveCopy(config)
		else config

	-- Determine if the path is a match for any privacy paths
	local targetPaths = {}
	for _, privacyPath in privacyConfig do -- a, d, e
		local match = true
		for index, pathSegment in ipairs(path) do -- a, d
			if privacyPath[index] == nil then
				break
			elseif pathSegment ~= privacyPath[index] then
				match = false
				break
			end
		end

		if match then
			local relativePath = table.clone(privacyPath)
			for _=1, #path do
				table.remove(relativePath, 1)
			end

			table.insert(targetPaths, relativePath)
		end
	end

	-- Remove any paths that are marked as private
	for _, targetPath in targetPaths do

		-- Clear root value if path points to it
		if #targetPath == 0 then
			configCopy = nil
			break
		end

		-- Nothing private can be left inside a value that is not a table. A change that removes a
		-- key sitting above a privacy path arrives carrying no value at all, so there is nothing to
		-- scrub; descending into it raised "attempt to index nil" and, with no pcall around the poll
		-- loop, took status polling down with it for the rest of the server's life.
		if type(configCopy) ~= "table" then
			continue
		end

		local target = configCopy
		for index, pathSegment in targetPath do
			if index == #targetPath then
				target[pathSegment] = nil
				break
			else
				target = target[pathSegment]

				-- Covers a scalar as well as a missing key: either way the privacy path runs deeper
				-- than the document does, so there is nothing there to remove
				if type(target) ~= "table" then
					Utilities.GBWarn("Privacy path ".. table.concat(targetPath, ".").. " does not exist in config.")
					break
				end
			end
		end
	end

	return configCopy
end

local function addRootmostPathToSet(rootmostPathSet: {[string]: {string}?}, newPath: {string}): ()
	if #newPath == 0 then
		table.clear(rootmostPathSet)
	end

	-- Build hash key from path, escaping segment delimiter in case user-defined path contains it
	local escapedNewPath: {string} = table.create(#newPath)
	for _, pathSegment in newPath do
		table.insert(escapedNewPath, (pathSegment:gsub("\\", "\\\\"):gsub("%.", "\\.")))
	end
	local newPathKey = table.concat(escapedNewPath, ".")

	-- If already exactly in set, skip adding
	if rootmostPathSet[newPathKey] then
		return
	end

	-- Check if existing paths cover new path
	for existingPathKey in rootmostPathSet do
		if string.sub(newPathKey, 1, #existingPathKey) == existingPathKey then

			-- If new one is higher-level than existing, replace it
			if #newPathKey < #existingPathKey then
				rootmostPathSet[existingPathKey] = nil
				rootmostPathSet[newPathKey] = newPath
				return

			-- If existing is higher-level than new, skip adding
			else
				return
			end
		end
	end

	-- If no existing paths cover new path, add it to the set
	rootmostPathSet[newPathKey] = newPath
end

--= API Functions =--

function InternalConfigs:IsReady() : boolean
	return ConfigsReady
end

function InternalConfigs:OnReady(callback : (newConfigs : any) -> ()) : RBXScriptConnection
	if not ConfigsReady then
		-- Each callback gets its own table of views, as it does once the configs are ready
		return ConfigReadySignal:Once(function()
			callback(self:GetAll(nil))
		end)
	else
		task.spawn(callback, self:GetAll(nil))
		return SignalConnection.new()
	end
end

--[[
	Marks the config store ready and releases everything waiting on it, once. The composer calls
	this after applying every configuration from a bootstrap payload.

	Readiness is deliberately not set per config. ApplyConfigs runs once per configuration, so
	flipping the flag there released consumers, and fired every OnReady callback, as soon as the
	first one was applied: Configs:Get on any later configuration then read a nil view. An app with
	no configurations at all never became ready under that rule either, which the v2 backend treats
	as a legitimate state.
]]
function InternalConfigs:SetReady()
	if ConfigsReady then
		return
	end

	ConfigsReady = true
	ConfigReadySignal:Fire()
end

function InternalConfigs:WaitForConfigsReady() : true
	if not ConfigsReady then
		ConfigReadySignal:Wait()
	end
	return true
end

function InternalConfigs:OnChanged(player: Player?, targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
	if type(targetConfig) == "string" then
		targetConfig = {targetConfig}
	end

	-- Establish bindable connection
	return BatchConfigUpdatedSignal:Connect(function(updatedPlayer: Player?, configId: number, changes : {{path : {string}, newValue : any, oldValue : any}}, oldConfigs : any)
		local isServerChange = (updatedPlayer == nil)

		-- If subscribed to server changes, ignore player-specific changes
		if player == nil and not isServerChange then
			return
		end

		-- If subscribed to player changes, only fire for server if no player-specific view is set
		if player and isServerChange then
			local entry = ActiveConfigs[configId]
			if entry and entry.viewByPlayer[player] then
				return
			end
		elseif player and updatedPlayer ~= player then
			return
		end

		-- Resolve the target identifier at fire time so subscriptions can precede config load
		if ResolveConfigId(targetConfig[1]) ~= configId then
			return
		end

		for _, change in changes do
			local match = true
			for index = 2, #targetConfig do
				local changeSegment = change.path[index - 1]
				if changeSegment == nil then
					break
				elseif targetConfig[index] ~= changeSegment then
					match = false
					break
				end
			end

			if match then
				callback(self:Get(player, targetConfig), self:Get(player, targetConfig, oldConfigs))
				break
			end
		end
	end)
end

function InternalConfigs:_checkConfigChanged(oldConfig, newConfig) : { {path : {string}, newValue : any, oldValue : any} }
	local changedBatch = {} :: {{path : {string}, newValue : any, oldValue : any}}

	local function addToBatch(path, newValue, _)
		table.insert(changedBatch, {path = path, newValue = newValue})
	end

	local function recursiveChangedFinder(old, new, _path)
		_path = _path or {}

		for oldKey, oldValue in old do
			local currentPath = table.clone(_path)
			table.insert(currentPath, oldKey)

			local newValue = new[oldKey]
			if newValue == nil then -- Removed
				addToBatch(currentPath, nil, oldValue)
			elseif type(newValue) ~= type(oldValue) then -- Changed type
				addToBatch(currentPath, newValue, oldValue)
			elseif type(newValue) == "table" then -- Recurse
				recursiveChangedFinder(oldValue, newValue, currentPath)
			elseif newValue ~= oldValue then -- Changed
				addToBatch(currentPath, newValue, oldValue)
			end

			--NOTE: could optimize by using the same table
			--table.remove(path, #path)
		end

		-- check if added
		for newKey, newValue in new do
			local currentPath = table.clone(_path)
			table.insert(currentPath, newKey)

			if old[newKey] == nil then -- Added
				addToBatch(currentPath, newValue, nil)
			end
		end
	end

	recursiveChangedFinder(oldConfig, newConfig)

	return changedBatch
end

-- Registers or updates a configuration's base document from a v2 payload.
-- Does not diff or replicate; evaluated views are composed and applied separately.
-- Returns the previous privacy paths when updating, for privacy transition diffing.
function InternalConfigs:SetBaseConfig(configData : {[string] : any}) : { { string } }?
	local existing = ActiveConfigs[configData.id]
	local oldPrivacy = existing and existing.privacy or nil

	local entry = existing or {
		viewByPlayer = {},
	}

	entry.id = configData.id
	entry.name = configData.name
	entry.alias = configData.alias
	entry.hash = configData.hash
	entry.updatedAt = configData.updatedAt
	entry.base = configData.configuration or {}
	entry.privacy = configData.privacy or {}

	ActiveConfigs[configData.id] = entry
	RebuildIdentifierMap()

	return oldPrivacy
end

-- Refreshes a config's consumer identity (alias/name) when it changed without a content change.
function InternalConfigs:UpdateConfigIdentity(configId : number, name : string?, alias : string?)
	local entry = ActiveConfigs[configId]
	if not entry then
		return
	end

	if entry.name ~= name or entry.alias ~= alias then
		entry.name = name
		entry.alias = alias
		RebuildIdentifierMap()
	end
end

-- Removes a configuration that no longer exists on the backend.
-- Applies empty views first so subscribers and clients observe the removal.
function InternalConfigs:RemoveConfig(configId : number)
	local entry = ActiveConfigs[configId]
	if not entry then
		return
	end

	for player in entry.viewByPlayer do
		self:ApplyConfigs(player, configId, nil)
	end
	self:ApplyConfigs(nil, configId, {})

	ActiveConfigs[configId] = nil
	RebuildIdentifierMap()
end

function InternalConfigs:GetBaseConfig(configId : number) : ConfigEntry?
	return ActiveConfigs[configId]
end

function InternalConfigs:GetConfigHashes() : { [number] : string }
	local hashes = {}
	for configId, entry in ActiveConfigs do
		hashes[configId] = entry.hash
	end
	return hashes
end

-- Returns evaluated views for every registered config, keyed by consumer identifier.
function InternalConfigs:GetAll(player : Player?) : { [string] : any }
	local views = {}
	for _, entry in ActiveConfigs do
		views[GetIdentifierForEntry(entry)] = player
			and entry.viewByPlayer[player]
			or entry.serverView
	end
	return views
end

-- Applies an evaluated view for a config. `player == nil` applies the server view;
-- a nil `newView` for a player clears their override so they fall back to the server view.
-- `oldPrivacy` is only passed when the config's base just changed, to diff privacy transitions.
function InternalConfigs:ApplyConfigs(player: Player?, configId : number, newView: {[string]: any}?, init : boolean?, oldPrivacy : { {string} }?)
	local entry = ActiveConfigs[configId]
	if not entry then
		Utilities.GBWarn("Cannot apply configs for unknown config id:", configId)
		return
	end

	if not player then
		assert(newView, "Server configs cannot be cleared")
	end

	-- Departed players just have their view cleared; there is nobody to notify or replicate to
	if player and player.Parent == nil then
		entry.viewByPlayer[player] = nil
		return
	end

	local oldConfigs = Utilities.recursiveCopy(player
		and entry.viewByPlayer[player]
		or entry.serverView
		or {}
	)
	local oldPrivatePaths = oldPrivacy or entry.privacy
	local privacyConfig = entry.privacy

	-- Freeze new configs to prevent modification
	local function recursiveFreeze(configs)
		if not table.isfrozen(configs) then
			table.freeze(configs)
		end
		for _, value in configs do
			if type(value) == "table" then
				recursiveFreeze(value)
			end
		end
	end

	if newView then
		recursiveFreeze(newView)
	end

	if player then
		entry.viewByPlayer[player] = newView

		-- If per-player view is being cleared, revert to the server view
		if newView == nil then
			newView = entry.serverView
		end
	else
		entry.serverView = newView
	end

	if init ~= true then
		local changedBatch = InternalConfigs:_checkConfigChanged(oldConfigs, newView)

		if #changedBatch > 0 then
			-- Shared by every listener rather than copied for each, so nothing may change it
			recursiveFreeze(oldConfigs)
			BatchConfigUpdatedSignal:Fire(player, configId, changedBatch, oldConfigs)
		end

		-- When public paths become private, queue scrubbing their rootmost value
		local newlyPrivatePathsToScrubSet: {[string]: {string}?} = {}
		for _, newPrivatePath in privacyConfig do
			local previousValueAtNewlyPrivatePath = Utilities.getValueAtPath(oldConfigs, newPrivatePath)
			local wasPreviouslyPresent = (previousValueAtNewlyPrivatePath ~= nil)
			if wasPreviouslyPresent and not IsPathPrivate(newPrivatePath, oldPrivatePaths) then
				addRootmostPathToSet(newlyPrivatePathsToScrubSet, newPrivatePath)
			end
		end
		local newlyPrivatePathsToScrub = Utilities.getTableValues(newlyPrivatePathsToScrubSet)

		-- When private paths become public, queue repopulating their rootmost value
		local newlyPublicPathsToRepopulateSet: {[string]: {string}?} = {}
		for _, oldPrivatePath in oldPrivatePaths do
			if not IsPathPrivate(oldPrivatePath, privacyConfig) then
				addRootmostPathToSet(newlyPublicPathsToRepopulateSet, oldPrivatePath)
			end
		end
		local newlyPublicPathsToRepopulate = Utilities.getTableValues(newlyPublicPathsToRepopulateSet)

		-- Skip redundant changes for paths being scrubbed or repopulated
		local filteredChangeBatch: typeof(changedBatch) = table.create(#changedBatch)
		for _, change in changedBatch do
			local willBeReplaced = IsPathPrivate(change.path, newlyPrivatePathsToScrub)
				or IsPathPrivate(change.path, newlyPublicPathsToRepopulate)
			if not willBeReplaced then
				table.insert(filteredChangeBatch, change)
			end
		end
		changedBatch = filteredChangeBatch

		-- Add changes for rootmost paths being scrubbed or repopulated
		for _, newlyPrivatePath in newlyPrivatePathsToScrubSet do
			table.insert(changedBatch, {
				path = newlyPrivatePath,
				newValue = nil,
				isPrivacyTransition = true,
			})
		end
		for _, newlyPublicPath in newlyPublicPathsToRepopulateSet do
			local valueAtNewlyPublicPath = Utilities.getValueAtPath(newView, newlyPublicPath)

			-- If not present in new configs, skip redundant send
			if valueAtNewlyPublicPath == nil then
				continue
			end

			table.insert(changedBatch, {
				path = newlyPublicPath,
				newValue = valueAtNewlyPublicPath,
				isPrivacyTransition = true,
			})
		end

		if #changedBatch > 0 then
			local filteredChanges = {}
			for _, change in changedBatch do
				if change.isPrivacyTransition or not IsPathPrivate(change.path, privacyConfig) then
					change.newValue = FilterConfigForClient(change.path, change.newValue, privacyConfig)
					table.insert(filteredChanges, change)
				end
			end

			-- A change that only touched private keys leaves nothing for clients to apply
			if #filteredChanges == 0 then
				return
			end

			if player then
				ConfigChangedRemote:FireClient(player, configId, filteredChanges)
			else
				-- Only send server config changes to players who don't have individually-defined views
				for _, potentialPlayer in Players:GetPlayers() do
					if not entry.viewByPlayer[potentialPlayer] then
						ConfigChangedRemote:FireClient(potentialPlayer, configId, filteredChanges)
					end
				end
			end
		end
	end
end

-- Get the value of a specific config. The first path segment identifies the config
-- by alias, name, or id; the remaining segments traverse its evaluated view.
function InternalConfigs:Get(player: Player?, path : string | { string }, configsOverride : any?) : any
	if typeof(path) ~= "table" and typeof(path) ~= "string" then
		Utilities.GBWarn("Config path must be a string or list of strings.")
		return nil
	end

	path = typeof(path) == "string" and {path} or path

	if #path == 0 then
		Utilities.GBWarn("Config path must begin with a configuration name or alias.")
		return nil
	end

	-- Overrides are config-local documents (e.g. old configs in OnChanged), so the
	-- identifier segment is skipped rather than resolved.
	if configsOverride then
		local value = configsOverride
		for index = 2, #path do
			value = value[path[index]]

			if value == nil then
				return nil
			end
		end

		return value
	end

	self:WaitForConfigsReady()

	local configId = ResolveConfigId(path[1])
	if not configId then
		Utilities.GBWarn("No Gamebeast config found matching \"".. tostring(path[1]).. "\"")
		return nil
	end

	local entry = ActiveConfigs[configId]
	local value = player
		and entry.viewByPlayer[player]
		or entry.serverView

	for index = 2, #path do
		if value == nil then
			return nil
		end
		value = value[path[index]]
	end

	return value
end

--= Initializers =--
function InternalConfigs:Init()

	-- Provide clients their full privacy-filtered config payload.
	GetConfigRemoteFunc.OnServerInvoke = function (player: Player)
		self:WaitForConfigsReady()

		local configs = {}
		-- The single identifier each config is keyed by for consumers. ConfigIdByIdentifier holds
		-- every spelling (id, name and alias all resolve), so a client keying its own payload off it
		-- listed the same document up to three times where the server listed it once.
		local identifierByConfigId = {}
		for configId, entry in ActiveConfigs do
			local view = entry.viewByPlayer[player] or entry.serverView
			configs[tostring(configId)] = FilterConfigForClient({}, view, entry.privacy)
			identifierByConfigId[tostring(configId)] = GetIdentifierForEntry(entry)
		end

		return {
			idByIdentifier = ConfigIdByIdentifier,
			identifierByConfigId = identifierByConfigId,
			configs = configs,
		}
	end
end

--= Return Module =--
return InternalConfigs
