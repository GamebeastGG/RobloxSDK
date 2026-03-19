--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    RequestFunctionHandler.luau
    
    Description:
        Gandles fetching requests(jobs) from Gamebeasts
    
--]]

--= Root =--

local RequestFunctionHandler = {}

--= Roblox Services =--

local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local RequestFunctions = shared.GBMod("RequestFunctions") ---@module RequestFunctions
local InternalConfigs = shared.GBMod("InternalConfigs") -- RECURSIVE!

--= Types =--

--= Object References =--

local CustomJobData = DataStoreService:GetDataStore("GB_CUSTOM_JOB_DATA")

--= Constants =--

-- How often we check for new requests from GB dashboard
local UPDATE_PERIOD = 1

-- Subscription topic name for direct requests from GB

--= Variables =--

local CustomJobCallbacks = {}
local ProcessedUpToRequestId = 0
local RequestResults = {}
local RequestQueue = {}

--= Public Variables =--

--= Internal Functions =--

local function AddResult(success : boolean, id : number, result : any)
    result = result or {}
    table.insert(RequestResults, {status = success and "success" or "failure", result = result, requestId = id})

    if #RequestResults == 1 then

        -- Delay sending results to GB to batch them.
        local delayTime = math.min(#RequestQueue * 0.1, 3)
        task.delay(delayTime, function()
            GBRequests:GBRequest("v1/requests/completed", RequestResults)
            RequestResults = {}
        end)
    end

end

--= API Functions =--

function RequestFunctionHandler:SetCallback(customJobName : string, callback : (jobData : {[string] : any}) -> (any))
    if CustomJobCallbacks[customJobName] then
        Utilities.GBWarn(`Job name "{customJobName}" already has a callback set, additional sets will overwrite the previous callback.`)
    end

    CustomJobCallbacks[customJobName] = callback
end

function RequestFunctionHandler:ExecuteRequests(requests : {})
    local LastProcessedUpTo = ProcessedUpToRequestId
    local willStartLoop = #RequestQueue == 0

    -- Make sure we don't process requests we've already processed
    for _, request in requests do
        -- Determine new ProcessedUpToRequestId
        if request.requestId > ProcessedUpToRequestId then
            ProcessedUpToRequestId = request.requestId
        end

        -- Add to queue if not already processed
        if request.requestId > LastProcessedUpTo then
            table.insert(RequestQueue, request)
        end
    end

    if willStartLoop then
        task.spawn(function()
            while #RequestQueue > 0 do
                local request = RequestQueue[1]

                -- Send job started message
                GBRequests:GBRequestAsync("v1/requests/started", {request.requestId})

                local function performRequest()
                    local requestFunc;
                    if request.details.custom then
                        requestFunc = CustomJobCallbacks[request.requestType]
                    else
                        requestFunc = RequestFunctions.funcs[request.requestType]
                    end

                    if not requestFunc then
                        Utilities.GBWarn(`No request function found for request type {request.requestType}`)
                        AddResult(false, request.requestId, {details="request callback not found"})
                        return
                    end

                    if request.details.custom then
                        local success, err = pcall(function()
                            local requestId = tostring(request.requestId)

                            CustomJobData:UpdateAsync(request.requestType, function(oldData)
                                oldData = oldData or {}

                                for i, info in oldData do
                                    if os.time() - info.timestamp > 10 then
                                        oldData[i] = nil
                                    end
                                end

                                oldData[requestId] = {jobData = request.args, timestamp = os.time(), requestId = requestId}
                                return oldData
                            end)

                            Utilities.publishMessage("GB_PROPAGATE_CUSTOM", {fromServer = game.JobId, requestId=requestId, requestType=request.requestType})
                            
                        end)

                        if not success then
                            Utilities.GBWarn(`Failed to update custom job data for request of type {request.requestType}: {err}`)
                        end
                    end
                
                    local success, data = pcall(requestFunc, request.args)

                    if not success then
                        AddResult(false, request.requestId, {details=data})
                    else
                        local responseDataType = type(data)

                        if responseDataType == "userdata" then
                            data = {
                                message = "returned value cannot be a userdata value"
                            }
                        elseif responseDataType == "table" then
                            local canEncode, err = pcall(function()
                                HttpService:JSONEncode(data)
                            end)

                            if not canEncode then
                                data = {
                                    message = "failed to encode returned value",
                                    encodeError = err
                                }
                            end
                        end

                        AddResult(true, request.requestId, data)
                    end
                end

                -- Either run relevant function in its own thread or (potentially) yield and run sequentially as determined by request details
                if request.details.async or request.details.custom then
                    task.spawn(performRequest)
                else
                    performRequest()
                end

                table.remove(RequestQueue, 1)
            end
        end)
    end
end

--= Initializers =--

function RequestFunctionHandler:Init()
    -- Receive requests from host server and other sources
	-- Check for new requsts and add to queue loop
    local finalRequest = false
	task.spawn(function()
		local function checkForRequests()
			-- Get requests from Gamebeast. Soon-to-be legacy?
			local success, newRequests = GBRequests:GBRequestAsync("v1/requests")
            if success then
                self:ExecuteRequests(newRequests)
            end
		end

		InternalConfigs:OnReady(function()
			repeat
				checkForRequests()
				UPDATE_PERIOD = InternalConfigs:GetActiveConfig("GBConfigs")["GBRates"]["CheckRequests"]
            until task.wait(UPDATE_PERIOD) == nil or finalRequest == true
		end)
	end)

    local customJobQueue = {}
    Utilities.promiseReturn(1, function()
        MessagingService:SubscribeAsync("GB_PROPAGATE_CUSTOM", function(message)
            local data = message.Data

            if data.fromServer == game.JobId then
                return
            end

            table.insert(customJobQueue, data)
            if customJobQueue[2] == nil then
                while customJobQueue[1] do
                    local jobInfo = customJobQueue[1]

                    local success, jobDataCache = pcall(function()
                        return CustomJobData:GetAsync(jobInfo.requestType)
                    end)

                    if not success or jobDataCache[jobInfo.requestId] == nil then
                        Utilities.GBWarn(`Failed to fetch custom job data for request of type {jobInfo.requestType}`, jobDataCache, jobInfo)
                        table.remove(customJobQueue, 1)
                        continue
                    end

                    local callback = CustomJobCallbacks[jobInfo.requestType]

                    if callback then
                        local success, err = pcall(function()
                            callback(jobDataCache[jobInfo.requestId].jobData)
                        end)

                        if not success then
                            Utilities.GBWarn(`Error executing custom job callback for request type {jobInfo.requestType}: {err}`)
                        end
                    else
                        Utilities.GBWarn(`Received custom job data for request type {jobInfo.requestType} but no callback is set.`)
                    end

                    task.wait(5) -- Wait at least 5 seconds between processing jobs of the same type to let cache clear.
                    table.remove(customJobQueue, 1)
                end
                
            end  
        end)
    end)

    GBRequests:OnFinalRequestCall(function()
        finalRequest = true
    end)
end

--= Return Module =--
return RequestFunctionHandler