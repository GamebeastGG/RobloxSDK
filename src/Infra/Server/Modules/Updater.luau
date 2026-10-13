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

local MetaData = require(script.Parent.Parent.Parent.MetaData) ---@module MetaData
local DataCache = require(script.Parent.Parent.Parent.Shared.Modules.DataCache)
local Utilities = require(script.Parent.Utilities)
local GBRequests = require(script.Parent.GBRequests)
local Changesets = require(script.Parent.Changesets) ---@module Changesets
local Experiments = require(script.Parent.InternalExperiments) ---@module InternalExperiments
local InternalConfigs = require(script.Parent.InternalConfigs) ---@module InternalConfigs
local DatatstoreBackup = require(script.Parent.DatastoreBackup) ---@module DatastoreBackup

--= Types =--

--[[
	Polling object from the bootstrap and status endpoints, so the backend can shed poll load
	without an SDK update. Usually carries only jitterRatio.
]]
type PollingDirective = {
	-- Sent only to shed load. Absent means statusPollRate applies.
	intervalSeconds : number?,
	-- Fraction of the interval to spread polls over, so servers don't poll in lockstep.
	jitterRatio : number?,
}

--= Constants =--

--[[
	Max seconds to wait for initial experiment assignment before applying the canonical config.
	Assignment keeps going in the background and its views apply when it finishes.
]]
local MAX_INITIAL_EXPERIMENT_ASSIGNMENT_WAIT_TIME = 10

-- Delay before a queued backup save, so a burst of config changes shares one DataStore write.
local BACKUP_SAVE_DEBOUNCE = 30

--[[
	Bootstrap retry backoff: doubles from CONNECTION_RETRY_DELAY up to MAX_CONNECTION_RETRY_DELAY,
	plus up to CONNECTION_RETRY_JITTER, so servers in fallback don't all hit bootstrap together when
	an outage ends.
]]
local CONNECTION_RETRY_DELAY = 10
local MAX_CONNECTION_RETRY_DELAY = 300
local CONNECTION_RETRY_JITTER = 0.25

-- Backups with any other version are rejected.
local BACKUP_SCHEMA_VERSION = 2

-- How often the poll loop re-derives its wait, so a lowered statusPollRate or a lifted directive
-- applies without waiting out a long interval.
local POLL_RECHECK_INTERVAL = 5

-- Caps directive jitter so a wait never exceeds twice the interval. Longer waits are intervalSeconds' job.
local MAX_POLL_JITTER_RATIO = 1

--= Object References =--

local PrimaryBackup = DatatstoreBackup.new(RunService:IsStudio())

--= Variables =--

local BackupSavePending = false

--[[
	Latest backend polling directive, unclamped. GetPollDelay applies the statusPollRate floor per
	poll so runtime setting changes take effect.
]]
local PollingIntervalSeconds : number? = nil
local PollingJitterRatio = 0

--[[
	Hash of the last fully applied status snapshot, sent as ?hash= so an unchanged one answers 304.
	Only set after a full apply, or a 304 would hide changes never applied. Not seeded from the
	bootstrap hash, which covers a different payload.
]]
local LastStatusHash : string? = nil

--= Public Variables =--

--= Internal Functions =--

-- Scoped per environment so the fallback never restores another environment's configs.
local function GetBackupKey() : string
	local environment = DataCache:Get("Settings").environment
		or (RunService:IsStudio() and "studio" or "production")
	return "Configs_".. environment
end

-- Parses "v1.10.0" (or "1.10.0") into { 1, 10, 0 }; nil for anything else
local function ParseVersion(version : any) : { number }?
	if type(version) ~= "string" then
		return nil
	end

	local major, minor, patch = string.match(version, "^v?(%d+)%.(%d+)%.(%d+)")
	if not major then
		return nil
	end

	return { tonumber(major) :: number, tonumber(minor) :: number, tonumber(patch) :: number }
end

