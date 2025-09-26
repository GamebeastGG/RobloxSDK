-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

local marketplaceService = game:GetService("MarketplaceService")
local messagingService = game:GetService("MessagingService")
local httpService = game:GetService("HttpService")
local runService = game:GetService("RunService")

local DataCache = shared.GBMod("DataCache")

local MessagingServiceDebugCache = {} :: {[string] : number}
local MessagingServiceRequestTimestamps = {}
local LastMessageTime = nil

local utilities = {}

-- Central function for warning messages across SDK. Indicates Gamebeast as warning source and allows for output settings.
utilities.GBWarn = function(...)
	if DataCache:Get("Settings").sdkWarningsEnabled then
		warn("GamebeastSDK:", ...)
		if DataCache:Get("Settings").includeWarningStackTrace then
			warn("GamebeastSDK Traceback:", debug.traceback())
		end
	end
end

utilities.GBLog = function (...)
	if DataCache:Get("Settings").sdkDebugEnabled then
		print("GamebeastSDK:", ...)
	end
end

utilities.resolvePlayerObject = function(playerQuery : Player | number)
	if typeof(playerQuery) == "number" then
		return game.Players:GetPlayerByUserId(playerQuery)
	else
		return playerQuery
	end
end

-- pcall wrapper function with retry support used extensively in SDK.
utilities.promiseReturn = function(maxRetries, callback, retries) : (any?, boolean)
	if maxRetries and not retries then
		retries = 0
	elseif retries and retries > maxRetries then
		--warn("Promise reached retry limit")
		return nil, false
	end

	local result

	local success, err = pcall(function()
		result = callback()
	end)

	if success then
		return result, true
	else
		task.wait()
		if retries then
			retries += 1
			
			if retries > maxRetries then
				utilities.GBWarn(err)
			end
		end

		return utilities.promiseReturn(maxRetries, callback, retries)
	end
end

function utilities:PCallRetry(retryCount : number, callback : () -> (), _count : number?) : (boolean, any?)
	if not _count then
		_count = 0
	end

	local success, result = pcall(callback)

	if success then
		return true, result
	else
		if _count < retryCount then
			task.wait(0.1)
			return self:PCallRetry(retryCount, callback, _count + 1)
		else
			return false, result
		end
	end
end

-- Check contents of two tables are the same without recursive iteration
-- Works only if we want to check key-value equivalence, and not type, table memory reference, etc. Works for SDK purposes *today*.
utilities.tableEqualityCheck = function(a, b)
	return table.concat(a) == table.concat(b)
end

-- Format time in seconds to specified format
utilities.formatTime = function(timeRemaining, onlyMinutes)	
	local hours = math.floor(timeRemaining/60/60)
	local minutes = math.floor((timeRemaining/60) - (hours * 60))
	local seconds = math.floor(timeRemaining - (minutes * 60) - (hours * 60 * 60))

	hours = tostring(hours)
	minutes = tostring(minutes)
	seconds = tostring(seconds)

	if #hours < 2 then
		hours = "0".. hours
	end
	if #minutes < 2 then
		minutes = "0".. minutes
	end
	if #seconds < 2 then
		seconds = "0".. seconds
	end

	return onlyMinutes and minutes.. ":".. seconds or hours.. ":".. minutes.. ":".. seconds
end

-- Convert seconds to time remaining in specified format
utilities.convertSecstoDay = function(timeRemaining) 
	local days = timeRemaining / (24 * 3600)

	timeRemaining = timeRemaining % (24 * 3600)
	
	local hours = timeRemaining / 3600

	timeRemaining %= 3600
	
	local minutes = timeRemaining / 60

	timeRemaining %= 60
	
	local seconds = timeRemaining

	return math.floor(days).. "d ".. math.floor(hours).. "h ".. math.floor(minutes).. "m ".. math.floor(seconds).. "s"
end 

-- Get product info with promise wrapper
utilities.getProductInfo = function(id, infoType)
	return utilities.promiseReturn(nil, function()
		return marketplaceService:GetProductInfo(id, infoType)
	end)
end

-- Recursive deep copy of a given table
utilities.recursiveCopy = function(tab, readOnly)
	local tableCopy = {}

	for index, value in tab do
		if type(value) == "table" then
			value = utilities.recursiveCopy(value, readOnly)
			
			if readOnly and not table.isfrozen(value) then
				table.freeze(value)
			end
		end

		tableCopy[index] = value
	end

	return tableCopy
