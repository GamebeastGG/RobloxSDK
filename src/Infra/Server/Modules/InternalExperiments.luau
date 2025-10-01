--!strict
local Experiments = {}

-- Services
local Players = game:GetService("Players")

-- Dependencies
local GBRequests = shared.GBMod("GBRequests")
local LocalizationCache = shared.GBMod("LocalizationCache") ---@module LocalizationCache
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal)
local Utilities = shared.GBMod("Utilities")
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local SignalConnection = shared.GBMod("SignalConnection") ---@module SignalConnection
local Cleaner = shared.GBMod("Cleaner") ---@module Cleaner
local Types = require(script.Parent.Parent.Parent.Types)

-- Types
type ConfigSnapshot = {
	options: {
		privacy: {{string}},
	},
	variables: {
		[string]: any,
	},
}
type AvailableExperimentGroupSnapshot = {
	id: number,
	groupName: string,
	experimentName: string,
	endsAt: number?,
	configs: ConfigSnapshot,
}
type AvailableExperimentsSnapshot = {
	timestampMs: number,
	groups: {AvailableExperimentGroupSnapshot},
	scheduled: {[string]: {number}},
	targetType: "gameserver" | "player" | nil,
	requiredProperties: {string}?,
}
type ExperimentReassignmentPropagationRequest = {
	playerIds: {string},
	gameserverIds: {string},
}

type BaseAssignmentResponse = {
	groups: {AvailableExperimentGroupSnapshot}?,
}
type GameserverAssignmentResponse = BaseAssignmentResponse & {
	targetType: "gameserver",
	gameserverGroupId: number?,
}
type PlayerAssignmentResponse = BaseAssignmentResponse & {
	targetType: "player",
	playerIdsByGroupId: {[string]: {string}},
}
type EmptyAssignmentResponse = nil
type AssignmentResponse =
	GameserverAssignmentResponse
	| PlayerAssignmentResponse
	| EmptyAssignmentResponse

--[[
	How long to wait before requesting bulk assignment after calling `queueAssignment()`.
]]
local BULK_ASSIGNMENT_SECONDS_TO_DEFER = 1

--[[
	How many seconds to wait before triggering reassignment for groups that have ended.
]]
local POST_EXPERIMENT_END_REASSIGNMENT_DELAY = 0

--[[
	How long assignment is willing to wait for available experiments to be fetched
	before proceeding with assignment requests anyway.

	This delay only happens when the full metadata for scheduled experiments that have
	become active is still being fetched from the backend.
]]
local MAX_ASSIGNMENT_EXPERIMENTS_FETCH_DELAY = 3

--[[
	How long to wait for assignment metadata callbacks to finish, before skipping them
	and proceeding with assignment without their result.
]]
local MAX_ASSIGNMENT_METADATA_CALLBACK_DURATION = 6

--[[
	When experiments have filters that require player properties, these
	callbacks are ran to retrieve and include that metadata in assignment
	requests.

	These callbacks can yield, but ideally should not yield for too long. If a
	callback yields for longer than `MAX_ASSIGNMENT_METADATA_CALLBACK_DURATION`
	seconds, the assignment request will proceed without its result.
]]
local PLAYER_PROPERTY_GETTERS: {[string]: (player: Player) -> any} = {
	inputType = function (player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "inputType")
	end,
	device = function (player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "device")
	end,
	deviceSubType = function (player)
		ServerClientInfoHandler:WaitUntilClientInfoResolved(player)
		return ServerClientInfoHandler:GetClientInfo(player, "deviceSubType")
	end,
	country = function (player)
		return LocalizationCache:GetRegionId(player)
	end,
	language = function (player)
		return LocalizationCache:GetLocaleId(player)
	end,
	placeId = function ()
		return game.PlaceId
	end,
	placeVersion = function ()
		return game.PlaceVersion
	end,
}

--[[
	When experiments have filters that require server properties, these
	callbacks are ran to retrieve and include that metadata in assignment
	requests.

	These callbacks can yield, but ideally should not yield for too long. If a
	callback yields for longer than `MAX_ASSIGNMENT_METADATA_CALLBACK_DURATION`
	seconds, the assignment request will proceed without its result.
]]
local SERVER_PROPERTY_GETTERS: {[string]: () -> any} = {
	placeId = function ()
		return game.PlaceId
	end,
	placeVersion = function ()
		return game.PlaceVersion
	end,
}

