--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	InternalConfigs.luau
	
	Description:
		Internal module for managing configuration data across the server and clients.
	
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

--= Object References =--

local GetConfigRemoteFunc = GetRemote("Function", "Get")
local GetEventDataRemoteFunc = GetRemote("Function", "GetEventData")
local EventDataUpdatedRemote = GetRemote("Event", "EventDataUpdated")
local ConfigChangedRemote = GetRemote("Event", "ConfigChanged")
local ConfigReadySignal = Signal.new()
local BatchConfigUpdatedSignal = Signal.new()

--= Constants =--

--= Variables =--

local ConfigsReady = false
local ActiveConfigs = {
	--Full dev defined configuration profile
	DevConfigs = {},

	-- Per-player dev-defined configuration profiles
	DevConfigsByPlayer = {} :: {
		[Player]: {
			[string]: any,
		}
	},

	--Metadata sent along with dev defined configs
	GBConfigs = {},
	--Set of client accessible configs
	ClientConfigs = {}
}
local CurrentClientPrivacy = {}
local CurrentClientPrivacyByPlayer = {} :: {
	[Player]: {{string}},
}
--[[ Full dev defined configuration profile
ActiveConfigs.DevConfigs = {}
-- Metadata sent along with dev defined configs
configsMod.GBConfigs = {}
-- Set of client accessible configs
configsMod.clientConfigs = {}]]

--= Public Variables =--

--= Internal Functions =--

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

		local target = configCopy
		for index, pathSegment in targetPath do
			if index == #targetPath then
				target[pathSegment] = nil
				break
			else
				target = target[pathSegment]

				if target == nil then
					Utilities.GBWarn("Privacy path ".. table.concat(targetPath, ".").. " does not exist in config.")
					break
				end
			end
		end
	end

	return configCopy
end

--= API Functions =--

function InternalConfigs:IsReady() : boolean
	return ConfigsReady
end

