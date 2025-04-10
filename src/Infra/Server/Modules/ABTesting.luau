--!strict
local ABTesting = {}

-- Services
local Players = game:GetService("Players")

-- Dependencies
local GBRequests = shared.GBMod("GBRequests")
local Signal = shared.GBMod("Signal")
local Utilities = shared.GBMod("Utilities")

-- Types
type ConfigSnapshot = {
	options: {
		privacy: {{string}},
	},
	variables: {
		[string]: any,
	},
}
type AvailableCampaignPartitionSnapshot = {
	id: number,
	endsAt: number?,
	configs: ConfigSnapshot,
}
type AvailableCampaignsSnapshot = {
	timestampMs: number,
	partitions: {AvailableCampaignPartitionSnapshot},
	scheduled: {[string]: {number}},
}
type CampaignReassignmentPropagationRequest = {
	playerIds: {number},
	gameserverIds: {string},
}

--[[
	How long to wait before requesting bulk assignment after calling `queueAssignment()`.
]]
local BULK_ASSIGNMENT_SECONDS_TO_DEFER = 1

--[[
	How many seconds to wait before triggering reassignment for partitions that have ended.
]]
local POST_CAMPAIGN_END_REASSIGNMENT_DELAY = 0

--[[
	Whether the application has any available campaigns to request assignments for,
	and has begun requesting them.
]]
local currentAssignmentState: {
	playerIdsPendingAssignment: {[number]: true},
	playerJoinListener: RBXScriptConnection,
	playerLeaveListener: RBXScriptConnection,
	deferredBulkAssignmentThread: thread?,
	activePartitionStateById: {[number]: {
		partition: AvailableCampaignPartitionSnapshot,
		playerSet: {[Player]: true},
		campaignEndTimer: thread?,
	}},

	--[[
		State for partitions we know are active, but haven't received yet from snapshots or
		assignment responses (i.e. if a future-scheduled partition has started).

		This is initialized by `initializeUnfetchedActivePartitionState()` when a
		scheduled partition starts.

		Once a partition is received, or if it ends before being received, it is removed
		from this map when `clearUnfetchedActivePartitionState()` is called.
	]]
	unfetchedActivePartitionStateById: {[number]: {
		endTime: number?,
		campaignEndTimer: thread?,
	}},

}? = nil

local lastAvailableCampaignsSnapshot = nil :: AvailableCampaignsSnapshot?

--[[
	Map of partition IDs scheduled to start in the future, and their corresponding
	timer thread for triggering assignment when they start.

	These are created and terminated early based on received snapshots.
]]
local assignmentWakeUpTimersByFuturePartitionId = {} :: {[number]: thread}

ABTesting.AssignedServerPartitionId = nil :: number?
ABTesting.AssignedPartitionIdByPlayer = {} :: {[Player]: number?}
ABTesting.OnServerPartitionIdChanged = Signal.new()
ABTesting.OnPlayerPartitionIdChanged = Signal.new()

ABTesting.AssignedServerConfig = nil :: ConfigSnapshot?
ABTesting.AssignedConfigByPlayer = {} :: {[Player]: ConfigSnapshot}
ABTesting.OnAssignedServerConfigChanged = Signal.new()
ABTesting.OnAssignedPlayerConfigChanged = Signal.new()

ABTesting.CanonicalServerConfig = nil :: ConfigSnapshot?

