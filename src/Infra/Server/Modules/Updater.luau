-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	Updater.luau

	Description:
		Bootstraps the SDK's configuration and experiment state from the backend,
		polls the status endpoint for changes, and composes evaluated config views
		(base + experiment changesets) for the server and players.

--]]

--= Root =--
local Updater = { }

--= Roblox Services =--

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--= Dependencies =--

local MetaData = shared.GBMod("MetaData") ---@module MetaData
local DataCache = shared.GBMod("DataCache")
local Utilities = shared.GBMod("Utilities")
local GBRequests = shared.GBMod("GBRequests")
local Changesets = shared.GBMod("Changesets") ---@module Changesets
local Experiments = shared.GBMod("InternalExperiments") ---@module InternalExperiments
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local DatatstoreBackup = shared.GBMod("DatastoreBackup") ---@module DatastoreBackup

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

--[[
	Trailing debounce for backup saves, to respect DataStore same-key write throttling
	when several config changes land in a short window.
]]
local BACKUP_SAVE_DEBOUNCE = 30

--[[
	How long to wait between attempts to reach the backend when bootstrap fails.
]]
local CONNECTION_RETRY_DELAY = 10

--[[
	Version stamp for the backup blob format. Old-format backups are rejected.
]]
local BACKUP_SCHEMA_VERSION = 2

--= Object References =--

local PrimaryBackup = DatatstoreBackup.new(RunService:IsStudio())

--= Variables =--

local BackupSavePending = false

--= Public Variables =--

--= Internal Functions =--

-- Backups are scoped per environment so switching environments never restores
-- another environment's configs on the startup fallback path.
local function GetBackupKey() : string
	local environment = DataCache:Get("Settings").environment
		or (RunService:IsStudio() and "studio" or "production")
	return "Configs_".. environment
end

--= API Functions =--

-- Composes and applies the evaluated views for a single config: the server view,
-- plus per-player views for players with experiment overlays.
-- `oldPrivacy` is passed through when the config's base just changed.
function Updater:ComposeAndApplyConfig(configId : number, init : boolean?, oldPrivacy : { {string} }?)
	local entry = InternalConfigs:GetBaseConfig(configId)
	if not entry then
		return
	end

	local serverView = Changesets.apply(entry.base, Experiments:GetChangesetsForConfig(configId))
	InternalConfigs:ApplyConfigs(nil, configId, serverView, init, oldPrivacy)

	for _, player in Players:GetPlayers() do
		if Experiments:HasPlayerOverlays(player, configId) then
			local playerView = Changesets.apply(entry.base, Experiments:GetChangesetsForConfig(configId, player))
			InternalConfigs:ApplyConfigs(player, configId, playerView, init, oldPrivacy)
		elseif entry.viewByPlayer[player] then
			-- Player lost their overlays; revert them to the server view
			InternalConfigs:ApplyConfigs(player, configId, nil, init, oldPrivacy)
		end
	end
end

function Updater:ComposeAndApplyAll(init : boolean?, oldPrivacyByConfigId : { [number] : { {string} } }?)
	for configId in InternalConfigs:GetConfigHashes() do
		self:ComposeAndApplyConfig(configId, init, oldPrivacyByConfigId and oldPrivacyByConfigId[configId])
	end
end

-- Recomposes a single player's views after their experiment assignments changed.
function Updater:ComposeAndApplyForPlayer(player : Player)
	for configId in InternalConfigs:GetConfigHashes() do
		local entry = InternalConfigs:GetBaseConfig(configId)
		if not entry then
			continue
		end

		if Experiments:HasPlayerOverlays(player, configId) then
			local playerView = Changesets.apply(entry.base, Experiments:GetChangesetsForConfig(configId, player))
			InternalConfigs:ApplyConfigs(player, configId, playerView)
		elseif entry.viewByPlayer[player] then
			InternalConfigs:ApplyConfigs(player, configId, nil)
		end
	end
end

