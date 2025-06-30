--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    DatastoreBackup.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local DatastoreBackup = { }

--= Roblox Services =--
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

--= Dependencies =--

--= Types =--

--= Constants =--
local BACKUP_STORE_KEY = (RunService:IsStudio() and "Studio" or "") .. "_Gamebeast_Backup"

--= Object References =--
local BackupConfigStore = DataStoreService:GetDataStore(BACKUP_STORE_KEY)

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function DatastoreBackup:Set(key, value) : boolean
    local success, errorMessage = pcall(function()
        BackupConfigStore:SetAsync(key, value)
    end)

    if not success then
        warn("Failed to save backup data for key '" .. key .. "': " .. tostring(errorMessage))
    end

    return success
end

function DatastoreBackup:Update(key, callback : (any) -> (any)) : boolean
    local success, errorMessage = pcall(function()
        BackupConfigStore:UpdateAsync(key, callback)
    end)

    if not success then
        warn("Failed to update backup data for key '" .. key .. "': " .. tostring(errorMessage))
    end

    return success
end

function DatastoreBackup:Get(key) : (boolean, any)
    local success, value = pcall(function()
        return BackupConfigStore:GetAsync(key)
    end)

    if not success then
        warn("Failed to retrieve backup data for key '" .. key .. "': " .. tostring(value))
        return nil
    end

    return success, value
end

--= Initializers =--
function DatastoreBackup:Init()
    
end

--= Return Module =--
return DatastoreBackup