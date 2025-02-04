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
local LocalizationService = game:GetService("LocalizationService")
local PolicyService = game:GetService("PolicyService")

--= Dependencies =--

local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local GetRemote = shared.GBMod("GetRemote")
local Utilities = shared.GBMod("Utilities")
local PlayerStats = shared.GBMod("PlayerStats") ---@module PlayerStats
local LocalizationCache = shared.GBMod("LocalizationCache") ---@module LocalizationCache
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local SocialHandler = shared.GBMod("SocialHandler") ---@module SocialHandler


--= Types =--

--= Object References =--

local FireMarkerEvent = GetRemote("Event", "FireMarker")

--= Constants =--

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

local MarkerQueue = {}
-- Map of unique session IDs for users for player-associated markers
local SessionIds = {}
-- Connections for supporting player positions for markers
local CharConnections = {}
local LastCharPositions = {}
local LastEventReportTime = 0


--= Public Variables =--

--= Internal Functions =--

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
		GBRequests:GBRequest("sdk/markers", data)
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
	local userId = tonumber(player)
	
	if not userId and player then
		userId = player.UserId
	end
	
	
	-- Marker fields
	local entry = {
		["timestamp"] = DateTime.now().UnixTimestampMillis,
		["type"] = markerType,
		["userId"] = userId,
		["sessionId"] = userId and SessionIds[userId] or nil,
		["value"] = value,
		["properties"] = {
			["origin"] = source,
			["device"] = ServerClientInfoHandler:GetClientInfo(player, "device"),
			["position"] = position ~= nil and EncodeVector3(position) or nil,
			["localeId"] = player and LocalizationCache:GetLocaleId(player) or nil,
			["regionId"] = player and LocalizationCache:GetRegionId(player) or nil,
			["sdkVersion"] = "unknown",
			-- server A/B testing partition ID if applicable
			--["partition_id"] = partition ~= "" and partition or nil,
		},
		-- server A/B testing partition ID if applicable
		--["partition_id"] = partition ~= "" and partition or nil,
	}
	
	table.insert(MarkerQueue, entry)
	
	-- If marker queue size limit reached then send batch
	if #MarkerQueue >= MAX_EVENT_QUEUE_SIZE then
		EngagementMarkers:SendMarkers()
	end
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

	local function playerAdded(player : Player)
		local userId = player.UserId
		
		-- Get unique session ID for user
		SessionIds[userId] = HttpService:GenerateGUID(false)
		
		-- Track deaths by default
		player.CharacterAdded:Connect(function(char)
			local connection
			local hum = char:FindFirstChildOfClass("Humanoid")
			
			if hum then
				CharConnections[player] = hum.Died:Connect(function()
					local primaryPart = char.PrimaryPart
					
					-- Still helpful to tell where players are falling out of the map. Solutions?
					if primaryPart then
						self:SDKMarker("Died", nil, {player = player, position = primaryPart.Position})
						CharConnections[player]:Disconnect()
						CharConnections[player] = nil
					end
				end)
			end
		end)
		
		-- Collect last position with this event given PlayerRemoving was inconsistent on character still existing for providing position for Logout markers
		player.CharacterRemoving:Connect(function(char)
			local position = char.PrimaryPart and char.PrimaryPart.Position or nil
			LastCharPositions[player] = position
		end)
		
		-- Get player Login position
		local char = player.Character or player.CharacterAdded:Wait()
		local position
		
		if char and char.PrimaryPart then
			position = char.PrimaryPart.Position
		end
		
		-- Send Login marker with relevant session information
		local loginArgs = {
			adsAllowed = Utilities.promiseReturn(1, function()
				return PolicyService:GetPolicyInfoForPlayerAsync(player).AreAdsAllowed
			end),
		}
		
		self:SDKMarker("Login", loginArgs, {player = player, position = position})
	end

	Players.PlayerAdded:Connect(playerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(playerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		
		-- Clear session state
		SessionIds[userId] = nil
		
		-- Collect last position for Logout marker
		local position = LastCharPositions[player]
		LastCharPositions[player] = nil
		
		-- Compute session length in addition to backend for reasons(?)
		local sessionLength = Utilities.roundNum(tick() - PlayerStats:GetStat(player, "session_length"), 0.1)
		local args = {
			["sessionLength"] = sessionLength,
			["friendPlayPercent"] = Utilities.roundNum(SocialHandler:GetTotalFriendPlaytime(player)/sessionLength, 0.01)
		}

		-- Send Logout marker with relevant info
		self:SDKMarker("Logout", args, {player = player, position = position})
		
		if CharConnections[player] then
			CharConnections[player]:Disconnect()
			CharConnections[player] = nil
		end
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
		EngagementMarkers:SendMarkers()
	end)
end

--= Return Module =--
return EngagementMarkers