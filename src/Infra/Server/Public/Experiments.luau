--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Experiments.luau

    Description:
        Server-side API for reading experiment assignments for players and the server.

--]]

--= Root =--
local Experiments = { }

--= Roblox Services =--

--= Dependencies =--

local InternalExperiments = require(script.Parent.Parent.Modules.InternalExperiments) ---@module InternalExperiments
local Types = require(script.Parent.Parent.Parent.Types)

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

local function BuildAssignments(player : Player?) : { Types.ExperimentAssignment }
    local assignments = {}

    for _, record in InternalExperiments:GetAssignments(player) do
        if record.status ~= "active" or not record.groupId then
            continue
        end

        local metadata = InternalExperiments:GetAssignmentMetadata(record.experimentId, record.groupId)
        if not metadata then
            continue
        end

        table.insert(assignments, {
            experimentId = record.experimentId,
            experimentName = metadata.experimentName,
            groupId = record.groupId,
            groupLabel = metadata.groupLabel,
            unitType = if player then "user" else "server",
            source = record.source,
        })
    end

    table.sort(assignments, function(a, b)
        return a.experimentId < b.experimentId
    end)

    return assignments
end

local function AssertPlayer(player : any, methodName : string)
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        error(`Experiments:{methodName} expects a Player as its first argument.`, 3)
    end
end

local function AssertPropertyTable(properties : any, methodName : string)
    if type(properties) ~= "table" then
        error(`Experiments:{methodName} expects a table of properties.`, 3)
    end
end

--= API Functions =--

--[[
    Sets developer-defined properties for a player, merged per key with any set
    previously. They are sent as `context.properties` with experiment assignment
    requests so experiments can target on them (e.g. { vip = true, level = 12 }).

    Values must be strings, numbers, booleans, or lists of those (max 100 items).
    Changing a property re-resolves the player's assignments.
]]
function Experiments:SetPlayerProperties(player : Player, properties : { [string] : Types.ExperimentPropertyValue })
    AssertPlayer(player, "SetPlayerProperties")
    AssertPropertyTable(properties, "SetPlayerProperties")
    InternalExperiments:SetPlayerProperties(player, properties)
end

--[[
    Sets a single developer-defined property for a player. Passing nil clears it.
]]
function Experiments:SetPlayerProperty(player : Player, key : string, value : Types.ExperimentPropertyValue?)
    AssertPlayer(player, "SetPlayerProperty")
    InternalExperiments:SetPlayerProperty(player, key, value)
end

function Experiments:GetPlayerProperties(player : Player) : { [string] : Types.ExperimentPropertyValue }
    AssertPlayer(player, "GetPlayerProperties")
    return InternalExperiments:GetPlayerProperties(player)
end

--[[
    Sets developer-defined properties for this server, merged per key with any set
    previously. They are sent with server assignment requests, and as shared context
    for player assignment requests (a player's own property with the same key wins).
    Changing a property re-resolves server and player assignments.
]]
function Experiments:SetServerProperties(properties : { [string] : Types.ExperimentPropertyValue })
    AssertPropertyTable(properties, "SetServerProperties")
    InternalExperiments:SetServerProperties(properties)
end

--[[
    Sets a single developer-defined property for this server. Passing nil clears it.
]]
function Experiments:SetServerProperty(key : string, value : Types.ExperimentPropertyValue?)
    InternalExperiments:SetServerProperty(key, value)
end

function Experiments:GetServerProperties() : { [string] : Types.ExperimentPropertyValue }
    return InternalExperiments:GetServerProperties()
end

--[[
    Returns the player's active experiment assignments. Multiple experiments can be
    active at once (at most one per base configuration).
]]
function Experiments:GetAssignmentsForPlayer(player : Player) : { Types.ExperimentAssignment }
    return BuildAssignments(player)
end

--[[
    Returns the server's active experiment assignments.
]]
function Experiments:GetServerAssignments() : { Types.ExperimentAssignment }
    return BuildAssignments(nil)
end

function Experiments:OnAssignmentsChangedForPlayer(player : Player, callback : (assignments : { Types.ExperimentAssignment }) -> ()) : RBXScriptConnection
    return InternalExperiments.OnPlayerAssignmentsChanged:Connect(function(changedPlayer : Player)
        if changedPlayer == player then
            callback(BuildAssignments(player))
        end
    end)
end

function Experiments:OnServerAssignmentsChanged(callback : (assignments : { Types.ExperimentAssignment }) -> ()) : RBXScriptConnection
    return InternalExperiments.OnServerAssignmentsChanged:Connect(function()
        callback(BuildAssignments(nil))
    end)
end

--[[
    Calls back with the player's assignments once they are first resolved, then again
    whenever they change.
]]
function Experiments:ObserveAssignmentsForPlayer(player : Player, callback : (assignments : { Types.ExperimentAssignment }) -> ()) : RBXScriptConnection
    local onChangedSignal = self:OnAssignmentsChangedForPlayer(player, callback)

    InternalExperiments:OnAssignmentsResolvedForPlayer(player, function()
        if onChangedSignal.Connected then
            callback(BuildAssignments(player))
        end
    end)

    return onChangedSignal
end

--[[
    Returns information about the experiment group currently assigned to the player, if any.

    DEPRECATED: Multiple experiments can now be active at once; this returns only the
    first active assignment (player assignments first, then server assignments).
    Use GetAssignmentsForPlayer / GetServerAssignments instead.
]]
function Experiments:GetGroupForPlayer(player : Player) : Types.ExperimentGroupMetadata?
    local assignment = BuildAssignments(player)[1] or BuildAssignments(nil)[1]
    if not assignment then
        return nil
    end

    return {
        experimentName = assignment.experimentName,
        groupName = assignment.groupLabel,
    }
end

--= Return Module =--
return Experiments
