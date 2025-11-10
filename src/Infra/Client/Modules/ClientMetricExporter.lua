--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    ClientMetricExporter.luau

    Description:
        Tracks various metrics on a timer and exports them to the server.
]]

--= Root =--
local ClientMetricExporter = {}

--= Roblox Services =--
local Players = game:GetService("Players")

--= Dependencies =--
local GetRemote = shared.GBMod("GetRemote")
local MetricCollector = shared.GBMod("MetricCollector") ---@module MetricCollector

--= Types =--

--= Object References =--
local ExportMetricsRemote = GetRemote("Event", "ExportClientMetrics")

--= Constants =--
-- how often the metric collector will probe for built in metrics
local PROBE_FREQUENCY = 1 -- seconds
-- how often the client instance of MetricCollector will report it's metrics
-- to the server
local REPORT_FREQUENCY = 10 -- seconds

function ClientMetricExporter:Init()
    -- probe metrics on timer
    task.spawn(function()
        while task.wait(PROBE_FREQUENCY) do
            --NOTE: MemoryUsage disabled by Roblox. 
            --MetricCollector:ReportMetric("MemoryUsage", Stats:GetTotalMemoryUsageMb())
            MetricCollector:ReportMetric("PhysicsFps", workspace:GetRealPhysicsFPS())
            MetricCollector:ReportMetric("Ping", Players.LocalPlayer:GetNetworkPing())
        end
    end)

    -- if on client, report metrics on timer
    task.spawn(function()
        while task.wait(REPORT_FREQUENCY) do
            local metricHistory = MetricCollector:ReadAndResetAllMetrics()
            ExportMetricsRemote:FireServer(metricHistory)
        end
    end)
end

return ClientMetricExporter