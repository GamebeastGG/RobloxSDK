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

local Utilities = shared.GBMod("Utilities")
local DataCache = shared.GBMod("DataCache")
local Signal = shared.GBMod("Signal") ---@module Signal
local MetaData = shared.GBMod("MetaData") ---@module MetaData

--= Types =--

--= Constants =--

local URL_SUFFIX = "/sdk"
local ENDPOINTS = {
	{ 
		URL = "https://api.gamebeast.gg", -- http://localhost:3001 -- https://api.gamebeast.gg -- https://api.stage.gamebeast.gg
		Requests = { -- NOTE: If you require URL parameters, use {param} in the route string. Example: "v1/servers/roblox/{serverId}"
			["v1/markers"] = "POST",
			["v1/requests"] = "GET",
			["v1/requests/completed"] = "POST",
			["v1/requests/started"] = "PUT",
			["v1/configurations"] = "GET",
			["v1/latest/version?platform=roblox"] = "GET",
			["v1/experiments"] = "GET",
			["v1/experiments/assignments"] = "POST",
			["v1/servers/roblox/{serverId}"] = "POST"
		},
		EndpointTree = {} -- Automatically generated from above
	}
}

--= Object References =--

local FinalRequestSignal = Signal.new()
local RequestProcessingCount = 0

--= Variables =--
local KeyYeildWarning = false
-- One time warning if requests are failing because of invalid/unset key
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

-- Callback that is fired when the game is shutting down for final request processing.
function GBRequests:OnFinalRequestCall(callback : () -> ())
	return FinalRequestSignal:Connect(function()
		local currentThread = coroutine.running()
		callback()
		if currentThread ~= coroutine.running() then
			error("Final request should not yeild!")
		end
	end)
end

-- Main method for dispatching requests from SDK to backend
-- Returns parsed body and original response if body can be resolve and response only otherwise
function GBRequests:GBRequest(requestRoute : string, args : {[string] : any}) : nil
	local _, requestsMethod = GetEndpointForRequest(requestRoute)
	if requestsMethod ~= "POST" then
		Utilities.GBWarn("GBRequest should only be used for POST requests. Use GBRequestAsync for other request types.")
	end

	task.spawn(function()
		self:GBRequestAsync(requestRoute, args)
	end)
end

--YEILDS 
function GBRequests:GBRequestAsync(requestRoute : string, args : {[string] : any}, maxRetries : number?) : (boolean, any?)
	local authKey = YeildForKey() -- Will wait for Key and Settings to be set
	local GBDomain, requestMethod = GetEndpointForRequest(requestRoute)
	
	if not GBDomain or not requestMethod then
		Utilities.GBWarn("Invalid request route:", requestRoute)
		return false, nil
	end

	RequestProcessingCount += 1

	local requestBody
	args = args or {}


	-- Define relevant headers. Backend enforces header presence unless specified.
	local isStudio = RunService:IsStudio()
	local headers = {
		["authorization"] = authKey,
		["isstudio"] = tostring(isStudio),
		["sdkversion"] = MetaData.version,
		["universeid"] = tostring(game.GameId),
		["serverid"] = Utilities.getServerId(),
	}

	local url = GBDomain.. "/".. requestRoute

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
	if response and #response.Body > 0 then
		if (response.StatusCode == 401 or response.StatusCode == 403) and not KeyWarningGiven then
			Utilities.GBWarn("Gamebeast project key invalid or not set! Set your project key in the :Setup method.")
			KeyWarningGiven = true
		end

		-- Decode returned body
		local bodyParsed = Utilities.promiseReturn(0, function()
			return HttpService:JSONDecode(response.Body)
		end)

		if success == false then
			Utilities.GBWarn("Request failed ("..response.StatusCode.. ") | "..(bodyParsed and bodyParsed.message or "Unknown error"))
		end
		
		return success, bodyParsed
	end

	return success
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