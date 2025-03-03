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

local CharConnections = {}
local LastCharPositions = {}


--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

--= Initializers =--
function SessionMarkers:Init()
	Utilities:OnPlayerAdded(function(player : Player)
		-- Track deaths by default
		player.CharacterAdded:Connect(function(char)
			local hum = char:FindFirstChildOfClass("Humanoid")
			
			if hum then
				CharConnections[player] = hum.Died:Connect(function()
					local primaryPart = char.PrimaryPart
					
					-- Still helpful to tell where players are falling out of the map. Solutions?
					if primaryPart then
						EngagementMarkers:SDKMarker("Died", nil, {player = player, position = primaryPart.Position})
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
		
		-- Send Login marker with relevant session information
		local loginArgs = {
			adsAllowed = Utilities.promiseReturn(1, function()
				return PolicyService:GetPolicyInfoForPlayerAsync(player).AreAdsAllowed
			end),
		}
		
		EngagementMarkers:SDKMarker("Login", loginArgs, {player = player, position = nil})
	end)

	Players.PlayerRemoving:Connect(function(player)		
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
		EngagementMarkers:SDKMarker("Logout", args, {player = player, position = position})

		if CharConnections[player] then
			CharConnections[player]:Disconnect()
			CharConnections[player] = nil
		end
	end)
end

--= Return Module =--
return SessionMarkers