--[[
	Whether the application has any available experiments to request assignments for,
	and has begun requesting them.
]]
local currentAssignmentState: {
	playerIdsPendingAssignment: {[number]: true},
	playerJoinListener: RBXScriptConnection,
	playerLeaveListener: RBXScriptConnection,
	deferredBulkAssignmentThread: thread?,
	activeGroupStateById: {[number]: {
		group: AvailableExperimentGroupSnapshot,
		playerSet: {[Player]: true},
		experimentEndTimer: thread?,
	}},

	--[[
		State for groups we know are active, but haven't received yet from snapshots or
		assignment responses (i.e. if a future-scheduled group has started).

		This is initialized by `initializeUnfetchedActiveGroupState()` when a
		scheduled group starts.

		Once a group is received, or if it ends before being received, it is removed
		from this map when `clearUnfetchedActiveGroupState()` is called.
	]]
	unfetchedActiveGroupStateById: {[number]: {
		endTime: number?,
		experimentEndTimer: thread?,
		onFetched: Signal.Signal,
	}},

}? = nil

local lastAvailableExperimentsSnapshot = nil :: AvailableExperimentsSnapshot?

--[[
	Map of experiment group IDs scheduled to start in the future, and their
	corresponding timer thread for triggering assignment when they start.

	These are created and terminated early based on received snapshots.
]]
local assignmentWakeUpTimersByFutureGroupId = {} :: {[number]: thread}

--[[
	Thread for deferring proactively fetching the latest available experiments
	from the backend, to consolidate multiple sequential requests into one.
]]
local deferredSnapshotFetchTimerThread = nil :: thread?

Experiments.AssignedServerGroupId = nil :: number?
Experiments.AssignedGroupIdByPlayer = {} :: {[Player]: number?}
Experiments.OnServerGroupIdChanged = Signal.new()
Experiments.OnPlayerGroupIdChanged = Signal.new()

Experiments.AssignedServerConfig = nil :: ConfigSnapshot?
Experiments.AssignedConfigByPlayer = {} :: {[Player]: ConfigSnapshot}
Experiments.OnAssignedServerConfigChanged = Signal.new()
Experiments.OnAssignedPlayerConfigChanged = Signal.new()

Experiments.CanonicalServerConfig = nil :: ConfigSnapshot?

Experiments.OnAssignmentDisabling = Signal.new()

--[[
	Updates whether assignments are being requested or not, based on the given
	snapshots of available experiments received from the backend.

	If assignment is triggered on, this will yield as it requests and waits for
	the initial assignments to be received from the backend.

	@canyield
]]
function Experiments:UpdateStateFromAvailableExperiments(
	availableExperimentsSnapshot: AvailableExperimentsSnapshot,
	canonicalServerConfig: ConfigSnapshot?
)
	if canonicalServerConfig then
		Experiments.CanonicalServerConfig = canonicalServerConfig
	end

	-- Ignore older snapshots (e.g. from old config change jobs, which take longer to propagate to gameservers)
	if lastAvailableExperimentsSnapshot and (lastAvailableExperimentsSnapshot.timestampMs >= availableExperimentsSnapshot.timestampMs) then
		return
	end
	lastAvailableExperimentsSnapshot = availableExperimentsSnapshot

	-- Start requesting assignment if there are any available experiments
	local availableGroups = availableExperimentsSnapshot.groups
	local wasAssignmentAlreadyEnabled = (currentAssignmentState ~= nil)
	if #availableGroups > 0 and not currentAssignmentState then
		enableAssignment()
	elseif #availableGroups == 0 and currentAssignmentState then
		disableAssignment()
	end

	-- If assignment is enabled, apply changes from the snapshot to its state
	if currentAssignmentState then

		-- Cache received experiment group configs
		local snapshotGroupIdSet = {} :: {[number]: true}
		local didReceiveNewGroup = false
		for _, group in availableGroups do
			snapshotGroupIdSet[group.id] = true
			if initializeActiveGroupState(group) then
				didReceiveNewGroup = true
			end
			clearUnfetchedActiveGroupState(group.id, true)
		end

		-- If snapshot just enabled assignment, trigger and wait for initial assignment
		if not wasAssignmentAlreadyEnabled then
			executeAssignmentRequest()

		-- If snapshot didn't just enable assignment, update groups' state based on it
		else
			-- Clear terminated unfetched groups
			for groupId in currentAssignmentState.unfetchedActiveGroupStateById do
				if not snapshotGroupIdSet[groupId] then
					Utilities.GBLog("Unfetched experiment group terminated:", groupId)
					clearUnfetchedActiveGroupState(groupId)
				end
			end

			-- Clear local assignments for experiments that have been terminated
			local terminatedGroupIds: {number} = {}
			if Experiments.AssignedServerGroupId and not snapshotGroupIdSet[Experiments.AssignedServerGroupId] then
				table.insert(terminatedGroupIds, Experiments.AssignedServerGroupId)
			end
			for groupId in currentAssignmentState.activeGroupStateById do
				if not snapshotGroupIdSet[groupId] then
					table.insert(terminatedGroupIds, groupId)
				end
			end
			if #terminatedGroupIds > 0 then
				Utilities.GBLog("Clearing terminated experiment groups:", terminatedGroupIds)
				reassignTerminatedGroupMembers(terminatedGroupIds)
				for _, groupId in terminatedGroupIds do
					clearActiveGroupState(groupId, true)
				end
			end

			-- If new groups are available, queue assignment for non-assigned players
			if didReceiveNewGroup then
				queueAssignmentForNonAssignedPlayers()
			end
		end
	end

	-- Schedule assignment wake-up timers for future experiments
	for groupIdKey, timestamps in availableExperimentsSnapshot.scheduled do
		local groupId = tonumber(groupIdKey) :: number
		if assignmentWakeUpTimersByFutureGroupId[groupId] then
			continue
		end

		local startTimeMs = timestamps[1]
		local endTimeMs = timestamps[2] :: number?

		local secondsUntilStart = math.max(0, startTimeMs - DateTime.now().UnixTimestampMillis) / 1000
		Utilities.GBLog("Scheduling future experiment group wake-up timer:", groupId, startTimeMs, "in", secondsUntilStart, "sec")
		assignmentWakeUpTimersByFutureGroupId[groupId] = task.delay(secondsUntilStart, function ()
			assignmentWakeUpTimersByFutureGroupId[groupId] = nil
			if currentAssignmentState then
				initializeUnfetchedActiveGroupState(groupId, endTimeMs)
			end
			queueAvailableExperimentsSnapshotUpdate()
		end)
	end
	for groupId, timer in assignmentWakeUpTimersByFutureGroupId do
		local groupIdKey = tostring(groupId)
		if not availableExperimentsSnapshot.scheduled[groupIdKey] then
			Utilities.GBLog("Future experiment group", groupId, "terminated, cancelling timer")
			task.cancel(timer)
			assignmentWakeUpTimersByFutureGroupId[groupId] = nil
		end
	end
