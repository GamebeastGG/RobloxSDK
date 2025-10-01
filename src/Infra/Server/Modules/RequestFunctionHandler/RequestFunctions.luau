-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

local Players = game:GetService("Players")
local ChatService = game:GetService("Chat")
local Updater = shared.GBMod("Updater")
local Utilities = shared.GBMod("Utilities")
local Experiments = shared.GBMod("InternalExperiments")

-- Header comments provide info on request details sent from backend.

-- host_only: whether this job is only ever executed by the host server or propagated by the host server for execution on all servers

-- async: whether this request yields other requests in the queue and returns its result immediately or is run on its own thread
-- and the result is added to the async batch queue.

-- Make sure to check HostServer:IsHostServer() before sending request results for host_only: false requests or risk every
-- server pinging our backend.
-- For requests where we actually want to aggregate results from servers, publish to the GBRequests.GB_RESULT_TOPIC channel
-- and the host will batch and report results

-- Functions we define for each request type from the GB dashboard
local requestFunctions = {}

requestFunctions.funcs = {
	-- host_only: true
	-- async: true
	["Ban"] = function(args)
		local userIdentifier = args.playerId
		local success
		
		-- We support UserIds + usernames from the dashboard
		if not tonumber(userIdentifier) then
			-- Get UserId from username
			userIdentifier, success = Utilities.promiseReturn(1, function()
				return Players:GetUserIdFromNameAsync(userIdentifier)
			end)
			
			-- If the service failed, we can't proceed
			if not success then
				error("Failed to resolve userId")
				return
			end
		else
			-- Valid numeric, we proceed
			userIdentifier = tonumber(userIdentifier)
		end
		
		-- If nil, we use -1 (Ban API representation of perm)
		local banTime = if args.unbanAt then args.unbanAt - (os.time() * 1000) else -1
		
		-- Execute ban action
		local _, success = Utilities.promiseReturn(2, function()
			Players:BanAsync({UserIds = {userIdentifier}, Duration = banTime, DisplayReason = args.reason, PrivateReason = args.privateReason or args.reason, ExcludeAltAccounts = args.excludeAlts})
		end)
		
		if not success then
			error("Failed to ban user")
		end
	end;
	
	-- host_only: true
	-- async: true
	["Unban"] = function(args)
		local userIdentifier = args.playerId
		local success

		-- We support UserIds + usernames from the dashboard
		if not tonumber(userIdentifier) then
			-- Get UserId from username
			userIdentifier, success = Utilities.promiseReturn(1, function()
				return Players:GetUserIdFromNameAsync(userIdentifier)
			end)

			-- If the service failed, we can't proceed
			if not success then
				error("Failed to resolve userId")
				return
			end
		else
			-- Valid numeric, we proceed
			userIdentifier = tonumber(userIdentifier)
		end
		
		-- Execute unban action
		local _, success = Utilities.promiseReturn(2, function()
			Players:UnbanAsync({UserIds = {userIdentifier}, ApplyToUniverse = true})
		end)

		if not success then
			error("Failed to unban user")
		end
	end;
	
	-- host_only: false
	-- async: true
	["Kick"] = function(args)
		local userIdentifier = args.playerId
		-- We support UserIds + usernames from the dashboard
		if tonumber(userIdentifier) then
			--
			for _, player in Players:GetPlayers() do
				if player.UserId == tonumber(userIdentifier) then
					local filteredReason = Utilities.promiseReturn(1, function()
						return ChatService:FilterStringForBroadcast(args.reason, player)
					end)

					player:Kick(filteredReason)
				end
			end
		else
			local player = Players:FindFirstChild(userIdentifier)

			if player then
				local filteredReason = Utilities.promiseReturn(1, function()
					return ChatService:FilterStringForBroadcast(args.reason, player)
				end)
				
				player:Kick(filteredReason)
			end
		end
	end;
	
	-- host_only: false
	-- async: false
	["UpdateConfigs"] = function(args)
		Utilities.GBLog("Received config update request", args)
		Updater:UpdateConfigs(args)
	end;

	-- host_only: false
	-- async: false
	["PropagateAvailableExperiments"] = function (args)
		Utilities.GBLog("Received experiment update request", args)
		Experiments:UpdateStateFromAvailableExperiments(args)
	end,

	-- host_only: false
	-- async: false
	["PropagateExperimentReassignment"] = function (args)
		Utilities.GBLog("Received experiment reassignment request", args)
		Experiments:ProcessExperimentReassignmentRequest(args)
	end
}

return requestFunctions