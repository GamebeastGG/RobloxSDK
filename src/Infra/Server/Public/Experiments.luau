local Experiments = {}

local InternalExperiments = shared.GBMod("InternalExperiments")
local Types = require(script.Parent.Parent.Parent.Types)

--[[
    Returns information about the experiment group currently assigned to the player, if any.
]]
function Experiments:GetGroupForPlayer(player: Player): Types.ExperimentGroupMetadata?
    local assignedGroupId = InternalExperiments.AssignedGroupIdByPlayer[player]
        or InternalExperiments.AssignedServerGroupId
    if not assignedGroupId then
        return nil
    end

    return InternalExperiments:GetActiveGroupMetadata(assignedGroupId)
end

return Experiments