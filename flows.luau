-- Commenting: pick a kind, write, reply.
local core = require("./core")
local nodes = require("./nodes")
local KINDS = nodes.KINDS
local panel = require("./panel")
local commit = panel.commit
local actions = require("./actions")
local send_pending = actions.send_pending
local ask_question = actions.ask_question
local file_todo = actions.file_todo

local function create_comment(cx, a, u, kind, text, quote)
	local c = core.new_comment(a, kind, text, u, os.time(), quote)
	commit(cx, a)
	if kind == "edit" and a.mode == "immediate" then
		send_pending(cx, a)
	elseif kind == "question" then
		ask_question(cx, a, c)
	elseif kind == "todo" then
		file_todo(cx, a, c)
	end
end

-- `quote`: the exact passage, when the comment is on a selection narrower than the unit.
local function prompt_comment(cx, a, u, kind, quote)
	cx:prompt({ placeholder = "Your comment…", action = "add" }):next(function(text, _e, cx2)
		if text and core.trim(text) ~= "" then
			create_comment(cx2, a, u, kind, core.trim(text), quote)
		end
	end)
end

local function add_flow(cx, a, u, quote)
	cx:pick({ items = KINDS, placeholder = "Comment on this passage", action = "choose" }):next(function(item, _e, cx2)
		if item then
			prompt_comment(cx2, a, u, item.kind, quote)
		end
	end)
end

local function comment_flow(cx, a, c)
	local items = { { label = "Reply", op = "reply" } }
	if c.kind == "edit" and c.state == "open" then
		table.insert(items, { label = "Send this comment now", op = "send" })
	end
	if c.kind == "question" then
		table.insert(items, { label = "Ask again", op = "again" })
	end
	if c.kind ~= "todo" and c.state ~= "filed" then
		table.insert(items, { label = "Make it a to-do", op = "todo" })
	end
	table.insert(items, { label = if c.state == "resolved" then "Reopen" else "Resolve", op = "resolve" })
	table.insert(items, { label = "Delete", op = "delete" })

	cx:pick({ items = items, placeholder = "Comment", action = "do" }):next(function(item, _e, cx2)
		if not item then
			return
		end
		if item.op == "reply" then
			cx2:prompt({ placeholder = "Your reply…", action = "reply" }):next(function(text, _e2, cx3)
				if not text or core.trim(text) == "" then
					return
				end
				core.reply(c, "you", core.trim(text), os.time())
				a.activity = os.time()
				if c.kind == "question" then
					ask_question(cx3, a, c)
				else
					if c.kind == "edit" and (c.state == "sent" or c.state == "applied" or c.state == "resolved") then
						c.state = "open"
					end
					commit(cx3, a)
					if c.kind == "edit" and a.mode == "immediate" then
						send_pending(cx3, a)
					end
				end
			end)
		elseif item.op == "send" then
			send_pending(cx2, a, false, { c })
		elseif item.op == "again" then
			ask_question(cx2, a, c)
		elseif item.op == "todo" then
			file_todo(cx2, a, c)
		elseif item.op == "resolve" then
			c.state = if c.state == "resolved" then "open" else "resolved"
			commit(cx2, a)
		elseif item.op == "delete" then
			local _, i = core.find_comment(a, c.id)
			if i then
				table.remove(a.comments, i)
			end
			commit(cx2, a)
		end
	end)
end

return {
	prompt_comment = prompt_comment,
	add_flow = add_flow,
	comment_flow = comment_flow,
}
