--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Heatmap.luau
    
    Description:
        Heatmap API for Gamebeast SDK.
    
--]]

--= Root =--
local Heatmap = { }

--= Roblox Services =--

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests

--= Types =--

--= Object References =--

--= Constants =--

local POSITION_ROUND_TO = 10
local DEFAULT_APPEARANCE_INFO = {
    color = Color3.fromRGB(255, 255, 255),
    shape = "Square"
}

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

local function RoundVector3(vector : Vector3, roundTo : number?) : Vector3
    roundTo = roundTo or POSITION_ROUND_TO

    vector *= roundTo
    local newVector = Vector3.new(math.round(vector.X), math.round(vector.Y), math.round(vector.Z))
    return newVector / roundTo
end

--= API Functions =--

function Heatmap:RegisterHeatmap(name : string, positionA : Vector3, positionB : Vector3)
    GBRequests:GBRequestAsync("v1/heatmap", {
        ["name"] = name,
        ["positionA"] = RoundVector3(positionA),
        ["positionB"] = RoundVector3(positionB)
    })
end

function Heatmap:AddHeatmapWaypoint(heatmapName : string, waypointName : string, position : Vector3, appearanceInfo : { color : Color3, shape : "Square" | "Circle"})
    appearanceInfo = DEFAULT_APPEARANCE_INFO or appearanceInfo
    
    -- Set defaults if not set.
    for key, value in pairs(DEFAULT_APPEARANCE_INFO) do
        if appearanceInfo[key] == nil then
            appearanceInfo[key] = value
        end
    end

    -- Convert color3 to hex
    appearanceInfo.color = appearanceInfo.color:ToHex()
    
    GBRequests:GBRequestAsync("v1/heatmap/waypoint", {
        ["heatmapName"] = heatmapName,
        ["waypointName"] = waypointName,
        ["position"] = RoundVector3(position),
        ["appearanceInfo"] = appearanceInfo
    })
end

--= Return Module =--
return Heatmap