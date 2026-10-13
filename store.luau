-- Reviews on disk: one JSON file of comments per review, one of its snapshot units, and a small index in tern.kv.
--
-- Window hooks have a 50 ms budget and file writes are slow, so a change only
-- updates memory and marks the review dirty; one timer writes everything that is
-- dirty 250 ms later (`touch`, `flush`). Reads come from memory first.
local core = require("./core")

local MAX_ARTIFACTS = 100

local FLUSH_MS = 250

local ART_DIR = tern.plugin.data .. "/artifacts"

local arts = {} -- id -> artifact, in memory

local index = nil

local index_dirty = false

local dirty = {} -- id -> { units = boolean }

local flush_pending = false

local function load_index()
	if index == nil then
		local v = tern.kv.get("index")
		index = if type(v) == "table" then v else {}
	end
	return index
end

local function index_put(a)
	local idx = load_index()
	local n = core.counts(a)
	local e = {
		id = a.id,
		title = a.title,
		ts = a.activity or a.created,
		mode = a.mode,
		pending = n.pending,
		sent = n.sent,
		applied = n.applied,
		src_pane = a.src and a.src.pane,
		src_kind = a.src and a.src.kind,
	}
	index_dirty = true
	for i, x in ipairs(idx) do
		if x.id == a.id then
			idx[i] = e
			return
		end
	end
	table.insert(idx, e)
	while #idx > MAX_ARTIFACTS do
		local old = table.remove(idx, 1)
		arts[old.id] = nil
		dirty[old.id] = nil
		pcall(tern.fs.remove, ART_DIR .. "/" .. old.id .. ".json")
		pcall(tern.fs.remove, ART_DIR .. "/" .. old.id .. ".units.json")
	end
end

-- Comments and metadata live in <id>.json, the (large, rarely changing) units in
-- <id>.units.json, so saving a comment never rewrites the whole snapshot.
local function save(a)
	if not tern.fs.exists(ART_DIR) then
		tern.fs.mkdir(ART_DIR)
	end
	local units = a.units
	a.units = nil
	local ok, text = pcall(tern.json.encode, a)
	a.units = units
	if not ok then
		error(text)
	end
	tern.fs.write(ART_DIR .. "/" .. a.id .. ".json", text)
end

local function save_units(a)
	if not tern.fs.exists(ART_DIR) then
		tern.fs.mkdir(ART_DIR)
	end
	tern.fs.write(ART_DIR .. "/" .. a.id .. ".units.json", tern.json.encode(a.units))
end

-- Writes everything that is dirty. Runs from the flush timer.
local function flush()
	local todo = dirty
	dirty = {}
	for id, d in pairs(todo) do
		local a = arts[id]
		if a then
			save(a)
			if d.units then
				save_units(a)
			end
		end
	end
	if index_dirty then
		index_dirty = false
		tern.kv.set("index", load_index())
	end
end

local function schedule_flush()
	if flush_pending then
		return
	end
	flush_pending = true
	tern.timer(FLUSH_MS, function()
		flush_pending = false
		local ok, err = pcall(flush)
		if not ok then
			tern.log.warn("annotate: save failed: " .. tostring(err))
		end
	end)
end

-- A review changed: update the index now, write the files soon. `units` also
-- rewrites the snapshot file (after a capture or a refresh).
local function touch(a, units)
	local d = dirty[a.id] or { units = false }
	d.units = d.units or units == true
	dirty[a.id] = d
	index_put(a)
	schedule_flush()
end

local function load(id)
	if arts[id] then
		return arts[id]
	end
	local path = ART_DIR .. "/" .. id .. ".json"
	if not tern.fs.exists(path) then
		return nil
	end
	local ok, a = pcall(function()
		return tern.json.decode(tern.fs.read(path))
	end)
	if not ok or type(a) ~= "table" then
		tern.log.warn("annotate: unreadable artifact " .. id)
		return nil
	end
	local upath = ART_DIR .. "/" .. id .. ".units.json"
	local migrate = false
	if tern.fs.exists(upath) then
		local uok, units = pcall(function()
			return tern.json.decode(tern.fs.read(upath))
		end)
		a.units = if uok and type(units) == "table" then units else tern.json.array()
	elseif a.units then
		migrate = true -- an artifact written before units moved to their own file
	end
	a.units = a.units or tern.json.array()
	a.comments = a.comments or tern.json.array()
	for _, c in ipairs(a.comments) do
		c.thread = c.thread or tern.json.array()
	end
	arts[id] = a
	if migrate then
		dirty[id] = { units = true }
		schedule_flush()
	end
	return a
end

local function sorted_index()
	local list = {}
	for _, e in ipairs(load_index()) do
		table.insert(list, e)
	end
	table.sort(list, function(x, y)
		return (x.ts or 0) > (y.ts or 0)
	end)
	return list
end

local function remember(a)
	arts[a.id] = a
end

-- Forgets a review: its cache entry, its files and its index entry.
local function drop(id)
	arts[id] = nil
	dirty[id] = nil
	pcall(tern.fs.remove, ART_DIR .. "/" .. id .. ".json")
	pcall(tern.fs.remove, ART_DIR .. "/" .. id .. ".units.json")
	local idx = load_index()
	for i, e in ipairs(idx) do
		if e.id == id then
			table.remove(idx, i)
			break
		end
	end
	index_dirty = true
	schedule_flush()
end

return {
	load_index = load_index,
	touch = touch,
	load = load,
	sorted_index = sorted_index,
	remember = remember,
	drop = drop,
}
