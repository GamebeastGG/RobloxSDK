--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SessionMarkers.luau
	
	Description:
		Handles session markers for player login and logout events.
		Tracks player session length and friend playtime percentage.
	
--]]

--= Root =--

local SessionMarkers = { }

--= Roblox Services =--

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local LaunchDataResolver = shared.GBMod("LaunchDataResolver") ---@module LaunchDataResolver
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module Markers
local PlayerStats = shared.GBMod("PlayerStats") ---@module PlayerStats
local SocialHandler = shared.GBMod("SocialHandler") ---@module SocialHandler
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local LastCharPositions = {}
local PlacesInUniverse = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

--= Initializers =--
function SessionMarkers:Init()
	Utilities:OnPlayerAdded(function(player : Player)
		-- Collect last position with this event given PlayerRemoving was inconsistent on character still existing for providing position for Logout markers
		player.CharacterRemoving:Connect(function(char)
			local position = char.PrimaryPart and char.PrimaryPart.Position or nil
			LastCharPositions[player] = position
		end)
		
		local joinData = player:GetJoinData()
		-- Check if the player teleported into the game. Only send login marker if they did not teleport in.
        if joinData.SourceGameId ~= game.GameId then
            
            -- Send Login marker with relevant session information
			local policyInfo = Utilities.promiseReturn(1, function()
				return PolicyService:GetPolicyInfoForPlayerAsync(player)
			end)

			-- Populate referrer data if available
			local isFriend;
			if joinData.ReferredByPlayerId then
				isFriend = Utilities.promiseReturn(1, function()
					return player:IsFriendsWith(joinData.ReferredByPlayerId)
				end)
			end

			local loginArgs = {
				policyInfo = policyInfo,
				publicServer = game.PrivateServerId == "",
				referrer = if joinData.ReferredByPlayerId and joinData.ReferredByPlayerId ~= 0 then {
					type = if isFriend then "friend" else "user",
					id = joinData.ReferredByPlayerId
				} else nil
			}

			LaunchDataResolver:OnResolved(player, function(launchData)
				if launchData then
					if launchData._gbDeeplink then
						loginArgs.referrer = {
							type = "gamebeastDeeplink",
							id = launchData._gbDeeplink.deeplinkId
						}
					elseif not loginArgs.referrer then
						loginArgs.referrer = {
							type = "deeplink",
							id = nil,
						}
					end
				end

				EngagementMarkers:SDKMarker("Login", loginArgs, {player = player, position = nil})
			end)

			PlayerStats:OnDefaultStatsResolved(function()
				ServerClientInfoHandler:UpdateClientData(player, "joinTime", PlayerStats:GetStat(player, "join_time"))
			end)
        end
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Collect last position for Logout marker
		local position = LastCharPositions[player]
		LastCharPositions[player] = nil
		
		-- Compute session length in addition to backend for reasons(?)
		local clientJoinTime = ServerClientInfoHandler:GetClientInfo(player, "joinTime")
		local sessionLength = Utilities.roundNum(os.time() - (clientJoinTime or PlayerStats:GetStat(player, "join_time")), 0.1)
		local friendPlaytime = SocialHandler:GetTotalFriendPlaytime(player)
		local args = {
			["sessionLength"] = sessionLength,
			["sessionLengthPercentageWithFriends"] = if friendPlaytime then Utilities.roundNum(friendPlaytime/sessionLength, 0.01) else nil
		}

		local teleportingToPlace = PlayerStats:GetStat(player, "teleporting_to")
		if ServerClientInfoHandler:IsClientInfoResolved(player) == true and teleportingToPlace and PlacesInUniverse[teleportingToPlace] then
			-- If the player was teleporting, we don't send a Logout marker
			EngagementMarkers:SDKMarker("PlaceTeleport", {
					sourcePlaceId = game.PlaceId,
					destinationPlaceId = teleportingToPlace,
					sessionLength = Utilities.roundNum(os.time() - PlayerStats:GetStat(player, "join_time"), 0.1)
				}, 
				{player = player, position = position}
			)
		else
			-- Send Logout marker with relevant info
			EngagementMarkers:SDKMarker("Logout", args, {player = player, position = position})
		end
	end)

	task.spawn(function()
		-- Collect all places in the universe for sessionId preservation
		local success, err = pcall(function()
			local placesPages = AssetService:GetGamePlacesAsync()
			while true do
				-- Wait for the places to be loaded
				for _, place in pairs(placesPages:GetCurrentPage()) do
					if not PlacesInUniverse[place.PlaceId] then
						PlacesInUniverse[place.PlaceId] = place
					end
				end

				if placesPages.IsFinished then
					break
				else
					placesPages:AdvanceToNextPageAsync()
				end
			end
		end)

		if not success then
			Utilities.GBWarn("Failed to get places in universe:", err)
		end
	end)
	
end

--= Return Module =--
return SessionMarkers