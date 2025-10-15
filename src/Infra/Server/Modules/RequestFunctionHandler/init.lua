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
local MessagingService = game:GetService("MessagingService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local HostServer = shared.GBMod("HostServer") ---@module HostServer
local RequestFunctions = shared.GBMod("RequestFunctions") ---@module RequestFunctions
local InternalConfigs = shared.GBMod("InternalConfigs") -- RECURSIVE!

--= Types =--

--= Object References =--

--= Constants =--

-- How often we check for new requests from GB dashboard
local UPDATE_PERIOD = 1
-- 1024 byte limit in docs but less in practice because of metadata. Not exactly calculated but this will never exceed the limit.
local MESSAGE_SIZE_LIMIT = 950
-- Bytes reserved in chunked request messages to fit chunk metadata
local MESSAGE_CHUNK_METADATA_RESERVED_BYTES = 50
-- Subscription topic name for direct requests from GB
local GB_MESSAGING_TOPIC = "GB_REQ_MESSAGE_V2"

--= Variables =--

local CustomJobCallbacks = {}
local ProcessedUpToRequestId = 0
local RequestBodyChunkPool = {}
local RequestResults = {}
local RequestQueue = {}

--= Public Variables =--

--= Internal Functions =--

local function AddResult(success : boolean, id : number, result : any)
    result = result or {}
    table.insert(RequestResults, {status = success and "success" or "failure", result = result, requestId = id})

    if #RequestResults == 1 then
        --TODO: Temp, in the future all servers will independently report success!
        if HostServer:IsHostServer() ~= true then
            RequestResults = {}
            return
        end

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
    local isHost = HostServer:IsHostServer()
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
                if isHost then --TODO: Remove eventually. We'll know a request started when the previous one completes.
                    GBRequests:GBRequestAsync("v1/requests/started", {request.requestId})
                end

                if (isHost or request.details.host_authority) and not request.details.hostOnly then
                    local requestString = HttpService:JSONEncode(request)
                    local argsString = HttpService:JSONEncode(request.args)

                    -- We need to chunk into messages that will fit into MessagingService limit to propagate requests to servers
                    if #requestString > MESSAGE_SIZE_LIMIT then
                        local request = Utilities.recursiveCopy(request)
                        request.chunked = true

                        -- Make chunks as large as possible to send fewest messages, accounting for chunk metadata we're adding too
                        local argsChunkSize = MESSAGE_SIZE_LIMIT - MESSAGE_CHUNK_METADATA_RESERVED_BYTES - (#requestString - #argsString)

                        -- We can only chunk args, so if the request itself is larger than the limit, abort
                        if argsChunkSize <= 0 then
                            Utilities.GBWarn("Request too large to chunk, aborting.")
                            AddResult(false, request.requestId, {details="request too large to chunk"})
                            continue
                        end

                        local argChunks = {}

                        -- Generate message chunks at determined size
                        local nextChunkStart = 1
                        local nextEscapeCharacterAt: number? = nil
                        while nextChunkStart <= string.len(argsString) do
                            local targetChunkEnd = nextChunkStart + argsChunkSize - 1

                            -- Shrink chunk size for each escape character that will overflow from it
                            local searchStart = nextChunkStart
                            while searchStart <= targetChunkEnd and nextChunkStart < targetChunkEnd do
                                nextEscapeCharacterAt = nextEscapeCharacterAt
                                    or string.find(argsString, `["\\]`, searchStart)
                                    or math.huge
                                if nextEscapeCharacterAt and nextEscapeCharacterAt <= targetChunkEnd then
                                    targetChunkEnd -= 1
                                    searchStart = nextEscapeCharacterAt + 1
                                    nextEscapeCharacterAt = nil
                                else
                                    break
                                end
                            end

                            table.insert(argChunks, string.sub(argsString, nextChunkStart, targetChunkEnd))
                            nextChunkStart = targetChunkEnd + 1
                        end

                        -- Let recipient servers how many chunks to expect before reconstruction
                        request.chunks = #argChunks

                        -- Send all chunks to other servers
                        for i = 1, #argChunks do
                            request.args = argChunks[i]
                            request.chunk_id = i

                            task.spawn(function()
                                Utilities.publishMessage(GB_MESSAGING_TOPIC, {request})
                            end)
                        end
                    else
                        -- No chunking needed, send full message to other servers
                        task.spawn(function()
                            Utilities.publishMessage(GB_MESSAGING_TOPIC, {request})
                        end)
                    end
                end

                -- Process request
                if not request.details.hostOnly or isHost or request.details.host_authority then
                    local function performRequest()
                        local requestFunc;
                        if request.details.custom then
                            requestFunc = CustomJobCallbacks[request.requestType]
                        else
                            requestFunc = RequestFunctions.funcs[request.requestType]
                        end

                        if not requestFunc then
                            AddResult(false, request.requestId, {details="request callback not found"})
                            return
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
                end

                table.remove(RequestQueue, 1)
            end
        end)
    end
end

--= Initializers =--

function RequestFunctionHandler:Init()
    -- Receive requests from host server and other sources
	Utilities.promiseReturn(nil, function()
		MessagingService:SubscribeAsync(GB_MESSAGING_TOPIC, function(message)
			local decodedRequests = message.Data
			local newRequests = {}

			for _, request in decodedRequests do
				-- This is a request sent from the host with total message size >1KiB, meaning it was chunked for MessagingService
				if request.chunked then
					if not RequestBodyChunkPool[request.requestId] then
						RequestBodyChunkPool[request.requestId] = {}
					end

					-- Add chunk to pool	
					RequestBodyChunkPool[request.requestId][request.chunk_id] = request.args

					local haveAllChunks = true

					for i = 1, request.chunks do
						if not RequestBodyChunkPool[request.requestId][i] then
							haveAllChunks = false
							break
						end
					end

					-- If all chunks accounted for, reconstruct via concatenation and load body, continue with normal pipeline
					if haveAllChunks then
						local argString = ""

						for i = 1, request.chunks do
							argString ..= RequestBodyChunkPool[request.requestId][i]
						end

						request.args = HttpService:JSONDecode(argString)
                        RequestBodyChunkPool[request.requestId] = nil
						table.insert(newRequests, request)
					else
						continue
					end
				else
					-- Not chunked, just add request
					table.insert(newRequests, request)
				end
			end

			self:ExecuteRequests(newRequests)
		end)
	end)

	-- Check for new requsts and add to queue loop
    local finalRequest = false
	task.spawn(function()
		local function checkForRequests()
			-- Only host should be asking for requests
			if not shared.GBMod("HostServer"):IsHostServer() then return end

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

    GBRequests:OnFinalRequestCall(function()
        finalRequest = true
    end)
end

--= Return Module =--
return RequestFunctionHandler