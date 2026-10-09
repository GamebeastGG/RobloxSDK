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

local Signal = require(script.Parent.Parent.Parent.Shared.Modules.Signal) ---@module Signal
local Schema = require(script.Parent.Parent.Parent.Shared.Modules.Schema) ---@module Schema
local ServerGate = require(script.Parent.ServerGate) ---@module ServerGate

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

local SessionData = ServerGate:GetCache() -- Cache for player session data, automatically cleared on player leave

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
            callback(SessionData[player])
        end)
    end
    return connection
end

--= Initializers =--
function PlayerStats:Init()
    ServerGate:OnPlayerAdded(function(player)
        self:Reset(player)
    end)
end

--= Return Module =--
return PlayerStats