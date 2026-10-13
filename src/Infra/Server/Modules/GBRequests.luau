--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	GBRequests.luau
	
	Description:
		Handles all HTTP requests to the Gamebeast backend.
	
--]]

--= Root =--
local GBRequests = { }

--= Roblox Services =--

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

--= Dependencies =--

local Utilities = require(script.Parent.Utilities)
local DataCache = require(script.Parent.Parent.Parent.Shared.Modules.DataCache)
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local MetaData = require(script.Parent.Parent.Parent.MetaData) ---@module MetaData

--= Types =--

--= Constants =--

local URL_SUFFIX = "/sdk"
local ENDPOINTS = {
	{ 
		URL = "https://api.gamebeast.gg", -- http://localhost:3001 -- https://api.gamebeast.gg -- https://api.stage.gamebeast.gg
		Requests = { -- NOTE: Use {param} in a route for URL parameters, e.g. "v1/servers/roblox/{serverId}"
			["v1/markers"] = "POST",
			["v1/latest/version?platform=roblox"] = "GET",
			["v1/servers/roblox/{serverId}"] = "POST",
			["v1/cohorts/membership"] = "POST",
			["v2/bootstrap"] = "GET",
			["v2/status"] = "GET",
			["v2/configurations"] = "GET",
			["v2/experiments/active"] = "GET",
			["v2/experiments/assignments/bulk"] = "POST"
		},
		EndpointTree = {} -- Automatically generated from above
	}
}
local ENVIRONMENT_MAP = {
	["production"] = "false",
	["studio"] = "true",
}
--= Object References =--

local FinalRequestSignal = Signal.new()
local RequestProcessingCount = 0

--= Variables =--
local KeyYeildWarning = false
-- One-time warning for an invalid or unset key
local KeyWarningGiven = false

--= Internal Functions =--

local function GetEndpointForRequest(requestRoute : string) : (string?, string?)
	for _, endpoint in ENDPOINTS do
		local current = endpoint.EndpointTree
		for _, part in string.split(requestRoute, "/") do
			current = current[part]
			if not current then
				return nil, nil
			end
		end

		return ((DataCache:Get("Settings").customUrl or endpoint.URL)..URL_SUFFIX), current["__method"]
	end
end

local function YeildForKey() : string | Secret
	local start = tick()
	while not DataCache:Get("Key") do
		task.wait()
		if tick() - start > 5 and not KeyYeildWarning then
			Utilities.GBWarn("Gamebeast key not found! Did you call Gamebeast:Setup()?")
			KeyYeildWarning = true
			break
		end
	end

	return DataCache:Get("Key")
end

--= API Functions =--

-- Runs the callback at shutdown, for sending final requests. It must not yield.
function GBRequests:OnFinalRequestCall(callback : () -> ())
	return FinalRequestSignal:Connect(function()
		local currentThread = coroutine.running()
		callback()
		if currentThread ~= coroutine.running() then
			error("Final request should not yeild!")
		end
	end)
end

-- Fire-and-forget POST to the backend. Returns nothing.
function GBRequests:GBRequest(requestRoute : string, args : {[string] : any}, headerOverrides : {[string] : any}?, maxRetries : number?) : nil
	local _, requestsMethod = GetEndpointForRequest(requestRoute)
	if requestsMethod ~= "POST" then
		Utilities.GBWarn("GBRequest should only be used for POST requests. Use GBRequestAsync for other request types.")
	end

	task.spawn(function()
		self:GBRequestAsync(requestRoute, args, headerOverrides, maxRetries)
	end)
end