end

--[[
	Processes a request from the backend to trigger requesting assignments for
	specific players and servers.
]]
function Experiments:ProcessExperimentReassignmentRequest(request: ExperimentReassignmentPropagationRequest)
	local currentGameserverId = Utilities.getServerId()

	-- If this gameserver is included in the request, queue reassignment
	if table.find(request.gameserverIds, currentGameserverId) then
		Utilities.GBLog("Queueing reassignment as requested for server...")
		queueAssignment(Players:GetPlayers())
	end

	-- If players in the server are included in the request, queue them for reassignment
	for _, playerIdString in request.playerIds do
		local playerId = tonumber(playerIdString)
		local player = playerId and Players:GetPlayerByUserId(playerId)
		if player then
			Utilities.GBLog("Queueing reassignment as requested for player:", player.Name)
			queueAssignment({ player })
		end
	end
end

--[[
	Calls `callback` with the experiment group ID applied to a player once it's known.
	If assignment is disabled, or the player leaves, this may be `nil`.

	Returns a function to cancel listening.
]]
function Experiments:ListenForPlayerAssignment(player: Player, callback: (groupId: number?) -> ()): RBXScriptConnection
	local listenerCleaner = Cleaner.new()
	local connection = SignalConnection.new(function()
		listenerCleaner:Destroy()
	end)

	local function resolve(groupId: number?)
		connection:Disconnect() -- Disconnect the listener
		task.spawn(callback, groupId)

		return connection -- Return dead connection
	end

	-- If assignment is not enabled, immediately return nil
	if not currentAssignmentState then
		return resolve(nil)
	end

	-- If server is assigned, return the assigned group ID
	if Experiments.AssignedServerGroupId then
		return resolve(Experiments.AssignedServerGroupId)
	end

	-- If player is assigned, return the assigned group ID
	if Experiments.AssignedGroupIdByPlayer[player] then
		return resolve(Experiments.AssignedGroupIdByPlayer[player])
	end

	-- Wait for assignment to change for player or server, or for it to be disabled
	listenerCleaner:Add(Experiments.OnPlayerGroupIdChanged:Connect(function (changedPlayer: Player, newGroupId: number?)
		if (changedPlayer == player) and newGroupId then
			resolve(newGroupId)
		end
	end))

	listenerCleaner:Add(Experiments.OnServerGroupIdChanged:Connect(function (newGroupId: number?)
		if newGroupId then
			resolve(newGroupId)
		end
	end))

	listenerCleaner:Add(Experiments.OnAssignmentDisabling:Connect(function ()
		resolve(nil)
	end))

	listenerCleaner:Add(Players.PlayerRemoving:Connect(function (leavingPlayer: Player)
		if leavingPlayer == player then
			resolve(nil)
		end
	end))

	return connection
