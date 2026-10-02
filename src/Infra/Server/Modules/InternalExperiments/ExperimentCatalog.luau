--!strict
--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	ExperimentCatalog.luau

	Description:
		Owns the catalog of active experiments: metadata reconciled from
		bootstrap/status payloads, and per-group changesets fetched from
		v2/experiments/active with hash-based change detection.

		Group changesets are immutable once seen and are never refetched.
		Assignment state lives in InternalExperiments; this module is purely
		the source of truth for what experiments exist and what they change.

--]]

--= Root =--
local ExperimentCatalog = { }

--= Roblox Services =--

--= Dependencies =--

local GBRequests = shared.GBMod("GBRequests")
local Utilities = shared.GBMod("Utilities")
local Changesets = require(script.Parent.Parent.Changesets)

--= Types =--

export type ExperimentGroupMeta = {
	id: number,
	label: string,
	weight: number?,
	ordinal: number,
}
export type ExperimentMeta = {
	id: number,
	name: string,
	unitType: "user" | "server",
	assignmentMode: "weightedHash" | "roundRobin",
	baseConfigurationId: number,
	autoAssignment: boolean,
	permanentEnrollment: boolean,
	requiredProperties: { string },
	startsAt: string,
	endsAt: string?,
	groups: { ExperimentGroupMeta },
}
export type ExperimentsByUnitType = {
	user: { ExperimentMeta },
	server: { ExperimentMeta },
}
export type ExperimentState = {
	meta: ExperimentMeta,
	changesetByGroupId: { [number]: Changesets.Changeset },
}
export type CatalogUpdateSummary = {
	newUserExperimentIds: { number },
	newServerExperimentIds: { number },
	removedExperimentIds: { number },
}

--= Constants =--

--= Variables =--

local Catalog: { [number]: ExperimentState } = {}

--[[
	Latest v2/experiments/active hash per unit type, for 304 change detection.
]]
local ActiveHashByUnitType: { [string]: string } = {}

--[[
	Application-level required properties from the latest bootstrap/status payload,
	unioned with per-experiment required properties in GetRequiredPropertyUnion.
]]
local GlobalRequiredProperties: { string } = {}

--= Internal Functions =--

--[[
	Fetches active experiments with changesets for the given unit type and merges
	them into the catalog. Uses hash-based change detection; a 304 keeps the cache.

	@canyield
]]
local function fetchActiveChangesets(unitType: "user" | "server"): boolean
	local didSucceed, response, statusCode = GBRequests:GBRequestAsync("v2/experiments/active", {
		["unit-type"] = unitType,
		hash = ActiveHashByUnitType[unitType],
	})

	if statusCode == 304 then
		return true
	end

	if not didSucceed or not response then
		Utilities.GBWarn("Failed to fetch active experiments for unit type:", unitType)
		return false
	end

	ActiveHashByUnitType[unitType] = response.hash

	for _, experimentData in response.experiments :: { any } do
		local existing = Catalog[experimentData.id]
		local changesetByGroupId: { [number]: Changesets.Changeset } = existing and existing.changesetByGroupId or {}

		local groups: { ExperimentGroupMeta } = {}
		for _, group in experimentData.groups do
			-- Changesets are immutable once seen; only store ones we don't have yet
			if not changesetByGroupId[group.id] and group.changeset then
				changesetByGroupId[group.id] = group.changeset
			end
			table.insert(groups, {
				id = group.id,
				label = group.label,
				weight = group.weight,
				ordinal = group.ordinal,
			})
		end

		Catalog[experimentData.id] = {
			meta = {
				id = experimentData.id,
				name = experimentData.name,
				unitType = experimentData.unitType,
				assignmentMode = experimentData.assignmentMode,
				baseConfigurationId = experimentData.baseConfigurationId,
				autoAssignment = experimentData.autoAssignment,
				permanentEnrollment = experimentData.permanentEnrollment,
				requiredProperties = experimentData.requiredProperties,
				startsAt = experimentData.startsAt,
				endsAt = experimentData.endsAt,
				groups = groups,
			},
			changesetByGroupId = changesetByGroupId,
		}
	end

	return true
end

--= API Functions =--

function ExperimentCatalog:Get(experimentId: number): ExperimentState?
	return Catalog[experimentId]
end

function ExperimentCatalog:GetUnitTypeCount(unitType: "user" | "server"): number
	local count = 0
	for _, state in Catalog do
		if state.meta.unitType == unitType then
			count += 1
		end
	end
	return count
