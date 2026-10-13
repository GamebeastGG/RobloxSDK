--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Configs.lua
    
    Description:
        Server-side API for accessing and observing configuration data.
    
--]]

--= Root =--
local Configs = { }

--= Roblox Services =--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local InternalConfigs = require(script.Parent.Parent.Modules.InternalConfigs) ---@module InternalConfigs

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Configs:Get(path : string | { string }) : any
    return InternalConfigs:Get(nil, path)
end

function Configs:GetForPlayer(player: Player, path: string | {string}) : any
    return InternalConfigs:Get(player, path)
end

function Configs:Observe(targetConfig : string | { string }, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    local onChangedSignal = self:OnChanged(targetConfig, callback) -- OnChanged doesn't fire for the initial load

    task.spawn(function() -- Get yields until ready, so this also covers the initial load
        local data = self:Get(targetConfig)

        if onChangedSignal.Connected then
            callback(data, nil)
        end
    end)

    return onChangedSignal
end

function Configs:ObserveForPlayer(player: Player, targetConfig: string | {string}, callback: (newValue: any, oldValue: any) -> ()): RBXScriptConnection
    local onChangedSignal = self:OnChangedForPlayer(player, targetConfig, callback)

    task.spawn(function()
        local data = self:GetForPlayer(player, targetConfig)
        if onChangedSignal.Connected then
            callback(data, nil)
        end
    end)

    return onChangedSignal
end

function Configs:OnChanged(targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    return InternalConfigs:OnChanged(nil, targetConfig, callback)
end

function Configs:OnChangedForPlayer(player: Player, targetConfig: string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    return InternalConfigs:OnChanged(player, targetConfig, callback)
end

function Configs:OnReady(callback : (configs : any) -> ()) : RBXScriptConnection
    return InternalConfigs:OnReady(callback)
end

function Configs:IsReady() : boolean
    return InternalConfigs:IsReady()
end

--= Return Module =--
return Configs