--[[
	Updates whether assignments are being requested or not, based on the given
	snapshots of available campaigns received from the backend.

	If assignment is triggered on, this will yield as it requests and waits for
	the initial assignments to be received from the backend.
]]
function ABTesting:UpdateStateFromAvailableCampaigns(
	availableCampaignsSnapshot: AvailableCampaignsSnapshot,
	canonicalServerConfig: ConfigSnapshot?
)
	if canonicalServerConfig then
		ABTesting.CanonicalServerConfig = canonicalServerConfig
	end

	-- Ignore older snapshots (e.g. from old config change jobs, which take longer to propagate to gameservers)
	if lastAvailableCampaignsSnapshot and (lastAvailableCampaignsSnapshot.timestampMs >= availableCampaignsSnapshot.timestampMs) then
		return
	end
	lastAvailableCampaignsSnapshot = availableCampaignsSnapshot

	-- Start requesting assignment if there are any available campaigns
	local availablePartitions = availableCampaignsSnapshot.partitions
	local wasAssignmentAlreadyEnabled = (currentAssignmentState ~= nil)
	if #availablePartitions > 0 and not currentAssignmentState then
		enableAssignment()
	elseif #availablePartitions == 0 and currentAssignmentState then
		disableAssignment()
	end

	-- If assignment is enabled, apply changes from the snapshot to its state
	if currentAssignmentState then

		-- Cache received partition configs
		local snapshotPartitionIdSet = {} :: {[number]: true}
		for _, partition in availablePartitions do
			snapshotPartitionIdSet[partition.id] = true
			initializeActivePartitionState(partition)
			clearUnfetchedActivePartitionState(partition.id)
		end

		-- If snapshot just enabled assignment, trigger and wait for initial assignment
		if not wasAssignmentAlreadyEnabled then
			executeAssignmentRequest()

		-- If snapshot didn't just enable assignment, update partition state based on it
		else
			-- Clear terminated unfetched partitions
			for partitionId in currentAssignmentState.unfetchedActivePartitionStateById do
				if not snapshotPartitionIdSet[partitionId] then
					Utilities.GBLog("Unfetched partition terminated:", partitionId)
					clearUnfetchedActivePartitionState(partitionId)
				end
			end

			-- Clear local assignments for campaigns that have been terminated
			local terminatedPartitionIds: {number} = {}
			if ABTesting.AssignedServerPartitionId and not snapshotPartitionIdSet[ABTesting.AssignedServerPartitionId] then
				table.insert(terminatedPartitionIds, ABTesting.AssignedServerPartitionId)
			end
			for partitionId in currentAssignmentState.activePartitionStateById do
				if not snapshotPartitionIdSet[partitionId] then
					table.insert(terminatedPartitionIds, partitionId)
				end
			end
			if #terminatedPartitionIds > 0 then
				Utilities.GBLog("Clearing terminated partitions:", terminatedPartitionIds)
				reassignTerminatedPartitionMembers(terminatedPartitionIds)
				for _, partitionId in terminatedPartitionIds do
					clearActivePartitionState(partitionId, true)
				end
			end
		end
	end

	-- Schedule assignment wake-up timers for future campaigns
	for partitionIdKey, timestamps in availableCampaignsSnapshot.scheduled do
		local partitionId = tonumber(partitionIdKey) :: number
		if assignmentWakeUpTimersByFuturePartitionId[partitionId] then
			continue
		end

		local startTimeMs = timestamps[1]
		local endTimeMs = timestamps[2] :: number?

		local secondsUntilStart = math.max(0, startTimeMs - DateTime.now().UnixTimestampMillis) / 1000
		Utilities.GBLog("Scheduling future partition wake-up timer:", partitionId, startTimeMs, "in", secondsUntilStart, "sec")
		assignmentWakeUpTimersByFuturePartitionId[partitionId] = task.delay(secondsUntilStart, function ()
			assignmentWakeUpTimersByFuturePartitionId[partitionId] = nil

			if not currentAssignmentState then
				Utilities.GBLog("Future partition", partitionId, "started, enabling assignment")
				enableAssignment()
			else
				Utilities.GBLog("Future partition", partitionId, "started, assignment already enabled")
			end
			if currentAssignmentState then
				initializeUnfetchedActivePartitionState(partitionId, endTimeMs)
			end
		end)
	end
	for partitionId, timer in assignmentWakeUpTimersByFuturePartitionId do
		local partitionIdKey = tostring(partitionId)
		if not availableCampaignsSnapshot.scheduled[partitionIdKey] then
			Utilities.GBLog("Future partition", partitionId, "terminated, cancelling timer")
			task.cancel(timer)
			assignmentWakeUpTimersByFuturePartitionId[partitionId] = nil
		end
	end
end

--[[
	Processes a request from the backend to trigger requesting assignments for
	specific players and servers.
]]
function ABTesting:ProcessCampaignReassignmentRequest(request: CampaignReassignmentPropagationRequest)
	local currentGameserverId = if game.JobId == ""
		then "00000000-0000-0000-0000-000000000000"
		else game.JobId

	-- If this gameserver is included in the request, queue reassignment
	if table.find(request.gameserverIds, currentGameserverId) then
		Utilities.GBLog("Queueing reassignment as requested for server...")
		queueAssignment(Players:GetPlayers())
	end

	-- If players in the server are included in the request, queue them for reassignment
	for _, playerId in request.playerIds do
		local player = Players:GetPlayerByUserId(playerId)
		if player then
			Utilities.GBLog("Queueing reassignment as requested for player:", player.Name)
			queueAssignment({ player })
		end
	end
end

