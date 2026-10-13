--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Timer.lua
    
    Description:
        Simple timer that fires a signal when the time is up.
    
--]]

--= Root =--

local Timer = {}
Timer.__index = Timer

--= Roblox Services =--

--= Dependencies =--

local Signal = require(script.Parent.Signal) ---@module Signal
local Cleaner = require(script.Parent.Cleaner) ---@module Cleaner

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function Timer.new(timeSeconds : number)
    local self = setmetatable({}, Timer)

    self._cleaner = Cleaner.new()
    self._timedOutSignal = Signal.new()

    self._cleaner:Add(self._timedOutSignal)

    -- Scheduled rather than checked per frame, since every pending player marker holds a timer
    local thread = task.delay(timeSeconds, function()
        self._timedOutSignal:Fire(true)
        self:Destroy()
    end)
    self._cleaner:Add({
        Destroy = function()
            -- Skipped while running, since the timer's own end destroys it from that thread
            if coroutine.status(thread) == "suspended" then
                task.cancel(thread)
            end
        end,
    })

    return self
end

--= Methods =--

function Timer:OnEnd(callback : (...any) -> ())
    return self._timedOutSignal:Once(function(timedOut, ...)
        if timedOut then
            callback(...)
        end
    end)
end

function Timer:Destroy()
    self._cleaner:Destroy()
end

return Timer