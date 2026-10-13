-- Annotate: comments on a snapshot of any block (an agent's reply, a file, a web
-- page, a terminal). Edit comments go to an agent on demand or in batches,
-- questions go to Carly, to-dos become cards on the general-todo board.
--
-- This file only registers things. Tern compiles every chunk it loads (about
-- 4 ms per KB when the window is busy) and every hook has a 50 ms budget whose
-- trip disables the hook, so the code lives in modules of at most about 6 KB,
-- preloaded one per timer tick shortly after load. Commands never compile
-- modules inside their own hook: until the preload is done they ask the user to
-- retry.

local T_LOAD = tern.now()
local last_alive = T_LOAD -- last time one of this plugin's timers ran
local TICK_MS = 60 * 1000
local WAIT_MS = 35 * 1000 -- after this, stop waiting for a preload and compile on demand
local PRELOAD_AFTER_MS = 6000 -- the window is busy starting up at first; compile once it settles
local PRELOAD_STEP_MS = 700

-- Modules are compiled with loadstring instead of `require`: measured in this
-- window, `require` cost 15-29 ms per small module (it also generates native code)
-- against 1.5-6 ms to compile the same source, and a stall in that cost is what
-- trips the 50 ms budget. Each module sees `req` as its `require`.
local DIR = tern.plugin.dir
local loaded = {}
local function req(name)
	local key = string.gsub(name, "^%./", "")
	local m = loaded[key]
	if m == nil then
		local f, err = loadstring("local require = ...\n" .. tern.fs.read(DIR .. "/" .. key .. ".luau"), "=" .. key)
		if not f then
			error(err)
		end
		m = f(req)
		loaded[key] = m
	end
	return m
end

local function events()
	return req("./events")
end

local function commands()
	return req("./commands")
end

-- What Carly is told (her context hook has a 4 ms budget, so it only returns this
-- string; a timer recomputes it from the index).
local summary = nil
local function update_summary()
	local idx = tern.kv.get("index")
	summary = nil
	if type(idx) ~= "table" then
		return
	end
	local p, s, r = 0, 0, 0
	for _, e in ipairs(idx) do
		p += e.pending or 0
		s += e.sent or 0
		r += e.applied or 0
	end
	if p + s + r > 0 then
		summary = string.format("Annotate: %d pending edit comments, %d sent, %d revisions to review.", p, s, r)
	end
end

local loaders = {
	function() return req("./core") end,
	function() return req("./anchor") end,
	function() return req("./nodes") end,
	function() return req("./view") end,
	function() return req("./store") end,
	function() return req("./panel") end,
	function() return req("./html") end,
	function() return req("./sources") end,
	function() return req("./prompts") end,
	function() return req("./actions") end,
	function() return req("./flows") end,
	function() return req("./reviews") end,
	function() return req("./events") end,
	function() return req("./commands") end,
}
local NAMES = { "core", "anchor", "nodes", "view", "store", "panel", "html", "sources", "prompts", "actions", "flows", "reviews", "events", "commands" }
local ready = false

-- One step per timer, the next armed only after this one finishes: when the
-- window has not rendered for a while, due timers fire together, and independent
-- timers would then compile several modules inside one 50 ms deadline.
local step_i = 0
local function preload_step()
	last_alive = tern.now()
	local t0 = last_alive
	-- As many modules as fit in about 10 ms; the next step is armed only afterwards.
	repeat
		step_i += 1
		local i = step_i
		local ok, err = pcall(loaders[i])
		if not ok then
			tern.log.warn("annotate: preload of " .. NAMES[i] .. " failed: " .. tostring(err))
		end
		if i == 1 then
			update_summary()
		end
	until step_i >= #loaders or tern.now() - t0 > 10
	local dt = tern.now() - t0
	if dt > 25 then
		tern.log.warn(string.format("annotate: preload step took %.0f ms (through %s)", dt, NAMES[step_i]))
	end
	if step_i < #loaders then
		tern.timer(PRELOAD_STEP_MS, preload_step)
	else
		ready = true
		tern.log.warn(string.format("annotate: ready after %.1f s", (tern.now() - T_LOAD) / 1000))
	end
end
tern.timer(PRELOAD_AFTER_MS, preload_step)

