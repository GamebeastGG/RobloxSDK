--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	EventsManager.luau
	
	Description:
		Handles the management of defined events, including starting and ending events based on time.
	
--]]

--= Root =--
local EventsManager = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs
local Utilities = shared.GBMod("Utilities")
local Signal = shared.GBMod("Signal")

--= Types =--

--= Object References =--

local EventStartedSignal = Signal.new()
local EventEndedSignal = Signal.new()

--= Constants =--

-- How often we check if it's time to execute an event
local EVENT_CHECK_PERIOD = 0.5

--= Variables =--

local EventStatusCache = {}

--= Public Variables =--

--= Internal Functions =--

local function FireEventStatus(start : boolean, eventName : string, eventData : { [string] : any })
	if start then
		EventStartedSignal:Fire(eventName, eventData.info)
	else
		EventEndedSignal:Fire(eventName, eventData.info)
	end

	EventStatusCache[eventName].Started = start

	-- FireClient(start, eventName, eventData)
end

--= API Functions =--

function EventsManager:OnStart(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptConnection
	return EventStartedSignal:Connect(function(name, info)
		if name == eventName then
			callback(info)
		end
	end)
end

function EventsManager:OnEnd(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptConnection
	return EventEndedSignal:Connect(function(name, info)
		if name == eventName then
			callback(info)
		end
	end)
end

--= Initializers =--
function EventsManager:Init()
	InternalConfigs:OnReady(function()

		-- Loop to check if an event should be executed
		task.spawn(function()
			while task.wait(EVENT_CHECK_PERIOD) do
				for eventName, eventData in InternalConfigs:GetActiveConfig("GBConfigs")["EventData"] do
					if not EventStatusCache[eventName] then
						EventStatusCache[eventName] = {
							Started = false
						}
					end
					local statusData = EventStatusCache[eventName]

					local curTime = os.time()
					
					if eventData.endTime and curTime >= eventData.startTime and curTime < eventData.endTime and not statusData.Started then
						print("Starting/continuing the '".. eventName.. "' event!")
						
						FireEventStatus(true, eventName, eventData)
					elseif curTime == eventData.endTime and statusData.Started then
						print("Ending the '".. eventName.. "' event!")
						
						FireEventStatus(false, eventName, eventData)
					elseif curTime == eventData.startTime and not statusData.Started then
						print("Starting the '".. eventName.. "' event!")

						FireEventStatus(true, eventName, eventData)
					end
				end
			end
		end)
	end)
end

--= Return Module =--
return EventsManager