-- Applies a full bootstrap payload: registers configs, reconciles experiments
-- (bounded by the initial assignment wait), then composes and applies all views.
function Updater:ApplyBootstrap(bootstrap, init : boolean?)
	-- Register config base documents, keeping old privacy for transition diffing
	local oldPrivacyByConfigId = {}
	local seenConfigIds = {}
	for _, configData in bootstrap.configurations do
		oldPrivacyByConfigId[configData.id] = InternalConfigs:SetBaseConfig(configData)
		seenConfigIds[configData.id] = true
	end

	-- Drop configs that no longer exist (e.g. re-bootstrap after an outage)
	for configId in InternalConfigs:GetConfigHashes() do
		if not seenConfigIds[configId] then
			InternalConfigs:RemoveConfig(configId)
		end
	end

	-- Reconcile experiments and trigger assignment, if applicable
	-- (this may yield, so it's limited by a timer to avoid blocking config readiness for too long)
	if bootstrap.experiments then
		local thread = coroutine.running()
		local didResume = false
		task.spawn(function ()
			Experiments:UpdateCatalog(bootstrap.experiments, bootstrap.requiredProperties)
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

	self:ComposeAndApplyAll(init, oldPrivacyByConfigId)

	self:QueueBackupSave()
end

-- Applies a status poll payload: refetches configs whose hash changed, removes
-- configs that disappeared, and reconciles the experiment catalog.
function Updater:ApplyStatus(status)
	local knownHashes = InternalConfigs:GetConfigHashes()
	local seenConfigIds = {}

	for _, configStatus in status.configurations do
		seenConfigIds[configStatus.id] = true

		if knownHashes[configStatus.id] == configStatus.hash then
			-- Content unchanged, but the identity (alias/name) may still have moved
			InternalConfigs:UpdateConfigIdentity(configStatus.id, configStatus.name, configStatus.alias)
			continue
		end

		-- The backend resolves configurations by alias only (normalized the same way it
		-- stores them); a name slugs to the same value, so it serves as the fallback.
		local configIdentifier = configStatus.alias or configStatus.name
		if not configIdentifier then
			Utilities.GBWarn("Config", configStatus.id, "has no alias or name and cannot be refetched.")
			continue
		end

		local didSucceed, configResp, statusCode = GBRequests:GBRequestAsync("v2/configurations", {
			configuration = configIdentifier,
			hash = knownHashes[configStatus.id],
		})

		if statusCode == 304 then
			continue
		end

		if not didSucceed or not configResp then
			Utilities.GBWarn("Failed to fetch updated config:", configStatus.id)
			continue
		end

		-- The single-config response carries no alias; identity comes from the status payload
		local oldPrivacy = InternalConfigs:SetBaseConfig({
			id = configStatus.id,
			name = configStatus.name,
			alias = configStatus.alias,
			hash = configResp.hash,
			updatedAt = configResp.updatedAt,
			configuration = configResp.configuration,
			privacy = configResp.privacy,
		})

		self:ComposeAndApplyConfig(configStatus.id, nil, oldPrivacy)
		self:QueueBackupSave()
	end

	for configId in knownHashes do
		if not seenConfigIds[configId] then
			Utilities.GBLog("Config removed:", configId)
			InternalConfigs:RemoveConfig(configId)
			self:QueueBackupSave()
		end
	end

	Experiments:UpdateCatalog(status.experiments, status.requiredProperties)
end

-- In the unlikely case GB is down, fall back on Roblox datastores
function Updater:GetBackupConfigs()
	local success, backup = PrimaryBackup:Get(GetBackupKey())

	if not success then
		Utilities.GBWarn("Couldn't get configs from backup. Attempting to re-establish connection with Gamebeast...")
		return nil
	end

	-- Reject old-format backups; they cannot be fed into the v2 pipeline
	if not backup or backup.schemaVersion ~= BACKUP_SCHEMA_VERSION then
		return nil
	end

	return backup.configurations
end

-- Save current config base documents to Roblox datastores for backup.
-- Experiments are never backed up; assignments cannot be resolved offline.
function Updater:SaveConfigsToBackup()
	local configurations = {}
	for configId in InternalConfigs:GetConfigHashes() do
		local entry = InternalConfigs:GetBaseConfig(configId)
		if entry then
			table.insert(configurations, {
				id = entry.id,
				name = entry.name,
				alias = entry.alias,
				hash = entry.hash,
				updatedAt = entry.updatedAt,
				configuration = entry.base,
				privacy = entry.privacy,
			})
		end
	end

	PrimaryBackup:Set(GetBackupKey(), {
		schemaVersion = BACKUP_SCHEMA_VERSION,
		savedAt = DateTime.now().UnixTimestampMillis,
		configurations = configurations,
	})
end

-- Queues a debounced backup save, coalescing bursts of config changes into one write.
function Updater:QueueBackupSave()
	if BackupSavePending then
		return
	end

	BackupSavePending = true
	task.delay(BACKUP_SAVE_DEBOUNCE, function()
		BackupSavePending = false
		self:SaveConfigsToBackup()
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

	-- Start up, bootstrap configurations and experiments

	local function fetchBootstrap()
		local success, bootstrap = GBRequests:GBRequestAsync("v2/bootstrap")
		if success then
			return bootstrap
		else
			return nil
		end
	end

	local bootstrap = fetchBootstrap()

	-- If no response or failed status, attempt to recover
	if not bootstrap then
		Utilities.GBWarn("Couldn't get configurations from Gamebeast. Attempting to load from backup...")

		-- Try to get datastore backed up configs so the game can run while we reconnect
		local backupConfigurations = self:GetBackupConfigs()
		local didApplyBackup = false
		if backupConfigurations then
			self:ApplyBootstrap({
				configurations = backupConfigurations,
				experiments = { user = {}, server = {} },
				requiredProperties = {},
			}, true)
			didApplyBackup = true
		end

		-- Wait for a live connection; everything else in the SDK depends on it
		repeat
			task.wait(CONNECTION_RETRY_DELAY)
			Utilities.GBWarn("Attempting to establish connection...")
			bootstrap = fetchBootstrap()
		until bootstrap

		Utilities.GBWarn("Connection established, fetching configurations...")

		-- If the backup was applied, this is no longer an initialization: diff and replicate
		self:ApplyBootstrap(bootstrap, not didApplyBackup)
	else
		self:ApplyBootstrap(bootstrap, true)
	end

	-- When experiment assignments change, recompose the affected evaluated views
	Experiments.OnServerAssignmentsChanged:Connect(function()
		if InternalConfigs:IsReady() then
			self:ComposeAndApplyAll()
		end
	end)

	Experiments.OnPlayerAssignmentsChanged:Connect(function(player : Player)
		if InternalConfigs:IsReady() then
			self:ComposeAndApplyForPlayer(player)
		end
	end)

	-- Poll the status endpoint for configuration and experiment changes
	task.spawn(function()
		while true do
			task.wait(DataCache:Get("Settings").statusPollRate)

			local didSucceed, status = GBRequests:GBRequestAsync("v2/status")
			if not didSucceed or not status then
				Utilities.GBLog("Status poll failed, retrying next interval")
				continue
			end

			self:ApplyStatus(status)
		end
	end)
end

--= Return Module =--
return Updater