local function heal(cx, why)
	local last = tern.kv.get("last_heal")
	if type(last) == "number" and os.time() - last < 600 then
		return false
	end
	tern.kv.set("last_heal", os.time())
	tern.log.warn("annotate: " .. why .. "; reloading plugins")
	cx:command("reload_plugins")
	return true
end

local function usable(cx)
	if ready then
		return true
	end
	local now = tern.now()
	-- A preload step re-arms its timer within a second: a silence of several seconds
	-- after the preload should have started means that hook was disabled.
	if now - T_LOAD > PRELOAD_AFTER_MS + 10 * 1000 and now - last_alive > 8 * 1000 and heal(cx, "preload stalled") then
		cx:toast("info", "Annotate is restarting", "Try again in a few seconds.")
		return false
	end
	if now - T_LOAD > WAIT_MS then
		return true
	end
	cx:toast("info", "Annotate is still starting", "Try again in a few seconds.")
	return false
end

-- Self-healing. A hook that runs over its 50 ms budget is disabled until the next
-- reload, and a stall on a busy machine is enough to do it; if it was the timer
-- hook, preloading, saving and batching all stop. A focus event is a sign the
-- window is in use: when no timer of ours has run for minutes, reload the plugins
-- (fresh VMs re-enable every hook), at most once every ten minutes.
tern.on("focus", function(_ev, cx)
	if tern.now() - last_alive > 2 * TICK_MS + 15 * 1000 then
		heal(cx, "timers stopped")
	end
end)

tern.on("agent_finished", function(ev, cx)
	if ready then
		events().agent_finished(ev, cx)
	end
end)

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id then
		return false
	end
	if not usable(cx) then
		return true
	end
	return events().canvas_action(ev, cx)
end)

-- Batch timer: no model involved; it only decides when to send. A cheap look at
-- the index decides whether the events module is needed at all.
local function schedule_tick()
	tern.timer(TICK_MS, function(cx)
		last_alive = tern.now()
		update_summary()
		local wanted = false
		local idx = tern.kv.get("index")
		if type(idx) == "table" then
			for _, e in ipairs(idx) do
				if e.mode == "batch" and (e.pending or 0) > 0 then
					wanted = true
					break
				end
			end
		end
		if wanted and cx and ready then
			local ok, err = pcall(function()
				events().tick(cx)
			end)
			if not ok then
				tern.log.warn("annotate: batch tick failed: " .. tostring(err))
			end
		end
		schedule_tick()
	end)
end
schedule_tick()

-- Carly can see what is waiting.
tern.carly.context(function(_cx)
	return summary
end)

tern.carly.export("annotations", {
	sig = "annotations(): { { id: string, title: string, pending: number, sent: number, applied: number } }",
	doc = "Lists annotation reviews with their counts of pending edit comments, comments sent to an agent and revisions awaiting review.",
}, function(_cx, _call)
	if not ready then
		return {}
	end
	return events().annotations()
end)

tern.carly.export("answer", {
	sig = "answer(review: string, comment: string, text: string): boolean",
	doc = "Saves text as Carly's answer in the thread of a question comment of an annotation review and marks it answered. Returns false when the review or comment no longer exists.",
}, function(review, comment, text, cx, _call)
	if not ready then
		return false
	end
	return events().answer(review, comment, text, cx)
end)

-- id, palette title, icon, default chords. Highlight text, copy it, then run
-- "Annotate copied text" (plugins cannot extend the built-in right-click menu).
local COMMANDS = {
	{ "capture", "Annotate this block…", "sparkle", { "ctrl+alt+a" } },
	{ "capture_selection", "Annotate copied text…", "sparkle", { "ctrl+alt+g" } },
	{ "review", "Open annotation review…", "sparkle", nil },
	{ "send", "Send pending annotation comments", "sparkle", nil },
	{ "export", "Copy annotations as Markdown…", "sparkle", nil },
	{ "delete", "Delete an annotation review…", "sparkle", nil },
	{ "todo_add", "Add to-do…", "success", { "ctrl+alt+t" } },
	{ "todo_open", "Open general to-do (floating)", "success", { "ctrl+alt+b" } },
}
for _, c in ipairs(COMMANDS) do
	local id = c[1]
	tern.command({
		id = id,
		title = c[2],
		icon = c[3],
		keys = c[4],
		run = function(cx)
			if usable(cx) then
				commands()["cmd_" .. id](cx)
			end
		end,
	})
end
