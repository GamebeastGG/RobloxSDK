--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    MetricCollector.luau

    Description:
        Holds history for various metrics. Used for reporting server and 
        client memory usage, ping and fps.
]]

--= Root =--
local MetricCollector = {}

--= Roblox Services =--

--= Dependencies =--

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--
local MetricHistory: {[string]: {number}} = {}

--= API Functions =--

-- reports a metric to the collector. caches in history
function MetricCollector:ReportMetric(metric: string, value: number)
    if not metric then
        return
    end

    if typeof(value) ~= "number" then
        return
    end

    local metricHistory = MetricHistory[metric];
    if not metricHistory then
        metricHistory = {}
        MetricHistory[metric] = metricHistory
    end

    table.insert(metricHistory, value)
end

-- reads a metric, resetting the history
function MetricCollector:ReadAndResetMetric(metric: string): {number}
    local metricHistory = MetricHistory[metric]
    if not metricHistory then
        return {}
    end

    local metricData = table.clone(metricHistory)
    MetricHistory[metric] = {}

    return metricData
end

-- reads and resets all metrics in the collector
-- returns a dictionary of all metrics
function MetricCollector:ReadAndResetAllMetrics(): {[string]: {number}}
    local allMetrics = {}

    for metric, _ in MetricHistory do
        allMetrics[metric] = MetricCollector:ReadAndResetMetric(metric)
    end

    return allMetrics
end

return MetricCollector