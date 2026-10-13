-- Palette command bodies.
local core = require("./core")
local anchor = require("./anchor")
local prompts = require("./prompts")
local store = require("./store")
local drop = store.drop
local panel = require("./panel")
local find_canvas = panel.find_canvas
local commit = panel.commit
local open_review = panel.open_review
local actions = require("./actions")
local send_pending = actions.send_pending
local general_board = actions.general_board
local add_card = actions.add_card
local flows = require("./flows")
local add_flow = flows.add_flow
local reviews = require("./reviews")
local refresh = reviews.refresh
local pick_artifact = reviews.pick_artifact
local open_source = reviews.open_source
local review_of_canvas = reviews.review_of_canvas

local function cmd_capture(cx)
	local pane = cx.session:focused()
	if not pane then
		cx:toast("error", "No block is focused")
		return
	end
	local own = review_of_canvas(cx, pane)
	if own then
		-- Already in a review panel: re-read its source rather than annotate the panel.
		refresh(cx, own)
		return
	end
	open_source(cx, pane, function(cx2, a)
		open_review(cx2, a, pane)
	end)
end

-- Highlight text in any block, copy it (Ctrl+C), run this and paste it (Ctrl+V) into
-- the prompt: the comment is on exactly that passage. In a review panel it comments
-- on the pasted paragraph text there. (Plugins cannot add to the built-in
-- right-click menu or read a selection, and starting a clipboard process would use
-- most of the hook's 50 ms.)
local function cmd_capture_selection(cx)
	local pane = cx.session:focused()
	if not pane then
		cx:toast("error", "No block is focused")
		return
	end
	local own = review_of_canvas(cx, pane)
	cx:prompt({ placeholder = "Paste the highlighted text (Ctrl+V)", action = "annotate" }):next(function(pasted, _e, cx2)
		local text = string.sub(core.trim(pasted or ""), 1, 20000)
		if text == "" then
			return
		end
		local function comment_on(cx3, a)
			local u = anchor.find_unit(a.units, text)
			if not u then
				-- Not in the block's text (the page changed, or it spans blocks): keep the
				-- passage as a paragraph of its own so the comment still has a place.
				local passage = if #text > 4000 then string.sub(text, 1, 4000) else text
				u = { id = "sel" .. core.b36(core.hash(core.norm(passage))), text = passage }
				table.insert(a.units, u)
				commit(cx3, a, true)
			end
			add_flow(cx3, a, u, text)
		end
		if own then
			comment_on(cx2, own)
			return
		end
		open_source(cx2, pane, function(cx3, a)
			open_review(cx3, a, pane)
			comment_on(cx3, a)
		end, true)
	end)
end

local function cmd_review(cx)
	pick_artifact(cx, "Open which review?", function(cx2, a)
		open_review(cx2, a, cx2.session:focused())
	end)
end

local function cmd_send(cx)
	pick_artifact(cx, "Send which review's comments?", function(cx2, a)
		send_pending(cx2, a)
	end)
end

local function cmd_export(cx)
	pick_artifact(cx, "Copy which review?", function(cx2, a)
		cx2:copy(prompts.to_markdown(a))
		cx2:toast("success", "Annotations copied as Markdown", a.title)
	end)
end

local function cmd_delete(cx)
	pick_artifact(cx, "Delete which review?", function(cx2, a)
		cx2:pick({
			items = { { label = "Delete “" .. a.title .. "” and its comments", yes = true }, { label = "Cancel" } },
			placeholder = "Really delete?",
			action = "confirm",
		}):next(function(item, _e, cx3)
			if not (item and item.yes) then
				return
			end
			local pane = find_canvas(cx3, a.id)
			if pane then
				cx3.layout:close(pane)
			end
			drop(a.id)
			cx3:toast("success", "Deleted", a.title)
		end)
	end)
end

local function cmd_todo_add(cx)
	cx:prompt({ placeholder = "New to-do…", action = "add" }):next(function(text, _e, cx2)
		if text and core.trim(text) ~= "" then
			add_card(cx2, general_board(), core.trim(text), nil)
		end
	end)
end

local function cmd_todo_open(cx)
	cx.board:open(general_board(), { how = "pip" })
end

return {
	cmd_capture = cmd_capture,
	cmd_capture_selection = cmd_capture_selection,
	cmd_review = cmd_review,
	cmd_send = cmd_send,
	cmd_export = cmd_export,
	cmd_delete = cmd_delete,
	cmd_todo_add = cmd_todo_add,
	cmd_todo_open = cmd_todo_open,
}