end

--[[
	Returns metadata about the specified experiment group, if it has been
	fetched from the backend, and is active.
]]
function Experiments:GetActiveGroupMetadata(groupId: number): Types.ExperimentGroupMetadata?
	if not currentAssignmentState then
		return nil
	end

	local groupState = currentAssignmentState.activeGroupStateById[groupId]
	if not groupState then
		return nil
	end

	return {
		experimentName = groupState.group.experimentName,
		groupName = groupState.group.groupName,
	}
end

--[[
	Starts requesting experiment assignments for players and the server.

	Called when the game receives GB configs and becomes aware of available
	experiments to enroll in.
]]
function enableAssignment()
	if currentAssignmentState then
		return
	end

	-- Start assignment & initialize state
	currentAssignmentState = {
		playerIdsPendingAssignment = {},
		playerJoinListener = Players.PlayerAdded:Connect(function (player)
			if not Experiments.AssignedServerGroupId then
				queueAssignment({ player })
			end
		end),
		playerLeaveListener = Players.PlayerRemoving:Connect(function (player)
			task.defer(function ()
				setAssignedPlayerGroupId(player, nil)
			end)
		end),
		deferredBulkAssignmentThread = nil,
		activeGroupStateById = {},
		unfetchedActiveGroupStateById = {},
	}

	Utilities.GBLog("Started requesting experiment assignment")
	
	-- Request initial assignment
	Utilities.GBLog("Queuing initial assignment...")
	queueAssignment(Players:GetPlayers())
end

--[[
	Stops requesting experiment assignments for players and the server.

	Called when the game receives an updated available experiments snapshot
	and becomes aware that there are no longer any available experiments.
]]
function disableAssignment()
	if not currentAssignmentState then
		return
	end

	Experiments.OnAssignmentDisabling:Fire()

	-- Clear current assignments
	setAssignedServerGroupId(nil)
	for player in Experiments.AssignedGroupIdByPlayer do
		setAssignedPlayerGroupId(player, nil)
	end

	-- Clear all active group state
	for groupId in currentAssignmentState.activeGroupStateById do
		clearActiveGroupState(groupId)
	end
	for groupId in currentAssignmentState.unfetchedActiveGroupStateById do
		clearUnfetchedActiveGroupState(groupId)
	end

	currentAssignmentState.playerJoinListener:Disconnect()
	currentAssignmentState.playerLeaveListener:Disconnect()

	if currentAssignmentState.deferredBulkAssignmentThread then
		task.cancel(currentAssignmentState.deferredBulkAssignmentThread)
	end

	currentAssignmentState = nil

	Utilities.GBLog("Stopped requesting experiment assignment")
end

--[[
	Queues players to be assigned to experiments in bulk.
]]
function queueAssignment(players: {Player})
	assert(currentAssignmentState, "Assignment has not been started")

	for _, player in players do
		currentAssignmentState.playerIdsPendingAssignment[player.UserId] = true
	end

	-- Start timer for deferred bulk assignment
	if not currentAssignmentState.deferredBulkAssignmentThread then
		currentAssignmentState.deferredBulkAssignmentThread = task.delay(BULK_ASSIGNMENT_SECONDS_TO_DEFER, function ()
			currentAssignmentState.deferredBulkAssignmentThread = nil
			executeAssignmentRequest()
		end)
	end
end

