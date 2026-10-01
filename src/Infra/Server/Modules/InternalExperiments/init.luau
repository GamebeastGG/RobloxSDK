--!strict
--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	InternalExperiments.luau

	Description:
		Resolves experiment assignments for players and the server through the
		v2 bulk assignment endpoint, and exposes assignment state to the rest
		of the SDK.

		Experiment structure (metadata + group changesets) is owned by the
		ExperimentCatalog submodule; evaluation context (standard Roblox
		properties plus developer-defined properties) is owned by the
		AssignmentContext submodule. The catalog is reconciled from
		bootstrap/status payloads by the Updater via UpdateCatalog.

--]]

--= Root =--
local Experiments = {}

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests")
local DataCache = shared.GBMod("DataCache")
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal)
local Utilities = shared.GBMod("Utilities")
local SignalConnection = shared.GBMod("SignalConnection") ---@module SignalConnection
local ServerGate = shared.GBMod("ServerGate") ---@module ServerGate
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local Cleaner = shared.GBMod("Cleaner") ---@module Cleaner
local Changesets = require(script.Parent.Changesets)
local ExperimentCatalog = require(script.ExperimentCatalog)
local AssignmentContext = require(script.AssignmentContext)

--= Types =--

export type ExperimentsByUnitType = ExperimentCatalog.ExperimentsByUnitType
export type AssignmentRecord = {
	experimentId: number,
	groupId: number?,
	automaticGroupId: number?,
	overrideGroupId: number?,
	status: "active" | "unenrolled",
	source: string?,
	assignmentVersion: number?,
}

type AssignmentState = {
	playerIdsPendingAssignment: { [number]: true },
	playerJoinListener: RBXScriptConnection,
	playerLeaveListener: RBXScriptConnection,
	deferredBulkAssignmentThread: thread?,
	--[[
		Id of the latest request sent for each player. A response is only applied for the players
		it is still the latest request for: two requests for one player can be in flight at once
		(a join and a property change, say), and the older one landing last must not undo the newer.
	]]
	latestRequestIdByPlayerId: { [number]: number },
	lastRequestId: number,
	-- Players whose assignment will be requested again once their client reports in
	playersAwaitingClientInfo: { [Player]: true },
}

--= Constants =--

--[[
	How long to wait before requesting bulk assignment after calling `queueAssignment()`.
]]
local BULK_ASSIGNMENT_SECONDS_TO_DEFER = 1

--[[
	How long to wait before retrying a failed server assignment request.
]]
local SERVER_ASSIGNMENT_RETRY_DELAY = 10

--[[
	How long to wait before retrying a failed bulk assignment request. The ordinary defer is a
	second, which is right for batching up joins but turns into one request per second per server
	for as long as the backend is unhealthy, so a failure backs off to the same delay the
	server-unit path uses.
]]
local USER_ASSIGNMENT_RETRY_DELAY = 10

--[[
	Maximum units per bulk assignment request, enforced by the backend.
]]
local MAX_BULK_ASSIGNMENT_UNITS = 250

--[[
	How often the assignment refresh loop re-derives how long it should be waiting, so a lowered
	assignmentRefreshRate is picked up without sitting out a whole long interval first.
]]
local ASSIGNMENT_REFRESH_RECHECK_INTERVAL = 5

--= Variables =--

--[[
	Whether the loop re-requesting assignments every assignmentRefreshRate seconds is running.
]]
local assignmentRefreshStarted = false

--[[
	Pending debounced re-assignment after developer-defined properties changed.
]]
local propertyRefreshThread: thread? = nil

--[[
	User-assignment machinery, active only while user-unit experiments exist.
]]
local currentAssignmentState: AssignmentState? = nil

--[[
	Players whose first bulk assignment response has arrived.
]]
local resolvedPlayerSet: { [Player]: true } = {}

--[[
	Fired with a player every time a bulk assignment response for them is processed,
	regardless of whether their assignments changed.
]]
local playerAssignmentsResolvedSignal = Signal.new()

