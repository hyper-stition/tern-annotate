-- Visible text out of an HTML page (nothing is run: no JavaScript, no layout).
-- Written in the subset common to Lua 5.4 and Luau so it can be tested alone.

local html = {}

local ENT = {
	amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
	mdash = "—", ndash = "–", hellip = "…", ldquo = "“", rdquo = "”",
	lsquo = "‘", rsquo = "’", copy = "©", middot = "·", bull = "•",
}

local BLOCK = {
	p = true, div = true, section = true, article = true, header = true, footer = true,
	nav = true, main = true, aside = true, blockquote = true, pre = true, figure = true,
	figcaption = true, ul = true, ol = true, table = true, tr = true, dl = true, dt = true,
	dd = true, form = true, details = true, summary = true, address = true,
}

local DROP = { "script", "style", "noscript", "svg", "template", "head", "iframe" }

-- Removes <tag ...> ... </tag> blocks with plain finds (linear, no backtracking).
local function drop_blocks(s, tag)
	local lower = string.lower(s)
	local open, close = "<" .. tag, "</" .. tag .. ">"
	local out, pos = {}, 1
	while true do
		local a = string.find(lower, open, pos, true)
		if not a then
			break
		end
		local after = string.sub(lower, a + #open, a + #open)
		if after ~= "" and not string.match(after, "[%s>/]") then
			-- a longer tag name that merely starts with this one
			table.insert(out, string.sub(s, pos, a + #open - 1))
			pos = a + #open
		else
			table.insert(out, string.sub(s, pos, a - 1))
			local b = string.find(lower, close, a, true)
			if not b then
				pos = #s + 1
				break
			end
			pos = b + #close
		end
	end
	table.insert(out, string.sub(s, pos))
	return table.concat(out)
end

-- The page title, or nil.
function html.title(s)
	local t = string.match(s, "<[tT][iI][tT][lL][eE][^>]*>(.-)</[tT][iI][tT][lL][eE]>")
	if not t then
		return nil
	end
	t = string.gsub(t, "%s+", " ")
	t = string.gsub(t, "^ ", "")
	t = string.gsub(t, " $", "")
	return t
end

html.DROP = DROP
html.drop_blocks = drop_blocks

-- `s` without <!-- comments -->.
function html.strip_comments(s)
	local out, pos = {}, 1
	while true do
		local a = string.find(s, "<!--", pos, true)
		if not a then
			break
		end
		table.insert(out, string.sub(s, pos, a - 1))
		local b = string.find(s, "-->", a, true)
		if not b then
			pos = #s + 1
			break
		end
		pos = b + 3
	end
	table.insert(out, string.sub(s, pos))
	return table.concat(out)
end

-- The page without scripts, styles, head and other non-visible blocks, and
-- without comments (all at once; callers with a time budget run the two parts
-- separately).
function html.visible(s)
	for _, tag in ipairs(DROP) do
		s = drop_blocks(s, tag)
	end
	return html.strip_comments(s)
end

-- Cuts `s` into pieces of about `n` bytes, always just after a '>' so no tag is split.
function html.chunks(s, n)
	local out, pos = {}, 1
	while pos <= #s do
		local e = pos + n - 1
		if e >= #s then
			table.insert(out, string.sub(s, pos))
			break
		end
		local gt = string.find(s, ">", e, true)
		if not gt then
			table.insert(out, string.sub(s, pos))
			break
		end
		table.insert(out, string.sub(s, pos, gt))
		pos = gt + 1
	end
	return out
end

local function entity(e)
	if string.sub(e, 1, 1) == "#" then
		local body = string.sub(e, 2)
		local n
		if string.sub(body, 1, 1) == "x" or string.sub(body, 1, 1) == "X" then
			n = tonumber(string.sub(body, 2), 16)
		else
			n = tonumber(body)
		end
		if n and n > 0 and n < 0x110000 then
			return utf8.char(n)
		end
		return "&" .. e .. ";"
	end
	return ENT[e] or ("&" .. e .. ";")
end

-- Text of one chunk of visible HTML: headings and list items marked, block
-- boundaries as blank lines, other tags dropped, entities decoded.
function html.to_text(s)
	s = string.gsub(s, "[\r\n\t]+", " ")
	s = string.gsub(s, "<![%a][^>]*>", "")
	s = string.gsub(s, "<(/?)(%a[%w]*)[^>]*>", function(slash, name)
		name = string.lower(name)
		local h = string.match(name, "^h([1-6])$")
		if h then
			if slash == "" then
				return "\n\n" .. string.rep("#", math.min(tonumber(h), 4)) .. " "
			end
			return "\n\n"
		end
		if name == "li" then
			if slash == "" then
				return "\n- "
			end
			return ""
		end
		if name == "br" or name == "hr" or name == "tr" then
			return "\n"
		end
		if BLOCK[name] then
			return "\n\n"
		end
		if name == "td" or name == "th" then
			if slash == "" then
				return " | "
			end
			return ""
		end
		return ""
	end)
	s = string.gsub(s, "&(#?%w+);", entity)
	s = string.gsub(s, "[ \t\r]+", " ")
	s = string.gsub(s, " *\n *", "\n")
	return s
end

-- Joins converted chunks: at most one blank line between paragraphs.
function html.join(pieces, title)
	local text = table.concat(pieces)
	text = string.gsub(text, "\n\n\n+", "\n\n")
	text = string.gsub(text, "^%s+", "")
	if title and title ~= "" then
		text = "# " .. title .. "\n\n" .. text
	end
	return text
end

return html
