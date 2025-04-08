-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	Updater.luau
	
	Description:
		No description provided.
	
--]]

--= Root =--
local Updater = { }

--= Roblox Services =--
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests")
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module EngagementMarkers
local ABTesting = shared.GBMod("ABTesting") ---@module ABTesting
local Utilities = shared.GBMod("Utilities")
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local Signal = shared.GBMod("Signal")
local MetaData = shared.GBMod("MetaData") ---@module MetaData

--= Types =--

--= Constants =--

local BACKUP_STORE_KEY = (RunService:IsStudio() and "Studio" or "") .. "GBConfigBackup"

--[[
	When config is being applied, this controls the maximum amount of seconds
	to wait for initial A/B testing assignment to complete before giving up
	and using the canonical config.

	If it takes longer, it will continue waiting for assignment to complete in the
	background, and apply assigned configs as they are received.
]]
local MAX_INITIAL_EXPERIMENT_ASSIGNMENT_WAIT_TIME = 5

--= Object References =--

local BackupConfigStore = DataStoreService:GetDataStore(BACKUP_STORE_KEY)

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

	-- Determine whether we're using canonical config profile or A/B testing partition

	-- ABTesting is integral to the configs, but it cant be a leaf.
	-- Maybe we have it listen and then fire 

	-- Trigger A/B testing campaign assignment, if applicable
	-- (this may yield, so it's limited by a timer to avoid blocking config readiness for too long)
	do
		local thread = coroutine.running()
		local didResume = false
		task.spawn(function ()
			ABTesting:UpdateStateFromAvailableCampaigns(newConfigs["GBConfigs"].ABTestingCampaigns, {
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
				Utilities.GBWarn("Initial campaign assignment taking unusually long, temporarily falling back to canonical config")
				coroutine.resume(thread)
			end
		end)
		if not didResume then
			coroutine.yield()
		end
	end

	-- If players are assigned to an A/B testing campaign, use that config for them
	for player, playerConfigs in ABTesting.AssignedConfigByPlayer do
		InternalConfigs:ApplyConfigs(player, playerConfigs.variables, playerConfigs.options.privacy, init)
	end

	-- If server is assigned to an A/B testing campaign, use that config, otherwise use canonical config
	if ABTesting.AssignedServerConfig then
		InternalConfigs:ApplyConfigs(
			nil,
			ABTesting.AssignedServerConfig.variables,
			ABTesting.AssignedServerConfig.options.privacy,
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
	local configs, success = Utilities.promiseReturn(2, function()
		return BackupConfigStore:GetAsync(BACKUP_STORE_KEY)
	end)
	
	if not success then
		Utilities.GBWarn("Couldn't get configs from backup. Attempting to re-establish connection with Gamebeast...")
	end

	return configs
end

-- Save new configs to Roblox datastores for backup
-- NOTE: if a server is starting up and there are a bunch of update config jobs pending, this can throttle, should probably add a flag
function Updater:SaveConfigsToBackup(newConfigs)
	Utilities.promiseReturn(1, function()
		BackupConfigStore:SetAsync(BACKUP_STORE_KEY, newConfigs)
	end)
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
			print("Connection with Gamebeast re-established! Loading newest configs...")
		else
			print("Backup configs loaded successfully!")
		end
	end

	-- Update marker properties when A/B testing campaigns are running
	ABTesting.OnServerPartitionIdChanged:Connect(function (partitionId)
		EngagementMarkers:SetServerExperimentPartitionId(partitionId)
	end)
	ABTesting.OnPlayerPartitionIdChanged:Connect(function (player, partitionId)
		EngagementMarkers:SetPlayerExperimentPartitionId(player, partitionId)
	end)

	-- Update configs for server with initialization flag
	self:UpdateConfigs(newConfigs, true)

	-- When the server's assigned A/B testing campaign config changes, update the internal configs
	ABTesting.OnAssignedServerConfigChanged:Connect(function (newAssignedConfigs)
		if InternalConfigs:IsReady() then
			if newAssignedConfigs then
				InternalConfigs:ApplyConfigs(nil, newAssignedConfigs.variables, newAssignedConfigs.options.privacy)
			else
				InternalConfigs:ApplyConfigs(
					nil,
					ABTesting.CanonicalServerConfig.variables,
					ABTesting.CanonicalServerConfig.options.privacy
				)
			end
		end
	end)

	-- When players' assigned A/B testing campaign config changes, update per-player internal configs
	ABTesting.OnAssignedPlayerConfigChanged:Connect(function (player, newAssignedConfigs)
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