-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.
--[[
    SignalConnection.lua
    
    Description:
        Emulates a RBXScriptConnection for signals, allowing for connection management
--]]

--= Root =--

local SignalConnection = {}
SignalConnection.__index = SignalConnection

--= Roblox Services =--

--= Dependencies =--

--= Types =--

export type SignalConnection = {
    Connected : boolean,
    Disconnect : (self : SignalConnection) -> ()
}

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function SignalConnection.new(onDisconnect : () -> ()?) : SignalConnection
    local self = setmetatable({}, SignalConnection)

    self.Connected = onDisconnect ~= nil
    self._callback = onDisconnect

    return self
end

--= Methods =--

function SignalConnection:Disconnect()
    if self.Connected then
        task.spawn(self._callback)
    end
    
    self.Connected = false
end

SignalConnection.Destroy = SignalConnection.Disconnect

return SignalConnection