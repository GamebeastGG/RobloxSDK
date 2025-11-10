--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	EngagementMarkers.luau
	
	Description:
		Handles processing and sending engagement markers to the Gamebeast backend.
	
--]]

--= Root =--
local EngagementMarkers = { }

--= Roblox Services =--

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Timer = shared.GBMod("Timer") ---@module Timer
local Cleaner = shared.GBMod("Cleaner")
local Utilities = shared.GBMod("Utilities")
local HostServer = shared.GBMod("HostServer") ---@module HostServer
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local Experiments = shared.GBMod("InternalExperiments") ---@module InternalExperiments
local FailedMarkers = shared.GBMod("FailedMarkers") ---@module FailedMarkers
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local SignalConnection = shared.GBMod("SignalConnection") ---@module SignalConnection
local LocalizationCache = shared.GBMod("LocalizationCache") ---@module LocalizationCache
local LaunchDataResolver = shared.GBMod("LaunchDataResolver") ---@module LaunchDataResolver
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler

--= Types =--

--= Object References =--

--= Constants =--

local CLIENT_DATA_TIMEOUT = RunService:IsStudio() and 10 or 45
local MAX_EVENT_QUEUE_SIZE = 1000
local QUEUE_CHECK_TIME = 5
local MAX_EVENT_REPORT_TIME = 10
local ALLOWED_VALUE_TYPES = {
	["string"] = true,
	["number"] = true,
	["boolean"] = true,
	["table"] = true, -- Only dictionaries, not arrays
}
local DROP_MARKER_CODES = {
	["INVALID_MARKERS"] = true,
	["SUBSCRIPTION_LIMIT_EXCEEDED"] = true,
	["SUBSCRIPTION_UNPAID"] = true
}

--= Variables =--

local WaitingPlayerMarkers = {}
local MarkerQueue = {}
-- Map of unique session IDs for users for player-associated markers
local SessionIds = {}
local LastEventReportTime = 0
local ClientInfoWarned = false


--= Public Variables =--

--= Internal Functions =--

local function GetSessionIdForPlayer(player) : string?
	if SessionIds[player] == nil and player.Parent then
		SessionIds[player] = HttpService:GenerateGUID(false)
		ServerClientInfoHandler:UpdateClientData(player, "sessionId", SessionIds[player])
	end

	return SessionIds[player]
end

local function EncodeVector3(vec)
	local vectorArray = {vec.X, vec.Y, vec.Z}

	for i = 1, 3 do
		vectorArray[i] = Utilities.roundNum(vectorArray[i], 0.0001)
	end

	return vectorArray
end

local function isMarkerDataValid(markerData : {}) : boolean
	for _, value in markerData do
		local valueType = type(value)
		if ALLOWED_VALUE_TYPES[valueType] == nil then
			return false
		end

		if valueType == "table" and not isMarkerDataValid(value) then
			return false
		end
	end

	return true
end

local function AddMarker(marker)
	table.insert(MarkerQueue, marker)
	
	-- If marker queue size limit reached then send batch
	if #MarkerQueue >= MAX_EVENT_QUEUE_SIZE then
		EngagementMarkers:SendMarkers()
	end
end

--= API Functions =--

-- Send batch to GB
function EngagementMarkers:SendMarkers(queue : {any}?) : (boolean, {[string] : any}?)
	local isCustomQueue = queue ~= nil
	queue = queue or MarkerQueue
	if #queue > 0 then
		LastEventReportTime = tick()
		
		local data = {
			markers = queue
		}

		if not isCustomQueue then
			MarkerQueue = {}
		end
		
		local success, errorBody = GBRequests:GBRequestAsync("v1/markers", data)
		if not success then
			if errorBody and errorBody.errorCode and DROP_MARKER_CODES[errorBody.errorCode] then
				return false, errorBody -- Drop the markers if they were all rejected.
			end
			
			-- If request failed, add markers back to queue for retry
			local invalidMarkerCount = 0
			for _, marker in data.markers do
				if not isMarkerDataValid(marker) then
					invalidMarkerCount += 1
					continue
				end
				
				FailedMarkers:AddMarker(marker)
			end

			if invalidMarkerCount > 0 then
				Utilities.GBWarn(`{invalidMarkerCount} of the {#data.markers} sent are invalid and will not be retried.`)
			end

			Utilities.GBWarn("Failed to send engagement markers to Gamebeast. Markers will be retried later.")
		end
		return success, errorBody
	end

	return true
end

