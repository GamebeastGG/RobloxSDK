-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	Updater.luau
	
	Description:
		Handles updating the internal configurations of the Gamebeast SDK
		based on the latest configurations received from the Gamebeast server.
		It also manages experiment assignments and applies configurations
		to players and the server.
	
--]]

--= Root =--
local Updater = { }

--= Roblox Services =--

local RunService = game:GetService("RunService")

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests")
local Experiments = shared.GBMod("InternalExperiments") ---@module InternalExperiments
local Utilities = shared.GBMod("Utilities")
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local Signal = shared.GBMod("Signal")
local DatatstoreBackup = shared.GBMod("DatastoreBackup") ---@module DatastoreBackup
local MetaData = shared.GBMod("MetaData") ---@module MetaData

--= Types =--

--= Constants =--

--[[
	When config is being applied, this controls the maximum amount of seconds
	to wait for initial experiment assignment to complete before giving up
	and using the canonical config.

	If it takes longer, it will continue waiting for assignment to complete in the
	background, and apply assigned configs as they are received.
]]
local MAX_INITIAL_EXPERIMENT_ASSIGNMENT_WAIT_TIME = 10

--= Object References =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--



--= API Functions =--

Updater.ModuleUpdated = Signal.new()
Updater.ConfigChanged = Signal.new()

-- Update modules based on config data in new module version
function Updater:UpdateConfigs(newConfigs, init)
	local currentGBConfigs = InternalConfigs:GetActiveConfig("GBConfigs")
	local lastVersion = not init and currentGBConfigs["GBPublishTime"] or nil
	
	-- If we got an old configuration version over the wire for some reason, don't apply it
	if lastVersion and newConfigs["GBConfigs"]["GBPublishTime"] <= lastVersion then
		return
	end

	--print("Loading new configs from Gamebeast")
	-- Save newly received configs to datastore for backup purposes. Only the host server needs to do this for resource considerations.
	-- Make sure we're not initializing and saving an already backed up config.
	if shared.GBMod("HostServer"):IsHostServer() and not init then
		task.spawn(function()
			self:SaveConfigsToBackup(newConfigs)
		end)
	end

	InternalConfigs:ApplyInternalConfigs(newConfigs["GBConfigs"])

	-- Update game configs
	init = init or not InternalConfigs:IsReady()

	-- Trigger experiment assignment, if applicable
	-- (this may yield, so it's limited by a timer to avoid blocking config readiness for too long)
	local availableExperimentsSnapshot = newConfigs.GBConfigs.Experiments
	if availableExperimentsSnapshot then
		local thread = coroutine.running()
		local didResume = false
		task.spawn(function ()
			Experiments:UpdateStateFromAvailableExperiments(availableExperimentsSnapshot, {
				variables = newConfigs.configs,
				options = newConfigs.options,
			})
			if not didResume then
				didResume = true
				coroutine.resume(thread)
			end
		end)
		task.delay(MAX_INITIAL_EXPERIMENT_ASSIGNMENT_WAIT_TIME, function()
			if not didResume then
				didResume = true
				Utilities.GBWarn("Initial experiment assignment taking unusually long, temporarily falling back to canonical config")
				coroutine.resume(thread)
			end
		end)
		if not didResume then
			coroutine.yield()
		end
	end

	-- If players are assigned to an experiment, use that config for them
	for player, playerConfigs in Experiments.AssignedConfigByPlayer do
		InternalConfigs:ApplyConfigs(player, playerConfigs.variables, playerConfigs.options.privacy, init)
	end

	-- If server is assigned to an experiment, use that config, otherwise use canonical config
	if Experiments.AssignedServerConfig then
		InternalConfigs:ApplyConfigs(
			nil,
			Experiments.AssignedServerConfig.variables,
			Experiments.AssignedServerConfig.options.privacy,
			init
		)
	else
		InternalConfigs:ApplyConfigs(nil, newConfigs.configs, newConfigs.options.privacy, init)
	end

	--[[ Signal mod update
	if not init then
		self.ModuleUpdated:Fire()
		ModuleUpdatedRemote:FireAllClients()
	end
	]]
end


-- In the unlikely case GB is down, fall back on Roblox datastores
function Updater:GetBackupConfigs()
	local success, configs = DatatstoreBackup:Get("Configs")
	
	if not success then
		Utilities.GBWarn("Couldn't get configs from backup. Attempting to re-establish connection with Gamebeast...")
	end

	-- Clear any experiment snapshot data from the backup configs
	if configs then
		configs.GBConfigs.Experiments = nil
	end

	return configs
end

-- Save new configs to Roblox datastores for backup
-- NOTE: if a server is starting up and there are a bunch of update config jobs pending, this can throttle, should probably add a flag
function Updater:SaveConfigsToBackup(newConfigs)
	local newBackupConfigs = Utilities.recursiveCopy(newConfigs)
	newBackupConfigs.GBConfigs.Experiments = nil

	DatatstoreBackup:Set("Configs", newBackupConfigs)
end


--= Initializers =--
function Updater:Init()

	-- Check version
	task.spawn(function()
		local success, versionData = GBRequests:GBRequestAsync("v1/latest/version?platform=roblox")
		if success and versionData.version then
			if MetaData.version < versionData.version then
				Utilities.GBWarn(`Gamebeast SDK is out of date! Please update to the latest version. {MetaData.version} -> {versionData.version}`)
			end
		end
	end)

	-- Start up, ask for most recent configuations

	local function fetchConfigs()
		local success, newConfigsResp = GBRequests:GBRequestAsync("v1/configurations", nil, 1)
		if success then
			return newConfigsResp.args
		else
			return nil
		end
	end

	local newConfigs = fetchConfigs()
	-- If no response or failed status, attempt to recover
	if not newConfigs then
		Utilities.GBWarn("Couldn't get configurations from Gamebeast. Attempting to load from backup...")
		-- Try to get datastore backed up configs
		newConfigs = self:GetBackupConfigs()

		-- If they've never published configs / no backup for this project, then we have to wait for a connection or we would error every other part of the system. Extremely unlikely.
		if not newConfigs then
			repeat
				task.wait(10)
				Utilities.GBWarn("Attempting to establish connection...")
				newConfigs = fetchConfigs()
			until newConfigs

			Utilities.GBWarn("Connection established, fetching configurations...")
		end
	end

	-- Update configs for server with initialization flag
	self:UpdateConfigs(newConfigs, true)

	-- When the server's assigned experiment config changes, update the internal configs
	Experiments.OnAssignedServerConfigChanged:Connect(function (newAssignedConfigs)
		if InternalConfigs:IsReady() then
			if newAssignedConfigs then
				InternalConfigs:ApplyConfigs(nil, newAssignedConfigs.variables, newAssignedConfigs.options.privacy)
			else
				InternalConfigs:ApplyConfigs(
					nil,
					Experiments.CanonicalServerConfig.variables,
					Experiments.CanonicalServerConfig.options.privacy
				)
			end
		end
	end)

	-- When players' assigned experiment config changes, update per-player internal configs
	Experiments.OnAssignedPlayerConfigChanged:Connect(function (player, newAssignedConfigs)
		if InternalConfigs:IsReady() then
			if newAssignedConfigs then
				InternalConfigs:ApplyConfigs(player, newAssignedConfigs.variables, newAssignedConfigs.options.privacy)
			else
				InternalConfigs:ApplyConfigs(player, nil, nil)
			end
		end
	end)
end

--= Return Module =--
return Updater