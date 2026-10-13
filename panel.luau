-- The review panel as a canvas: find, redraw, open.
local view = require("./view")
local build_view = view.build_view
local store = require("./store")
local touch = store.touch

local function find_canvas(cx, id)
	local tag = "annotate:" .. id .. "."
	for _, c in ipairs(cx.canvas:list()) do
		if c.owner == tern.plugin.id and string.find(c.about or "", tag, 1, true) then
			return c.pane
		end
	end
	return nil
end

-- Persist, update the index and redraw the panel if it is open. `units` also
-- rewrites the snapshot file (after a capture or a refresh). Window hooks have a
-- 50 ms budget and a trip disables the hook, so slow commits are logged.
local function commit(cx, a, units)
	local t0 = tern.now()
	touch(a, units)
	local pane = find_canvas(cx, a.id)
	if pane then
		local ok, err = pcall(function()
			cx.canvas:set(pane, { view = build_view(a) })
		end)
		if not ok then
			tern.log.warn("annotate: redraw failed: " .. tostring(err))
		end
	end
	local dt = tern.now() - t0
	if dt > 20 then
		tern.log.warn(string.format("annotate: commit took %.0f ms (%d units, %d comments)", dt, #a.units, #a.comments))
	end
end

local ABOUT = "Click a paragraph to comment on it (edit, question, note or to-do). Click a comment to reply, "
	.. "resolve, send, make it a to-do or delete it. Send sends the pending edit comments to an agent; the mode "
	.. "button cycles manual, immediate and batched sending; Refresh re-reads the source and re-attaches comments."

local function open_review(cx, a, over)
	local pane = find_canvas(cx, a.id)
	if pane then
		cx.layout:focus(pane)
		return
	end
	local title = "Review: " .. a.title
	if #title > 78 then
		title = string.sub(title, 1, 77) .. "…"
	end
	local p, err = cx.canvas:open({
		title = title,
		about = "annotate:" .. a.id .. ". " .. ABOUT,
		view = build_view(a),
		how = "beside",
		focus = true,
	})
	if not p then
		cx:toast("error", "Could not open the review panel", err)
		return
	end
	if tern.kv.get("float") == true then
		pcall(function()
			cx.layout:float(p, over, "br")
		end)
	end
end

return {
	find_canvas = find_canvas,
	commit = commit,
	open_review = open_review,
}
