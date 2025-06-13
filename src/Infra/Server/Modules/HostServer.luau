--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	HostServer.luau
	
	Description:
		Handles the host server role in a Gamebeast server environment.
		Ensures that only one host server exists at a time and manages cross-server communication.
	
--]]

--= Root =--
local HostServer = { }

--= Roblox Services =--

local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities

--= Types =--

--= Object References =--

--= Constants =--

-- Messaging service topics for cross server communication
local HOST_HEARTBEAT_TOPIC = "GB_HOST_HEARTBEAT"
local SERVER_SHUTDOWN_TOPIC = "GB_SERVER_SHUTDOWN"
-- How often we check if no host exists and resolve
local HEARTBEAT_INTERVAL = 30

--= Variables =--

local HostServerStatus = RunService:IsStudio()
local OtherHostFound = false
local LastHeartbeatTick = tick()
local ServersSinceStartup = 0
local LastHeartbeatSent = os.time()

--= Public Variables =--

--= Internal Functions =--

local function assumeHostServerRole()
	--Utilities.GBWarn("No Gamebeast host server detected - assuming role.")
	
	HostServerStatus = true
end

local function SendHeartbeat(newFlag : boolean?)
	LastHeartbeatSent = os.time()
	Utilities.publishMessage(HOST_HEARTBEAT_TOPIC, {Source = game.JobId, NewServer = newFlag})
end

--= API Functions =--

-- Returns whether we are currently the host server
function HostServer:IsHostServer() : boolean
	return HostServerStatus
end

-- Update fields so we are no longer the host server and don't execute host only requests
function HostServer:RelinquishHostServerRole()
	HostServerStatus = false
end

-- Sends out signal to see if the host server responds. If no response, attempts to assume host server role
function HostServer:CheckHostServerActive(isNew : boolean?)
	if HostServerStatus then
		return
	end

	OtherHostFound = false

	SendHeartbeat(isNew)
	task.wait(2)
	
	if not OtherHostFound then
		assumeHostServerRole()
	end
end

--= Initializers =--
function HostServer:Init()
	
	if RunService:IsStudio() then
		assumeHostServerRole()
		return
	end

	-- If ping is received on this channel and it is not from ourself, then another host server exists and we relinquish role
	local success, reason = pcall(function()
		MessagingService:SubscribeAsync(HOST_HEARTBEAT_TOPIC, function(message : {Sent : number, Data : {Source : string, NewServer : boolean?}})
			if message.Data.Source == game.JobId then return end

			LastHeartbeatTick = tick()
			--print("New host server found: ".. message.Data)

			if message.Data.Source > game.JobId then -- If other server should be host
				self:RelinquishHostServerRole()
				OtherHostFound = true
			elseif HostServerStatus then -- If we are host
				--Check timestamp, dont reply to any that are older than last heartbeat
				if message.Sent > LastHeartbeatSent then
					SendHeartbeat()
				end
			end

			if message.Data.NewServer then
				ServersSinceStartup += 1
			end
		end)
	end)
	
	Utilities.promiseReturn(1, function()
		MessagingService:SubscribeAsync(SERVER_SHUTDOWN_TOPIC, function(message)
			if message.Data < ServersSinceStartup then
				ServersSinceStartup = math.max(ServersSinceStartup - 1, 0)
			end
		end)
	end)

	if success then
		RunService.Heartbeat:Connect(function()
			if HostServerStatus and os.time() - LastHeartbeatSent > HEARTBEAT_INTERVAL then --Host
				SendHeartbeat()
			elseif tick() - LastHeartbeatTick > ((HEARTBEAT_INTERVAL + 5) + ServersSinceStartup) then -- Non-host
				LastHeartbeatTick = tick()
				self:CheckHostServerActive()
			end
		end)

		self:CheckHostServerActive(true)

		game:BindToClose(function(reason)
			if reason == Enum.CloseReason.DeveloperShutdown or reason == Enum.CloseReason.DeveloperUpdate then
				return
			end

			Utilities.publishMessage(SERVER_SHUTDOWN_TOPIC, ServersSinceStartup)
		end)
	else
		Utilities.GBWarn("Failed to subscribe to host heartbeat topic, starting rogue host server...", reason)
		assumeHostServerRole()
	end
end

--= Return Module =--
return HostServer