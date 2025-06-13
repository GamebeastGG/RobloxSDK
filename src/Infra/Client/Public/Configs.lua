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

function Configs:OnReady(callback : (configs : any) -> ()) : RBXScriptConnection
    return ClientConfigs:OnReady(callback)
end

function Configs:IsReady() : boolean
    return ClientConfigs:IsReady()
end

-- Added for type consistency, but these methods are server-only.

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