--[[
	Requests assignment from the backend server for queued players and the server.
]]
function executeAssignmentRequest()
	local assignmentState = currentAssignmentState
	assert(assignmentState, "Assignment has not been started")

	-- Cancel any pending deferred assignment (i.e. if execution is requested early)
	if assignmentState.deferredBulkAssignmentThread then
		task.cancel(assignmentState.deferredBulkAssignmentThread)
		assignmentState.deferredBulkAssignmentThread = nil
	end

	-- Consume queue of players pending assignment
	local playerIds: {number} = {}
	for playerId in assignmentState.playerIdsPendingAssignment do
		table.insert(playerIds, playerId)
	end
	assignmentState.playerIdsPendingAssignment = {}

	-- Build list of known groups that backend shouldn't include in response
	local knownGroupIds: {number} = {}
	for groupId in assignmentState.activeGroupStateById do
		table.insert(knownGroupIds, groupId)
	end

	-- If there are unfetched groups, wait up to max delay for them to be fetched
	-- (these may introduce new metadata required for assignment, which is retrieved next)
	local pendingUnfetchedGroupCallbacks: {() -> ()} = {}
	for _, unfetchedGroupState in assignmentState.unfetchedActiveGroupStateById do
		table.insert(pendingUnfetchedGroupCallbacks, function ()
			unfetchedGroupState.onFetched:Wait()
		end)
	end
	Utilities.waitForAnyCall({
		function ()
			Utilities.waitForAllCalls(pendingUnfetchedGroupCallbacks)
		end,
		function ()
			task.wait(MAX_ASSIGNMENT_EXPERIMENTS_FETCH_DELAY)
		end,
	})
	if currentAssignmentState ~= assignmentState then
		return
	end

	-- Retrieve metadata needed for assignment
	local serverProperties, playerPropertiesByIdString = getMetadataForAssignment(playerIds, MAX_ASSIGNMENT_METADATA_CALLBACK_DURATION)
	if currentAssignmentState ~= assignmentState then
		return
	end

	Utilities.GBLog(`Requesting assignment (playerIds: {table.concat(playerIds, ", ")})...`)
	local didSucceed, response = GBRequests:GBRequestAsync("v1/experiments/assignments", {
		playerIds = playerIds,
		knownGroupIds = knownGroupIds,
		allowGameserverAssignment = true,
		serverProperties = serverProperties,
		playerProperties = playerPropertiesByIdString,
	})
	if currentAssignmentState ~= assignmentState then
		return
	end

	-- Requeue requested players if assignment request failed
	Utilities.GBLog("Received assignment response:", didSucceed, response)
	if not didSucceed then
		Utilities.GBWarn("Failed to get experiment assignment:", response)

		local players: {Player} = {}
		for _, playerId in playerIds do
			local player = Players:GetPlayerByUserId(playerId)
			if player then
				table.insert(players, player)
			end
		end
		queueAssignment(players)

		return
	end
	local assignmentResponse = response :: AssignmentResponse

	-- If no experiments are available for assignment, disable assignment
	if not assignmentResponse then
		disableAssignment()
		return
	end

	-- Cache new received group snapshots
	if assignmentResponse.groups then
		for _, group in assignmentResponse.groups do
			initializeActiveGroupState(group)
			clearUnfetchedActiveGroupState(group.id, true)
		end
	end

	if assignmentResponse.targetType == "gameserver" then
		setAssignedServerGroupId(assignmentResponse.gameserverGroupId)

		-- Clear previous per-player assignments, if any
		for player in Experiments.AssignedGroupIdByPlayer do
			setAssignedPlayerGroupId(player, nil)
		end

	elseif assignmentResponse.targetType == "player" then
		local assignedPlayerIdSet: {[number]: true} = {}
		for groupIdString, groupPlayerIds in assignmentResponse.playerIdsByGroupId do
			local groupId = tonumber(groupIdString) :: number
			for _, playerIdString in groupPlayerIds do
				local playerId = tonumber(playerIdString)
				local player = playerId and Players:GetPlayerByUserId(playerId)
				if player then
					setAssignedPlayerGroupId(player, groupId)
				end
				if playerId then
					assignedPlayerIdSet[playerId] = true
				end
			end
		end

		-- Clear assignment for players who were not reassigned to a new group
		for _, playerId in playerIds do
			if not assignedPlayerIdSet[playerId] then
				local player = Players:GetPlayerByUserId(playerId)
				if player then
					setAssignedPlayerGroupId(player, nil)
				end
			end
		end

		-- Clear previous per-server assignment, if any
		setAssignedServerGroupId(nil)
	end
end

function setAssignedPlayerGroupId(player: Player, groupId: number?)
	assert(currentAssignmentState, "Assignment has not been started")
	assert(groupId == nil or currentAssignmentState.activeGroupStateById[groupId], "Experiment group state has not been initialized")

	Utilities.GBLog("Setting assigned experiment group ID for player:", player.UserId, groupId)

	local previousGroupId = Experiments.AssignedGroupIdByPlayer[player]
	if previousGroupId == groupId then
		Utilities.GBLog("Skipping setting assigned experiment group ID for player:", player.UserId, `(unchanged {groupId} -> {previousGroupId})`)
		return
	end

	-- Clear from currently assigned group, if any
	local previousGroupState = previousGroupId and currentAssignmentState.activeGroupStateById[previousGroupId]
	if previousGroupState then
		Utilities.GBLog("Clearing player from previous group state:", player.UserId, previousGroupId)
		previousGroupState.playerSet[player] = nil
	end

	Experiments.AssignedGroupIdByPlayer[player] = groupId
	Experiments.OnPlayerGroupIdChanged:Fire(player, groupId)

	if groupId then
		local groupState = currentAssignmentState.activeGroupStateById[groupId]
		Experiments.AssignedConfigByPlayer[player] = groupState.group.configs
		Experiments.OnAssignedPlayerConfigChanged:Fire(player, groupState.group.configs)
		currentAssignmentState.activeGroupStateById[groupId].playerSet[player] = true

	-- If unassigning from a group, clear the assigned config
	else
		Experiments.AssignedConfigByPlayer[player] = nil
		Experiments.OnAssignedPlayerConfigChanged:Fire(player, nil)
	end
