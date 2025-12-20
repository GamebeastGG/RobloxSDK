--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Cohorts.lua
    
    Description:
        Public API module for Cohorts Service.
    
--]]

--= Root =--
local Cohorts = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--= Dependencies =--

local InternalCohorts = shared.GBMod("InternalCohorts") ---@module InternalCohorts

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function Cohorts:GetCohortMembershipStatusAsync(cohortName : string, userIds : { number } ) : { [ number ] : boolean }
    return InternalCohorts:GetCohortMembershipStatusAsync(cohortName, userIds)
end

--= Return Module =--
return Cohorts