local function IsFiniteNumber(value : any) : boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--= API Functions =--

-- How long to wait before reconnection attempt `attempt` (1 for the first retry)
function Updater:GetConnectionRetryDelay(attempt : number, statusCode : number?, jitterRoll : number?) : number
	-- A rejected key won't fix itself, so check back rarely. GBRequests already warned about it.
	local delay = if statusCode == 401 or statusCode == 403
		then MAX_CONNECTION_RETRY_DELAY
		else math.min(CONNECTION_RETRY_DELAY * 2 ^ (attempt - 1), MAX_CONNECTION_RETRY_DELAY)

	return delay * (1 + (jitterRoll or math.random()) * CONNECTION_RETRY_JITTER)
end

-- Whether `current` is older than `latest`, compared numerically so 1.9 sorts before 1.10.
-- False if either can't be parsed.
function Updater:IsVersionOutdated(current : string, latest : string) : boolean
	local currentParts, latestParts = ParseVersion(current), ParseVersion(latest)
	if not currentParts or not latestParts then
		return false
	end

	for index = 1, 3 do
		if currentParts[index] ~= latestParts[index] then
			return currentParts[index] < latestParts[index]
		end
	end
	return false
end

--[[
	Stores the polling directive from a bootstrap or status response, dropping malformed fields.
	It can only slow polling: an intervalSeconds under statusPollRate is ignored (logged, not
	warned), so a bad value can't flood requests.
]]
function Updater:SetPollingDirective(polling : PollingDirective?)
	if polling ~= nil and type(polling) ~= "table" then
		Utilities.GBLog("Ignoring malformed polling directive:", polling)
		polling = nil
	end

	local intervalSeconds = polling and polling.intervalSeconds
	if intervalSeconds ~= nil and not IsFiniteNumber(intervalSeconds) then
		Utilities.GBLog("Ignoring non-numeric poll interval from the backend:", intervalSeconds)
		intervalSeconds = nil
	end

	local jitterRatio = polling and polling.jitterRatio
	if jitterRatio ~= nil and not (IsFiniteNumber(jitterRatio) and jitterRatio >= 0 and jitterRatio <= MAX_POLL_JITTER_RATIO) then
		Utilities.GBLog(`Ignoring poll jitter ratio of {jitterRatio}, expected a number between 0 and {MAX_POLL_JITTER_RATIO}`)
		jitterRatio = nil
	end

	PollingIntervalSeconds = intervalSeconds
	PollingJitterRatio = jitterRatio or 0

	local pollRateSetting = DataCache:Get("Settings").statusPollRate
	if intervalSeconds and intervalSeconds < pollRateSetting then
		Utilities.GBLog(`Backend asked for a {intervalSeconds}s poll interval, under the statusPollRate setting of {pollRateSetting}s; staying on the setting`)
	end
end

--[[
	Delay before the next status poll: the longer of statusPollRate and the backend interval, plus
	jitter (which only adds). `jitterRoll` (0 to 1) is rolled once per poll by the caller, so
	re-deriving the wait mid-flight doesn't re-roll it shorter.
]]
function Updater:GetPollDelay(jitterRoll : number?) : number
	local interval = DataCache:Get("Settings").statusPollRate
	if PollingIntervalSeconds and PollingIntervalSeconds > interval then
		interval = PollingIntervalSeconds
	end

	return interval * (1 + (jitterRoll or math.random()) * PollingJitterRatio)
end

-- Composes and applies a config's server view, plus per-player views for players with experiment
-- overlays. `oldPrivacy` is only passed when the config's base just changed.
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
	self:SetPollingDirective(bootstrap.polling)

	-- Register config base documents, keeping old privacy for transition diffing
	local oldPrivacyByConfigId = {}
	local seenConfigIds = {}
	for _, configData in bootstrap.configurations do
		oldPrivacyByConfigId[configData.id] = InternalConfigs:SetBaseConfig(configData)
		seenConfigIds[configData.id] = true
	end

	-- Drop configs missing from this payload (e.g. re-bootstrap after an outage)
	for configId in InternalConfigs:GetConfigHashes() do
		if not seenConfigIds[configId] then
			InternalConfigs:RemoveConfig(configId)
		end
	end

	-- Assignment may yield, so it's capped to keep config readiness from waiting on it too long
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

	-- Ready only once every config in the payload is applied
	InternalConfigs:SetReady()

	self:QueueBackupSave()
