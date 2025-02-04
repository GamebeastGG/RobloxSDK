--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SentimentCapture.luau
	
	Description:
		No description provided.
	
--]]

--= Root =--

local SentimentCapture = { }

--= Roblox Services =--

local Chat = game:GetService("Chat")
local Players = game:GetService("Players")
local LocalizationService = game:GetService("LocalizationService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local InternalConfigs = shared.GBMod("InternalConfigs")
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module Markers

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

local ChatConnections = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

--= Initializers =--
function SentimentCapture:Init()
	Players.PlayerAdded:Connect(function(player)
		-- Get relevant language settings
		local translator = Utilities.promiseReturn(1, function()
			return LocalizationService:GetTranslatorForPlayer(player)
		end)
	
		ChatConnections[player] = player.Chatted:Connect(function(message)
			local position
			
			-- Compliance
			message = Utilities.promiseReturn(0, function()
				Chat:FilterStringForBroadcast(message, player)
			end) or message
	
			if player.Character and player.Character.PrimaryPart then
				position = player.Character.PrimaryPart.Position
			end

			-- Send marker with relevant args
			local args = {
				["message"] = message
			}
	
			EngagementMarkers:SDKMarker("Chat", args, {player = player, position = position})
		end)
	end)
	
	-- Clear session connections on player leave
	Players.PlayerRemoving:Connect(function(player)
		if ChatConnections[player] then
			ChatConnections[player]:Disconnect()
			ChatConnections[player] = nil
		end
	end)
end

--= Return Module =--
return SentimentCapture