end

function setAssignedServerGroupId(groupId: number?)
	assert(currentAssignmentState, "Assignment has not been started")
	assert(groupId == nil or currentAssignmentState.activeGroupStateById[groupId], "Experiment group state has not been initialized")

	local previousGroupId = Experiments.AssignedServerGroupId
	if previousGroupId == groupId then
		return
	end

	Experiments.AssignedServerGroupId = groupId
	Experiments.OnServerGroupIdChanged:Fire(groupId)

	if groupId then
		local groupState = currentAssignmentState.activeGroupStateById[groupId]
		Experiments.AssignedServerConfig = groupState.group.configs
		Experiments.OnAssignedServerConfigChanged:Fire(groupState.group.configs)

	else
		Experiments.AssignedServerConfig = nil
		Experiments.OnAssignedServerConfigChanged:Fire(nil)
	end
end

function getDoAvailableExperimentsRemain(excludedGroupIdList: {number}?): boolean
	if not currentAssignmentState then
		return false
	end

	local excludedGroupIdSet = {} :: {[number]: true?}
	if excludedGroupIdList then
		for _, groupId in excludedGroupIdList do
			excludedGroupIdSet[groupId] = true
		end
	end

	for groupId, state in currentAssignmentState.activeGroupStateById do
		if excludedGroupIdSet[groupId] then
			continue
		end

		-- Skip active groups that may have just ended
		if state.group.endsAt and DateTime.now().UnixTimestampMillis >= state.group.endsAt then
			continue
		end

		return true
	end

	for groupId, state in currentAssignmentState.unfetchedActiveGroupStateById do
		if excludedGroupIdSet[groupId] then
			continue
		end

		-- Skip unfetched groups that may have just ended
		if state.endTime and DateTime.now().UnixTimestampMillis >= state.endTime then
			continue
		end

		return true
	end

	return false
end

--[[
	Queues reassignment for members of the given terminated groups,
	if any available experiments remain.
]]
function reassignTerminatedGroupMembers(terminatedGroupIds: {number})
	assert(currentAssignmentState, "Assignment has not been started")

	local unassignedPlayers: {Player} = {}
	local didUnassignServer = false

	-- Identify members in need of reassignment
	for _, groupId in terminatedGroupIds do
		local groupState = currentAssignmentState.activeGroupStateById[groupId]
		if groupState then
			for player in groupState.playerSet do
				Utilities.GBLog("Queuing reassignment for player from terminated experiment group:", groupId, player.Name)
				table.insert(unassignedPlayers, player)
			end
		end

		if Experiments.AssignedServerGroupId == groupId then
			Utilities.GBLog("Queuing reassignment for server from terminated experiment group:", groupId)
			didUnassignServer = true
		end
	end

	-- Skip reassignment if no experiments remain
	if not getDoAvailableExperimentsRemain(terminatedGroupIds) then
		Utilities.GBLog("No experiments available, skipping reassignment")
		return
	end

	-- If server was unassigned, check for new assignments of any kind
	if didUnassignServer then
		queueAssignment(Players:GetPlayers())
	end

	-- If players were unassigned, check for new assignment for them
	if #unassignedPlayers > 0 then
		queueAssignment(unassignedPlayers)
	end
end

