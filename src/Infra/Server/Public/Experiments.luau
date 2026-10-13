--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Experiments.luau

    Description:
        Server-side API for experiment assignments and targeting properties.

--]]

--= Root =--
local Experiments = { }

--= Roblox Services =--

--= Dependencies =--

local InternalExperiments = require(script.Parent.Parent.Modules.InternalExperiments) ---@module InternalExperiments
local ServerGate = require(script.Parent.Parent.Modules.ServerGate) ---@module ServerGate
local Types = require(script.Parent.Parent.Parent.Types)

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

-- Per-player assignment subscriptions, disconnected when the player leaves
local SubscriptionsByPlayer = {} :: { [Player] : { RBXScriptConnection } }

--= Public Variables =--

--= Internal Functions =--

-- Identifies an assignment set by its experiments, groups and sources
local function GetAssignmentsKey(assignments : { Types.ExperimentAssignment }) : string
    local parts = table.create(#assignments)
    for _, assignment in assignments do
        table.insert(parts, `{assignment.experimentId}:{assignment.groupId}:{assignment.source or ""}`)
    end
    return table.concat(parts, ",")
end

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
    Sets developer-defined targeting properties for a player, merged per key with existing
    ones (e.g. { vip = true, level = 12 }). Values must be strings, numbers, booleans, or
    lists of one of those types (max 100 items). Changing a property re-resolves the
    player's assignments.
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
    Sets developer-defined targeting properties for this server, merged per key with existing
    ones. Player assignment requests see them too, though a player's own property with the
    same key wins. Changing a property re-resolves server and player assignments.
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
    Returns the player's active experiment assignments, one per experiment they're in.
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
    local connection = InternalExperiments.OnPlayerAssignmentsChanged:Connect(function(changedPlayer : Player)
        if changedPlayer == player then
            callback(BuildAssignments(player))
        end
    end)

    -- Disconnected when the player leaves, see the removal handler below
    local subscriptions = SubscriptionsByPlayer[player]
    if not subscriptions then
        subscriptions = {}
        SubscriptionsByPlayer[player] = subscriptions
    end
    table.insert(subscriptions, connection)

    return connection
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
    -- A player's first resolution reaches both listeners below, so a set identical to the last
    -- one delivered is skipped
    local lastDeliveredKey : string? = nil
    local function deliver(assignments : { Types.ExperimentAssignment })
        local key = GetAssignmentsKey(assignments)
        if key == lastDeliveredKey then
            return
        end
        lastDeliveredKey = key
        callback(assignments)
    end

    local onChangedSignal = self:OnAssignmentsChangedForPlayer(player, deliver)

    InternalExperiments:OnAssignmentsResolvedForPlayer(player, function()
        if onChangedSignal.Connected then
            deliver(BuildAssignments(player))
        end
    end)

    return onChangedSignal
end

--[[
    DEPRECATED: Use GetAssignmentsForPlayer / GetServerAssignments instead.

    Returns only the first active assignment, player assignments before server ones.
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

--= Initializers =--
do
    ServerGate:OnPlayerRemoved(function(player : Player)
        local subscriptions = SubscriptionsByPlayer[player]
        SubscriptionsByPlayer[player] = nil

        -- Deferred so subscriptions still hear the assignment change that another listener on this
        -- signal fires when it clears the player's assignments
        task.defer(function()
            for _, subscription in subscriptions or {} do
                subscription:Disconnect()
            end
        end)
    end)
end

--= Return Module =--
return Experiments
