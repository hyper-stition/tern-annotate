-- Node builders and labels for the review panel.
local ui = tern.ui

local PAGE = 20 -- units per page of the review panel

local SHOW_CHARS = 1500 -- longest unit text drawn

local KINDS = {
	{ label = "Edit: ask the agent to change this", detail = "sent per the panel's mode", kind = "edit" },
	{ label = "Question: ask, change nothing", detail = "answered by Carly", kind = "question" },
	{ label = "Note: just for me", kind = "note" },
	{ label = "To-do: add to general-todo", kind = "todo" },
}

local KIND_LABEL = { edit = "edit", question = "ask", note = "note", todo = "to-do" }

local KIND_TONE = { edit = "accent", question = "info", note = "muted", todo = "warning" }

-- Right-click menu action ids; Tern turns each id into the menu label.
local MENU_KIND = { request_edit = "edit", ask_question = "question", add_note = "note", add_todo = "todo" }

-- The unit a clicked node shows: node ids end with ".u<unit id>" (the node's key).
local function unit_of_node(a, node)
	for _, u in ipairs(a.units) do
		if string.sub(node, -(#u.id + 2)) == ".u" .. u.id then
			return u
		end
	end
	return nil
end

local STATE_TONE = {
	open = "neutral",
	asking = "pending",
	answered = "info",
	sent = "warning",
	applied = "success",
	resolved = "muted",
	filed = "muted",
}

local MODES = { "manual", "immediate", "batch" }

local MODE_LABEL = { manual = "send: manual", immediate = "send: immediately", batch = "send: batched" }

local function mark(n, props)
	n.p = n.p or {}
	for k, v in pairs(props) do
		n.p[k] = v
	end
	return n
end

local function act(n, name, value)
	return mark(n, { actions = { click = name .. "=" .. value } })
end

local function button(label, tone, name, value)
	return act(ui.badge(label, tone), name, value)
end

local function unit_text_node(a, u)
	local t = u.text
	if #t > SHOW_CHARS then
		t = string.sub(t, 1, SHOW_CHARS) .. "…"
	end
	if a.src and (a.src.kind == "agent" or a.src.kind == "file") then
		return ui.md(t)
	end
	return ui.text({ ui.span(t, if u.role == "user" then "muted" else "") })
end

local function comment_node(a, c)
	local first = c.thread[1] and c.thread[1].text or ""
	local rows = {
		ui.row({
			ui.badge(KIND_LABEL[c.kind] or c.kind, KIND_TONE[c.kind] or "neutral"),
			ui.badge(c.state, STATE_TONE[c.state] or "neutral"),
			ui.text({ ui.span(first, if c.state == "resolved" then "muted" else "strong") }),
		}),
	}
	for i = 2, #c.thread do
		local m = c.thread[i]
		table.insert(rows, ui.text({ ui.span("  ↳ " .. m.who .. ": ", "muted"), ui.span(m.text) }))
	end
	return act(mark(ui.col(rows), { key = "c" .. c.id }), "cm", a.id .. "|" .. c.id)
end

return {
	PAGE = PAGE,
	KINDS = KINDS,
	MENU_KIND = MENU_KIND,
	unit_of_node = unit_of_node,
	MODES = MODES,
	MODE_LABEL = MODE_LABEL,
	mark = mark,
	button = button,
	unit_text_node = unit_text_node,
	comment_node = comment_node,
}
