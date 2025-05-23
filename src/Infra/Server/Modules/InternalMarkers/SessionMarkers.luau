--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SessionMarkers.luau
	
	Description:
		No description provided.
	
--]]

--= Root =--

local SessionMarkers = { }

--= Roblox Services =--

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module Markers
local PlayerStats = shared.GBMod("PlayerStats") ---@module PlayerStats
local SocialHandler = shared.GBMod("SocialHandler") ---@module SocialHandler

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local LastCharPositions = {}


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
		
		-- Send Login marker with relevant session information
		local policyInfo = Utilities.promiseReturn(1, function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)

		local loginArgs = {
			policyInfo = policyInfo
		}

		EngagementMarkers:SDKMarker("Login", loginArgs, {player = player, position = nil})
	end)

	Players.PlayerRemoving:Connect(function(player)		
		-- Collect last position for Logout marker
		local position = LastCharPositions[player]
		LastCharPositions[player] = nil
		
		-- Compute session length in addition to backend for reasons(?)
		local sessionLength = Utilities.roundNum(tick() - PlayerStats:GetStat(player, "session_length"), 0.1)
		local friendPlaytimePercent = SocialHandler:GetTotalFriendPlaytime(player)
		local args = {
			["sessionLength"] = sessionLength,
			["sessionLengthPercentageWithFriends"] = if friendPlaytimePercent then Utilities.roundNum(friendPlaytimePercent/sessionLength, 0.01) else nil
		}

		-- Send Logout marker with relevant info
		EngagementMarkers:SDKMarker("Logout", args, {player = player, position = position})
	end)
end

--= Return Module =--
return SessionMarkers