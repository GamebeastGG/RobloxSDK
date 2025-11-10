--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientConfigs.lua
    
    Description:
        Internal module for managing client-side configuration data.
    
--]]

--= Root =--
local ClientConfigs = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")
local Signal = shared.GBMod("Signal")
local SignalConnection = shared.GBMod("SignalConnection")

--= Types =--

--= Object References =--

local GetConfigRemoteFunc = GetRemote("Function", "Get")
--local GetEventDataRemoteFunc = GetRemote("Function", "GetEventData")
local ConfigChangedRemote = GetRemote("Event", "ConfigChanged")
local ConfigUpdatedSignal = Signal.new()
local ConfigReadySignal = Signal.new()

--= Constants =--

--= Variables =--

local CachedConfigs = {}
local ConfigsReady = false

--= Public Variables =--

--= Internal Functions =--

local function DeepCopy(object)
    local newObject = {}
    for key, value in pairs(object) do
        if type(value) == "table" then
            newObject[key] = DeepCopy(value)
        else
            newObject[key] = value
        end
    end
    return newObject
end

--= API Functions =--

function ClientConfigs:WaitForConfigsReady()
	if not ConfigsReady then
		ConfigReadySignal:Wait()
	end
end

function ClientConfigs:Get(path : string | { string }, _configs : any?)
    if typeof(path) ~= "table" and typeof(path) ~= "string" then
		error("Config path must be a string or list of strings.")
		return nil
	end

    self:WaitForConfigsReady()

    if typeof(path) == "string" then
        path = {path}
    end
	
    local target = _configs or CachedConfigs
	for _, key in path do
        target = target[key]

        if target == nil then
            return nil
        end
    end

	return target
end

function ClientConfigs:OnChanged(targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    if type(targetConfig) == "string" then
        targetConfig = {targetConfig}
    end

    return ConfigUpdatedSignal:Connect(function(changes : { { path : {string}, newValue : any, oldValue : any}}, oldConfigs : any)
        for _, change in changes do
            local match = true
            for index, pathSegment in targetConfig do
                if change.path[index] == nil then
                    break
                elseif change.path[index] ~= pathSegment then
                    match = false
                    break
                end
            end

            if match then
                callback(self:Get(targetConfig), self:Get(targetConfig, oldConfigs))
                break
            end
        end
    end)
end

function ClientConfigs:OnReady(callback : (configs : any) -> ()) : RBXScriptConnection
    if ConfigsReady then
        task.spawn(callback, CachedConfigs)
        return SignalConnection.new()
    end

    return ConfigReadySignal:Once(function()
        callback(CachedConfigs)
    end)
end
    
function ClientConfigs:IsReady() : boolean
    return ConfigsReady
end

--= Initializers =--
function ClientConfigs:Init()
    ConfigChangedRemote.OnClientEvent:Connect(function(changes : { { path : {string}, newValue : any}})
        if not ConfigsReady then return end

        local oldConfigs = DeepCopy(CachedConfigs)

        for _, change in changes do
            local target = CachedConfigs
            for index, pathSegment in change.path do
                if index == #change.path then
                    target[pathSegment] = change.newValue
                else
                    target = target[pathSegment]
                end
            end
        end

        ConfigUpdatedSignal:Fire(changes, oldConfigs)
    end)

    task.spawn(function()
        CachedConfigs = GetConfigRemoteFunc:InvokeServer()
        --TODO: Make sure we actually got something
        ConfigsReady = true
        ConfigReadySignal:Fire(CachedConfigs)
    end)
end

--= Return Module =--
return ClientConfigs