-- Core function, should be used internally by SDK rather than fireMarker
-- function EngagementMarkers:CreateMarker(source, markerType, player, position, value)
function EngagementMarkers:_createMarker(source : "server" | "client" | "sdk", markerType : string, value : any | {[string] : any}, metaData : {[string] : any})
	metaData = metaData or {}
	-- Validate all arguments.
	local usageStr
	
	if source == "server" then 
		usageStr = "Usage: FireMarker(MarkerType, Value (optional), Parameters (optional))"
	elseif source == "client" then
		usageStr = "Usage: FireMarker(MarkerType, Value (optional), Parameters (optional))"
	end
	
	if typeof(markerType) ~= "string" then
		Utilities.GBWarn("MarkerType argument should be a string.")
		return
	end

	local player = metaData.player
	local position = metaData.position
	
	if player ~= nil and not (player:IsA("Player") or typeof(player) == "number") then
		Utilities.GBWarn("Player argument for ".. source .." marker \"".. markerType.."\" should be a player instance, string/numeric identifier, or nil.\n".. usageStr)
		return
	end
	
	if position ~= nil and typeof(position) ~= "Vector3" then
		Utilities.GBWarn("Position argument for ".. source .." marker \"".. markerType.."\" should be Vector3 or nil.\n".. usageStr)
		return
	end
	
	local valueType = type(value)
	if valueType == "table" and #value > 0 then -- Array check
		Utilities.GBWarn("Value argument for ".. source .." marker \"".. markerType.."\" should not be an array. Use a dictionary instead.")
		return
	end

	if value ~= nil and ALLOWED_VALUE_TYPES[valueType] == nil then
		Utilities.GBWarn("Value argument for ".. source .." marker \"".. markerType.."\" be a primitive type or dictionary, got: ".. valueType)
  		return
	end

	if value ~= nil and valueType ~= "table" then
		value = { value = value } -- Wrap non-table values in a table
	end
	
	-- Interface allows for player instance or userId. We already validated args types, so just handle accordingly.
	local player = Utilities.resolvePlayerObject(player)
	
	-- Marker fields
	
	local entry = {
		["markerId"] = HttpService:GenerateGUID(false),
		["timestamp"] = metaData.timestampOverride or DateTime.now().UnixTimestampMillis,
		["type"] = markerType,
		["serverId"] = Utilities.getServerId(),
		["userId"] = player and player.UserId, 
		["sessionId"] = nil, -- Resolved later
		["value"] = value,
		["properties"] = {
			["sdkPlatform"] = "roblox",
			["placeId"] = game.PlaceId,
			["placeVersion"] = game.PlaceVersion,
			["origin"] = source,
			["device"] = nil, -- Resolved later
			["deviceSubType"] = nil, -- Resolved later
			["inputType"] = nil, -- Resolved later
			["deeplinkData"] = nil, -- Resolved later
			["position"] = position ~= nil and EncodeVector3(position) or nil,
			["language"] = player and LocalizationCache:GetLocaleId(player) or nil,
			["country"] = player and LocalizationCache:GetRegionId(player) or nil,
			["experimentGroupId"] = player
				and Experiments.AssignedGroupIdByPlayer[player]
				or Experiments.AssignedServerGroupId,
		},
	}

	--[[
		Ensure markers are sent with all required data.
	]]

	InternalConfigs:OnReady(function()
		if not player then -- Server marker
			AddMarker(entry)
			return
		end

		local pendingMarkerData = {
			pendingCleaner = Cleaner.new(),
			tasks = {},
			activeTasks = 0,
			resolved = nil,
		}

		local function resolved(shutdown : boolean?)
			pendingMarkerData.pendingCleaner:Clean()

			-- Add any final missing data to the marker
			entry.properties.device = ServerClientInfoHandler:GetClientInfo(player, "device")
			entry.properties.deviceSubType = ServerClientInfoHandler:GetClientInfo(player, "deviceSubType")
			entry.properties.inputType = ServerClientInfoHandler:GetClientInfo(player, "inputType")

			-- Attempt to resolve session ID from client info so we preserve it across game sessions.
			local sessionId = ServerClientInfoHandler:GetClientInfo(player, "sessionId")
			if sessionId and sessionId ~= "" then
				entry.sessionId = sessionId
				if player.Parent then
					SessionIds[player] = sessionId
				end
			else
				entry.sessionId = GetSessionIdForPlayer(player)
			end

			AddMarker(entry)

			-- Remove from waiting list if it exists
			if not shutdown then
				local index = table.find(WaitingPlayerMarkers, pendingMarkerData)
				if index then
					table.remove(WaitingPlayerMarkers, index)
				end
			end
		end

		pendingMarkerData.resolved = resolved

		-- Task manager

		-- Will only add tasks if they arent already finished and the connection is still active.
		local function addTask(taskName : string, connection : RBXScriptConnection?)
			if not pendingMarkerData.tasks[taskName] and connection ~= nil and connection.Connected == true then
				pendingMarkerData.activeTasks += 1
				pendingMarkerData.tasks[taskName] = connection

				if connection then
					pendingMarkerData.pendingCleaner:Add(connection)
				end
			end
		end

		local function completeTask(taskName : string)
			if pendingMarkerData.tasks[taskName] then
				pendingMarkerData.tasks[taskName] = nil
				pendingMarkerData.activeTasks -= 1

				if pendingMarkerData.activeTasks <= 0 then
					resolved()
				end
			end
		end

		-- Check for custom tasks
		if metaData.tasks then
			for taskName, taskFunction in metaData.tasks do
				local connection = SignalConnection.new(function()
					completeTask(taskName)
				end)

				addTask(taskName, connection)

				task.spawn(function()
					taskFunction(value)
					connection:Disconnect()
					completeTask(taskName)
				end)
			end
		end

		-- Stop wating after some time if tasks are not resolved
		local dataFetchTimer = Timer.new(CLIENT_DATA_TIMEOUT)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer:OnEnd(function()
			if not pendingMarkerData.tasks["clientInfo"] then
				return
			end

			if not ServerClientInfoHandler:IsClientInfoResolved(player) and ClientInfoWarned == false then
				Utilities.GBWarn("Failed to resolve client info, did you forget to :Setup() Gamebeast SDK on the client?")
				ClientInfoWarned = true
			end

			completeTask("clientInfo")
		end))

		-- Ensure marker gets fired with device info on timeout or bind to close
		addTask("clientInfo", ServerClientInfoHandler:OnClientInfoResolved(player, function()
			completeTask("clientInfo")
		end))

		-- Ensure we have launch data if available
		addTask("launchData", LaunchDataResolver:OnResolved(player, function(launchData)
			if launchData and launchData._gbDeeplink then
				entry.properties.deeplinkData = {
					["id"] = launchData._gbDeeplink.deeplinkId,
					["interactionId"] = launchData._gbDeeplink.interactionId
				}
			end

			completeTask("launchData")
		end))

		if entry.properties.experimentGroupId == nil then
			addTask("experimentGroup", Experiments:ListenForPlayerAssignment(player, function (groupId: number?)
				entry.properties.experimentGroupId = groupId
				completeTask("experimentGroup")
			end))
		end

		if pendingMarkerData.activeTasks <= 0 then
			resolved()
		else
			table.insert(WaitingPlayerMarkers, pendingMarkerData)
		end
	end)
