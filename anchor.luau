-- Re-attaching comments to a fresh read of their source, and finding a passage.

local core = require("./core")

local anchor = {}

-- The newest unit containing `text` (whitespace-normalised), or nil. A selection
-- that spans several units is matched by its first line.
function anchor.find_unit(units, text)
	local function search(needle)
		if needle == "" then
			return nil
		end
		if #needle > 300 then
			needle = string.sub(needle, 1, 300)
		end
		for i = #units, 1, -1 do
			if string.find(core.norm(units[i].text), needle, 1, true) then
				return units[i]
			end
		end
		return nil
	end
	local u = search(core.norm(text))
	if u then
		return u
	end
	local first = string.match(text, "[^\r\n]+")
	if first then
		return search(core.norm(first))
	end
	return nil
end

-- Swaps in the units of a fresh read of the source. A comment keeps its unit if
-- that unit's id is still there; otherwise it follows its quote to the unit now
-- containing it; otherwise it is orphaned. A *sent* edit whose unit vanished
-- (its text changed) is marked applied: the agent probably did it.
function anchor.reanchor(a, units)
	local by_id, normed = {}, {}
	for i, u in ipairs(units) do
		by_id[u.id] = u
		normed[i] = core.norm(u.text)
	end
	local stats = { kept = 0, moved = 0, applied = 0, orphaned = 0 }
	for _, c in ipairs(a.comments) do
		if by_id[c.unit] then
			c.orphaned = nil
			stats.kept = stats.kept + 1
		else
			local found
			local q = core.unquote(c.quote or "")
			if #q > 0 then
				for i, u in ipairs(units) do
					if string.find(normed[i], q, 1, true) then
						found = u
						break
					end
				end
			end
			if found then
				c.unit = found.id
				c.orphaned = nil
			else
				c.orphaned = true
			end
			if c.state == "sent" then
				c.state = "applied"
				stats.applied = stats.applied + 1
			elseif found then
				stats.moved = stats.moved + 1
			else
				stats.orphaned = stats.orphaned + 1
			end
		end
	end
	a.units = units
	return stats
end

return anchor
