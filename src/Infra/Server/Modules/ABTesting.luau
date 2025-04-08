----!strict
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
	scheduled: {[string]: number},
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
		playerSet: {[Player]: true},
		campaignEndTimer: thread?,
	}},

	--[[
		Set of partitions we are aware are active, but have not received yet (e.g. if a campaign
		was scheduled to start in the future).

		Once a partition is received, it is removed from this set.
	]]
	unfetchedActivePartitionIdSet: {[number]: true},

}? = nil

local lastAvailableCampaignsSnapshot = nil :: AvailableCampaignsSnapshot?

--[[
	Cache of partitions that have been received from the backend (from available
	campaign snapshots, and assignment responses)
]]
local knownPartitions = {} :: {[number]: AvailableCampaignPartitionSnapshot}

--[[
	Map of partition IDs scheduled to start in the future, and their corresponding
	timer thread for triggering assignment when they start.

	These are created and terminated early based on received snapshots.
]]
local assignmentWakeUpTimersByFuturePartitionId = {} :: {[number]: thread}

ABTesting.assignedServerPartitionId = nil :: number?
ABTesting.assignedPartitionIdByPlayer = {} :: {[Player]: number}
ABTesting.onServerPartitionIdChanged = Signal.new()
ABTesting.onPlayerPartitionIdChanged = Signal.new()

ABTesting.assignedServerConfig = nil :: ConfigSnapshot?
ABTesting.assignedConfigByPlayer = {} :: {[Player]: ConfigSnapshot}
ABTesting.onAssignedServerConfigChanged = Signal.new()
ABTesting.onAssignedPlayerConfigChanged = Signal.new()

ABTesting.canonicalServerConfig = nil :: ConfigSnapshot?