--[[
	Guard so only one server assignment retry is pending at a time.
]]
local serverAssignmentRetryPending = false

--= Public Variables =--

-- Active/unenrolled assignment records for server-unit experiments, by experiment id
Experiments.ServerAssignments = {} :: { [number]: AssignmentRecord }
-- Per-player assignment records for user-unit experiments, by experiment id
Experiments.AssignmentsByPlayer = {} :: { [Player]: { [number]: AssignmentRecord } }

Experiments.OnServerAssignmentsChanged = Signal.new()
Experiments.OnPlayerAssignmentsChanged = Signal.new() -- (player: Player)
Experiments.OnAssignmentDisabling = Signal.new()

--= Internal Functions =--

--[[
	Converts a bulk response assignment array into a record map keyed by experiment id.
]]
local function buildRecordMap(records: { any }?): { [number]: AssignmentRecord }
	local recordMap: { [number]: AssignmentRecord } = {}
	for _, record in (records or {}) :: { any } do
		recordMap[record.experimentId] = record
	end
	return recordMap
end

local executeUserAssignmentRequest -- Forward declaration for queueAssignment

--[[
	Queues players to be assigned to experiments in bulk.
]]
local function queueAssignment(players: { Player }, deferSeconds: number?)
	local assignmentState = currentAssignmentState
	assert(assignmentState, "Assignment has not been started")

	for _, player in players do
		assignmentState.playerIdsPendingAssignment[player.UserId] = true
	end

	-- Start timer for deferred bulk assignment
	if not assignmentState.deferredBulkAssignmentThread then
		assignmentState.deferredBulkAssignmentThread = task.delay(deferSeconds or BULK_ASSIGNMENT_SECONDS_TO_DEFER, function()
			assignmentState.deferredBulkAssignmentThread = nil
			executeUserAssignmentRequest()
		end)
	end
end

--[[
	Requests a player's assignment again as soon as their client reports in.

	Used when a request had to go out before the client did, so it was sent without the
	client-reported properties targeting needs (device, input type). Without this, a player on a
	slow-loading device misses a targeted experiment until the next assignment refresh, and then
	switches into it partway through their session.
]]
local function requeueOnClientInfo(assignmentState: AssignmentState, player: Player)
	if assignmentState.playersAwaitingClientInfo[player] then
		return
	end
	assignmentState.playersAwaitingClientInfo[player] = true

	Utilities.GBLog(`Client info for player {player.UserId} has not arrived yet; requesting their assignment again once it does`)

	-- Never fires if the player leaves first; the leave listener drops them from the awaiting set
	ServerClientInfoHandler:OnClientInfoResolved(player, function()
		if currentAssignmentState ~= assignmentState then
			return
		end

		assignmentState.playersAwaitingClientInfo[player] = nil
		if player.Parent then
			queueAssignment({ player })
		end
	end)
end

