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
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler

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
		
		local joinData = player:GetJoinData()
		-- Check if the player teleported into the game. Only send login marker if they did not teleport in.
        if joinData.SourceGameId ~= game.GameId then
            
            -- Send Login marker with relevant session information
			local policyInfo = Utilities.promiseReturn(1, function()
				return PolicyService:GetPolicyInfoForPlayerAsync(player)
			end)

			local loginArgs = {
				policyInfo = policyInfo
			}

			EngagementMarkers:SDKMarker("Login", loginArgs, {player = player, position = nil})

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
		local friendPlaytimePercent = SocialHandler:GetTotalFriendPlaytime(player)
		local args = {
			["sessionLength"] = sessionLength,
			["sessionLengthPercentageWithFriends"] = if friendPlaytimePercent then Utilities.roundNum(friendPlaytimePercent/sessionLength, 0.01) else nil
		}

		if ServerClientInfoHandler:IsClientInfoResolved() == true and PlayerStats:GetStat(player, "teleporting") == true then
			-- If the player was teleporting, we don't send a Logout marker
			return
		end

		-- Send Logout marker with relevant info
		EngagementMarkers:SDKMarker("Logout", args, {player = player, position = position})
	end)
end

--= Return Module =--
return SessionMarkers