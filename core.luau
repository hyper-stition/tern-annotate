-- Pure logic for the annotate plugin: no Tern APIs, so it can be tested alone.
-- Written in the subset common to Lua 5.4 and Luau (no type annotations, no
-- compound assignment, no if-expressions).
--
-- An artifact is a frozen snapshot of some block, split into units, plus the
-- comments made on it:
--   { id, title, src = {kind, pane?, path?, cwd?}, units = {{id, text, role?, msg?}},
--     comments = {{id, unit, quote, kind, state, thread = {{who, text, ts}}, ts, orphaned?}},
--     mode = "manual" | "immediate" | "batch", target?, activity }
-- Comment kinds: edit (sent to an agent), question (answered by a side agent),
-- note (private), todo (becomes a board card).
-- Comment states: open, asking, answered, sent, applied, resolved, filed.

local core = {}

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

function core.hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

function core.b36(n)
	if n == 0 then
		return "0"
	end
	local out = {}
	while n > 0 do
		local d = n % 36
		table.insert(out, 1, string.sub(B36, d + 1, d + 1))
		n = (n - d) // 36
	end
	return table.concat(out)
end

function core.trim(s)
	local t = string.gsub(s, "^%s+", "")
	t = string.gsub(t, "%s+$", "")
	return t
end

function core.norm(s)
	return core.trim((string.gsub(s, "%s+", " ")))
end

-- A short, single-line quote of a unit, for anchoring and display.
function core.quote(text, n)
	n = n or 160
	local q = core.norm(text)
	if #q > n then
		q = string.sub(q, 1, n) .. "…"
	end
	return q
end

local function unquote(q)
	return (string.gsub(q, "…$", ""))
end
core.unquote = unquote

-- Splits text into units: paragraphs (blank-line separated, fenced code kept
-- together) cut to at most `max_lines` lines. Unit ids hash the normalised text,
-- with a counter for repeats, so a unit keeps its id while its text and its
-- repeat order are unchanged, wherever it moves.
--
-- `work` is a list of { text, role?, msg? } (a document is one item, a chat one
-- per message). Returns a stepper: each call `step(n)` handles up to `n` lines
-- and returns the unit list once everything is split, else nil. Window hooks have
-- a 50 ms budget, so callers run it in short slices.
function core.unit_stepper(work, opts)
	opts = opts or {}
	local max_lines = opts.max_lines or 12
	local seen, units = {}, {}
	local wi = 0
	local iter, cur, fence, role, msg = nil, {}, false, nil, nil

	local function add(chunk)
		local t = core.trim(chunk)
		if t == "" then
			return
		end
		local h = core.hash(core.norm(t))
		seen[h] = (seen[h] or 0) + 1
		local id = core.b36(h)
		if seen[h] > 1 then
			id = id .. "." .. seen[h]
		end
		table.insert(units, { id = id, text = t, role = role, msg = msg })
	end

	local function flush()
		local i = 1
		while i <= #cur do
			local j = math.min(i + max_lines - 1, #cur)
			add(table.concat(cur, "\n", i, j))
			i = j + 1
		end
		cur = {}
	end

	return function(budget)
		local n = 0
		while n < budget do
			if iter == nil then
				wi = wi + 1
				local w = work[wi]
				if w == nil then
					return units
				end
				role, msg = w.role, w.msg
				cur, fence = {}, false
				iter = string.gmatch((w.text or "") .. "\n", "(.-)\r?\n")
			end
			local line = iter()
			if line == nil then
				flush()
				iter = nil
			else
				if string.match(line, "^%s*```") or string.match(line, "^%s*~~~") then
					fence = not fence
					table.insert(cur, line)
				elseif not fence and string.match(line, "^%s*$") then
					flush()
				else
					table.insert(cur, line)
				end
				n = n + 1
			end
		end
		return nil
	end
end

function core.split_units(text, opts)
	opts = opts or {}
	return core.unit_stepper({ { text = text, role = opts.role, msg = opts.msg } }, opts)(math.huge)
end

-- Units of a chat transcript; each unit remembers its message number and role.
function core.units_from_messages(msgs)
	local work = {}
	for i, m in ipairs(msgs) do
		table.insert(work, { text = m.text or "", role = m.role, msg = i })
	end
	return core.unit_stepper(work)(math.huge)
end

function core.unit_by_id(a, id)
	for i, u in ipairs(a.units) do
		if u.id == id then
			return u, i
		end
	end
	return nil, nil
end

function core.new_artifact(id, title, src, units, now)
	return {
		id = id,
		title = title,
		src = src,
		units = units,
		comments = {},
		mode = "manual",
		created = now,
		activity = now,
	}
end

-- `quote` (optional) is the exact passage commented on, when narrower than the unit.
function core.new_comment(a, kind, text, unit, now, quote)
	local c = {
		id = "c" .. core.b36(core.hash(a.id .. ":" .. now .. ":" .. #a.comments .. ":" .. text)),
		unit = unit.id,
		quote = core.quote(quote or unit.text),
		kind = kind,
		state = "open",
		thread = { { who = "you", text = text, ts = now } },
		ts = now,
	}
	table.insert(a.comments, c)
	a.activity = now
	return c
end

function core.find_comment(a, id)
	for i, c in ipairs(a.comments) do
		if c.id == id then
			return c, i
		end
	end
	return nil, nil
end

function core.reply(c, who, text, now)
	table.insert(c.thread, { who = who, text = text, ts = now })
end

-- Comments of `a` waiting to be sent to an agent.
function core.pending(a)
	local out = {}
	for _, c in ipairs(a.comments) do
		if c.kind == "edit" and c.state == "open" then
			table.insert(out, c)
		end
	end
	return out
end

function core.counts(a)
	local n = { total = #a.comments, open = 0, pending = 0, sent = 0, applied = 0, resolved = 0 }
	for _, c in ipairs(a.comments) do
		if c.state == "resolved" or c.state == "filed" then
			n.resolved = n.resolved + 1
		else
			n.open = n.open + 1
		end
		if c.state == "sent" then
			n.sent = n.sent + 1
		elseif c.state == "applied" then
			n.applied = n.applied + 1
		end
		if c.kind == "edit" and c.state == "open" then
			n.pending = n.pending + 1
		end
	end
	return n
end

return core
