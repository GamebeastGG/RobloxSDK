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
        -- Lets a Fire already in progress skip it, since it iterates over a snapshot
        callbackData.disconnected = true

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
            -- Only the first fire counts; this stays connected until the waiting thread resumes
            if isFired then
                return
            end
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

--[[
    Calls every listener connected when the fire begins.

    Iterates over a snapshot of the listeners. Walking the live list let a listener that connected
    another one mid-fire shift the list under the loop, so the next listener in line was silently
    skipped. Now a listener connected during a fire waits for the next one, and a listener
    disconnected during a fire (by an earlier listener) is not called, matching RBXScriptSignal.
]]
function Signal:Fire(...)
    local argCount = select("#", ...)

    for _, callbackData in table.clone(self._callbacks) do
        if callbackData.disconnected then
            continue
        end

        -- Disconnected before it runs, so a fire from inside its own callback can't call it again
        if callbackData.isOnce then
            callbackData.connection:Disconnect()
        end

        local dataToSend = table.create(argCount)
        for argIndex = 1, argCount do
            local arg = select(argIndex, ...)
            dataToSend[argIndex] = DeepCopy(arg)
        end

        task.spawn(callbackData.callback, table.unpack(dataToSend, 1, argCount))
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