--[[
	Initializes state for the given active experiment group.

	This sets up tracking for when the group should become inactive
	and be cleaned up.

	Returns whether this was a new group, or if it was already initialized.
]]
function initializeActiveGroupState(groupSnapshot: AvailableExperimentGroupSnapshot): boolean
	assert(currentAssignmentState, "Assignment has not been started")

	-- Only initialize group state once
	if currentAssignmentState.activeGroupStateById[groupSnapshot.id] then
		return false
	end

	-- Initialize group state
	currentAssignmentState.activeGroupStateById[groupSnapshot.id] = {
		group = groupSnapshot,
		playerSet = {},
	}

	-- Start timer until the group's experiment ends, to trigger reassignment
	if groupSnapshot.endsAt then
		local secondsUntilEnd = math.max(0, groupSnapshot.endsAt - DateTime.now().UnixTimestampMillis) / 1000
		local groupState = currentAssignmentState.activeGroupStateById[groupSnapshot.id]
		groupState.experimentEndTimer = task.delay(secondsUntilEnd + POST_EXPERIMENT_END_REASSIGNMENT_DELAY, function ()
			groupState.experimentEndTimer = nil
			Utilities.GBLog("Group", groupSnapshot.id, "experiment ended, reassigning members & clearing...")
			reassignTerminatedGroupMembers({ groupSnapshot.id })
			clearActiveGroupState(groupSnapshot.id, true)

			-- Stop assignment if this was the last available group remaining
			if not getDoAvailableExperimentsRemain() then
				Utilities.GBLog("No experiments remain, stopping assignment")
				disableAssignment()
			end
		end)
	end

	return true
end

--[[
	Clears active state for the specified experiment group.

	Called when the group has ended or has been terminated, or when experiment assignment
	is stopping.

	**Note:** Members assigned to the group must first be reassigned elsewhere,
	          unless `didQueueMemberReassignment` is `true`.
]]
function clearActiveGroupState(groupId: number, didQueueMemberReassignment: boolean?)
	if not currentAssignmentState then
		return
	end

	local groupState = currentAssignmentState.activeGroupStateById[groupId]
	if not groupState then
		return
	end

	-- Ensure members have been reassigned beforehand
	if not didQueueMemberReassignment then
		assert(next(groupState.playerSet) == nil, "Cannot clear active experiment group state while players are assigned to it")
		assert(Experiments.AssignedServerGroupId ~= groupId, "Cannot clear active experiment group state while server is assigned to it")
	end

	if groupState.experimentEndTimer then
		task.cancel(groupState.experimentEndTimer)
	end

	currentAssignmentState.activeGroupStateById[groupId] = nil

	Utilities.GBLog("Cleared active experiment group state:", groupId)
end

--[[
	Initializes state for the given active experiment group that hasn't been fetched yet.

	This is used for groups that were scheduled to start in the future, are now
	active, but haven't been received from the backend yet.

	If the group ends before being received, it will be cleared automatically.
]]
function initializeUnfetchedActiveGroupState(groupId: number, endTime: number?)
	assert(currentAssignmentState, "Assignment has not been started")

	-- Ensure we aren't tracking this group yet
	if currentAssignmentState.activeGroupStateById[groupId] then
		return
	end
	if currentAssignmentState.unfetchedActiveGroupStateById[groupId] then
		return
	end

	-- Initialize unfetched group state
	currentAssignmentState.unfetchedActiveGroupStateById[groupId] = {
		endTime = endTime,
		onFetched = Signal.new(),
	}

	-- Start timer until the group's experiment ends, to forget about it
	if endTime then
		local secondsUntilEnd = math.max(0, endTime - DateTime.now().UnixTimestampMillis) / 1000
		local unfetchedGroupState = currentAssignmentState.unfetchedActiveGroupStateById[groupId]
		unfetchedGroupState.experimentEndTimer = task.delay(secondsUntilEnd, function ()
			unfetchedGroupState.experimentEndTimer = nil
			Utilities.GBLog("Unfetched group", groupId, "experiment ended, clearing")
			clearUnfetchedActiveGroupState(groupId)

			-- Stop assignment if this was the last available group remaining
			if not getDoAvailableExperimentsRemain() then
				Utilities.GBLog("No experiments remain, stopping assignment")
				disableAssignment()
			end
		end)
	end

	Utilities.GBLog("Initialized state for unfetched active experiment group", groupId, "until", endTime)
end

--[[
	Clears active state for the specified unfetched experiment group.

	Called either when the group has been received from the backend,
	or when it has ended or been terminated beforehand.
]]
function clearUnfetchedActiveGroupState(groupId: number, shouldFireFetchedSignal: boolean?)
	if not currentAssignmentState then
		return
	end

	local unfetchedGroupState = currentAssignmentState.unfetchedActiveGroupStateById[groupId]
	if not unfetchedGroupState then
		return
	end

	if unfetchedGroupState.experimentEndTimer then
		task.cancel(unfetchedGroupState.experimentEndTimer)
	end

	if shouldFireFetchedSignal then
		unfetchedGroupState.onFetched:Fire()
		unfetchedGroupState.onFetched:Destroy()
	end

	currentAssignmentState.unfetchedActiveGroupStateById[groupId] = nil

	Utilities.GBLog("Cleared unfetched active experiment group state:", groupId)
