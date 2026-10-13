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

local Timer = require(script.Parent.Parent.Parent.Shared.Modules.Timer) ---@module Timer
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local Cleaner = require(script.Parent.Parent.Parent.Shared.Modules.Cleaner)
local Utilities = require(script.Parent.Utilities)
local DataCache = require(script.Parent.Parent.Parent.Shared.Modules.DataCache)
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate
local GBRequests = require(script.Parent.GBRequests) ---@module GBRequests
local Experiments = require(script.Parent.InternalExperiments) ---@module InternalExperiments
local InternalConfigs = require(script.Parent.InternalConfigs) ---@module InternalConfigs
local SignalConnection = require(script.Parent.Parent.Parent.Shared.Modules.Signal.SignalConnection) ---@module SignalConnection
local LocalizationCache = require(script.Parent.LocalizationCache) ---@module LocalizationCache
local LaunchDataResolver = require(script.Parent.LaunchDataResolver) ---@module LaunchDataResolver
local ServerClientInfoHandler = require(script.Parent.ServerClientInfoHandler) ---@module ServerClientInfoHandler

--= Types =--

--= Object References =--

--= Constants =--

local CLIENT_DATA_TIMEOUT = RunService:IsStudio() and 10 or 45
local MAX_EVENT_QUEUE_SIZE = 1000
local QUEUE_CHECK_TIME = 5
local MAX_REJECTION_REASONS_LOGGED = 5
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
-- Session IDs for player markers
local SessionIds = ServerGate:GetCache() -- Cleared on player leave
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
	
	-- Spawned since markers are added from threads that must not yield, including the shutdown flush
	if #MarkerQueue >= MAX_EVENT_QUEUE_SIZE then
		task.spawn(function()
			EngagementMarkers:SendMarkers()
		end)
	end
end

--= API Functions =--

EngagementMarkers.MarkersFailed = Signal.new()

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
		
		local success, responseBody = GBRequests:GBRequestAsync("v1/markers", data)

		-- A successful batch can still have some markers rejected (invalid shape, subscription limits)
		if success and responseBody and (responseBody.rejectedMarkersCount or 0) > 0 then
			local reasons = {}
			for index, rejected in responseBody.rejectedMarkers or {} do
				if index > MAX_REJECTION_REASONS_LOGGED then
					break
				end
				local markerType = type(rejected.marker) == "table" and rejected.marker.type or "unknown"
				table.insert(reasons, `{markerType}: {rejected.reason}`)
			end

			Utilities.GBWarn(`{responseBody.rejectedMarkersCount} of the {#data.markers} markers sent were rejected by Gamebeast: {table.concat(reasons, "; ")}`)
		end

		if not success then
			-- Not resent here, the valid markers go to the developer through MarkersFailed to retry.
			-- Resending here too would duplicate them, since the backend doesn't de-duplicate.
			local toRetry = {}
			local invalidMarkerCount = 0
			for _, marker in data.markers do
				if not isMarkerDataValid(marker) then
					invalidMarkerCount += 1
					continue
				end
				
				if not isCustomQueue then
					table.insert(toRetry, marker)
				end
			end

			if toRetry[1] then
				self.MarkersFailed:Fire(toRetry)
			end

			if invalidMarkerCount > 0 then
				Utilities.GBWarn(`{invalidMarkerCount} of the {#data.markers} sent are invalid and will not be retried.`)
			end

			if responseBody and responseBody.errorCode and DROP_MARKER_CODES[responseBody.errorCode] then
				return false, responseBody -- Rejected for a known reason, skip the generic warning
			end

			Utilities.GBWarn("Failed to send engagement markers to Gamebeast.")
		end
		return success, responseBody
	end

	return true
end

-- Shared by FireMarker and SDKMarker
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
		value = { value = value }
	end
	
	-- Player may be an instance or a userId
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
			["language"] = nil, -- Resolved later
			["country"] = nil, -- Resolved later
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

			-- Prefer the client's session ID, which carries over teleports within the game
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

			-- Left in place on shutdown, which is iterating this list
			if not shutdown then
				local index = table.find(WaitingPlayerMarkers, pendingMarkerData)
				if index then
					table.remove(WaitingPlayerMarkers, index)
				end
			end
		end

		pendingMarkerData.resolved = resolved

		-- Task manager

		-- A nil or disconnected connection means the callback already ran
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

		-- Stop waiting on unresolved tasks after a timeout
		local dataFetchTimer = Timer.new(CLIENT_DATA_TIMEOUT)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer:OnEnd(function()
			if pendingMarkerData.tasks["clientInfo"] then
				if not ServerClientInfoHandler:IsClientInfoResolved(player) and ClientInfoWarned == false then
					Utilities.GBWarn("Failed to resolve client info, did you forget to :Setup() Gamebeast SDK on the client?")
					ClientInfoWarned = true
				end

				completeTask("clientInfo")
			end

			-- Send the marker without whatever is still missing rather than hold it. Markers held too long
			-- are lost on a crash or rejected as stale; without assignments the marker just counts toward
			-- no experiment.
			completeTask("localization")
			completeTask("launchData")
			completeTask("experimentAssignments")
		end))

		-- Device and input type come from the client
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

		-- Localization comes from engine lookups that yield, so the marker waits on them here
		-- rather than in the caller's thread
		addTask("localization", LocalizationCache:OnResolved(player, function(localization)
			entry.properties.language = localization.localeId
			entry.properties.country = localization.regionId

			completeTask("localization")
		end))

		-- The backend attributes markers to experiments from the player's stored assignments, so wait
		-- for those to resolve
		addTask("experimentAssignments", Experiments:OnAssignmentsResolvedForPlayer(player, function()
			completeTask("experimentAssignments")
		end))

		if pendingMarkerData.activeTasks <= 0 then
			resolved()
		else
			table.insert(WaitingPlayerMarkers, pendingMarkerData)
		end
	end)
end

-- Used by the public Markers API
-- Usage: EngagementMarkers:FireMarker("LevelUp", {playerLevel = player:GetAttribute("Level")}, {player = player, position = player.Character.PrimaryPart.Position})
function EngagementMarkers:FireMarker(...)
	self:_createMarker("server", ...)
end

-- Used internally by SDK to create markers
function EngagementMarkers:SDKMarker(...)
	self:_createMarker("sdk", ...)
end

--= Initializers =--
function EngagementMarkers:Init()
	-- Flush the queue every markerFlushRate seconds
	task.spawn(function()
		while true do
			local markerFlushRate = DataCache:Get("Settings").markerFlushRate
			task.wait(math.min(QUEUE_CHECK_TIME, markerFlushRate))

			local lastReportElapsed = tick() - LastEventReportTime

			if lastReportElapsed >= markerFlushRate then
				-- Protected so one bad batch can't end this loop
				local didSend, sendError = pcall(self.SendMarkers, self)
				if not didSend then
					Utilities.GBWarn("Failed to send engagement markers:", sendError)
				end
			end
		end
	end)

	GBRequests:OnFinalRequestCall(function()
		for _, data in WaitingPlayerMarkers do
			data.resolved(true)
		end

		self:SendMarkers()

	end)
end

--= Return Module =--
return EngagementMarkers