function InternalConfigs:OnReady(callback : (newConfigs : any) -> ()) : RBXScriptConnection
	if not ConfigsReady then
		return ConfigReadySignal:Once(callback)
	else
		task.spawn(callback, ActiveConfigs.DevConfigs)
		return SignalConnection.new()
	end
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
	return BatchConfigUpdatedSignal:Connect(function(updatedPlayer: Player?, changes : {{path : {string}, newValue : any, oldValue : any}}, oldConfigs : any)
		local isServerChange = (updatedPlayer == nil)

		-- If subscribed to server changes, ignore player-specific changes
		if player == nil and not isServerChange then
			return
		end

		-- If subscribed to player changes, only fire for server if no player-specific config is set
		if player and isServerChange then
			if ActiveConfigs.DevConfigsByPlayer[player] then
				return
			end
		elseif player and updatedPlayer ~= player then
			return
		end

		for _, change in changes do
			local match = true
			for index, path in targetConfig do
				if change.path[index] == nil then
					break
				elseif path ~= change.path[index] then
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

function InternalConfigs:ApplyInternalConfigs(newGBConfigs)
	-- Split internally used metadata from dev facing configs
	for index, value in newGBConfigs do
		ActiveConfigs.GBConfigs[index] = value
	end

	-- Note: In the future, check to see if the event data actually changed from the internal config update.
	--EventDataUpdatedRemote:FireAllClients(newConfigs["GBEventData"])
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

function InternalConfigs:ApplyConfigs(player: Player?, newConfigs: {[string]: any}?, privacyConfig : { {string} }?, init : boolean?)
	if not player then
		assert(newConfigs, "Server configs cannot be cleared")
		assert(privacyConfig, "Server config privacy cannot be cleared")
	end

	local oldConfigs = Utilities.recursiveCopy(player
		and ActiveConfigs.DevConfigsByPlayer[player]
		or ActiveConfigs.DevConfigs
	)
	local oldPrivatePaths = player
		and CurrentClientPrivacyByPlayer[player]
		or CurrentClientPrivacy

	if player then
		CurrentClientPrivacyByPlayer[player] = privacyConfig
	else
		CurrentClientPrivacy = privacyConfig
	end
	-- We can't recurse over a "config metadata object" unless we make a reserved key for the metadata and preserve the structure of the config object
	-- Create a config-wide metadata key to avoid collisions with config object structure.
	-- Can store metadata + key in configs mod in the future if there's other relevant metadata we want to access at any time.
	--local metadataKey = httpService:GenerateGUID(false)
	--local configMetadata = {}

	
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

	if newConfigs then
		recursiveFreeze(newConfigs)
	end

	if player then
		ActiveConfigs.DevConfigsByPlayer[player] = newConfigs

		-- If per-player config is being cleared, revert to global config
		if newConfigs == nil then
			newConfigs = ActiveConfigs.DevConfigs
		end
		if privacyConfig == nil then
			privacyConfig = CurrentClientPrivacy
		end
	else
		ActiveConfigs.DevConfigs = newConfigs
	end

	if init ~= true then
		local changedBatch = InternalConfigs:_checkConfigChanged(oldConfigs, newConfigs)

		if #changedBatch > 0 then
			BatchConfigUpdatedSignal:Fire(player, changedBatch, oldConfigs)
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
			local valueAtNewlyPublicPath = Utilities.getValueAtPath(newConfigs, newlyPublicPath)

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

			if player then
				ConfigChangedRemote:FireClient(player, filteredChanges)
			else
				-- Only send server config changes to players who don't have individually-defined
				for _, potentialPlayer in Players:GetPlayers() do
					if not ActiveConfigs.DevConfigsByPlayer[potentialPlayer] then
						ConfigChangedRemote:FireClient(potentialPlayer, filteredChanges)
					end
				end
			end
		end
	end

	
	-- Freeze highest level table not referenced in traversal
	
	--shared.GBMod("InternalConfigs").clientConfigs = newClientConfigs
	---- Freeze highest level table not referenced in traversal
	--table.freeze(clientConfigs)
	
	--TODO:
	ConfigsReady = true

	ConfigReadySignal:Fire(newConfigs)
	--ConfigUpdatedSignal:Fire(path, newValue, oldValue)
end

-- Get the value of a specific config
function InternalConfigs:Get(player: Player?, path : string | { string }, configsOverride : any?) : any
	if typeof(path) ~= "table" and typeof(path) ~= "string" then
		Utilities.GBWarn("Config path must be a string or list of strings.")
		return nil
	end

	path = typeof(path) == "string" and {path} or path
	
	if not configsOverride then
		self:WaitForConfigsReady()
	end

	local configs = player
		and ActiveConfigs.DevConfigsByPlayer[player]
		or ActiveConfigs.DevConfigs

	local value = configsOverride or configs
	for _, key in ipairs(path) do
		value = value[key]

		if value == nil then
			return nil
		end
	end

	return value
end

function InternalConfigs:GetActiveConfig(key : string) : any
	return ActiveConfigs[key]
end

-- Get the value of a specific event
function InternalConfigs:GetEventData(eventName : string) : { [string] : any }
	local info = ActiveConfigs.GBConfigs.GBEventData[eventName]
	
	if not info then
		Utilities.GBWarn("No Gamebeast event named ".. eventName)
	end
	
	return info
end

--= Initializers =--
function InternalConfigs:Init()

	-- Call Get for clients and return value.
	GetConfigRemoteFunc.OnServerInvoke = function (player: Player, path: {string}?)
		self:WaitForConfigsReady()

		local privatePaths = CurrentClientPrivacyByPlayer[player] or CurrentClientPrivacy

		if path == nil then
			local playerConfig = player
				and ActiveConfigs.DevConfigsByPlayer[player]
				or ActiveConfigs.DevConfigs
			return FilterConfigForClient({}, playerConfig, privatePaths)
		end

		if IsPathPrivate(path, privatePaths) then
			return nil
		end

		return FilterConfigForClient(path, self:Get(player, path), privatePaths)
		-- NOTE: We'll want to modify to reflect privacy. To be most efficient, we can create a get function that references a
		-- "client" config set that essentially recursively copies the set of configs only assigning a value if it has client accessibility.
		-- This means we only every make one copy of a table rather than on every client request.
		--return configsMod.get(path, configsMod.clientConfigs)
	end

	-- Call GetEventData for clients and return value
	--[[GetEventDataRemoteFunc.OnServerInvoke = function(_)
		return ActiveConfigs.GBConfigs.GBEventData
	end]]
end

--= Return Module =--
return InternalConfigs