--YEILDS
-- Returns success, the parsed body if any, and the status code if a response came back.
function GBRequests:GBRequestAsync(requestRoute : string, args : {[string] : any}, headerOverrides : {[string] : any}?, maxRetries : number?) : (boolean, any?, number?)
	local authKey = YeildForKey() -- Setup sets the key and settings together
	local GBDomain, requestMethod = GetEndpointForRequest(requestRoute)
	
	if not GBDomain or not requestMethod then
		Utilities.GBWarn("Invalid request route:", requestRoute)
		return false, nil
	end

	local requestBody
	args = args or {}


	local targetEnvironment = DataCache:Get("Settings").environment
	local isStudioHeader = tostring(RunService:IsStudio())

	if targetEnvironment and ENVIRONMENT_MAP[targetEnvironment] then
		isStudioHeader = ENVIRONMENT_MAP[targetEnvironment]
	end

	-- Backend enforces header presence unless noted. "environment" is for v2 routes, where "studio"
	-- means development. "isstudio" is for v1 routes.
	local headers = {
		["authorization"] = authKey,
		["isstudio"] = isStudioHeader,
		["environment"] = targetEnvironment or (RunService:IsStudio() and "studio" or "production"),
		["sdkversion"] = MetaData.version,
		["universeid"] = tostring(game.GameId),
		["serverid"] = Utilities.getServerId(),
		-- The snapshot rate limit is keyed on this. Without it, servers behind one egress IP share a bucket.
		["server-id"] = Utilities.getServerId(),
	}

	-- Apply header overrides if provided
	if headerOverrides then
		for key, value in headerOverrides do
			headers[key] = value
		end
	end

	local url = GBDomain.. "/".. requestRoute

	-- Encoded before counting the request as in flight, so a payload JSON can't encode never holds up BindToClose.
	local didEncode, encodeError = pcall(function()
		if requestMethod == "POST" or requestMethod == "PUT" then
			requestBody = HttpService:JSONEncode(args)
			headers["Content-Type"] = "application/json"
		elseif requestMethod == "GET" then
			-- Encode args to query string
			local paramString = "?"
			for key, val in args do
				paramString ..= key.. "=".. HttpService:UrlEncode(val).. "&"
			end

			paramString = string.sub(paramString, 1, #paramString - 1)
			url ..= paramString
		end
	end)

	if not didEncode then
		Utilities.GBWarn(`Couldn't encode the request to {requestRoute}, so it was not sent:`, encodeError)
		return false, nil
	end

	RequestProcessingCount += 1

	-- Send request
	local response, requestSuccess = Utilities.promiseReturn(maxRetries or 1, function()
		return HttpService:RequestAsync({
			Url = url,
			Method = requestMethod,
			Headers = headers,
			Body = requestBody
		})
	end)

	RequestProcessingCount -= 1

	local success = requestSuccess and response.Success or false
	local statusCode = response and response.StatusCode or nil
	if response and #response.Body > 0 then
		if (statusCode == 401 or statusCode == 403) and not KeyWarningGiven then
			Utilities.GBWarn("Gamebeast project key invalid or not set! Set your project key in the :Setup method.")
			KeyWarningGiven = true
		end

		-- Decode returned body
		local bodyParsed = Utilities.promiseReturn(0, function()
			return HttpService:JSONDecode(response.Body)
		end)

		-- 304 is the expected "not modified" reply to hash-based change detection
		if success == false and statusCode ~= 304 then
			Utilities.GBWarn("Request failed ("..statusCode.. ") | ".. requestRoute .." | "..(bodyParsed and bodyParsed.message or "Unknown error"))
		end

		return success, bodyParsed, statusCode
	end

	return success, nil, statusCode
end

--= Initializers =--
function GBRequests:Init()
	game:BindToClose(function()
		FinalRequestSignal:Fire()

		repeat
			task.wait()
		until RequestProcessingCount == 0
	end)
end

do -- Generate endpoint tree for fast lookup
	for _, endpoint in ENDPOINTS do
		for route, method in endpoint.Requests do
			local path = string.split(route, "/")
			local current = endpoint.EndpointTree
			for _, part in path do
				local isParamRoute = string.match(part, "{(.*)}") ~= nil

				if not current[part] then
					if isParamRoute then
						local nextPath = {}
						setmetatable(current, {
							__index = function(self, key)
								return nextPath
							end
						})
					else
						current[part] = {}
					end
				end

				current = current[part]
			end

			current["__method"] = method
		end
	end
end

--= Return Module =--
return GBRequests