--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    SignalTimeout.lua
    
    Description:
        Wrap a signal with a timeout.
    
--]]

--= Root =--

local SignalTimeout = {}
SignalTimeout.__index = SignalTimeout

--= Roblox Services =--

local RunService = game:GetService("RunService")

--= Dependencies =--

local Signal = require(script.Parent.Signal) ---@module Signal
local Cleaner = require(script.Parent.Cleaner) ---@module Cleaner

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function SignalTimeout.new(timeoutSeconds : number, targetSignal : RBXScriptSignal, validator : ((...any) -> boolean)?)
    local self = setmetatable({}, SignalTimeout)

    self._cleaner = Cleaner.new()
    self._timeoutSeconds = timeoutSeconds
    self._validator = validator
    self._startTick = tick()
    self._timedOutSignal = Signal.new()
    self._targetSignal = targetSignal

    self._cleaner:Add(self._timedOutSignal)
    self._cleaner:Add(RunService.Heartbeat:Connect(function()
        if tick() - self._startTick >= self._timeoutSeconds then
            self._timedOutSignal:Fire(true)
            self:Destroy()
        end
    end))

    self._cleaner:Add(self._targetSignal:Connect(function(...)
        if self._validator and not self._validator(...) then
            return
        end

        self._timedOutSignal:Fire(false, ...)
        self:Destroy()
    end))

    return self
end

--= Methods =--

function SignalTimeout:Wait() : (boolean, ...any)
    return self._timedOutSignal:Wait()
end

function SignalTimeout:Once(callback : (boolean, ...any)  -> ()) : RBXScriptConnection
    return self._timedOutSignal:Connect(callback)
end

function SignalTimeout:Destroy()
    self._cleaner:Destroy()
end

return SignalTimeout