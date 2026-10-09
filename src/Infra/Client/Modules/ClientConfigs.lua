--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    ClientConfigs.lua

    Description:
        Internal module for managing client-side configuration data.
        Mirrors the server's multi-config store; consumer paths begin with the
        configuration's alias or name.

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
local ConfigChangedRemote = GetRemote("Event", "ConfigChanged")
-- Neither signal copies its arguments per listener: every Configs:Observe adds a listener, and with
-- ~1,600 of them each fire used to make ~1,600 deep copies of the configuration. Listeners only read
-- the arguments, and the old config a change carries is frozen before it is shared.
local ConfigUpdatedSignal = Signal.new({ copyArguments = false })
local ConfigReadySignal = Signal.new({ copyArguments = false })

--= Constants =--

--= Variables =--

-- Config documents keyed by stringified config id
local CachedConfigs = {}
-- Consumer path identifiers (alias, name, or id) mapped to config ids
local IdByIdentifier = {}
-- The one identifier each config is listed under, mirroring the server's own keying
local IdentifierByConfigId = {}
local ConfigsReady = false
-- Guards the re-pull below, so two events for unknown configs cannot race each other
local IsRepullingConfigs = false

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

local function DeepFreeze(object)
    if not table.isfrozen(object) then
        table.freeze(object)
    end
    for _, value in object do
        if type(value) == "table" then
            DeepFreeze(value)
        end
    end
end

local function ResolveConfigId(identifier : string) : number?
    return IdByIdentifier[tostring(identifier)]
end

-- Returns every cached config document keyed by consumer identifier.
-- Keyed off IdentifierByConfigId rather than IdByIdentifier: the latter resolves every spelling
-- of a config (id, name and alias), which listed the same document up to three times here while
-- the server's equivalent listed it once.
local function GetAllViews()
    local views = {}
    for configId, identifier in IdentifierByConfigId do
        views[identifier] = CachedConfigs[tostring(configId)]
    end
    return views
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

    if #path == 0 then
        error("Config path must begin with a configuration name or alias.")
        return nil
    end

    -- Overrides are config-local documents (e.g. old configs in OnChanged), so the
    -- identifier segment is skipped rather than resolved.
    local target
    if _configs then
        target = _configs
    else
        local configId = ResolveConfigId(path[1])
        if not configId then
            return nil
        end

        target = CachedConfigs[tostring(configId)]
    end

	for index = 2, #path do
        if target == nil then
            return nil
        end
        target = target[path[index]]
    end

	return target
end

function ClientConfigs:OnChanged(targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    if type(targetConfig) == "string" then
        targetConfig = {targetConfig}
    end

    return ConfigUpdatedSignal:Connect(function(configId : number, changes : { { path : {string}, newValue : any, oldValue : any}}, oldConfigs : any)
        -- Resolve the target identifier at fire time so subscriptions can precede config load
        if ResolveConfigId(targetConfig[1]) ~= configId then
            return
        end

        for _, change in changes do
            local match = true
            for index = 2, #targetConfig do
                local changeSegment = change.path[index - 1]
                if changeSegment == nil then
                    break
                elseif changeSegment ~= targetConfig[index] then
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
        task.spawn(callback, GetAllViews())
        return SignalConnection.new()
    end

    return ConfigReadySignal:Once(function()
        callback(GetAllViews())
    end)
end

function ClientConfigs:IsReady() : boolean
    return ConfigsReady
end

--= Initializers =--
function ClientConfigs:Init()
    ConfigChangedRemote.OnClientEvent:Connect(function(configId : number, changes : { { path : {string}, newValue : any}})
        if not ConfigsReady then return end

        local configKey = tostring(configId)
        local config = CachedConfigs[configKey]

        -- Unknown config (e.g. created after join): re-pull the full payload instead of patching
        if config == nil then
            if IsRepullingConfigs then
                return
            end
            IsRepullingConfigs = true

            task.spawn(function()
                local didSucceed, payload = pcall(function()
                    return GetConfigRemoteFunc:InvokeServer()
                end)

                IsRepullingConfigs = false

                if not didSucceed or not payload then
                    return
                end

                CachedConfigs = payload.configs
                IdByIdentifier = payload.idByIdentifier
                IdentifierByConfigId = payload.identifierByConfigId

                -- OnChanged and Observe resolve their identifier when fired, so they support
                -- subscribing to a config that does not exist yet. Without this they never heard
                -- about the config they were waiting for.
                ConfigUpdatedSignal:Fire(configId, changes, nil)
            end)
            return
        end

        local oldConfig = DeepCopy(config)

        for _, change in changes do
            local target = config
            for index, pathSegment in change.path do
                if index == #change.path then
                    target[pathSegment] = change.newValue
                else
                    target = target[pathSegment]
                end
            end
        end

        -- Shared by every listener rather than copied for each, so nothing may change it. The change
        -- list is not frozen: its values were just written into the live cache above.
        DeepFreeze(oldConfig)
        ConfigUpdatedSignal:Fire(configId, changes, oldConfig)
    end)

    task.spawn(function()
        local payload = GetConfigRemoteFunc:InvokeServer()
        --TODO: Make sure we actually got something
        CachedConfigs = payload.configs
        IdByIdentifier = payload.idByIdentifier
        IdentifierByConfigId = payload.identifierByConfigId
        ConfigsReady = true
        ConfigReadySignal:Fire()
    end)
end

--= Return Module =--
return ClientConfigs
