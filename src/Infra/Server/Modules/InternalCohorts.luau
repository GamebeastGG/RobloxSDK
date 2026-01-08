--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    InternalCohorts.luau
    
    Description:
        Internal module for cohort management.
    
--]]

--= Root =--
local InternalCohorts = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local Utilities = shared.GBMod("Utilities") ---@module Utilities

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function InternalCohorts:GetCohortMembershipStatusAsync(cohortName : string, userIds : { number } ) : { [ number ] : boolean }
    local success, result = GBRequests:GBRequestAsync("v1/cohorts/membership", {
            cohortName = cohortName,
            userIds = userIds
        })

    if not success then
        error("Failed to get cohort membership status: ".. tostring(result))
    else
        if result.cohortExists == false then
            error("Cohort '".. cohortName .. "' does not exist.", 3)
            return
        end

        local toReturn = {}
        for _, membership in result.users do
            toReturn[membership.userId] = membership.isMember
        end

        return toReturn
    end
end

--= Initializers =--
function InternalCohorts:Init()
    
end

--= Return Module =--
return InternalCohorts