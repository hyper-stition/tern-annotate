-- Sending, asking and filing: edit comments to an agent, questions to Carly, to-dos to the general board.
local core = require("./core")
local prompts = require("./prompts")
local panel = require("./panel")
local commit = panel.commit

local function agent_alive(cx, pane)
	for _, ag in ipairs(cx.agents:list()) do
		if ag.pane == pane and ag.state ~= "exited" then
			return ag
		end
	end
	return nil
end

local function pick_agent(cx, cb)
	local items = {}
	for _, ag in ipairs(cx.agents:list()) do
		if ag.state ~= "exited" then
			table.insert(items, {
				label = "#" .. ag.pane .. " " .. (ag.model or ag.command or "agent"),
				detail = (ag.cwd or "") .. " · " .. ag.state,
				pane = ag.pane,
			})
		end
	end
	if #items == 0 then
		cx:toast("error", "No agent is running", "Start one, then send again.")
		return
	end
	cx:pick({ items = items, placeholder = "Send to which agent?", action = "send" }):next(function(item, _err, cx2)
		if item then
			cb(cx2, item.pane)
		end
	end)
end

-- `auto`: never open a picker; skip quietly when no agent is known.
-- `only`: send just these comments instead of every pending edit.
local function send_pending(cx, a, auto, only)
	local list = only or core.pending(a)
	if #list == 0 then
		if not auto then
			cx:toast("info", "Nothing pending", "No open edit comments.")
		end
		return
	end
	local function go(cx2, pane)
		local ok, err = pcall(function()
			cx2.agents:ask(pane, prompts.format_edits(a, list))
		end)
		if not ok then
			cx2:toast("error", "Could not send", string.sub(tostring(err), 1, 140))
			return
		end
		local now = os.time()
		for _, c in ipairs(list) do
			c.state = "sent"
			c.sent_ts = now
		end
		a.target = pane
		a.activity = now
		commit(cx2, a)
		cx2:toast("success", "Sent " .. #list .. " comment" .. (if #list == 1 then "" else "s"), "to agent #" .. pane)
	end
	local target = a.target or (if a.src and a.src.kind == "agent" then a.src.pane else nil)
	if target and agent_alive(cx, target) then
		go(cx, target)
	elseif not auto then
		pick_agent(cx, go)
	end
end

-- A question goes to Carly, who answers in her popup and saves the answer into
-- the comment's thread through the `answer` export below. (Starting a side
-- agent from here would block the window thread past the 50 ms budget.)
local function ask_question(cx, a, c)
	c.state = "asking"
	commit(cx, a)
	local hint = "When you have your answer, save it in my review thread by running this with your lua tool: "
		.. "await(plugins['annotate'].answer('"
		.. a.id
		.. "', '"
		.. c.id
		.. "', <your answer, as a Lua string>)). Then show me the answer."
	cx:ask_carly(prompts.format_question(a, c, hint))
end

-- Every to-do goes to one general board, ~/general-todo.md by default
-- (override with the tern.kv key "general_board").
local function general_board()
	local path = tern.kv.get("general_board")
	if type(path) == "string" and path ~= "" then
		return path
	end
	return (tern.getenv("USERPROFILE") or tern.getenv("HOME") or ".") .. "/general-todo.md"
end

-- `tags`: card tags, or nil for a plain to-do.
local function add_card(cx, path, text, done, tags)
	cx.board:read(path):next(function(snap, _err, cx2)
		local lane = "Todo"
		for _, l in ipairs(snap and snap.lanes or {}) do
			if not l.complete and l.title then
				lane = l.title
				break
			end
		end
		cx2.board:add(path, { lane = lane, text = text, tags = tags }):next(function(id, err, cx3)
			if not id then
				cx3:toast("error", "Could not add the to-do", tostring(err))
				return
			end
			cx3:toast("success", "Added to " .. lane, path)
			if done then
				done(cx3)
			end
		end)
	end)
end

local function file_todo(cx, a, c)
	add_card(cx, general_board(), prompts.todo_text(c), function(cx2)
		c.state = "filed"
		commit(cx2, a)
	end, { "annotate" })
end

return {
	send_pending = send_pending,
	ask_question = ask_question,
	general_board = general_board,
	add_card = add_card,
	file_todo = file_todo,
}
