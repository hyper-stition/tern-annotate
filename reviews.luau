-- Reviews of blocks: open, refresh, choose.
local core = require("./core")
local anchor = require("./anchor")
local store = require("./store")
local load = store.load
local sorted_index = store.sorted_index
local remember = store.remember
local panel = require("./panel")
local commit = panel.commit
local sources = require("./sources")
local src_of = sources.src_of
local fetch = sources.fetch

local function refresh(cx, a, quiet)
	fetch(cx, a.src, function(units, err, cx2)
		if not units then
			if not quiet then
				cx2:toast("error", "Cannot refresh", err)
			end
			return
		end
		local st = anchor.reanchor(a, units)
		commit(cx2, a, true)
		if not quiet then
			cx2:toast(
				"info",
				"Refreshed",
				string.format("%d kept, %d moved, %d applied, %d detached", st.kept, st.moved, st.applied, st.orphaned)
			)
		end
	end)
end

local function pick_artifact(cx, placeholder, cb)
	local items = {}
	for _, e in ipairs(sorted_index()) do
		table.insert(items, {
			label = e.title,
			detail = string.format("%d pending · %d sent · %d to review", e.pending or 0, e.sent or 0, e.applied or 0),
			id = e.id,
		})
	end
	if #items == 0 then
		cx:toast("info", "No annotation reviews yet", "Use “Annotate this block” first.")
		return
	end
	if #items == 1 then
		local a = load(items[1].id)
		if a then
			cb(cx, a)
		end
		return
	end
	cx:pick({ items = items, placeholder = placeholder, action = "open" }):next(function(item, _e, cx2)
		local a = item and load(item.id)
		if a then
			cb(cx2, a)
		end
	end)
end

-- The review of block `pane`: reuse the newest one (refreshed against the block's
-- current text) or snapshot the block into a new one. cb(cx, a).
-- `lenient`: carry on with no units when the block can't be read (the copied-text
-- command still has the copied text).
local function open_source(cx, pane, cb, lenient)
	local src = src_of(cx, pane)
	local existing = nil
	for _, e in ipairs(sorted_index()) do
		if e.src_pane == pane and e.src_kind == src.kind then
			existing = load(e.id)
			if existing then
				break
			end
		end
	end
	fetch(cx, src, function(units, err, cx2)
		if not units or #units == 0 then
			if not lenient then
				cx2:toast("error", "Nothing to annotate", err or "the block has no text")
				return
			end
			cx2:toast("info", "Couldn't read the whole block", err or "its text is empty")
			units = tern.json.array()
		end
		local t0 = tern.now()
		local a = existing
		local changed = true
		if a then
			-- The snapshot file only needs rewriting when the unit list differs.
			if #units == 0 then
				changed = false
			else
				changed = #a.units ~= #units
				for i = 1, #units do
					if changed then
						break
					end
					changed = a.units[i].id ~= units[i].id
				end
				anchor.reanchor(a, units)
			end
			a.src.title = src.title or a.src.title
		else
			local now = os.time()
			local title = src.title or ("block " .. pane)
			a = core.new_artifact(core.b36(core.hash(title .. ":" .. now .. ":" .. pane)), title, src, units, now)
			a.comments = tern.json.array()
			remember(a)
			-- Chats and terminals grow at the end: open on the newest page.
			if src.kind == "agent" or src.kind == "terminal" then
				a.page = 1000000
			end
		end
		a.units = tern.json.array(a.units)
		commit(cx2, a, changed)
		local dt = tern.now() - t0
		if dt > 30 then
			tern.log.warn(string.format("annotate: open_source took %.0f ms (%d units)", dt, #a.units))
		end
		cb(cx2, a)
	end)
end

-- The review a focused block is, when that block is one of this plugin's panels.
local function review_of_canvas(cx, pane)
	for _, c in ipairs(cx.canvas:list()) do
		if c.pane == pane and c.owner == tern.plugin.id then
			local aid = string.match(c.about or "", "annotate:(%w+)%.")
			return aid and load(aid) or nil
		end
	end
	return nil
end

return {
	refresh = refresh,
	pick_artifact = pick_artifact,
	open_source = open_source,
	review_of_canvas = review_of_canvas,
}
