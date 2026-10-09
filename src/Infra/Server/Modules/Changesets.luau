--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	Changesets.luau

	Description:
		Applies experiment changeset operations to configuration documents.
		Changesets are ordered lists of operations (set/add/delete at a path)
		that transform a base configuration into an experiment group's variant.

		Semantics intentionally mirror the backend's changesetMerge so that a
		locally composed view is identical to a backend-evaluated one:
		- "add" behaves exactly like "set".
		- Paths only traverse dictionaries. A missing segment, a non-table value,
		  or an array anywhere along the path makes the whole operation a no-op.
		- Missing intermediate tables are never created.

--]]

--= Root =--
local Changesets = { }

--= Roblox Services =--

--= Dependencies =--

local Utilities = require(script.Parent.Utilities)

--= Types =--

export type ChangesetOperation = {
	op : "set" | "add" | "delete",
	path : { string },
	value : any?,
}

export type Changeset = {
	operations : { ChangesetOperation },
}

--= Constants =--

--= Variables =--

--= Internal Functions =--

local function ApplyOperation(doc : { [string] : any }, operation : ChangesetOperation)
	local path = operation.path
	if #path == 0 then
		return
	end

	-- Walk to the parent of the target; only dictionaries are traversed
	local parent = doc
	for index = 1, #path - 1 do
		local child = parent[path[index]]
		if type(child) ~= "table" or #child > 0 then
			return
		end
		parent = child
	end

	local key = path[#path]

	if operation.op == "set" or operation.op == "add" then
		-- Copied, matching the backend's copy-on-write merge. By reference, a later operation that
		-- writes inside this value (set shop, then set shop.price) changed the cached changeset
		-- itself, and once the composed view was frozen the next composition hit a read-only table.
		parent[key] = if type(operation.value) == "table" then Utilities.recursiveCopy(operation.value) else operation.value
	elseif operation.op == "delete" then
		parent[key] = nil
	else
		Utilities.GBWarn("Unknown changeset operation:", operation.op)
	end
end

--= API Functions =--

-- Applies the given changesets, in order, on top of a base configuration document.
-- The base document is never mutated; with no changesets it is returned as-is.
function Changesets.apply(baseDoc : { [string] : any }, orderedChangesets : { Changeset }) : { [string] : any }
	if #orderedChangesets == 0 then
		return baseDoc
	end

	local doc = Utilities.recursiveCopy(baseDoc)

	for _, changeset in orderedChangesets do
		for _, operation in changeset.operations do
			ApplyOperation(doc, operation)
		end
	end

	return doc
end

--= Return Module =--
return Changesets
