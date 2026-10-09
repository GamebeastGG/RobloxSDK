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

--[[
    By default every listener gets its own deep copy of each argument, so one listener can't change
    what the next one sees. Pass `copyArguments = false` for signals whose arguments are large and
    only read: a config signal with ~1,600 listeners made ~1,600 copies of the configuration per
    fire. Its listeners then share the arguments, so they must not modify them.
]]
function Signal.new(options : { copyArguments : boolean? }?) : Signal
    local self = setmetatable({}, Signal)

    self._callbacks = {} :: {isOnce : boolean, callback : (any) -> ()}
    self._copyArguments = not (options and options.copyArguments == false)

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

--[[
    Yields until the next fire and returns its arguments.

    The thread is suspended and resumed by the fire itself. It used to poll a flag with
    `repeat task.wait() until isFired`, so every waiting thread was resumed every frame: with ~1,600
    config subscriptions waiting on the first payload, that was ~1,600 resumes per frame per client.
]]
function Signal:Wait() : ...any
    local thread = coroutine.running()

    self:_createConnection(true, function(...)
        -- A waiter whose thread was cancelled meanwhile has nothing left to resume
        if coroutine.status(thread) == "suspended" then
            task.spawn(thread, ...)
        end
    end)

    return coroutine.yield()
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
    local didFireOnce = false

    for _, callbackData in table.clone(self._callbacks) do
        if callbackData.disconnected then
            continue
        end

        -- Disconnected before it runs, so a fire from inside its own callback can't call it again.
        -- Marked here and removed in one pass below: disconnecting each one through its connection
        -- costs a search of the listener list apiece, which adds up with ~1,600 waiters.
        if callbackData.isOnce then
            callbackData.disconnected = true
            callbackData.connection.Connected = false
            didFireOnce = true
        end

        if self._copyArguments then
            local dataToSend = table.create(argCount)
            for argIndex = 1, argCount do
                local arg = select(argIndex, ...)
                dataToSend[argIndex] = DeepCopy(arg)
            end

            task.spawn(callbackData.callback, table.unpack(dataToSend, 1, argCount))
        else
            task.spawn(callbackData.callback, ...)
        end
    end

    if didFireOnce then
        local remaining = table.create(#self._callbacks)
        for _, callbackData in self._callbacks do
            if not callbackData.disconnected then
                table.insert(remaining, callbackData)
            end
        end
        self._callbacks = remaining
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