-- The review panel: turns a review into a view of tern.ui nodes.
local core = require("./core")
local ui = tern.ui
local nodes = require("./nodes")
local PAGE = nodes.PAGE
local MODE_LABEL = nodes.MODE_LABEL
local mark = nodes.mark
local button = nodes.button
local unit_text_node = nodes.unit_text_node
local comment_node = nodes.comment_node

local function build_view(a)
	local n = core.counts(a)
	local by_unit, orphans = {}, {}
	local present = {}
	for _, u in ipairs(a.units) do
		present[u.id] = true
	end
	for _, c in ipairs(a.comments) do
		if present[c.unit] then
			by_unit[c.unit] = by_unit[c.unit] or {}
			table.insert(by_unit[c.unit], c)
		else
			table.insert(orphans, c)
		end
	end

	local shown = {}
	for i, u in ipairs(a.units) do
		if not a.only or by_unit[u.id] then
			table.insert(shown, { u = u, i = i })
		end
	end
	local pages = math.max(1, math.ceil(#shown / PAGE))
	local page = math.min(math.max(a.page or 1, 1), pages)
	a.page = page

	local head = {
		ui.row({
			ui.badge(n.open .. " open", if n.open > 0 then "accent" else "muted"),
			ui.badge(n.pending .. " pending", if n.pending > 0 then "warning" else "muted"),
			ui.badge(n.sent .. " sent", "muted"),
			ui.badge(n.applied .. " to review", if n.applied > 0 then "success" else "muted"),
			ui.badge(n.resolved .. " done", "muted"),
		}),
		ui.row({
			button("Send " .. n.pending, if n.pending > 0 then "accent" else "muted", "send", a.id),
			button(MODE_LABEL[a.mode or "manual"], "info", "mode", a.id),
			button("Refresh", "neutral", "refresh", a.id),
		}),
		ui.row({
			button(if a.only then "all" else "commented", "neutral", "only", a.id),
			button("Copy MD", "neutral", "md", a.id),
			button("◀", "neutral", "page", a.id .. "|-1"),
			ui.badge(page .. "/" .. pages, "muted"),
			button("▶", "neutral", "page", a.id .. "|1"),
		}),
		ui.rule(""),
	}

	local body = {}
	local last_msg = nil
	for k = (page - 1) * PAGE + 1, math.min(page * PAGE, #shown) do
		local u = shown[k].u
		if u.msg and u.msg ~= last_msg then
			last_msg = u.msg
			table.insert(body, ui.text({ ui.span(if u.role == "user" then "you" else "agent", "accent") }))
		end
		local cs = by_unit[u.id]
		local unit = mark(unit_text_node(a, u), { key = "u" .. u.id, mark = if cs then "pick" else nil })
		local target = a.id .. "|" .. u.id
		-- Click opens the kind picker; right-click offers each kind directly.
		unit.p.actions = {
			click = "add=" .. target,
			menu = { "request_edit", "ask_question", "add_note", "add_todo" },
		}
		table.insert(body, unit)
		for _, c in ipairs(cs or {}) do
			table.insert(body, comment_node(a, c))
		end
	end
	if #shown == 0 then
		table.insert(body, ui.text({ ui.span("No paragraphs have comments yet.", "muted") }))
	end
	if #orphans > 0 then
		table.insert(body, ui.rule("detached (their text changed or is gone)"))
		for _, c in ipairs(orphans) do
			table.insert(body, ui.text({ ui.span('"' .. c.quote .. '"', "muted") }))
			table.insert(body, comment_node(a, c))
		end
	end

	local children = {}
	for _, x in ipairs(head) do
		table.insert(children, x)
	end
	for _, x in ipairs(body) do
		table.insert(children, x)
	end
	return ui.col(children)
end

return {
	build_view = build_view,
}