end

-- Applies a status poll payload: refetches configs whose hash changed, removes missing ones, and
-- reconciles the experiment catalog. Returns whether everything applied. If not, the caller must
-- drop this snapshot's hash, or later polls answer 304 and the change is never retried.
function Updater:ApplyStatus(status) : boolean
	-- Read before the refetches below, so a directive shedding load still lands if they fail
	self:SetPollingDirective(status.polling)

	local knownHashes = InternalConfigs:GetConfigHashes()
	local seenConfigIds = {}
	local isComplete = true

	for _, configStatus in status.configurations do
		seenConfigIds[configStatus.id] = true

		if knownHashes[configStatus.id] == configStatus.hash then
			-- Content unchanged, but the identity (alias/name) may still have moved
			InternalConfigs:UpdateConfigIdentity(configStatus.id, configStatus.name, configStatus.alias)
			continue
		end

		-- The endpoint resolves by alias. A name slugs to the same value, so it works as a fallback.
		local configIdentifier = configStatus.alias or configStatus.name
		if not configIdentifier then
			-- Not counted as incomplete: retrying can't help until the config gets an alias or name,
			-- which changes the status payload anyway
			Utilities.GBWarn("Config", configStatus.id, "has no alias or name and cannot be refetched.")
			continue
		end

		local didSucceed, configResp, statusCode = GBRequests:GBRequestAsync("v2/configurations", {
			configuration = configIdentifier,
			hash = knownHashes[configStatus.id],
		})

		-- Status says the content changed, so a 304 here is a cache that hasn't caught up
		if statusCode == 304 then
			Utilities.GBLog("Config", configStatus.id, "is not updated yet where it is fetched from; retrying next poll")
			isComplete = false
			continue
		end

		if not didSucceed or not configResp then
			Utilities.GBWarn("Failed to fetch updated config:", configStatus.id)
			isComplete = false
			continue
		end

		-- GetConfigHashes only lists configs with a hash, so one without would never be recomposed,
		-- backed up or removed. Guards a malformed response.
		if type(configResp.hash) ~= "string" then
			Utilities.GBWarn("Config", configStatus.id, "was returned without a hash and was not applied.")
			isComplete = false
			continue
		end

		-- Fetched by alias, so it can be a different config if the alias moved since the status. Applying
		-- it would store that config's content under this id.
		if configResp.configurationId ~= nil and tonumber(configResp.configurationId) ~= configStatus.id then
			Utilities.GBLog("Config", configStatus.id, "fetched as", configResp.configurationId, "; retrying next poll")
			isComplete = false
			continue
		end

		-- Applied anyway since it's newer than ours, but it isn't the version the status lists, so
		-- the next poll checks again
		if configResp.hash ~= configStatus.hash then
			isComplete = false
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

	if not Experiments:UpdateCatalog(status.experiments, status.requiredProperties) then
		isComplete = false
	end

	return isComplete
end

-- In the unlikely case GB is down, fall back on Roblox datastores
function Updater:GetBackupConfigs()
	local success, backup = PrimaryBackup:Get(GetBackupKey())

	if not success then
		Utilities.GBWarn("Couldn't get configs from backup. Attempting to re-establish connection with Gamebeast...")
		return nil
	end

	-- Other schema versions can't be applied
	if not backup or backup.schemaVersion ~= BACKUP_SCHEMA_VERSION then
		return nil
	end

	return backup.configurations
end

