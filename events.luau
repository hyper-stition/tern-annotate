-- Event handlers: canvas clicks, agent completion, batch ticks, Carly exports.
local core = require("./core")
local prompts = require("./prompts")
local nodes = require("./nodes")
local MENU_KIND = nodes.MENU_KIND
local unit_of_node = nodes.unit_of_node
local MODES = nodes.MODES
local store = require("./store")
local load_index = store.load_index
local load = store.load
local sorted_index = store.sorted_index
local panel = require("./panel")
local commit = panel.commit
local actions = require("./actions")
local send_pending = actions.send_pending
local flows = require("./flows")
local prompt_comment = flows.prompt_comment
local add_flow = flows.add_flow
local comment_flow = flows.comment_flow
local reviews = require("./reviews")
local refresh = reviews.refresh

local BATCH_N = 3 -- batch mode: send when this many edits are pending…

local BATCH_IDLE = 120 -- …or after this many seconds without a new comment

local function agent_finished(ev, cx)
	for _, e in ipairs(load_index()) do
		if (e.sent or 0) > 0 then
			local a = load(e.id)
			if a and a.target == ev.pane then
				local n = 0
				for _, c in ipairs(a.comments) do
					if c.state == "sent" then
						n += 1
						c.state = if ev.result == "done" then "applied" else "open"
					end
				end
				if n > 0 then
					commit(cx, a)
					if ev.result == "done" then
						cx:toast("success", n .. " revision" .. (if n == 1 then "" else "s") .. " ready to review", a.title)
					else
						cx:toast("error", "Agent " .. ev.result, n .. " comment(s) are open again")
					end
				end
			end
		end
	end
end

local function canvas_action(ev, cx)
	if ev.owner ~= tern.plugin.id then
		return false
	end
	local aid, rest = string.match(ev.value or "", "^([^|]*)|?(.*)$")
	if not aid or aid == "" then
		aid = string.match(ev.about or "", "annotate:(%w+)%.")
	end
	local a = load(aid or "")
	if not a then
		cx:toast("error", "That review is gone", "Its file was deleted.")
		return true
	end
	if ev.act == "add" or MENU_KIND[ev.act] then
		local u = if ev.act == "add" then core.unit_by_id(a, rest) else unit_of_node(a, ev.node or "")
		if u and ev.act == "add" then
			add_flow(cx, a, u)
		elseif u then
			prompt_comment(cx, a, u, MENU_KIND[ev.act], nil)
		end
	elseif ev.act == "cm" then
		local c = core.find_comment(a, rest)
		if c then
			comment_flow(cx, a, c)
		end
	elseif ev.act == "send" then
		send_pending(cx, a)
	elseif ev.act == "mode" then
		local cur = 1
		for i, m in ipairs(MODES) do
			if m == (a.mode or "manual") then
				cur = i
			end
		end
		a.mode = MODES[cur % #MODES + 1]
		commit(cx, a)
		if a.mode == "immediate" then
			send_pending(cx, a, true)
		end
	elseif ev.act == "refresh" then
		refresh(cx, a)
	elseif ev.act == "only" then
		a.only = not a.only
		a.page = 1
		commit(cx, a)
	elseif ev.act == "md" then
		cx:copy(prompts.to_markdown(a))
		cx:toast("success", "Annotations copied as Markdown", a.title)
	elseif ev.act == "page" then
		a.page = (a.page or 1) + (tonumber(rest) or 0)
		commit(cx, a)
	else
		return false
	end
	return true
end

local function tick(cx)
	for _, e in ipairs(load_index()) do
		if e.mode == "batch" and (e.pending or 0) > 0 then
			local a = load(e.id)
			if a and (e.pending >= BATCH_N or os.time() - (a.activity or 0) >= BATCH_IDLE) then
				send_pending(cx, a, true)
			end
		end
	end
end

local function answer(review, comment, text, cx)
	local a = load(review or "")
	local c = a and core.find_comment(a, comment or "")
	if not c or type(text) ~= "string" or text == "" then
		return false
	end
	core.reply(c, "carly", text, os.time())
	c.state = "answered"
	commit(cx, a)
	return true
end

local function annotations()
	local out = {}
	for _, e in ipairs(sorted_index()) do
		table.insert(out, { id = e.id, title = e.title, pending = e.pending or 0, sent = e.sent or 0, applied = e.applied or 0 })
	end
	return out
end

return {
	agent_finished = agent_finished,
	canvas_action = canvas_action,
	tick = tick,
	answer = answer,
	annotations = annotations,
}
