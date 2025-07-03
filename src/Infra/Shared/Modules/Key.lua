--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    GetRemote.luau
    
    Description:
        An object that gets keys for the Gamebeast SDK.
    
--]]


--= Root =--

local Key = {}
Key.__index = Key

--= Roblox Services =--

--= Dependencies =--

local DataCache = shared.GBMod("DataCache") ---@module DataCache

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function Key.new(name : string)
    local self = setmetatable({}, Key)

    self._key = name

    return self
end

--= Methods =--

function Key:Get() : string
    return self._key .. DataCache:Get("SdkId")
end

function Key:Destroy()
    
end

return Key