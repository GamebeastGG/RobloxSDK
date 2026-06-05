--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SentimentCapture.luau
	
	Description:
		Captures player chat messages and sends them as markers for sentiment analysis.
		Messages are filtered for compliance before being sent.
	
--]]

--= Root =--

local SentimentCapture = { }

--= Roblox Services =--

local Chat = game:GetService("Chat")
local Players = game:GetService("Players")
local LocalizationService = game:GetService("LocalizationService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities")
local ServerGate = shared.GBMod("ServerGate") ---@module ServerGate
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module Markers

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

--= Initializers =--
function SentimentCapture:Init()
	ServerGate:OnPlayerAdded(function(player, cleaner)
		cleaner:Add(player.Chatted:Connect(function(message) -- Auto disconnected on player leave
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
		end))	
	end)
end

--= Return Module =--
return SentimentCapture