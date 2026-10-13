-- Text built from reviews: prompts to agents and Carly, board cards, Markdown export.

local core = require("./core")

local prompts = {}

local function thread_text(c, skip_last)
	local lines = {}
	local last = #c.thread
	if skip_last then
		last = last - 1
	end
	for i = 1, last do
		local m = c.thread[i]
		table.insert(lines, "   " .. m.who .. ": " .. m.text)
	end
	return table.concat(lines, "\n")
end

local function source_line(a)
	local s = "Source: " .. a.title
	if a.src and a.src.path then
		s = s .. " (" .. a.src.path .. ")"
	end
	return s
end

-- The prompt that carries a batch of edit comments to an agent.
function prompts.format_edits(a, list)
	local out = {}
	table.insert(out, "Revise the work below according to my review comments. Each comment quotes the passage it concerns.")
	if a.src and a.src.kind == "file" and a.src.path then
		table.insert(out, "The text is the file " .. a.src.path .. ": edit it in place.")
	elseif a.src and a.src.kind == "agent" then
		table.insert(out, "The passages are from your earlier replies in this conversation.")
	elseif a.src and a.src.kind == "browser" and a.src.path then
		table.insert(out, "The passages are from the web page " .. a.src.path .. ". Find the source that produces that page and change it there.")
	end
	table.insert(out, "Where a comment is ambiguous, make the smallest reasonable change and say what you assumed. Finish with a short list of what changed.")
	table.insert(out, "")
	for i, c in ipairs(list) do
		table.insert(out, i .. '. Re: "' .. c.quote .. '"')
		table.insert(out, "   Comment: " .. c.thread[1].text)
		if #c.thread > 1 then
			table.insert(out, "   Discussion:")
			local rest = {}
			for k = 2, #c.thread do
				table.insert(rest, "   " .. c.thread[k].who .. ": " .. c.thread[k].text)
			end
			table.insert(out, table.concat(rest, "\n"))
		end
	end
	return table.concat(out, "\n")
end

-- The prompt that asks an assistant a question about a passage. `extra` is
-- appended as a final instruction (how to hand the answer back).
function prompts.format_question(a, c, extra)
	local _, idx = core.unit_by_id(a, c.unit)
	local ctx = {}
	if idx then
		for i = math.max(1, idx - 1), math.min(#a.units, idx + 1) do
			table.insert(ctx, a.units[i].text)
		end
	else
		table.insert(ctx, c.quote)
	end
	local context = table.concat(ctx, "\n\n")
	if #context > 3000 then
		context = string.sub(context, 1, 3000) .. "…"
	end
	local out = {
		"Answer a question about a passage of text. Be concise. Do not modify any files, and do nothing beyond answering except what the final instruction (if any) asks.",
		source_line(a),
		"",
		"Context:",
		"<<<",
		context,
		">>>",
		"",
		'Passage in question: "' .. c.quote .. '"',
	}
	if #c.thread > 1 then
		table.insert(out, "Conversation so far:")
		table.insert(out, thread_text(c, true))
	end
	table.insert(out, "Question: " .. c.thread[#c.thread].text)
	if extra and extra ~= "" then
		table.insert(out, "")
		table.insert(out, extra)
	end
	return table.concat(out, "\n")
end

-- A card for the to-do board from a comment.
function prompts.todo_text(c)
	local t = c.thread[1].text
	if c.quote and c.quote ~= "" then
		t = t .. ' (re: "' .. core.quote(core.unquote(c.quote), 60) .. '")'
	end
	return t
end

function prompts.date(ts)
	return os.date("!%Y-%m-%d %H:%M", ts)
end

-- Markdown export: comments grouped by unit, in document order, then orphans.
function prompts.to_markdown(a)
	local n = core.counts(a)
	local md = {}
	table.insert(md, "# Annotations: " .. a.title)
	table.insert(md, "")
	table.insert(md, "- Comments: " .. n.total .. " (" .. n.open .. " open, " .. n.resolved .. " resolved)")
	table.insert(md, "- Source: " .. ((a.src and a.src.path) or (a.src and a.src.kind) or "block"))
	table.insert(md, "")
	local order = {}
	for i, u in ipairs(a.units) do
		order[u.id] = i
	end
	local groups, keys = {}, {}
	for _, c in ipairs(a.comments) do
		local k = c.unit
		if not groups[k] then
			groups[k] = {}
			table.insert(keys, k)
		end
		table.insert(groups[k], c)
	end
	table.sort(keys, function(x, y)
		return (order[x] or 1e9) < (order[y] or 1e9)
	end)
	for _, k in ipairs(keys) do
		local first = groups[k][1]
		local label = order[k] and "" or " (detached)"
		table.insert(md, "## " .. core.quote(core.unquote(first.quote), 80) .. label)
		table.insert(md, "")
		table.insert(md, "> " .. first.quote)
		table.insert(md, "")
		for _, c in ipairs(groups[k]) do
			table.insert(md, "- **" .. c.kind .. "** " .. prompts.date(c.ts) .. " · " .. c.state)
			for _, m in ipairs(c.thread) do
				table.insert(md, "  - " .. m.who .. ": " .. string.gsub(m.text, "\n", " "))
			end
		end
		table.insert(md, "")
	end
	return table.concat(md, "\n")
end

return prompts
