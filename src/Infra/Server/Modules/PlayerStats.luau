--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    PlayerStats.luau
    
    Description:
        No description provided.
    
--]]

--= Root =--
local PlayerStats = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

--= Types =--

--= Object References =--

--= Constants =--

local DEFAULT_SCHEMA = {
    session_length = function()
		return tick()
	end,
    teleporting = function()
        return false
    end
}

--= Variables =--

local SessionData = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function PlayerStats:GetStats(player : Player)
    return SessionData[player]
end

function PlayerStats:GetStat(player : Player, stat : string)
    if not SessionData[player] then
        return nil
    end
    return SessionData[player][stat]
end

function PlayerStats:Clear(player : Player)
    SessionData[player] = nil
end

function PlayerStats:Reset(player : Player)
    SessionData[player] = {}
    for statName, initializer in DEFAULT_SCHEMA do
        SessionData[player][statName] = initializer()
    end
end

--= Initializers =--
function PlayerStats:Init()

    -- Set up state for player session
    for _, player in Players:GetPlayers() do
        self:Reset(player)
    end

    Players.PlayerAdded:Connect(function(player)
        self:Reset(player)
    end)

    -- Other SDK modules may rely on state stored in this module for various purposes.
    -- Because various modules might rely on this state, it's not safe for them to call clearPlayerSessionData themselves.
    -- Run with delay to allow time to process and then clear to avoid memory leaks. Not likely worth doing some fancy dependency/roll call system.
    Players.PlayerRemoving:Connect(function(player)
        task.wait(3)
        self:Clear(player)
    end)
end

--= Return Module =--
return PlayerStats