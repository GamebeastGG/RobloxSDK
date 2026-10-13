--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	SentimentCapture.luau
	
	Description:
		Captures player chat messages and sends them as markers for sentiment analysis.
		Only filtered text is sent. A message that fails filtering is dropped.
	
--]]

--= Root =--

local SentimentCapture = { }

--= Roblox Services =--

local TextService = game:GetService("TextService")
local Players = game:GetService("Players")
local LocalizationService = game:GetService("LocalizationService")

--= Dependencies =--

local Utilities = require(script.Parent.Parent.Utilities)
local ServerGate = require(script.Parent.Parent.ServerGate) ---@module ServerGate
local EngagementMarkers = require(script.Parent.Parent.EngagementMarkers) ---@module Markers

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

			-- Broadcast filtering is the strictest level, since the text leaves the game
			local didFilter, filteredMessage = pcall(function()
				local result = TextService:FilterStringAsync(message, player.UserId, Enum.TextFilterContext.PublicChat)
				return result:GetNonChatStringForBroadcastAsync()
			end)

			if not didFilter then
				Utilities.GBLog("Chat message dropped, filtering failed:", filteredMessage)
				return
			end

			if player.Character and player.Character.PrimaryPart then
				position = player.Character.PrimaryPart.Position
			end

			-- Send marker with relevant args
			local args = {
				["message"] = filteredMessage
			}
	
			EngagementMarkers:SDKMarker("Chat", args, {player = player, position = position})
		end))	
	end)
end

--= Return Module =--
return SentimentCapture