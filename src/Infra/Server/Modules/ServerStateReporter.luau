--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    ServerStateReporter.luau

    Description:
        Collects server metrics and client metrics from ClientMetricExporter,
        and reports the server state to the backend.
]]

--= Root =--
local ServerStateReporter = {}

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--
local GBRequests = require(script.Parent.GBRequests) ---@module GBRequests
local MetricCollector = require(script.Parent.Parent.Parent.Shared.Modules.MetricCollector) ---@module MetricCollector
local GetRemote = require(script.Parent.Parent.Parent.Shared.Modules.GetRemote) ---@module GetRemote
local Utilities = require(script.Parent.Utilities) ---@module Utilities
local DataCache = require(script.Parent.Parent.Parent.Shared.Modules.DataCache)

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
-- Most client metric reports accepted from one player per server report, so a client firing in a
-- loop can't grow the metric history without bound. Clients report every 10s.
local MAX_CLIENT_METRIC_REPORTS_PER_SERVER_REPORT = 10
-- How often the report loop rechecks serverReportRate, so a lowered rate applies quickly
local REPORT_RECHECK_INTERVAL = 5 -- seconds

--= Variables =--

-- Client metric reports accepted from each player since the last server report
local ClientMetricReportsByPlayer : { [Player] : number } = {}

--= Interval Functions =--
-- Aggregates a metric history, nil if empty. Sorts the history in place.
local function AggregateMetric(metricHistory: {number})
    if not metricHistory  or #metricHistory == 0 then
        return nil
    end

    table.sort(metricHistory)

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

-- Reads and resets the collected metrics
function ServerStateReporter:PrepareServerStateReport()
    local players = Players:GetPlayers()
    local userIds = {}
    for _, player in players do
        table.insert(userIds, player.UserId)
    end

    local metricHistory = MetricCollector:ReadAndResetAllMetrics()
    -- Each report starts a new window for the per-player cap on client metric reports
    table.clear(ClientMetricReportsByPlayer)
    
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

    -- report the server state every serverReportRate seconds
    task.spawn(function()
        local lastReportTime = tick()

        while true do
            local remaining = DataCache:Get("Settings").serverReportRate - (tick() - lastReportTime)
            if remaining > 0 then
                task.wait(math.min(remaining, REPORT_RECHECK_INTERVAL))
                continue
            end

            lastReportTime = tick()
            self:SendServerStateReport()
        end
    end)

    ExportMetricsRemote.OnServerEvent:Connect(function(player : Player, metrics : ClientMetricReport)
        if type(metrics) ~= "table" or type(metrics.PhysicsFps) ~= "table" or type(metrics.Ping) ~= "table" then
            return
        end

        local reportCount = (ClientMetricReportsByPlayer[player] or 0) + 1
        if reportCount > MAX_CLIENT_METRIC_REPORTS_PER_SERVER_REPORT then
            return
        end
        ClientMetricReportsByPlayer[player] = reportCount

        -- Only the first 10, since the client probes every second and reports every 10s
        for i = 1, 10 do
            --local memoryUsage = metrics.MemoryUsage[i]
            local physicsFps = metrics.PhysicsFps[i]
            local ping = metrics.Ping[i]

            --[[ ensure memory is a number, and is within reasonable bounds
            if type(memoryUsage) == "number" and memoryUsage >= 0 and memoryUsage < 100000 then
                MetricCollector:ReportMetric("ClientMemoryUsage", memoryUsage)
            end]]

            -- Refresh rates are usually under 360
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