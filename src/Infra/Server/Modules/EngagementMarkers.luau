--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	EngagementMarkers.luau
	
	Description:
		No description provided.
	
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
local MetaData = shared.GBMod("MetaData")
local GetRemote = shared.GBMod("GetRemote")
local Utilities = shared.GBMod("Utilities")
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local LocalizationCache = shared.GBMod("LocalizationCache") ---@module LocalizationCache
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local Experiments = shared.GBMod("Experiments") ---@module Experiments

--= Types =--

--= Object References =--

local FireMarkerEvent = GetRemote("Event", "FireMarker")

--= Constants =--

local CLIENT_DATA_TIMEOUT = RunService:IsStudio() and 10 or 45
local MAX_EVENT_QUEUE_SIZE = 1000
local QUEUE_CHECK_TIME = 5
local MAX_EVENT_REPORT_TIME = 10
local SYSTEM_MARKERS = {
	["Died"] = true,
	["Logout"] = true,
	["Login"] = true,
	["Purchase"] = true,
	["Chat"] = true,
	--["GBClientPerformance"] = true,
	--["GBServerPerformance"] = true,
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

--= API Functions =--

-- Send batch to GB
function EngagementMarkers:SendMarkers()
	if #MarkerQueue > 0 then
		LastEventReportTime = tick()
		
		local data = {
			markers = MarkerQueue
		}

		MarkerQueue = {}
		GBRequests:GBRequest("v1/markers", data)
	end
end

-- Core function, should be used internally by SDK rather than fireMarker
-- function EngagementMarkers:CreateMarker(source, markerType, player, position, value)
function EngagementMarkers:_createMarker(source : "server" | "client" | "sdk", markerType : string, value : number | {[string] : any}, metaData : {[string] : any})
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
	
	local valueType = typeof(value)

	if value ~= nil and valueType ~= "table" and valueType ~= "number" or (valueType == "table" and #value > 0) then
		Utilities.GBWarn("Value for ".. source .." marker \"".. markerType.."\" should be a key-value dictionary, number, or nil.\n".. usageStr)
		return
	end
	
	-- Interface allows for player instance or userId. We already validated args types, so just handle accordingly.
	local player = Utilities.resolvePlayerObject(player)
	
	-- Marker fields
	

	local entry = {
		["markerId"] = HttpService:GenerateGUID(false),
		["timestamp"] = metaData.timestampOverride or DateTime.now().UnixTimestampMillis,
		["type"] = markerType,
		["userId"] = player and player.UserId, 
		["sessionId"] = player and GetSessionIdForPlayer(player),
		["value"] = value,
		["properties"] = {
			["sdkPlatform"] = "roblox",
			["origin"] = source,
			["device"] = nil, -- Resolved later
			["deviceSubType"] = nil, -- Resolved later
			["inputType"] = nil, -- Resolved later
			["position"] = position ~= nil and EncodeVector3(position) or nil,
			["language"] = player and LocalizationCache:GetLocaleId(player) or nil,
			["country"] = player and LocalizationCache:GetRegionId(player) or nil,
			["experimentGroupId"] = player
				and Experiments.AssignedGroupIdByPlayer[player]
				or Experiments.AssignedServerGroupId,
		},
	}

	local function addMarker()
		table.insert(MarkerQueue, entry)
		
		-- If marker queue size limit reached then send batch
		if #MarkerQueue >= MAX_EVENT_QUEUE_SIZE then
			EngagementMarkers:SendMarkers()
		end
	end

	--[[
		Ensure markers are sent with all required data.
	]]

	local pendingMarkerData = {
		pendingCleaner = Cleaner.new(),
		tasks = {},
		activeTasks = 0,
		resolved = nil,
	}

	InternalConfigs:OnReady(function()
		local function resolved(shutdown : boolean?)
			pendingMarkerData.pendingCleaner:Clean()

			-- Add any final missing data to the marker
			entry.properties.device = ServerClientInfoHandler:GetClientInfo(player, "device")
			entry.properties.deviceSubType = ServerClientInfoHandler:GetClientInfo(player, "deviceSubType")
			entry.properties.inputType = ServerClientInfoHandler:GetClientInfo(player, "inputType")
			addMarker()

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

		-- Stop wating after some time if tasks are not resolved
		local dataFetchTimer = Timer.new(CLIENT_DATA_TIMEOUT)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer)
		pendingMarkerData.pendingCleaner:Add(dataFetchTimer:OnEnd(function()
			if not ServerClientInfoHandler:IsClientInfoResolved(player) and ClientInfoWarned == false then
				Utilities.GBWarn("Failed to resolve client info, did you forget to :Setup() Gamebeast SDK on the client?")
				ClientInfoWarned = true
			end

			resolved()
		end))

		if player then -- Ensure marker gets fired with device info on timeout or bind to close
			addTask("clientInfo", ServerClientInfoHandler:OnClientInfoResolved(player, function()
				completeTask("clientInfo")
			end))
		end

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
	--[[ Handle client requests through API module
	FireMarkerEvent.OnServerEvent:Connect(function(player, markerType, value, metaData)
		if metaData then
			metaData.player = player
		else
			metaData = {player = player}
		end

		EngagementMarkers:_createMarker("client", markerType, value, metaData)
	end)]]

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
				EngagementMarkers:SendMarkers()
			end
			
			if InternalConfigs:WaitForConfigsReady() then
				MAX_EVENT_REPORT_TIME = InternalConfigs:GetActiveConfig("GBConfigs")["GBRates"]["EngagementMarkers"]
			end
		end
	end)

	GBRequests:OnFinalRequestCall(function()
		for _, data in WaitingPlayerMarkers do
			data.resolved(true)
		end

		EngagementMarkers:SendMarkers()
	end)
end

--= Return Module =--
return EngagementMarkers