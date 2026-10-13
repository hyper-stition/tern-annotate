-- Reading blocks (and the clipboard) into units.
local core = require("./core")
local html = require("./html")

local MAX_CHARS = 60000 -- most text taken from one source

local function flatten(r)
	if type(r) == "string" then
		return r
	end
	if type(r) ~= "table" then
		return nil
	end
	if type(r.text) == "string" then
		return r.text
	end
	local parts = {}
	for _, l in ipairs(r.lines or {}) do
		table.insert(parts, if type(l) == "string" then l else (l.text or tostring(l)))
	end
	return table.concat(parts, "\n")
end

local function src_of(cx, pane)
	local info = cx.session:pane(pane)
	local src = { kind = "block", pane = pane }
	if info then
		src.kind = info.kind or "block"
		src.cwd = info.cwd
		src.path = info.path
		src.title = info.title
	end
	if src.kind == "browser" then
		src.path = info and info.url or nil
	elseif src.kind ~= "agent" and src.kind ~= "file" then
		src.path = nil
	end
	return src
end

-- Page text out of a browser snapshot answer.
local function page_text(ok)
	if type(ok) == "string" then
		return ok
	end
	if type(ok) ~= "table" then
		return nil
	end
	for _, k in ipairs({ "text", "snapshot", "tree", "content" }) do
		if type(ok[k]) == "string" then
			return ok[k]
		end
	end
	return nil
end

local function cut(text)
	if #text > MAX_CHARS then
		return string.sub(text, 1, MAX_CHARS) .. "\n\n[Cut at " .. MAX_CHARS .. " characters.]"
	end
	return text
end

-- Splits `work` (see core.unit_stepper) in slices short enough for a window
-- hook, then calls cb(units, nil, cx).
local function split_sliced(cx, work, cb)
	local step = core.unit_stepper(work)
	local function run(cx2)
		local t0 = tern.now()
		repeat
			local units = step(150)
			if units then
				cb(units, nil, cx2)
				return
			end
		until tern.now() - t0 > 10
		tern.timer(1, run)
	end
	run(cx)
end

-- Runs `step` (one small piece of work; returns true when finished) in slices of
-- about 10 ms across timer ticks, then done(cx).
local function sliced(cx, step, done)
	local function run(cx2)
		local t0 = tern.now()
		repeat
			if step() then
				done(cx2)
				return
			end
		until tern.now() - t0 > 10
		tern.timer(1, run)
	end
	run(cx)
end

local NO_TEXT = "That page has almost no text without JavaScript. Press Ctrl+A then Ctrl+C in it, then use “Annotate copied text” (ctrl+alt+g)."

-- HTML in, units out (via cb), in slices short enough for a window hook.
local function page_from_html(cx, body, cb)
	body = string.sub(body, 1, 300000)
	local title = html.title(body)
	if title then
		title = core.trim(html.to_text(title))
	end
	local ti, stage, ci, chunks, pieces = 1, 1, 1, nil, {}
	local function step()
		if ti <= #html.DROP then
			body = html.drop_blocks(body, html.DROP[ti])
			ti = ti + 1
			return false
		end
		if stage == 1 then
			body = html.strip_comments(body)
			chunks = html.chunks(body, 20000)
			stage = 2
			return false
		end
		if ci <= #chunks then
			table.insert(pieces, html.to_text(chunks[ci]))
			ci = ci + 1
			return false
		end
		return true
	end
	sliced(cx, step, function(cx2)
		local text = html.join(pieces, title)
		if #text < 200 then
			cb(nil, NO_TEXT, cx2)
			return
		end
		split_sliced(cx2, { { text = cut(text) } }, cb)
	end)
end

-- A browser block's text by fetching its address (Tern's own page snapshot needs
-- macOS or Linux), so what is read is the page as the server sends it.
local function page_via_http(cx, src, cb)
	local url = src.path
	if not url or url == "" then
		cb(nil, "that page has no address", cx)
		return
	end
	if string.sub(url, 1, 7) == "file://" then
		local path = string.gsub(string.sub(url, 8), "^/(%a:)", "%1")
		local ok, body = pcall(tern.fs.read, path, 2000000)
		if ok then
			page_from_html(cx, body, cb)
		else
			cb(nil, "cannot read " .. path, cx)
		end
		return
	end
	tern.fetch(url, { timeout_ms = 15000 }, function(res, _cx)
		if res.error or (res.status or 0) >= 400 then
			tern.timer(1, function(cx3)
				cb(nil, res.error or ("the server answered " .. tostring(res.status)), cx3)
			end)
			return
		end
		-- continue outside the fetch hook, whose budget the work below would blow
		tern.timer(1, function(cx3)
			page_from_html(cx3, res.body or "", cb)
		end)
	end)
end
-- cb(units, err, cx). Agents give their chat messages (newest that fit), files
-- their live buffer, browser blocks their page text, everything else the
-- block's text.
local function fetch(cx, src, cb)
	if src.kind == "agent" and src.pane then
		local ok, msgs = pcall(function()
			return cx.agents:transcript(src.pane, { last = 400 })
		end)
		if ok and type(msgs) == "table" and #msgs > 0 then
			local work, total = {}, 0
			for i = #msgs, 1, -1 do
				local t = msgs[i].text or ""
				if total + #t > MAX_CHARS and #work > 0 then
					break
				end
				total = total + math.min(#t, MAX_CHARS)
				table.insert(work, 1, { text = string.sub(t, 1, MAX_CHARS), role = msgs[i].role, msg = i })
			end
			split_sliced(cx, work, cb)
			return
		end
	end
	if src.kind == "browser" then
		local os_name = string.lower(tern.runtime.os or "")
		if string.find(os_name, "win", 1, true) or not src.pane then
			page_via_http(cx, src, cb)
			return
		end
		-- macOS and Linux: Tern's snapshot first, the address as a fallback.
		cx.browser
			:call({ op = "snapshot", block = src.pane, mode = "text", format = "text", nodes = 3000 })
			:next(function(r, _err, cx2)
				local text = page_text(r and r.ok)
				if text then
					split_sliced(cx2, { { text = cut(text) } }, cb)
				else
					page_via_http(cx2, src, cb)
				end
			end)
		return
	end
	if src.kind == "file" and src.path then
		cx.docs:read(src.path):next(function(text, err, cx2)
			if text then
				split_sliced(cx2, { { text = cut(text) } }, cb)
			else
				cb(nil, err or "file unreadable", cx2)
			end
		end)
		return
	end
	local r = if src.pane then cx.session:read(src.pane, { as = "text", max_chars = MAX_CHARS, lines = 2000 }) else nil
	local text = flatten(r)
	if not text then
		cb(nil, "that block is gone; the snapshot is kept", cx)
		return
	end
	split_sliced(cx, { { text = cut(text) } }, cb)
end

return {
	src_of = src_of,
	fetch = fetch,
}