end

--[[
	Returns the union of application-level and per-experiment required properties
	for the given unit type.
]]
function ExperimentCatalog:GetRequiredPropertyUnion(unitType: "user" | "server"): { string }
	local propertySet: { [string]: true } = {}
	for _, property in GlobalRequiredProperties do
		propertySet[property] = true
	end
	for _, state in Catalog do
		if state.meta.unitType == unitType then
			for _, property in state.meta.requiredProperties do
				propertySet[property] = true
			end
		end
	end

	local properties: { string } = {}
	for property in propertySet do
		table.insert(properties, property)
	end
	return properties
end

--[[
	Returns display metadata for an experiment group, if active in the catalog.
]]
function ExperimentCatalog:GetMetadata(experimentId: number, groupId: number): { experimentName: string, groupLabel: string }?
	local state = Catalog[experimentId]
	if not state then
		return nil
	end

	for _, group in state.meta.groups do
		if group.id == groupId then
			return {
				experimentName = state.meta.name,
				groupLabel = group.label,
			}
		end
	end

	return nil
end

--[[
	Keeps only the experiments that are actually in the catalog, so a changeset fetch that failed
	is not reported to the caller as a started experiment.
]]
local function filterToCatalogued(experimentIds: { number }): { number }
	local catalogued = {}
	for _, experimentId in experimentIds do
		if Catalog[experimentId] then
			table.insert(catalogued, experimentId)
		end
	end
	return catalogued
end

--[[
	Reconciles the catalog against a bootstrap/status payload: refreshes metadata,
	removes stopped experiments, and fetches changesets for anything new.

	Returns a summary of what changed so the caller can react to it
	(trigger assignment for new experiments, strip assignments for removed ones).

	@canyield
]]
function ExperimentCatalog:Update(experiments: ExperimentsByUnitType, requiredProperties: { string }?): CatalogUpdateSummary
	if requiredProperties then
		GlobalRequiredProperties = requiredProperties
	end

	local summary: CatalogUpdateSummary = {
		newUserExperimentIds = {},
		newServerExperimentIds = {},
		removedExperimentIds = {},
	}

	-- Identify new experiments and unseen groups per unit type
	local seenExperimentIds: { [number]: true } = {}
	local unitTypesNeedingFetch: { [string]: true } = {}

	for _, unitType in { "user" :: "user" | "server", "server" :: "user" | "server" } do
		for _, meta in experiments[unitType] do
			seenExperimentIds[meta.id] = true

			local existing = Catalog[meta.id]
			if not existing then
				unitTypesNeedingFetch[unitType] = true
				if unitType == "user" then
					table.insert(summary.newUserExperimentIds, meta.id)
				else
					table.insert(summary.newServerExperimentIds, meta.id)
				end
			else
				-- Keep metadata fresh (e.g. endsAt extensions); groups are immutable but
				-- check for unseen group ids just in case
				existing.meta = meta
				for _, group in meta.groups do
					if not existing.changesetByGroupId[group.id] then
						unitTypesNeedingFetch[unitType] = true
					end
				end
			end
		end
	end

	-- Remove stopped experiments
	for experimentId, state in Catalog do
		if not seenExperimentIds[experimentId] then
			Utilities.GBLog("Experiment stopped:", experimentId)

			-- The active-catalog hash is only a 304 token for what this server has cached, so it has
			-- to go with the cache. Kept, it lets a later refetch for a re-appearing experiment be
			-- answered 304, which would leave that experiment with no changesets for good.
			ActiveHashByUnitType[state.meta.unitType] = nil

			Catalog[experimentId] = nil
			table.insert(summary.removedExperimentIds, experimentId)
		end
	end

	-- Fetch changesets for unit types with new experiments or groups
	for unitType in unitTypesNeedingFetch do
		fetchActiveChangesets(unitType :: "user" | "server")
	end

	-- A fetch that failed leaves its experiments out of the catalog. Reporting them as started
	-- anyway had the caller re-assign every player in the server on every poll, for experiments it
	-- still had no changesets to apply. They stay uncatalogued, so the next poll sees them as new
	-- again and retries the fetch.
	summary.newUserExperimentIds = filterToCatalogued(summary.newUserExperimentIds)
	summary.newServerExperimentIds = filterToCatalogued(summary.newServerExperimentIds)

	return summary
end

--= Return Module =--
return ExperimentCatalog
