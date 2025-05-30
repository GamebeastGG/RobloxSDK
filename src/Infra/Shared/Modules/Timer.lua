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

local RunService = game:GetService("RunService")

--= Dependencies =--

local Signal = shared.GBMod("Signal") ---@module Signal
local Cleaner = shared.GBMod("Cleaner") ---@module Cleaner

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function Timer.new(timeSeconds : number)
    local self = setmetatable({}, Timer)

    self._cleaner = Cleaner.new()
    self._startTick = tick()
    self._timedOutSignal = Signal.new()

    self._cleaner:Add(self._timedOutSignal)
    self._cleaner:Add(RunService.Heartbeat:Connect(function()
        if tick() - self._startTick >= timeSeconds then
            self._timedOutSignal:Fire(true)
            self:Destroy()
        end
    end))

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