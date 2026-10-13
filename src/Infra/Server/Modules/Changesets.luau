--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

	Changesets.luau

	Description:
		Applies experiment changesets (ordered set/add/delete operations at a path)
		to a base configuration document, producing an experiment group's variant.

		Mirrors the backend's merge so a local view matches a backend-evaluated one.
		"add" behaves like "set". Paths only traverse dictionaries: a missing segment,
		a non-table value or an array along the path makes the operation a no-op, and
		missing intermediate tables are never created.

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
		-- Copied so a later operation writing inside it (set shop, then set shop.price) can't mutate
		-- the cached changeset, which would also be frozen along with the composed view.
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