--[[
	Starts requesting campaign assignments for players and the server.

	Called when the game receives GB configs and becomes aware of available
	campaigns to enroll in.
]]
function enableAssignment()
	if currentAssignmentState then
		return
	end

	-- Start assignment & initialize state
	currentAssignmentState = {
		playerIdsPendingAssignment = {},
		playerJoinListener = Players.PlayerAdded:Connect(function (player)
			if not ABTesting.AssignedServerPartitionId then
				queueAssignment({ player })
			end
		end),
		playerLeaveListener = Players.PlayerRemoving:Connect(function (player)
			task.defer(function ()
				setAssignedPlayerPartitionId(player, nil)
			end)
		end),
		deferredBulkAssignmentThread = nil,
		activePartitionStateById = {},
		unfetchedActivePartitionStateById = {},
	}

	Utilities.GBLog("Started requesting campaign assignment")
	
	-- Request initial assignment
	Utilities.GBLog("Queuing initial assignment...")
	queueAssignment(Players:GetPlayers())
end

--[[
	Stops requesting campaign assignments for players and the server.

	Called when the game receives an updated available campaigns snapshot
	and becomes aware that there are no longer any available campaigns.
]]
function disableAssignment()
	if not currentAssignmentState then
		return
	end

	-- Clear current assignments
	setAssignedServerPartitionId(nil)
	for player in ABTesting.AssignedPartitionIdByPlayer do
		setAssignedPlayerPartitionId(player, nil)
	end

	-- Clear all active partition state
	for partitionId in currentAssignmentState.activePartitionStateById do
		clearActivePartitionState(partitionId)
	end
	for partitionId in currentAssignmentState.unfetchedActivePartitionStateById do
		clearUnfetchedActivePartitionState(partitionId)
	end

	currentAssignmentState.playerJoinListener:Disconnect()
	currentAssignmentState.playerLeaveListener:Disconnect()

	if currentAssignmentState.deferredBulkAssignmentThread then
		task.cancel(currentAssignmentState.deferredBulkAssignmentThread)
	end

	currentAssignmentState = nil

	Utilities.GBLog("Stopped requesting campaign assignment")
end

