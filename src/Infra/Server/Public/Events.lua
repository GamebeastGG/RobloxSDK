--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Events.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local Events = { }

--= Roblox Services =--

--= Dependencies =--

local EventsManager = shared.GBMod("EventsManager") ---@module EventsManager
local Configs = shared.GBMod("Configs") ---@module Configs

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Events:GetEventData(eventName : string)
    return Configs:GetEventData(eventName)
end

function Events:OnStart(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptSignal
    return EventsManager:OnStart(eventName, callback)
end

function Events:OnEnd(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptSignal
    return EventsManager:OnEnd(eventName, callback)
end

--= Return Module =--
return Events
