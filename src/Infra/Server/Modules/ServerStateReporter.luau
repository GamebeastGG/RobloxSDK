--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    ServerStateReporter.luau

    Description:
        Tracks various metrics, records them to MetricCollector. Records
        incoming metrics from ClientExporter. Reports the server state to
        the backend.      
]]

--= Root =--
local ServerStateReporter = {}

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--
local GBRequests = shared.GBMod("GBRequests") ---@module GBRequests
local MetricCollector = shared.GBMod("MetricCollector") ---@module MetricCollector
local GetRemote = shared.GBMod("GetRemote") ---@module GetRemote
local Utilities = shared.GBMod("Utilities") ---@module Utilities

--= Types =--
type ClientMetricReport = {
    MemoryUsage: {number},
    PhysicsFps: {number},
    Ping: {number}
}

--= Object References =--
local ExportMetricsRemote = GetRemote("Event", "ExportClientMetrics")

--= Constants =--
local PROBE_FREQUENCY = 1 -- seconds
local REPORT_FREQUENCY = 10 -- seconds

--= Variables =--

--= Interval Functions =--
-- turns an array of metric history into predefined aggregations
-- returns nil if the history is empty
local function AggregateMetric(metricHistory: {number})
    if not metricHistory  or #metricHistory == 0 then
        return nil
    end

    table.sort(metricHistory)

    -- definitions
    local firstValue = metricHistory[1]
    local min, max = firstValue, firstValue
    local sum = 0

    for _, metric in metricHistory do
        min = math.min(min, metric)
        max = math.max(max, metric)
        sum += metric;
    end

    return {
        min = min,
        max = max,
        sum = sum,
        average = sum / #metricHistory,
        median = metricHistory[math.max(math.floor(#metricHistory / 2), 1)],
        p25 = metricHistory[math.max(math.floor(#metricHistory * 0.25), 1)],
        p75 = metricHistory[math.max(math.floor(#metricHistory * 0.75), 1)],
        p90 = metricHistory[math.max(math.floor(#metricHistory * 0.90), 1)],
        p99 = metricHistory[math.max(math.floor(#metricHistory * 0.99), 1)]
    }
end

--= API Functions =--

-- Send server state report to GB
function ServerStateReporter:SendServerStateReport()
    local serverStateReport = self:PrepareServerStateReport()
    local serverId = Utilities.getServerId()

    GBRequests:GBRequest(`v1/servers/roblox/{serverId}`, serverStateReport)
end

-- Prepares the server state report
function ServerStateReporter:PrepareServerStateReport()
    local players = Players:GetPlayers()
    local userIds = {}
    for _, player in players do
        table.insert(userIds, player.UserId)
    end

    -- read metrics from collector
    local metricHistory = MetricCollector:ReadAndResetAllMetrics()
    
    -- construct the server state report
    local serverStateReport = {
        timestamp = DateTime.now():ToIsoDate(),
        rootPlaceId = game.PlaceId,
        universeId = game.GameId,
        placeVersion = game.PlaceVersion,
        players = userIds,
        metadata = {
            clientPing = AggregateMetric(metricHistory.ClientPing),
            --clientMemoryUsage = AggregateMetric(metricHistory.ClientMemoryUsage),
            clientFps = AggregateMetric(metricHistory.ClientPhysicsFps),
            --serverMemoryUsage = AggregateMetric(metricHistory.MemoryUsage),
            serverFps = AggregateMetric(metricHistory.PhysicsFps),
            serverAgeSeconds = workspace.DistributedGameTime,
            matchmakingType = game.MatchmakingType.Name,
            privateServerId = game.PrivateServerId,
            privateServerOwnerId = game.PrivateServerOwnerId
        }
    }

    return serverStateReport
end

function ServerStateReporter:Init()
    -- probe metrics on timer
    task.spawn(function()
        while task.wait(PROBE_FREQUENCY) do
            --MetricCollector:ReportMetric("MemoryUsage", Stats:GetTotalMemoryUsageMb())
            MetricCollector:ReportMetric("PhysicsFps", workspace:GetRealPhysicsFPS())
        end
    end)

    -- report the server state on a timer
    task.spawn(function()
        while task.wait(REPORT_FREQUENCY) do
            self:SendServerStateReport()
        end
    end)

    ExportMetricsRemote.OnServerEvent:Connect(function(player : Player, metrics : ClientMetricReport)
        -- only use the first 10 values
        -- this is because the client will report the history every 10 seconds,
        -- and probes every 1 second, so in theory it's always going to be 10 values
        -- this also prevents the client from sending unlimited values 
        for i = 1, 10 do
            --local memoryUsage = metrics.MemoryUsage[i]
            local physicsFps = metrics.PhysicsFps[i]
            local ping = metrics.Ping[i]

            --[[ ensure memory is a number, and is within reasonable bounds
            if type(memoryUsage) == "number" and memoryUsage >= 0 and memoryUsage < 100000 then
                MetricCollector:ReportMetric("ClientMemoryUsage", memoryUsage)
            end]]

            -- ensure fps is a number and within reasonable bounds
            -- 360 is written here since refresh rates are usually under 360
            if type(physicsFps) == "number" and physicsFps >= 0 and physicsFps <= 360 then
                MetricCollector:ReportMetric("ClientPhysicsFps", physicsFps)
            end

            if type(ping) == "number" and ping >= 0 and ping <= 100000 then
                MetricCollector:ReportMetric("ClientPing", ping)
            end
        end
    end)

    -- send report on final request call
    GBRequests:OnFinalRequestCall(function()
        self:SendServerStateReport()
    end)
end

return ServerStateReporter