-- The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
-- All rights reserved.

-- Queue with O(1) pop, unlike table.remove(t, 1)
local queue = {}

function queue.new()
	local q = {
		first = 0,
		last = -1,
		len = 0
	}

	function q.push(list, value)
		list.last += 1
		list[list.last] = value
		list.len += 1
	end

	function q.pop(list)
		local first = list.first
		
		if first > list.last then return end
		
		local value = list[first]
		list[first] = nil
		list.first += 1
		list.len -= 1
		
		return value
	end

	return q
end

return queue