--[[
	Queues players to be assigned to campaigns in bulk.
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

	-- Build list of known partitions that backend shouldn't include in response
	local knownPartitionIds: {number} = {}
	for partitionId in assignmentState.activePartitionStateById do
		table.insert(knownPartitionIds, partitionId)
	end

	Utilities.GBLog(`Requesting assignment (playerIds: {table.concat(playerIds, ", ")})...`)
	local didSucceed, response = GBRequests:GBRequestAsync("v1/experiments/assignments", {
		playerIds = playerIds,
		knownPartitionIds = knownPartitionIds,
		allowGameserverAssignment = true,
	})
	if currentAssignmentState ~= assignmentState then
		return
	end

	-- Requeue requested players if assignment request failed
	Utilities.GBLog("Received assignment response:", didSucceed, response)
	if not didSucceed then
		Utilities.GBWarn("Failed to get campaign assignment:", response)

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

	-- If no campaigns are available for assignment, disable assignment
	if not response then
		disableAssignment()
		return
	end

	-- Cache new received partition snapshots
	if response.partitions then
		for _, partition in response.partitions do
			initializeActivePartitionState(partition)
			clearUnfetchedActivePartitionState(partition.id)
		end
	end

	if response.gameserverPartitionId then
		setAssignedServerPartitionId(response.gameserverPartitionId)

		-- Clear previous per-player assignments, if any
		for player in ABTesting.AssignedPartitionIdByPlayer do
			setAssignedPlayerPartitionId(player, nil)
		end

	elseif response.playerIdsByPartitionId then
		for partitionIdString: string, partitionPlayerIds in response.playerIdsByPartitionId do
			local partitionId = tonumber(partitionIdString) :: number
			for _, playerId in partitionPlayerIds do
				local player = Players:GetPlayerByUserId(playerId)
				if player then
					setAssignedPlayerPartitionId(player, partitionId)
				end
			end
		end

		-- Clear previous per-server assignment, if any
		setAssignedServerPartitionId(nil)
	end
end

function setAssignedPlayerPartitionId(player: Player, partitionId: number?)
	assert(currentAssignmentState, "Assignment has not been started")
	assert(partitionId == nil or currentAssignmentState.activePartitionStateById[partitionId], "Partition state has not been initialized")

	Utilities.GBLog("Setting assigned partition ID for player:", player.UserId, partitionId)

	local previousPartitionId = ABTesting.AssignedPartitionIdByPlayer[player]
	if previousPartitionId == partitionId then
		Utilities.GBLog("Skipping setting assigned partition ID for player:", player.UserId, `(unchanged {partitionId} -> {previousPartitionId})`)
		return
	end

	-- Clear from currently assigned partition, if any
	local previousPartitionState = previousPartitionId and currentAssignmentState.activePartitionStateById[previousPartitionId]
	if previousPartitionState then
		Utilities.GBLog("Clearing player from previous partition state:", player.UserId, previousPartitionId)
		previousPartitionState.playerSet[player] = nil
	end

	ABTesting.AssignedPartitionIdByPlayer[player] = partitionId
	ABTesting.OnPlayerPartitionIdChanged:Fire(player, partitionId)

	if partitionId then
		local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
		ABTesting.AssignedConfigByPlayer[player] = partitionState.partition.configs
		ABTesting.OnAssignedPlayerConfigChanged:Fire(player, partitionState.partition.configs)
		currentAssignmentState.activePartitionStateById[partitionId].playerSet[player] = true

	-- If unassigning from a partition, clear the assigned config
	else
		ABTesting.AssignedConfigByPlayer[player] = nil
		ABTesting.OnAssignedPlayerConfigChanged:Fire(player, nil)
	end
end

function setAssignedServerPartitionId(partitionId: number?)
	assert(currentAssignmentState, "Assignment has not been started")
	assert(partitionId == nil or currentAssignmentState.activePartitionStateById[partitionId], "Partition state has not been initialized")

	local previousPartitionId = ABTesting.AssignedServerPartitionId
	if previousPartitionId == partitionId then
		return
	end

	ABTesting.AssignedServerPartitionId = partitionId
	ABTesting.OnServerPartitionIdChanged:Fire(partitionId)

	if partitionId then
		local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
		ABTesting.AssignedServerConfig = partitionState.partition.configs
		ABTesting.OnAssignedServerConfigChanged:Fire(partitionState.partition.configs)

	else
		ABTesting.AssignedServerConfig = nil
		ABTesting.OnAssignedServerConfigChanged:Fire(nil)
	end
end

function getDoAvailableCampaignsRemain(excludedPartitionIdList: {number}?): boolean
	if not currentAssignmentState then
		return false
	end

	local excludedPartitionIdSet = {} :: {[number]: true?}
	if excludedPartitionIdList then
		for _, partitionId in excludedPartitionIdList do
			excludedPartitionIdSet[partitionId] = true
		end
	end

	for partitionId, state in currentAssignmentState.activePartitionStateById do
		if excludedPartitionIdSet[partitionId] then
			continue
		end

		-- Skip active partitions that may have just ended
		if state.partition.endsAt and DateTime.now().UnixTimestampMillis >= state.partition.endsAt then
			continue
		end

		return true
	end

	for partitionId, state in currentAssignmentState.unfetchedActivePartitionStateById do
		if excludedPartitionIdSet[partitionId] then
			continue
		end

		-- Skip unfetched partitions that may have just ended
		if state.endTime and DateTime.now().UnixTimestampMillis >= state.endTime then
			continue
		end

		return true
	end

	return false
end

--[[
	Queues reassignment for members of the given terminated partitions,
	if any available campaigns remain.
]]
function reassignTerminatedPartitionMembers(terminatedPartitionIds: {number})
	assert(currentAssignmentState, "Assignment has not been started")

	local unassignedPlayers: {Player} = {}
	local didUnassignServer = false

	-- Identify members in need of reassignment
	for _, partitionId in terminatedPartitionIds do
		local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
		if partitionState then
			for player in partitionState.playerSet do
				Utilities.GBLog("Queuing reassignment for player from terminated partition:", partitionId, player.Name)
				table.insert(unassignedPlayers, player)
			end
		end

		if ABTesting.AssignedServerPartitionId == partitionId then
			Utilities.GBLog("Queuing reassignment for server from terminated partition:", partitionId)
			didUnassignServer = true
		end
	end

	-- Skip reassignment if no campaigns remain
	if not getDoAvailableCampaignsRemain(terminatedPartitionIds) then
		Utilities.GBLog("No campaigns available, skipping reassignment")
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
	Initializes state for the given active partition.

	This sets up tracking for when the partition should become inactive
	and be cleaned up.
]]
function initializeActivePartitionState(partitionSnapshot: AvailableCampaignPartitionSnapshot)
	assert(currentAssignmentState, "Assignment has not been started")

	-- Only initialize partition state once
	if currentAssignmentState.activePartitionStateById[partitionSnapshot.id] then
		return
	end

	-- Initialize partition state
	currentAssignmentState.activePartitionStateById[partitionSnapshot.id] = {
		partition = partitionSnapshot,
		playerSet = {},
	}

	-- Start timer until partition campaign ends, to trigger reassignment
	if partitionSnapshot.endsAt then
		local secondsUntilEnd = math.max(0, partitionSnapshot.endsAt - DateTime.now().UnixTimestampMillis) / 1000
		local partitionState = currentAssignmentState.activePartitionStateById[partitionSnapshot.id]
		partitionState.campaignEndTimer = task.delay(secondsUntilEnd + POST_CAMPAIGN_END_REASSIGNMENT_DELAY, function ()
			partitionState.campaignEndTimer = nil
			Utilities.GBLog("Partition", partitionSnapshot.id, "campaign ended, reassigning members & clearing...")
			reassignTerminatedPartitionMembers({ partitionSnapshot.id })
			clearActivePartitionState(partitionSnapshot.id, true)

			-- Stop assignment if this was the last available partition remaining
			if not getDoAvailableCampaignsRemain() then
				Utilities.GBLog("No campaigns remain, stopping assignment")
				disableAssignment()
			end
		end)
	end
