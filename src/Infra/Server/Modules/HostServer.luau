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
local SERVER_STARTUP_TOPIC = "GB_SERVER_STARTUP"
-- How often we check if no host exists and resolve
local HEARTBEAT_INTERVAL = 10

--= Variables =--

local HostServerStatus = RunService:IsStudio()
local OtherHostFound = false
local LastHeartbeatTick = tick()
local ServersSinceStartup = 0
local LastHeartbeatSent = os.time()
local ServerId = Utilities.getServerId()

--= Public Variables =--

--= Internal Functions =--

local function assumeHostServerRole()
	--Utilities.GBWarn("No Gamebeast host server detected - assuming role.")
	
	HostServerStatus = true
end

local function SendHeartbeat()
	LastHeartbeatSent = os.time()
	Utilities.publishMessage(HOST_HEARTBEAT_TOPIC, {Source = ServerId})
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

-- If no response, attempts to assume host server role
function HostServer:CheckHostServerActive()
	if HostServerStatus then
		return
	end

	OtherHostFound = false

	task.wait(HEARTBEAT_INTERVAL + 2) -- Wait a bit to see if we get a response from an active host server

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
		MessagingService:SubscribeAsync(HOST_HEARTBEAT_TOPIC, function(message : {Sent : number, Data : {Source : string}})
			if message.Data.Source == ServerId then return end

			LastHeartbeatTick = tick()
			--print("New host server found: ".. message.Data)
			OtherHostFound = true
			if message.Data.Source > ServerId then -- If other server should be host
				self:RelinquishHostServerRole()
			end
		end)
	end)
	
	Utilities.promiseReturn(1, function()
		MessagingService:SubscribeAsync(SERVER_STARTUP_TOPIC, function()
			ServersSinceStartup += 1
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
				assumeHostServerRole()
			end
		end)

		game:BindToClose(function(reason)
			if reason == Enum.CloseReason.DeveloperShutdown or reason == Enum.CloseReason.DeveloperUpdate then
				return
			end

			Utilities.publishMessage(SERVER_SHUTDOWN_TOPIC, ServersSinceStartup)
		end)

		Utilities.publishMessage(SERVER_STARTUP_TOPIC, true)
		self:CheckHostServerActive()
	else
		Utilities.GBWarn("Failed to subscribe to host heartbeat topic, starting rogue host server with reason: ".. reason)
		assumeHostServerRole()
	end
end

--= Return Module =--
return HostServer