end

-- Fire an engagement marker. Used by devs via API module, wraps createMarker to declare source.
-- Usage: EngagementMarkers:FireMarker("LevelUp", {playerLevel = player:GetAttribute("Level")}, {player = player, position = player.Character.PrimaryPart.Position})
function EngagementMarkers:FireMarker(...)
	self:_createMarker("server", ...)
end

-- Used internally by SDK to create markers
function EngagementMarkers:SDKMarker(...)
	self:_createMarker("sdk", ...)
end

function EngagementMarkers:ClearSessionId(player : Player)
	SessionIds[player] = nil
end

--= Initializers =--
function EngagementMarkers:Init()
	--NOTE: Firing markers from client is disabled. Shifting responsibility to the developer for security.

	Players.ChildRemoved:Connect(function(player)
		task.defer(function()
			EngagementMarkers:ClearSessionId(player)
		end)
	end)

	-- Check if time limit has elapsed and send current data, if any
	task.spawn(function()
		while task.wait(QUEUE_CHECK_TIME) do
			-- Check if we need to send queued events to GB
			local lastReportElapsed = tick() - LastEventReportTime

			if lastReportElapsed >= MAX_EVENT_REPORT_TIME then
				self:SendMarkers()
			end
			
			if InternalConfigs:WaitForConfigsReady() then
				MAX_EVENT_REPORT_TIME = InternalConfigs:GetActiveConfig("GBConfigs")["GBRates"]["EngagementMarkers"]
			end
		end
	end)

	task.spawn(function()
		while task.wait(10) do
			if not HostServer:IsHostServer() then
				-- If not host, we don't need to send markers
				continue
			end

			local processedCount = FailedMarkers:Get(1000, function(markers)
				if #markers > 0 then
					-- If we have markers to send, send them
					local validMarkers = {}
					local count = 0
					for _, marker in markers do
						if not isMarkerDataValid(marker) then
							Utilities.GBWarn("Invalid marker data detected, skipping marker")
							continue
						end

						table.insert(validMarkers, marker)
						count += 1
					end

					self:SendMarkers(validMarkers)
				end

				-- NOTE: If send fails, it automatically re-inserts markers into the backup
			end)

			if processedCount <= 0 then
				task.wait(55) -- Wait longer if no markers to process
			end
		end
	end)

	GBRequests:OnFinalRequestCall(function()
		for _, data in WaitingPlayerMarkers do
			data.resolved(true)
		end

		self:SendMarkers()

		FailedMarkers:ForceSavePending()
	end)
end

--= Return Module =--
return EngagementMarkers