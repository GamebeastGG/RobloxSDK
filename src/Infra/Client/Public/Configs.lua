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

local ClientConfigs = require(script.Parent.Parent.Modules.ClientConfigs) ---@module ClientConfigs

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Configs:Get(path : string | { string }) : any
    return ClientConfigs:Get(path)
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

function Configs:OnChanged(targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    return ClientConfigs:OnChanged(targetConfig, callback)
end

function Configs:OnReady(callback : (configs : any) -> ()) : RBXScriptConnection
    return ClientConfigs:OnReady(callback)
end

function Configs:IsReady() : boolean
    return ClientConfigs:IsReady()
end

-- Server-only, defined so the client and server modules share one type.

function Configs:GetForPlayer(player: Player, path: string | {string}) : any
    error("Configs:GetForPlayer is a server-only method. Use :Get instead.")
end

function Configs:ObserveForPlayer(player: Player, targetConfig: string | {string}, callback: (newValue: any, oldValue: any) -> ()): RBXScriptConnection
    error("Configs:ObserveForPlayer is a server-only method. Use :Observe instead.")
end

function Configs:OnChangedForPlayer(player: Player, targetConfig: string | {string}, callback : (newValue : any, oldValue : any) -> ()) : RBXScriptConnection
    error("Configs:OnChangedForPlayer is a server-only method. Use :OnChanged instead.")
end

--= Return Module =--
return Configs