-- Saves config base documents to the DataStore backup. Experiments aren't backed up, since
-- assignments can't be resolved offline.
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

-- Coalesces config changes within BACKUP_SAVE_DEBOUNCE into one backup write.
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
		if success and versionData and self:IsVersionOutdated(MetaData.version, versionData.version) then
			Utilities.GBWarn(`Gamebeast SDK is out of date! Please update to the latest version. {MetaData.version} -> {versionData.version}`)
		end
	end)

	-- Start up, bootstrap configurations and experiments

	local function fetchBootstrap()
		local success, bootstrap, statusCode = GBRequests:GBRequestAsync("v2/bootstrap")
		return (if success then bootstrap else nil), statusCode
	end

	-- An apply that throws counts as a failed attempt, so it can't end this thread before status
	-- polling starts.
	local function tryApply(payload, isInit : boolean) : boolean
		local didApply, applyError = pcall(self.ApplyBootstrap, self, payload, isInit)
		if not didApply then
			Utilities.GBWarn("Failed to apply configurations from Gamebeast:", applyError)
		end
		return didApply
	end

	local bootstrap, statusCode = fetchBootstrap()

	-- If no response, failed status or a failed apply, attempt to recover
	if not (bootstrap and tryApply(bootstrap, true)) then
		Utilities.GBWarn("Couldn't get configurations from Gamebeast. Attempting to load from backup...")

		-- Run on the DataStore backup while reconnecting. If it applies, the live apply after it
		-- isn't an init, so it diffs and replicates.
		local isInit = true
		local backupConfigurations = self:GetBackupConfigs()
		if backupConfigurations and tryApply({
			configurations = backupConfigurations,
			experiments = { user = {}, server = {} },
			requiredProperties = {},
		}, true) then
			isInit = false
		end

		-- Wait for a live connection; everything else in the SDK depends on it
		local attempt = 0
		repeat
			attempt += 1
			local delay = self:GetConnectionRetryDelay(attempt, statusCode)
			Utilities.GBWarn(`Couldn't reach Gamebeast; retrying in {math.ceil(delay)}s.`)
			task.wait(delay)

			bootstrap, statusCode = fetchBootstrap()
		until bootstrap and tryApply(bootstrap, isInit)

		Utilities.GBWarn("Connection to Gamebeast established.")
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
		local lastPollTime = tick()
		local jitterRoll = math.random()

		while true do
			local remaining = self:GetPollDelay(jitterRoll) - (tick() - lastPollTime)
			if remaining > 0 then
				-- Capped so a settings or directive change is picked up within POLL_RECHECK_INTERVAL
				task.wait(math.min(remaining, POLL_RECHECK_INTERVAL))
				continue
			end

			-- An unchanged snapshot answers 304 with no body
			local didSucceed, status, statusCode = GBRequests:GBRequestAsync("v2/status", {
				hash = LastStatusHash,
			})

			if statusCode == 304 then
				Utilities.GBLog("Status unchanged since the last poll")
			elseif didSucceed and status then
				-- pcall so an apply error can't kill the poll loop
				local didApply, applyResult = pcall(self.ApplyStatus, self, status)

				if didApply and applyResult then
					LastStatusHash = status.hash
				elseif didApply then
					-- A refetch failed or was stale. Dropping the hash gets the full snapshot next poll,
					-- which retries only what's missing.
					LastStatusHash = nil
					Utilities.GBLog("Status poll applied in part; retrying the rest next poll")
				else
					-- Dropped so the next poll refetches the whole snapshot and tries again
					LastStatusHash = nil
					Utilities.GBWarn("Failed to apply the status poll:", applyResult)
				end
			else
				Utilities.GBLog("Status poll failed, retrying next interval")
			end

			-- Timed from the end of the cycle, so a slow poll can't tighten the cadence
			lastPollTime = tick()
			jitterRoll = math.random()
		end
	end)
end

--= Return Module =--
return Updater
