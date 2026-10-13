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

local GetRemote = require(script.Parent.Parent.Parent.Shared.Modules.GetRemote)
local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal)
local SignalConnection = require(script.Parent.Parent.Parent.Shared.Modules.Signal.SignalConnection)

--= Types =--

--= Object References =--

local GetConfigRemoteFunc = GetRemote("Function", "Get")
local ConfigChangedRemote = GetRemote("Event", "ConfigChanged")
local ConfigIdentitiesChangedRemote = GetRemote("Event", "ConfigIdentitiesChanged")
-- Arguments aren't copied per listener, since every Configs:Observe adds one. Listeners only read
-- them, and the old config a change carries is frozen.
local ConfigUpdatedSignal = Signal.new({ copyArguments = false })
local ConfigReadySignal = Signal.new({ copyArguments = false })

--= Constants =--

-- The old view of a config the client didn't have yet, matching the server's
local EMPTY_CONFIG = table.freeze({})

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

-- The key in `container` a path segment refers to: as given, or as an array index, since privacy
-- and Get paths are strings.
local function ResolveSegment(container, segment)
    if container[segment] == nil then
        local index = tonumber(segment)
        if index ~= nil and container[index] ~= nil then
            return index
        end
    end
    return segment
end

local function ResolveConfigId(identifier : string) : number?
    return IdByIdentifier[tostring(identifier)]
end

-- Every cached config document keyed by consumer identifier. Uses IdentifierByConfigId since
-- IdByIdentifier holds every spelling (id, name, alias) of each config.
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
        -- Stops at non-table values. A segment like "2" also indexes arrays, since paths are strings.
        if type(target) ~= "table" then
            return nil
        end
        target = target[ResolveSegment(target, path[index])]
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
                elseif tostring(changeSegment) ~= tostring(targetConfig[index]) then
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
    -- The server sends its identifier maps whenever a config is renamed, given an alias, created or
    -- deleted. Updates before the initial payload are ignored, since it carries them too.
    ConfigIdentitiesChangedRemote.OnClientEvent:Connect(function(idByIdentifier, identifierByConfigId)
        if not ConfigsReady or type(idByIdentifier) ~= "table" or type(identifierByConfigId) ~= "table" then
            return
        end

        IdByIdentifier = idByIdentifier
        IdentifierByConfigId = identifierByConfigId

        -- A deleted config's values are cleared by its last change, so only the entry is left to drop
        for configKey in CachedConfigs do
            if identifierByConfigId[configKey] == nil then
                CachedConfigs[configKey] = nil
            end
        end

        -- A new config starts empty; its values arrive as changes
        for configKey in identifierByConfigId do
            if CachedConfigs[configKey] == nil then
                CachedConfigs[configKey] = {}
            end
        end
    end)

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

                -- So OnChanged and Observe subscribed before this config existed still fire
                ConfigUpdatedSignal:Fire(configId, changes, EMPTY_CONFIG)
            end)
            return
        end

        local oldConfig = DeepCopy(config)

        for _, change in changes do
            local path = change.path

            -- An empty path is the whole config: the server sends one when an entire config becomes
            -- private (no value) or public again (its full value).
            if #path == 0 then
                config = if type(change.newValue) == "table" then change.newValue else {}
                CachedConfigs[configKey] = config
                continue
            end

            local target = config
            for index, pathSegment in path do
                local key = ResolveSegment(target, pathSegment)
                if index == #path then
                    target[key] = change.newValue
                    break
                end

                local child = target[key]
                if type(child) ~= "table" then
                    -- Parent missing or not a table (e.g. removed earlier in this batch). A removal
                    -- has nothing left to do, a value goes into a fresh table.
                    if change.newValue == nil then
                        break
                    end
                    child = {}
                    target[key] = child
                end
                target = child
            end
        end

        -- Shared by every listener, so frozen. The change list isn't, since its values were just
        -- written into the live cache.
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