end

--[[
	Clears active state for the specified partition.
	
	Called when the partition has ended or has been terminated, or when campaign assignment
	is stopping.

	**Note:** Members assigned to the partition must first be reassigned elsewhere,
	          unless `didQueueMemberReassignment` is `true`.
]]
function clearActivePartitionState(partitionId: number, didQueueMemberReassignment: boolean?)
	if not currentAssignmentState then
		return
	end

	local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
	if not partitionState then
		return
	end

	-- Ensure members have been reassigned beforehand
	if not didQueueMemberReassignment then
		assert(next(partitionState.playerSet) == nil, "Cannot clear active partition state while players are assigned to it")
		assert(ABTesting.AssignedServerPartitionId ~= partitionId, "Cannot clear active partition state while server is assigned to it")
	end

	if partitionState.campaignEndTimer then
		task.cancel(partitionState.campaignEndTimer)
	end

	currentAssignmentState.activePartitionStateById[partitionId] = nil

	Utilities.GBLog("Cleared active partition state:", partitionId)
end

--[[
	Initializes state for the given active partition that hasn't been fetched yet.

	This is used for partitions that were scheduled to start in the future, are now
	active, but haven't been received from the backend yet.

	If the partition ends before being received, it will be cleared automatically.
]]
function initializeUnfetchedActivePartitionState(partitionId: number, endTime: number?)
	assert(currentAssignmentState, "Assignment has not been started")

	-- Ensure we aren't tracking this partition yet
	if currentAssignmentState.activePartitionStateById[partitionId] then
		return
	end
	if currentAssignmentState.unfetchedActivePartitionStateById[partitionId] then
		return
	end

	-- Initialize unfetched partition state
	currentAssignmentState.unfetchedActivePartitionStateById[partitionId] = {
		endTime = endTime,
	}

	-- Start timer until partition campaign ends, to forget about it
	if endTime then
		local secondsUntilEnd = math.max(0, endTime - DateTime.now().UnixTimestampMillis) / 1000
		local unfetchedPartitionState = currentAssignmentState.unfetchedActivePartitionStateById[partitionId]
		unfetchedPartitionState.campaignEndTimer = task.delay(secondsUntilEnd, function ()
			unfetchedPartitionState.campaignEndTimer = nil
			Utilities.GBLog("Unfetched partition", partitionId, "campaign ended, clearing")
			clearUnfetchedActivePartitionState(partitionId)

			-- Stop assignment if this was the last available partition remaining
			if not getDoAvailableCampaignsRemain() then
				Utilities.GBLog("No campaigns remain, stopping assignment")
				disableAssignment()
			end
		end)
	end

	Utilities.GBLog("Initialized state for unfetched active partition", partitionId, "until", endTime)
end

--[[
	Clears active state for the specified unfetched partition.

	Called either when the partition has been received from the backend,
	or when it has ended or been terminated beforehand.
]]
function clearUnfetchedActivePartitionState(partitionId: number)
	if not currentAssignmentState then
		return
	end

	local unfetchedPartitionState = currentAssignmentState.unfetchedActivePartitionStateById[partitionId]
	if not unfetchedPartitionState then
		return
	end

	if unfetchedPartitionState.campaignEndTimer then
		task.cancel(unfetchedPartitionState.campaignEndTimer)
	end

	currentAssignmentState.unfetchedActivePartitionStateById[partitionId] = nil

	Utilities.GBLog("Cleared unfetched active partition state:", partitionId)
end

return ABTesting