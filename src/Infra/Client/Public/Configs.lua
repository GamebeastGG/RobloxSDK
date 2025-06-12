--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Configs.lua
    
    Description:
        Public API module for accessing client-specific configuration data.
    
--]]

--= Root =--
local Configs = { }

--= Roblox Services =--

--= Dependencies =--

local ClientConfigs = shared.GBMod("ClientConfigs") ---@module ClientConfigs
local Signal = shared.GBMod("Signal") ---@module Signal

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Configs:Get(path : string | { string })
    return ClientConfigs:Get(path)
end

function Configs:Observe(targetConfig : string | { string }, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    local onChangedSignal = self:OnChanged(targetConfig, callback) -- OnChanged does not fire when OnReady fires.
    
    task.spawn(function() -- Get will yeild until ready, so this works as initial callback + wait for ready
        local data = self:Get(targetConfig)

        if onChangedSignal.Connected then
            callback(data, nil) -- Initial callback with nil oldValue
        end
    end)

    return onChangedSignal
end

function Configs:OnChanged(targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    return ClientConfigs:OnChanged(targetConfig, callback)
end

function Configs:OnReady(callback : (configs : any) -> ()) : RBXScriptSignal
    return ClientConfigs:OnReady(callback)
end

function Configs:IsReady() : boolean
    return ClientConfigs:IsReady()
end

--= Return Module =--
return Configs