--[[
	Requests bulk assignment from the backend for queued players.

	@canyield
]]
function executeUserAssignmentRequest()
	local assignmentState = currentAssignmentState
	if not assignmentState then
		return
	end

	-- Cancel any pending deferred assignment (i.e. if execution is requested early)
	if assignmentState.deferredBulkAssignmentThread then
		task.cancel(assignmentState.deferredBulkAssignmentThread)
		assignmentState.deferredBulkAssignmentThread = nil
	end

	-- Consume queue of players pending assignment
	local playerIds: { number } = {}
	for playerId in assignmentState.playerIdsPendingAssignment do
		table.insert(playerIds, playerId)
	end
	assignmentState.playerIdsPendingAssignment = {}

	if #playerIds == 0 then
		return
	end

	assignmentState.lastRequestId += 1
	local requestId = assignmentState.lastRequestId
	for _, playerId in playerIds do
		assignmentState.latestRequestIdByPlayerId[playerId] = requestId
	end

	-- Retrieve context needed for assignment
	local contextByPlayerId, playersAwaitingClientInfo = AssignmentContext:GetForPlayers(playerIds, ExperimentCatalog:GetRequiredPropertyUnion("user"))
	if currentAssignmentState ~= assignmentState then
		return
	end

	for _, player in playersAwaitingClientInfo do
		requeueOnClientInfo(assignmentState, player)
	end

	local units: { any } = {}
	for _, playerId in playerIds do
		table.insert(units, {
			distinctId = tostring(playerId),
			context = contextByPlayerId[playerId],
		})
	end

	for chunkStart = 1, #units, MAX_BULK_ASSIGNMENT_UNITS do
		local chunk = table.move(units, chunkStart, math.min(chunkStart + MAX_BULK_ASSIGNMENT_UNITS - 1, #units), 1, {})

		Utilities.GBLog(`Requesting bulk assignment for {#chunk} player(s)...`)
		local didSucceed, response = GBRequests:GBRequestAsync("v2/experiments/assignments/bulk", {
			unitType = "user",
			sharedContext = AssignmentContext:GetShared(),
			units = chunk,
		})
		if currentAssignmentState ~= assignmentState then
			return
		end

		-- Requeue requested players if the assignment request failed
		if not didSucceed then
			Utilities.GBWarn("Failed to get experiment assignments:", response)

			local playersToRequeue: { Player } = {}
			for _, unit in chunk do
				local playerId = tonumber(unit.distinctId) :: number
				local player = Players:GetPlayerByUserId(playerId)
				-- A newer request for the player is already out, and retries itself if it fails
				if player and assignmentState.latestRequestIdByPlayerId[playerId] == requestId then
					table.insert(playersToRequeue, player)
				end
			end
			if #playersToRequeue > 0 then
				queueAssignment(playersToRequeue, USER_ASSIGNMENT_RETRY_DELAY)
			end

			continue
		end

		-- The response is the complete assignment set for each unit; replace wholesale
		for _, unit in chunk do
			local playerId = tonumber(unit.distinctId) :: number
			local player = Players:GetPlayerByUserId(playerId)
			if not player then
				continue
			end

			-- Superseded by a request sent after this one, which applies the player's assignments itself
			if assignmentState.latestRequestIdByPlayerId[playerId] ~= requestId then
				continue
			end

			local newRecords = buildRecordMap(response.assignments[unit.distinctId])
			local didChange = not Utilities.primativeDeepEqual(Experiments.AssignmentsByPlayer[player] or {}, newRecords)

			Experiments.AssignmentsByPlayer[player] = newRecords
			resolvedPlayerSet[player] = true
			playerAssignmentsResolvedSignal:Fire(player)

			if didChange then
				Utilities.GBLog("Assignments changed for player:", player.UserId)
				Experiments.OnPlayerAssignmentsChanged:Fire(player)
			end
		end
	end
end

--[[
	Requests assignment from the backend for this server, for server-unit experiments.
	Retries on failure while server-unit experiments remain active.

	@canyield
]]
local function executeServerAssignmentRequest()
	local serverContext = AssignmentContext:GetForServer(ExperimentCatalog:GetRequiredPropertyUnion("server"))
	local serverId = Utilities.getServerId()

	Utilities.GBLog("Requesting server experiment assignment...")
	local didSucceed, response = GBRequests:GBRequestAsync("v2/experiments/assignments/bulk", {
		unitType = "server",
		sharedContext = AssignmentContext:GetShared(),
		units = {
			{
				distinctId = serverId,
				context = serverContext,
			},
		},
	})

	if not didSucceed then
		Utilities.GBWarn("Failed to get server experiment assignment:", response)

		-- Retry while server-unit experiments remain
		if not serverAssignmentRetryPending then
			serverAssignmentRetryPending = true
			task.delay(SERVER_ASSIGNMENT_RETRY_DELAY, function()
				serverAssignmentRetryPending = false
				if ExperimentCatalog:GetUnitTypeCount("server") > 0 then
					executeServerAssignmentRequest()
				end
			end)
		end
		return
	end

	local newRecords = buildRecordMap(response.assignments[serverId])
	local didChange = not Utilities.primativeDeepEqual(Experiments.ServerAssignments, newRecords)

	Experiments.ServerAssignments = newRecords

	if didChange then
		Utilities.GBLog("Server assignments changed")
		Experiments.OnServerAssignmentsChanged:Fire()
	end
end

--[[
	Re-requests the assignments of every player in the server, and of the server itself, every
	assignmentRefreshRate seconds.

	This is the only way an assignment changed on the dashboard (a manual reassignment, an unenroll)
	reaches a live server: the status snapshot moves when an experiment's definition does, not when
	one unit's assignment does, so without it the change waits for the player to rejoin. Repeating
	the request is harmless, since an unchanged assignment resolves to the same group and the backend
	records its exposure once per assignment version.

	Started from the first catalog update rather than Init, so the settings are known to be set.
]]
local function startAssignmentRefresh()
	if assignmentRefreshStarted then
		return
	end
	assignmentRefreshStarted = true

	task.spawn(function()
		local lastRefreshTime = tick()

		while true do
			local remaining = DataCache:Get("Settings").assignmentRefreshRate - (tick() - lastRefreshTime)
			if remaining > 0 then
				task.wait(math.min(remaining, ASSIGNMENT_REFRESH_RECHECK_INTERVAL))
				continue
			end

			lastRefreshTime = tick()

			if currentAssignmentState then
				local players = Players:GetPlayers()
				if #players > 0 then
					queueAssignment(players)
				end
			end

			-- A pending retry is already about to re-request the server's assignment
			if ExperimentCatalog:GetUnitTypeCount("server") > 0 and not serverAssignmentRetryPending then
				task.spawn(executeServerAssignmentRequest)
			end
		end
	end)
end

--[[
	Starts requesting experiment assignments for players.
	Called when the catalog first contains user-unit experiments.
]]
local function enableAssignment()
	if currentAssignmentState then
		return
	end

	local assignmentState: AssignmentState
	assignmentState = {
		playerIdsPendingAssignment = {},
		playerJoinListener = Players.PlayerAdded:Connect(function(player)
			queueAssignment({ player })
		end),
		playerLeaveListener = ServerGate:OnPlayerRemoved(function(player)
			Experiments.AssignmentsByPlayer[player] = nil
			resolvedPlayerSet[player] = nil
			assignmentState.latestRequestIdByPlayerId[player.UserId] = nil
			assignmentState.playersAwaitingClientInfo[player] = nil
			Experiments.OnPlayerAssignmentsChanged:Fire(player)
		end),
		deferredBulkAssignmentThread = nil,
		latestRequestIdByPlayerId = {},
		lastRequestId = 0,
		playersAwaitingClientInfo = {},
	}
	currentAssignmentState = assignmentState

	Utilities.GBLog("Started requesting experiment assignment")
end

--[[
	Stops requesting experiment assignments for players.
	Called when the catalog no longer contains user-unit experiments.
]]
local function disableAssignment()
	local assignmentState = currentAssignmentState
	if not assignmentState then
		return
	end

	Experiments.OnAssignmentDisabling:Fire()

	assignmentState.playerJoinListener:Disconnect()
	assignmentState.playerLeaveListener:Disconnect()

	if assignmentState.deferredBulkAssignmentThread then
		task.cancel(assignmentState.deferredBulkAssignmentThread)
	end

	currentAssignmentState = nil
	table.clear(resolvedPlayerSet)
	-- No user experiments are running, so these records mean nothing now. Left in place they pin a
	-- Player for every player who was in the server when assignment stopped, and the leave
	-- listener that would have cleared them has just been disconnected.
	table.clear(Experiments.AssignmentsByPlayer)

	Utilities.GBLog("Stopped requesting experiment assignment")
end

--[[
	Re-resolves assignments after developer-defined properties changed, so
	targeting filters see the new context. Debounced to coalesce bursts of updates.

	Player properties only affect that player. Server properties travel as shared
	context for every unit, so they refresh the server and all players.
]]
local function scheduleContextRefresh(player: Player?)
	if player then
		if currentAssignmentState then
			queueAssignment({ player })
		end
		return
	end

	if propertyRefreshThread then
		return
	end

	propertyRefreshThread = task.delay(BULK_ASSIGNMENT_SECONDS_TO_DEFER, function()
		propertyRefreshThread = nil

		if ExperimentCatalog:GetUnitTypeCount("server") > 0 then
			task.spawn(executeServerAssignmentRequest)
		end
		if currentAssignmentState then
			queueAssignment(Players:GetPlayers())
		end
	end)
end

--= API Functions =--

--[[
	Developer-defined properties included as `context.properties` in assignment
	requests, for experiment targeting. Changing them re-resolves assignments.
]]
function Experiments:SetPlayerProperties(player: Player, properties: { [string]: any })
	if AssignmentContext:SetPlayerProperties(player, properties) then
		scheduleContextRefresh(player)
	end
end

function Experiments:SetPlayerProperty(player: Player, key: string, value: any)
	if AssignmentContext:SetPlayerProperty(player, key, value) then
		scheduleContextRefresh(player)
	end
end

function Experiments:GetPlayerProperties(player: Player): AssignmentContext.PropertyMap
	return AssignmentContext:GetPlayerProperties(player)
end

function Experiments:SetServerProperties(properties: { [string]: any })
	if AssignmentContext:SetServerProperties(properties) then
		scheduleContextRefresh(nil)
	end
end

function Experiments:SetServerProperty(key: string, value: any)
	if AssignmentContext:SetServerProperty(key, value) then
		scheduleContextRefresh(nil)
	end
end

function Experiments:GetServerProperties(): AssignmentContext.PropertyMap
	return AssignmentContext:GetServerProperties()
end

--[[
	Reconciles the experiment catalog against a bootstrap/status payload and reacts
	to what changed.

	New experiments trigger assignment for current players (user-unit) or the server
	itself (server-unit). Removed experiments have their assignments stripped, firing
	the changed signals so configs recompose.

	@canyield
]]
function Experiments:UpdateCatalog(experiments: ExperimentsByUnitType, requiredProperties: { string }?)
	startAssignmentRefresh()

	local summary = ExperimentCatalog:Update(experiments, requiredProperties)

	-- Strip assignments for stopped experiments
	local didServerAssignmentsChange = false
	local changedPlayers: { [Player]: true } = {}

	for _, experimentId in summary.removedExperimentIds do
		if Experiments.ServerAssignments[experimentId] then
			Experiments.ServerAssignments[experimentId] = nil
			didServerAssignmentsChange = true
		end

		for player, records in Experiments.AssignmentsByPlayer do
			if records[experimentId] then
				records[experimentId] = nil
				changedPlayers[player] = true
			end
		end
	end

	-- Toggle user assignment machinery based on the reconciled catalog
	local userExperimentCount = ExperimentCatalog:GetUnitTypeCount("user")
	local wasAssignmentAlreadyEnabled = (currentAssignmentState ~= nil)

	if userExperimentCount > 0 and not wasAssignmentAlreadyEnabled then
		enableAssignment()
	elseif userExperimentCount == 0 and wasAssignmentAlreadyEnabled then
		disableAssignment()
	end

	-- Assign for new experiments: all current players for user-unit starts,
	-- the server itself for server-unit starts
	if #summary.newUserExperimentIds > 0 and currentAssignmentState then
		queueAssignment(Players:GetPlayers())

		-- On initial enable, resolve immediately so config composition can wait on it
		if not wasAssignmentAlreadyEnabled then
			executeUserAssignmentRequest()
		end
	end

	if #summary.newServerExperimentIds > 0 then
		executeServerAssignmentRequest()
	end

	-- Fire removal signals last so subscribers recompose against the final catalog
	if didServerAssignmentsChange then
		Experiments.OnServerAssignmentsChanged:Fire()
	end
	for player in changedPlayers do
		Experiments.OnPlayerAssignmentsChanged:Fire(player)
	end
end

--[[
	Returns the ordered changesets to apply on top of the given config's base document.

	Server-unit changesets come first (they define the server view all players inherit),
	then the player's user-unit changesets, each in ascending experiment id order to match
	the backend's merge order.
]]
function Experiments:GetChangesetsForConfig(configId: number, player: Player?): { Changesets.Changeset }
	local function collect(unitType: "user" | "server", records: { [number]: AssignmentRecord })
		local collected: { { changeset: Changesets.Changeset, experimentId: number } } = {}
		for experimentId, record in records do
			local state = ExperimentCatalog:Get(experimentId)
			if not state
				or state.meta.unitType ~= unitType
				or state.meta.baseConfigurationId ~= configId
				or record.status ~= "active"
				or not record.groupId
			then
				continue
			end

			local changeset = state.changesetByGroupId[record.groupId :: number]
			if changeset then
				table.insert(collected, {
					changeset = changeset,
					experimentId = experimentId,
				})
			end
		end

		table.sort(collected, function(a, b)
			return a.experimentId < b.experimentId
		end)

		return collected
	end

	local orderedChangesets: { Changesets.Changeset } = {}
	for _, item in collect("server", Experiments.ServerAssignments) do
		table.insert(orderedChangesets, item.changeset)
	end
	if player then
		for _, item in collect("user", Experiments.AssignmentsByPlayer[player] or {}) do
			table.insert(orderedChangesets, item.changeset)
		end
	end

	return orderedChangesets
end

--[[
	Whether the player has any active user-unit assignment affecting the given config,
	i.e. whether they need a per-player view of it.
]]
function Experiments:HasPlayerOverlays(player: Player, configId: number): boolean
	local records = Experiments.AssignmentsByPlayer[player]
	if not records then
		return false
	end

	for experimentId, record in records do
		local state = ExperimentCatalog:Get(experimentId)
		if state
			and state.meta.baseConfigurationId == configId
			and record.status == "active"
			and record.groupId
			and state.changesetByGroupId[record.groupId :: number]
		then
			return true
		end
	end

	return false
end

--[[
	Returns the assignment records for a player, or for the server when `player` is nil.
]]
function Experiments:GetAssignments(player: Player?): { AssignmentRecord }
	local records = if player then Experiments.AssignmentsByPlayer[player] else Experiments.ServerAssignments

	local assignments: { AssignmentRecord } = {}
	for _, record in records or {} do
		table.insert(assignments, record)
	end
	return assignments
end

--[[
	Returns display metadata for an assignment, if its experiment and group are
	active in the catalog.
]]
function Experiments:GetAssignmentMetadata(experimentId: number, groupId: number): { experimentName: string, groupLabel: string }?
	return ExperimentCatalog:GetMetadata(experimentId, groupId)
end

--[[
	Calls `callback` once the player's experiment assignments have been resolved
	(their first bulk response has arrived), or immediately when no user-unit
	experiments are active. Also resolves if assignment is disabled or the player leaves.

	Returns a connection to cancel listening.
]]
function Experiments:OnAssignmentsResolvedForPlayer(player: Player, callback: () -> ()): RBXScriptConnection
	local listenerCleaner = Cleaner.new()
	local connection = SignalConnection.new(function()
		listenerCleaner:Destroy()
	end)

	local function resolve()
		connection:Disconnect() -- Disconnect the listener
		task.spawn(callback)

		return connection -- Return dead connection
	end

	-- If no user-unit experiments are active, resolve immediately
	if not currentAssignmentState then
		return resolve()
	end

	if resolvedPlayerSet[player] then
		return resolve()
	end

	listenerCleaner:Add(playerAssignmentsResolvedSignal:Connect(function(resolvedPlayer: Player)
		if resolvedPlayer == player then
			resolve()
		end
	end))

	listenerCleaner:Add(Experiments.OnAssignmentDisabling:Connect(function()
		resolve()
	end))

	listenerCleaner:Add(Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
		if leavingPlayer == player then
			resolve()
		end
	end))

	return connection
end

--= Return Module =--
return Experiments
