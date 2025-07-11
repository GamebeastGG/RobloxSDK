--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Cleaner.lua
    
    Description:
        A utility module for managing and cleaning up objects and connections.
    
--]]

--= Root =--

local Cleaner = {}
Cleaner.__index = Cleaner

--= Roblox Services =--

--= Dependencies =--

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function Cleaner.new()
    local self = setmetatable({}, Cleaner)

    self._toClean = {}

    return self
end

--= Methods =--

function Cleaner:Add(object : Instance | RBXScriptConnection | {Destroy : () -> ()})
    if typeof(object) == "table" and typeof(object.Destroy) ~= "function" then
        error("Object does not have a Destroy method.")
    end

    table.insert(self._toClean, object)
end

function Cleaner:Destroy()
    for _, object in ipairs(self._toClean) do
        if typeof(object) == "RBXScriptConnection" then
            object:Disconnect()
        else
            object:Destroy()
        end
    end
end

Cleaner.Clean = Cleaner.Destroy

return Cleaner