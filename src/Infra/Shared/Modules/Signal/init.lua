-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.
--[[
    Signal.lua
    
    Description:
        Custom signal class that doesnt use Roblox's deffered signal system.
    
--]]

--= Root =--

local Signal = {}
Signal.__index = Signal

--= Dependencies =--

local SignalConnection = require(script.SignalConnection)

--= Types =--

export type SignalConnection = SignalConnection.SignalConnection

export type Signal = {
    Connect : (self : Signal, (...any) -> ()) -> SignalConnection,
    Once : (self : Signal, (...any) -> ()) -> SignalConnection,
    Wait : (self : Signal) -> ...any,
    Fire : (self : Signal, ...any) -> (),
    Destroy : (self : Signal) -> ()
}

--= Internal Functions =--

local function DeepCopy(t : any) : any
    if type(t) ~= "table" then
        return t
    end

    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = DeepCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

--= Constructor =--

function Signal.new() : Signal
    local self = setmetatable({}, Signal)

    self._callbacks = {} :: {isOnce : boolean, callback : (any) -> ()}

    return self
end

--= Methods =--

function Signal:_createConnection(isOnce : boolean, callback : (any) -> ()) : SignalConnection
    local callbackData = {
        isOnce = isOnce,
        callback = callback,
    }

    callbackData.connection = SignalConnection.new(function()
        local index = table.find(self._callbacks, callbackData)

        if index then
            table.remove(self._callbacks, index)
        end
    end)

    table.insert(self._callbacks, callbackData)

    return callbackData.connection
end

function Signal:Connect(callback : (any) -> ()) : SignalConnection
    return self:_createConnection(false, callback)
end

function Signal:Once(callback : (any) -> ()) : SignalConnection
    return self:_createConnection(true, callback)
end

function Signal:Wait() : ...any
    local isFired = false
    local data = nil

    local callbackData = {
        isOnce = false,
        callback = function(...)
            isFired = true
            data = table.pack(...)
        end
    }
    table.insert(self._callbacks, callbackData)

    repeat task.wait() until isFired

    local index = table.find(self._callbacks, callbackData)
    if index then
        table.remove(self._callbacks, index)
    end

    return table.unpack(data)
end

function Signal:Fire(...)
    local argCount = select("#", ...)
    local lastLength = #self._callbacks
    local currentIndex = 1
    while currentIndex <= #self._callbacks do
        local callbackData = self._callbacks[currentIndex]
        local dataToSend = table.create(argCount)
        for argIndex = 1, argCount do
            local arg = select(argIndex, ...)
            dataToSend[argIndex] = DeepCopy(arg)
        end

        task.spawn(callbackData.callback, table.unpack(dataToSend, 1, argCount))
        if callbackData.isOnce then
            callbackData.connection:Disconnect()
        end

        local newLength = #self._callbacks
        currentIndex += (1 - (lastLength - newLength))
        lastLength = newLength
    end
end

function Signal:Destroy()
    for _, callbackData in ipairs(self._callbacks) do
        if callbackData.connection then
            callbackData.connection:Disconnect()
        end
    end
end

return Signal