end

--[[
	Identifies players who are not assigned to any experiment group (i.e. they weren't
	eligible for any available experiments at assignment time), and queues them for
	assignment.

	This is called when new experiment groups become available (e.g. when new snapshots
	include a new group, or when a scheduled group begins)
]]
function queueAssignmentForNonAssignedPlayers()
	if not currentAssignmentState then
		return
	end

	local nonAssignedPlayers: {Player} = {}
	for _, player in Players:GetPlayers() do
		if not Experiments.AssignedGroupIdByPlayer[player] then
			table.insert(nonAssignedPlayers, player)
		end
	end

	if #nonAssignedPlayers > 0 then
		Utilities.GBLog("New experiment groups available, queueing assignment for non-assigned players", nonAssignedPlayers)
		queueAssignment(nonAssignedPlayers)
	end
end

--[[
	Queues fetching the latest available experiments snapshot from the backend
	proactively (to get the latest full set of available experiments, including
	ones that may have just started after having been scheduled).

	This can trigger enabling assignment, or if already enabled, can trigger
	reassignment for non-assigned players.

	TODO: Consider only firing this on the host server, and propagating the
	      fetched snapshot to other servers through a GB request.
]]
function queueAvailableExperimentsSnapshotUpdate()
	if deferredSnapshotFetchTimerThread then
		return
	end

	deferredSnapshotFetchTimerThread = task.delay(1, function ()
		deferredSnapshotFetchTimerThread = nil

		local didSucceed, response = GBRequests:GBRequestAsync("v1/experiments")
		if not didSucceed then
			Utilities.GBWarn("Failed to fetch available experiments snapshot:", response)
			return
		end

		Experiments:UpdateStateFromAvailableExperiments(response)
	end)
end

--[[
	Retrieves and returns metadata needed for assigning the given players,
	or the gameserver, based on the current experiment target type, and
	the properties required by known, active experiment groups.

	@canyield
]]
function getMetadataForAssignment(playerIds: {number}?, timeout: number?): ({[string]: any}?, {[string]: {[string]: any}}?)
	local snapshot = lastAvailableExperimentsSnapshot
	if not (snapshot and snapshot.targetType and snapshot.requiredProperties) then
		return nil, nil
	end

	local serverProperties: {[string]: any} = {}
	local playerPropertiesByIdString: {[string]: {[string]: any}} = {}

	local metadataRetrievalCallbacks: {() -> ()} = {}

	if snapshot.targetType == "gameserver" then
		for _, property in snapshot.requiredProperties do
			if not SERVER_PROPERTY_GETTERS[property] then
				continue
			end
			table.insert(metadataRetrievalCallbacks, function ()
				serverProperties[property] = SERVER_PROPERTY_GETTERS[property]()
			end)
		end

	elseif snapshot.targetType == "player" and playerIds then
		for _, playerId in playerIds do
			local player = Players:GetPlayerByUserId(playerId)
			if not player then
				continue
			end

			local playerIdString = tostring(playerId)
			playerPropertiesByIdString[playerIdString] = {}
			local playerProperties = playerPropertiesByIdString[playerIdString]

			-- Call each property getter in parallel to populate player metadata
			for _, property in snapshot.requiredProperties do
				if PLAYER_PROPERTY_GETTERS[property] then
					table.insert(metadataRetrievalCallbacks, function ()
						playerProperties[property] = PLAYER_PROPERTY_GETTERS[property](player)
					end)
				end
			end
		end
	end

	-- Yield until all population callbacks finish, or max duration is reached
	if timeout then
		Utilities.waitForAnyCall({
			function ()
				Utilities.waitForAllCalls(metadataRetrievalCallbacks)
			end,
			function ()
				task.wait(timeout)
			end,
		})
	else
		Utilities.waitForAllCalls(metadataRetrievalCallbacks)
	end

	-- Remove empty player property containers (to avoid having them incorrectly serialized as arrays)
	for playerIdString, playerProperties in playerPropertiesByIdString do
		if next(playerProperties) == nil then
			playerPropertiesByIdString[playerIdString] = nil
		end
	end

	-- Return appropriate properties containers if they aren't empty
	if snapshot.targetType == "gameserver" and next(serverProperties) then
		return serverProperties, nil
	elseif snapshot.targetType == "player" and next(playerPropertiesByIdString) then
		return nil, playerPropertiesByIdString
	else
		return nil, nil
	end
end

return Experiments