--[[
	Updates whether assignments are being requested or not, based on the given
	snapshots of available campaigns received from the backend.

	If assignment is triggered on, this will yield as it requests and waits for
	the initial assignments to be received from the backend.
]]
function ABTesting:updateStateFromAvailableCampaigns(
	availableCampaignsSnapshot: AvailableCampaignsSnapshot,
	canonicalServerConfig: ConfigSnapshot?
)
	if canonicalServerConfig then
		ABTesting.canonicalServerConfig = canonicalServerConfig
	end

	-- Ignore older snapshots (e.g. from config change jobs, which take longer to propagate to gameservers)
	if lastAvailableCampaignsSnapshot and (lastAvailableCampaignsSnapshot.timestampMs >= availableCampaignsSnapshot.timestampMs) then
		return
	end
	lastAvailableCampaignsSnapshot = availableCampaignsSnapshot

	-- Cache partition configs
	local availablePartitions = availableCampaignsSnapshot.partitions
	local snapshotPartitionIdSet = {} :: {[number]: true}
	for _, partition in availablePartitions do
		knownPartitions[partition.id] = partition
		snapshotPartitionIdSet[partition.id] = true

		-- If partition was considered unfetched (e.g. from having been scheduled for the future), remove it from the set
		if currentAssignmentState and currentAssignmentState.unfetchedActivePartitionIdSet[partition.id] then
			currentAssignmentState.unfetchedActivePartitionIdSet[partition.id] = nil
			Utilities.GBLog("Unfetched partition received, removed from set:", partition.id)
		end
	end

	-- Clear local assignments for campaigns that have been terminated
	if currentAssignmentState then
		local terminatedPartitionIds: {number} = {}
		if ABTesting.assignedServerPartitionId and not snapshotPartitionIdSet[ABTesting.assignedServerPartitionId] then
			table.insert(terminatedPartitionIds, ABTesting.assignedServerPartitionId)
		end
		for partitionId in currentAssignmentState.activePartitionStateById do
			if not snapshotPartitionIdSet[partitionId] then
				table.insert(terminatedPartitionIds, partitionId)
			end
		end
		Utilities.GBLog("Terminated partitions:", terminatedPartitionIds)
		if #terminatedPartitionIds > 0 then
			clearTerminatedPartitionAssignments(terminatedPartitionIds)
		end

		-- Clear terminated unfetched partitions
		for partitionId in currentAssignmentState.unfetchedActivePartitionIdSet do
			if not snapshotPartitionIdSet[partitionId] then
				Utilities.GBLog("Unfetched partition terminated:", partitionId)
				currentAssignmentState.unfetchedActivePartitionIdSet[partitionId] = nil
			end
		end
	end

	-- Schedule assignment wake-up timers for future campaigns
	for partitionIdKey, startTimeMs in availableCampaignsSnapshot.scheduled do
		local partitionId = tonumber(partitionIdKey) :: number
		if assignmentWakeUpTimersByFuturePartitionId[partitionId] then
			continue
		end

		local secondsUntilStart = math.max(0, startTimeMs - DateTime.now().UnixTimestampMillis) / 1000
		Utilities.GBLog("Scheduling future partition wake-up timer:", partitionId, startTimeMs, "in", secondsUntilStart, "sec")
		assignmentWakeUpTimersByFuturePartitionId[partitionId] = task.delay(secondsUntilStart, function ()
			assignmentWakeUpTimersByFuturePartitionId[partitionId] = nil

			if not currentAssignmentState then
				Utilities.GBLog("Future partition", partitionId, "started, enabling assignment")
				startRequestingAssignment()
			else
				Utilities.GBLog("Future partition", partitionId, "started, assignment already enabled")
				if not currentAssignmentState.unfetchedActivePartitionIdSet[partitionId] then
					currentAssignmentState.unfetchedActivePartitionIdSet[partitionId] = true
				end
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

	-- Start requesting assignment if there are any available campaigns
	if #availablePartitions > 0 and not currentAssignmentState then
		startRequestingAssignment()
	elseif #availablePartitions == 0 and currentAssignmentState then
		stopRequestingAssignment()
	end
end

--[[
	Processes a request from the backend to trigger requesting assignments for
	specific players and servers.
]]
function ABTesting:processCampaignReassignmentRequest(request: CampaignReassignmentPropagationRequest)
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
function startRequestingAssignment()
	if currentAssignmentState then
		return
	end

	-- Start assignment & initialize state
	currentAssignmentState = {
		playerIdsPendingAssignment = {},
		playerJoinListener = Players.PlayerAdded:Connect(function (player)
			if not ABTesting.assignedServerPartitionId then
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
		unfetchedActivePartitionIdSet = {},
	}

	Utilities.GBLog("Started requesting campaign assignment")
	
	-- Request initial assignment
	Utilities.GBLog("Requesting initial assignment...")
	queueAssignment(Players:GetPlayers())
	executeAssignmentRequest()
end

--[[
	Stops requesting campaign assignments for players and the server.

	Called when the game receives an updated available campaigns snapshot
	and becomes aware that there are no longer any available campaigns.
]]
function stopRequestingAssignment()
	if not currentAssignmentState then
		return
	end

	-- Clear current assignments
	setAssignedServerPartitionId(nil)
	for player in ABTesting.assignedPartitionIdByPlayer do
		setAssignedPlayerPartitionId(player, nil)
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
	for partitionId in knownPartitions do
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
		stopRequestingAssignment()
		return
	end

	-- Cache new received partition snapshots
	if response.partitions then
		for _, partition in response.partitions do
			knownPartitions[partition.id] = partition
			assignmentState.unfetchedActivePartitionIdSet[partition.id] = nil
		end
	end

	if response.gameserverPartitionId then
		setAssignedServerPartitionId(response.gameserverPartitionId)

		-- Clear previous per-player assignments, if any
		for player in ABTesting.assignedPartitionIdByPlayer do
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

	local previousPartitionId = ABTesting.assignedPartitionIdByPlayer[player]
	if previousPartitionId == partitionId then
		return
	end

	-- Clear from currently assigned partition, if any
	local previousPartitionState = previousPartitionId and currentAssignmentState.activePartitionStateById[previousPartitionId]
	if previousPartitionState then
		previousPartitionState.playerSet[player] = nil

		-- If no players left in partition, clean up its state
		if next(previousPartitionState.playerSet) == nil then
			if previousPartitionState.campaignEndTimer then
				task.cancel(previousPartitionState.campaignEndTimer)
			end
			currentAssignmentState.activePartitionStateById[previousPartitionId] = nil
		end
	end

	ABTesting.assignedPartitionIdByPlayer[player] = partitionId
	ABTesting.onPlayerPartitionIdChanged:Fire(player, partitionId)

	if partitionId then
		local partition = knownPartitions[partitionId]
		ABTesting.assignedConfigByPlayer[player] = partition.configs
		ABTesting.onAssignedPlayerConfigChanged:Fire(player, partition.configs)

		if currentAssignmentState.activePartitionStateById[partitionId] then
			currentAssignmentState.activePartitionStateById[partitionId].playerSet[player] = true

		-- If assigning to new partition, initialize the partition's state
		else
			currentAssignmentState.activePartitionStateById[partitionId] = {
				playerSet = {
					[player] = true,
				},
			}

			-- Start timer until partition campaign ends, to trigger reassignment
			if partition.endsAt then
				local secondsUntilEnd = math.max(0, partition.endsAt - DateTime.now().UnixTimestampMillis) / 1000
				local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
				partitionState.campaignEndTimer = task.delay(secondsUntilEnd + POST_CAMPAIGN_END_REASSIGNMENT_DELAY, function ()
					partitionState.campaignEndTimer = nil
					clearTerminatedPartitionAssignments({ partitionId })
				end)
			end
		end

	-- If unassigning from a partition, clear the assigned config
	else
		ABTesting.assignedConfigByPlayer[player] = nil
		ABTesting.onAssignedPlayerConfigChanged:Fire(player, nil)
	end
end

function setAssignedServerPartitionId(partitionId: number?)
	assert(currentAssignmentState, "Assignment has not been started")

	local previousPartitionId = ABTesting.assignedServerPartitionId
	if previousPartitionId == partitionId then
		return
	end

	-- Clean up previously assigned partition state
	local previousPartitionState = previousPartitionId and currentAssignmentState.activePartitionStateById[previousPartitionId]
	if previousPartitionState then
		if previousPartitionState.campaignEndTimer then
			task.cancel(previousPartitionState.campaignEndTimer)
		end
		currentAssignmentState.activePartitionStateById[previousPartitionId] = nil
	end

	ABTesting.assignedServerPartitionId = partitionId
	ABTesting.onServerPartitionIdChanged:Fire(partitionId)

	if partitionId then
		local partition = knownPartitions[partitionId]
		ABTesting.assignedServerConfig = partition.configs
		ABTesting.onAssignedServerConfigChanged:Fire(partition.configs)

		currentAssignmentState.activePartitionStateById[partitionId] = {
			playerSet = {},
		}

		-- Start timer until partition campaign ends, to trigger reassignment
		if partition.endsAt then
			local secondsUntilEnd = math.max(0, partition.endsAt - DateTime.now().UnixTimestampMillis) / 1000
			local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
			partitionState.campaignEndTimer = task.delay(secondsUntilEnd + POST_CAMPAIGN_END_REASSIGNMENT_DELAY, function ()
				partitionState.campaignEndTimer = nil
				clearTerminatedPartitionAssignments({ partitionId })
			end)
		end

	else
		ABTesting.assignedServerConfig = nil
		ABTesting.onAssignedServerConfigChanged:Fire(nil)
	end
end

function clearTerminatedPartitionAssignments(terminatedPartitionIds: {number})
	assert(currentAssignmentState, "Assignment has not been started")

	local unassignedPlayers: {Player} = {}
	local didUnassignServer = false

	-- Clear assignments to terminated partitions
	for _, partitionId in terminatedPartitionIds do
		local partitionState = currentAssignmentState.activePartitionStateById[partitionId]
		if partitionState then
			for player in partitionState.playerSet do
				Utilities.GBLog("Queuing reassignment for player from terminated partition:", partitionId, player.Name)
				table.insert(unassignedPlayers, player)
			end
		end

		if ABTesting.assignedServerPartitionId == partitionId then
			Utilities.GBLog("Queuing reassignment for server from terminated partition:", partitionId)
			didUnassignServer = true
		end
	end

	-- Skip reassignment if no campaigns remain
	local doCampaignsRemain = (lastAvailableCampaignsSnapshot and #lastAvailableCampaignsSnapshot.partitions > 0)
		or (next(currentAssignmentState.unfetchedActivePartitionIdSet) ~= nil)
	if not doCampaignsRemain then
		Utilities.GBLog("No campaigns available, skipping reassignment")
		if didUnassignServer then
			setAssignedServerPartitionId(nil)
		end
		for _, player in unassignedPlayers do
			setAssignedPlayerPartitionId(player, nil)
		end
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

return ABTesting