end

-- Round num to nearest specified increment. Roblox changes may have made less numerically stable, resulting in some odd floating point errors in limited instances
utilities.roundNum = function(num, nearest) 
	return math.floor(0.5 + (num/nearest)) / (1/nearest)
end

-- Publish message with messaging service with promise wrapper. All MessageService messages go through here for potential usage monitoring.
utilities.publishMessage = function(channel, message)
	local success, errorMessage = utilities:PCallRetry(1, function()
		MessagingServiceDebugCache[channel] = (MessagingServiceDebugCache[channel] or 0) + 1
		messagingService:PublishAsync(channel, message)
	end)

	-- Measure request rate for potential throttling issues
	local avg = 0
	if LastMessageTime then
		local timeSinceLastMessage = os.clock() - LastMessageTime
		
		table.insert(MessagingServiceRequestTimestamps, {Time = timeSinceLastMessage})
		if #MessagingServiceRequestTimestamps > 100 then
			table.remove(MessagingServiceRequestTimestamps, 1)
		end

		for _, entry in MessagingServiceRequestTimestamps do
			avg += entry.Time
		end

		avg = 60 / (avg / #MessagingServiceRequestTimestamps)
	end

	if not success then
		utilities.GBWarn(`Failed to publish message to channel: {channel} (Req count on channel: {MessagingServiceDebugCache[channel]}, Avg. total req/min: {math.round(avg)}) with error: {errorMessage}`)
	else
		LastMessageTime = os.clock()
	end
end

--- Returns an array of all values found in the given table, regardless of key type.
function utilities.getTableValues<K, V>(t: {[K]: V}): {V}
	local values: {V} = {}
	for _, value in t do
		table.insert(values, value)
	end
	return values
end

--- Returns the value found when traversing `root` upon reaching the given `path`.
function utilities.getValueAtPath(root: any, path: {string}): any
	local value = root
	for _, pathSegment in path do
		if typeof(value) ~= "table" then
			value = nil
			break
		end
		value = value[pathSegment]
	end
	return value
end

local serverId = if runService:IsStudio()
	then `studio:{httpService:GenerateGUID(false):lower()}`
	else game.JobId

--- Returns the server's ID in live games, or a generated one for each Studio test session (prefixed with `studio:`).
function utilities.getServerId(): string
	return serverId
end

-- Wrapper for player added that ensures players that joined before the signal was attached get passed through the callback.
function utilities:OnPlayerAdded(callback : (player : Player) -> ())
	for _, player in pairs(game.Players:GetPlayers()) do
		task.spawn(callback, player)
	end
	return game.Players.PlayerAdded:Connect(callback)
end

--[[
	Calls the given functions in parallel, and waits for all of them to finish.
]]
function utilities.waitForAllCalls(callbacks: {[any]: () -> ()})
	local suspendedThreadsRemaining = #callbacks
	if suspendedThreadsRemaining == 0 then
		return
	end

	local thread = coroutine.running()

	for callbackIndex, callback in callbacks do
		task.spawn(function ()
			local didSucceed, result = pcall(callback)
			if not didSucceed then
				utilities.GBWarn(`Uncaught error in waitForAllCalls callback {callbackIndex}: {result}`)
			end

			suspendedThreadsRemaining -= 1
			if suspendedThreadsRemaining == 0 then
				coroutine.resume(thread)
			end
		end)
	end

	if suspendedThreadsRemaining > 0 then
		coroutine.yield()
	end
end

--[[
	Calls the given functions in parallel, and waits until any of them finish.
]]
function utilities.waitForAnyCall(callbacks: {[any]: () -> ()})
	if #callbacks == 0 then
		return
	end

	local thread = coroutine.running()
	local didResume = false

	for callbackIndex, callback in callbacks do
		task.spawn(function ()
			local didSucceed, result = pcall(callback)
			if not didSucceed then
				utilities.GBWarn(`Uncaught error in waitForAnyCall callback {callbackIndex}: {result}`)
			end

			if not didResume then
				didResume = true
				coroutine.resume(thread)
			end
		end)
	end

	if not didResume then
		coroutine.yield()
	end
end

return utilities
