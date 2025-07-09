--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    PlayerStats.luau
    
    Description:
        Holds general player state data.
    
--]]

--= Root =--
local PlayerStats = { }

--= Roblox Services =--

local Players = game:GetService("Players")

--= Dependencies =--

local Signal = shared.GBMod("Signal") ---@module Signal
local Schema = shared.GBMod("Schema") ---@module Schema

--= Types =--

--= Object References =--

local DefaultStatsResolved = Signal.new()

--= Constants =--

local DEFAULT_SCHEMA = Schema.new({
    join_time = { default = function()
        return os.time()
    end, type = "number" },
    teleporting_to = { default = function()
        return nil 
    end, type = {"number", "nil"} }
})

--= Variables =--

local SessionData = {}

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function PlayerStats:SetStat(player : Player, stat : string, value : any)
    if not SessionData[player] and player.Parent then
        self:Reset(player)
    end

    if not DEFAULT_SCHEMA:HasKey(stat) then
        error("Cannot set stat: " .. stat)
    end

    SessionData[player][stat] = value
end

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
    SessionData[player] = DEFAULT_SCHEMA:GetDefault()

    DefaultStatsResolved:Fire(player, SessionData[player])
end

function PlayerStats:OnDefaultStatsResolved(player : Player, callback : (stats : { [string] : any }) -> nil) : RBXScriptSignal
    local connection; connection = DefaultStatsResolved:Connect(function(resolvedPlayer, stats)
        if resolvedPlayer == player then
            callback(stats)
            connection:Disconnect()
        end
    end)

    if SessionData[player] then
        connection:Disconnect() -- Disconnect immediately if already resolved
        task.spawn(function()
            callback(SessionData[Players.LocalPlayer])
        end)
    end
    return connection
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
        task.defer(function()
            self:Clear(player)
        end)
    end)
end

--= Return Module =--
return PlayerStats