--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    FailedMarkers.lua
    
    Description:
        - Ordered datastore holds keys for batches of failed markers.
        - Normal datastore holds the markers themselves.
        - 2 requests per batch. One to delete the ordered key, and one to delete the markers.
        Enum.DataStoreRequestType.SetIncrementSortedAsync
        Enum.DataStoreRequestType.SetIncrementAsync
--]]

--= Root =--
local FailedMarkers = { }

--= Roblox Services =--
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

--= Dependencies =--

local Utilities = shared.GBMod("Utilities") ---@module Utilities

--= Types =--

--= Object References =--

local MarkersDataStore = DataStoreService:GetDataStore("GB_FailedMarkers")
local OrderedMarkersDataStore = DataStoreService:GetOrderedDataStore("GB_FailedMarkers")

--= Constants =--

local MAX_RETRY_COUNT = 3 -- Maximum number of retries for saving markers
local MAX_QUEUE_SIZE = 400
local MAX_MARKERS_PER_BATCH = 1000 -- Maximum markers per batch

--= Variables =--

local RetryQueue = {} :: {{retryCount : number, markers : {any}}}
local MarkersPendingBatch = {} :: {any}
local MarkersPendingCount = 0

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function FailedMarkers:CanAfford() : boolean
    local budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
    local sortedBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)
    local getSortedBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetSortedAsync)

    -- Check if we have enough budget for both requests
    return getSortedBudget > 1 and budget >= 30 and sortedBudget >= 12
end

-- Uses Budget of 1 Ordered and 1 Normal
function FailedMarkers:Save(markers : {any}, isRetry : boolean?) : boolean
    local key = HttpService:GenerateGUID(false)
    local markerCount = #markers
    if markerCount > MAX_MARKERS_PER_BATCH then
        Utilities.GBWarn("Too many markers to save in one batch:", markerCount)
        return false
    end

    local success, errorMessage = pcall(function()
        if not self:CanAfford() then
            error("Not enough budget to save markers")
        end
        -- Add the key to the ordered datastore
        OrderedMarkersDataStore:SetAsync(key, markerCount)
        
        -- Save the markers to the normal datastore
        MarkersDataStore:SetAsync(key, markers)
    end)

    if not success then
        --Utilities.GBWarn("Failed to save markers:", errorMessage)
        if not isRetry then
            if #RetryQueue + 1 >= MAX_QUEUE_SIZE then
                -- If the queue is full, remove the oldest item
                table.remove(RetryQueue, 2)
            end

            table.insert(RetryQueue, {
                retryCount = 0,
                markers = markers
            })
        end
        return false
    end

    return true
end

-- Uses max budget of 1 GetSorted, 20 SetIncrementAsync, and 10 SetIncrementSortedAsync
function FailedMarkers:Get(maxMarkers : number, callback : (({any}) -> ())) : number
    if not self:CanAfford() then
        return {}
    end

    local keyPageSuccess, keyPages = pcall(function()
        return OrderedMarkersDataStore:GetSortedAsync(false, 10) -- Get the first 10 keys
    end)

    if not keyPageSuccess then
        Utilities.GBWarn("Failed to retrieve keys from OrderedMarkersDataStore:", keyPages)
        return {}
    end

    local markers = {}
    local count = 0
    local toDelete = {}

    for _, kvPair in pairs(keyPages:GetCurrentPage()) do
        if kvPair.value + count > maxMarkers then
            -- If adding this batch exceeds the maxMarkers limit, break
            break
        end

        local fetchedMarkers = {}
        local success, err = pcall(function()
            MarkersDataStore:UpdateAsync(kvPair.key, function(current)
                if not current then
                    return nil -- If the key doesn't exist cancel the operation
                end

                fetchedMarkers = current

                return {} -- Return empty table so if deletion fails, we don't keep the markers that were processed.
            end)
        end)
    
        if success then
            for _, marker in pairs(fetchedMarkers) do
                table.insert(markers, marker)
            end

            count += kvPair.value
            table.insert(toDelete, kvPair.key)
        else
            Utilities.GBWarn("Failed to retrieve markers for key:", kvPair.key, "Error:", err)
        end
    end

    task.spawn(function()
        callback(markers)
    end)

    for _, key in toDelete do
        local deleteSuccess, deleteError = pcall(function()
            MarkersDataStore:RemoveAsync(key)
            OrderedMarkersDataStore:RemoveAsync(key)
        end)

        if not deleteSuccess then
            Utilities.GBWarn("Failed to delete key from OrderedMarkersDataStore:", key, "Error:", deleteError)
        end
    end

    return count
end

function FailedMarkers:ForceSavePending()
    if MarkersPendingCount > 0 then
        -- If there are pending markers, save them immediately
        local toSave = MarkersPendingBatch
        MarkersPendingBatch = {}
        MarkersPendingCount = 0

        self:Save(toSave)
    end
end

function FailedMarkers:AddMarker(marker : {[string] : any})
    MarkersPendingCount += 1
    MarkersPendingBatch[MarkersPendingCount] = marker
    if MarkersPendingCount >= MAX_MARKERS_PER_BATCH then
        -- If we have enough markers, save them
        local toSave = MarkersPendingBatch
        MarkersPendingBatch = {}
        MarkersPendingCount = 0

        self:Save(toSave)
    end
end

--= Initializers =--
function FailedMarkers:Init()
    task.spawn(function()
        while true do
            if #RetryQueue > 0 then
                if self:CanAfford() then
                    -- If budget is low, wait before retrying
                    task.wait(5)
                    continue
                end


                local retryItem = table.remove(RetryQueue, 1)
                -- Attempt to save the markers again
                if retryItem.retryCount < MAX_RETRY_COUNT then
                    retryItem.retryCount += 1
                    local success = self:Save(retryItem.markers, true)
                    if not success then
                        table.insert(RetryQueue, retryItem) -- Reinsert the item for retry
                        task.wait(5)
                    end
                else
                    Utilities.GBWarn("Failed to save markers after maximum retries")
                end
            end
            task.wait(2)
        end
    end)
end

--= Return Module =--
return FailedMarkers