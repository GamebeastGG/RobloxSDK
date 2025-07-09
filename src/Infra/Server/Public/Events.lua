--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Events.lua
    
    Description:
        Public API for managing definined events.
    
--]]

--= Root =--
local Events = { }

--= Roblox Services =--

--= Dependencies =--

local EventsManager = shared.GBMod("EventsManager") ---@module EventsManager
local InternalConfigs = shared.GBMod("InternalConfigs") ---@module InternalConfigs

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Events:GetEventData(eventName : string)
    return InternalConfigs:GetEventData(eventName)
end

function Events:OnStart(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptConnection
    return EventsManager:OnStart(eventName, callback)
end

function Events:OnEnd(eventName : string, callback : (eventInfo : { [string] : any }) -> ()) : RBXScriptConnection
    return EventsManager:OnEnd(eventName, callback)
end

--= Return Module =--
return Events
