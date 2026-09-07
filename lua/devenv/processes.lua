-- Process/service management on top of `devenv processes`.
--
-- Lifecycle as seen from Neovim:
--   not_running   --up()-->   initializing   --(up -d exits 0)-->   running
--   running       --down()--> shutting_down  --(down exits)-->      not_running
--
-- `devenv processes up -d` blocks until the processes have started, and the
-- process manager cannot be queried before that, so `initializing` simply
-- spans the lifetime of that command. While `running`, `devenv processes list`
-- is polled to keep per-process phases current and to notice the manager
-- disappearing (e.g. `devenv processes down` run from a terminal).
local config = require("devenv.config")
local devenv = require("devenv.devenv")

local M = {}

---@alias DevenvProcessesStatus
---| "not_running"   # No process manager is running.
---| "initializing"  # `devenv processes up` is starting the processes.
---| "running"       # The process manager is up; see `processes` for per-process phases.
---| "shutting_down" # `devenv processes down` is stopping the processes.

---@class DevenvProcessPort
---@field name string devenv's port name, e.g. "main".
---@field port integer The port actually bound (devenv may allocate around conflicts).

---@class DevenvProcess
---@field name string
---@field phase string devenv's phase for the process, e.g. "ready", "exited", "stopped".
---@field restarts integer
---@field ports DevenvProcessPort[] Bound ports as reported by the manager, in devenv's order.

---Phase given to configured processes while the process manager is not running.
M.PHASE_OFF = "off"

-- devenv cannot start the process manager on its own; `up` needs at least one
-- configured process. To start the manager without touching the user's
-- processes we inject a throwaway process with `--option` that exits at once.
-- It is filtered out of everything the plugin reports.
local MANAGER_PROCESS = "devenv-nvim-manager"

---@class DevenvProcessesState
---@field status DevenvProcessesStatus
---@field processes table<string, DevenvProcess> Processes by name. While the manager is down these are the configured processes with phase `off`.
---@field configured string[] Process names from devenv.nix (via `devenv eval processes`), sorted.
---@field err string|nil Error from the last failed up/down/list/eval.

---@type DevenvProcessesState
M.state = {
	status = "not_running",
	processes = {},
	configured = {},
	err = nil,
}

---@type uv.uv_timer_t|nil
local poll_timer

---@param msg string
---@param level integer
local function notify(msg, level)
	if config.get("notify") then
		vim.notify(msg, level, { title = "devenv" })
	end
end

local NO_MANAGER = "No process manager is running"

---@param status DevenvProcessesStatus
---@param processes table<string, DevenvProcess>|nil
local function set_state(status, processes)
	local changed = status ~= M.state.status or not vim.deep_equal(processes or {}, M.state.processes)
	M.state.status = status
	M.state.processes = processes or {}
	if changed then
		vim.api.nvim_exec_autocmds("User", {
			pattern = "DevenvProcessesChanged",
			data = { status = status, processes = M.state.processes },
		})
	end
end

---Parse the output of `devenv processes list`. Lines look like:
---`redis    ready restarts: 0 ports: main:6379, management:15672`
---@param stdout string
---@return table<string, DevenvProcess>
function M.parse_list(stdout)
	local processes = {}
	for line in devenv.strip_ansi(stdout):gmatch("[^\n]+") do
		local name, phase, restarts, rest = line:match("^%s*(%S+)%s+(%S+)%s+restarts:%s*(%d+)(.*)$")
		if name and name ~= MANAGER_PROCESS then
			local ports = {}
			local port_list = rest:match("ports:%s*(.*)$")
			if port_list then
				for port_name, port in port_list:gmatch("([%w_%-]+):(%d+)") do
					ports[#ports + 1] = { name = port_name, port = tonumber(port) }
				end
			end
			processes[name] = { name = name, phase = phase, restarts = tonumber(restarts), ports = ports }
		end
	end
	return processes
end

---Run `devenv <args>` in `root`.
---@param root string
---@param args string[]
---@param callback fun(res: vim.SystemCompleted, stderr: string)
local function run_devenv(root, args, callback)
	local cmd = vim.list_extend(devenv.cmd(config.get("devenv")), args)
	local ok, err = pcall(vim.system, cmd, { cwd = root, text = true }, function(res)
		vim.schedule(function()
			callback(res, vim.trim(devenv.strip_ansi(res.stderr or "")))
		end)
	end)
	if not ok then
		vim.schedule(function()
			callback({ code = 127, signal = 0, stdout = "", stderr = "" }, ("failed to spawn devenv: %s"):format(err))
		end)
	end
end

---Run `devenv processes <args>` in `root`.
---@param root string
---@param args string[]
---@param callback fun(res: vim.SystemCompleted, stderr: string)
local function run(root, args, callback)
	run_devenv(root, vim.list_extend({ "processes" }, args), callback)
end

---Configured processes as an `off` process table.
---@return table<string, DevenvProcess>
local function off_processes()
	local processes = {}
	for _, name in ipairs(M.state.configured) do
		processes[name] = { name = name, phase = M.PHASE_OFF, restarts = 0, ports = {} }
	end
	return processes
end

---Copy of the current process table with `phase` set for `names` (all known
---processes when `names` is empty). Used to show what is about to happen
---before devenv reports it.
---@param names string[]
---@param phase string
---@return table<string, DevenvProcess>
local function with_phase(names, phase)
	local processes = vim.deepcopy(M.state.processes)
	if #names == 0 then
		names = vim.tbl_keys(processes)
	end
	for _, name in ipairs(names) do
		local p = processes[name] or { name = name, restarts = 0, ports = {} }
		p.phase = phase
		processes[name] = p
	end
	return processes
end

---Fingerprint of the evaluated process configuration from the last discover().
---@type string|nil
local fingerprint

---Read the configured process names from devenv.nix (`devenv eval processes`).
---This needs no running manager; it is what lets the panel list processes that
---can be started. Cheap when the evaluation is cached.
---`changed` is true when the process configuration differs from the previous
---discovery (false on the first one).
---@param root string
---@param callback fun(ok: boolean, changed: boolean)
function M.discover(root, callback)
	run_devenv(root, { "eval", "processes" }, function(res, stderr)
		if res.code ~= 0 then
			M.state.err = "failed to evaluate processes:\n" .. devenv.summarize_errors(stderr)
			callback(false, false)
			return
		end
		local ok, decoded = pcall(vim.json.decode, res.stdout or "")
		local defs = ok and type(decoded) == "table" and decoded.processes or nil
		if type(defs) ~= "table" then
			M.state.err = "unexpected output from devenv eval processes"
			callback(false, false)
			return
		end
		local names = vim.tbl_keys(defs)
		table.sort(names)
		M.state.configured = names

		local new_fingerprint = vim.fn.sha256(res.stdout or "")
		local changed = fingerprint ~= nil and fingerprint ~= new_fingerprint
		fingerprint = new_fingerprint
		callback(true, changed)
	end)
end

local function stop_polling()
	if poll_timer then
		poll_timer:stop()
		poll_timer:close()
		poll_timer = nil
	end
end

---@param root string
local function start_polling(root)
	stop_polling()
	local interval = config.get("processes_poll_ms")
	if not interval or interval <= 0 then
		return
	end
	poll_timer = vim.uv.new_timer()
	poll_timer:start(interval, interval, function()
		vim.schedule(function()
			if M.state.status == "running" then
				M.refresh(root)
			end
		end)
	end)
end

---Query `devenv processes list` and update the state from the answer.
---When no manager is running, the configured processes are discovered from
---devenv.nix instead and reported with phase `off`.
---Transitional states (`initializing`, `shutting_down`) are left alone.
---@param root string
---@param callback fun(state: DevenvProcessesState)|nil
function M.refresh(root, callback)
	local function finish()
		if callback then
			callback(M.state)
		end
	end
	run(root, { "list" }, function(res, stderr)
		if M.state.status == "initializing" or M.state.status == "shutting_down" then
			-- An up/down is in flight; it will set the final state itself.
		elseif res.code == 0 then
			M.state.err = nil
			local listed = M.parse_list(res.stdout or "")
			-- Whatever the manager reports is configured; remember it for later.
			if #M.state.configured == 0 then
				local names = vim.tbl_keys(listed)
				table.sort(names)
				M.state.configured = names
			end
			-- Keep configured processes the manager does not report as `off`.
			for _, name in ipairs(M.state.configured) do
				if not listed[name] then
					listed[name] = { name = name, phase = M.PHASE_OFF, restarts = 0, ports = {} }
				end
			end
			set_state("running", listed)
			if not poll_timer then
				start_polling(root)
			end
		elseif stderr:find(NO_MANAGER, 1, true) then
			M.state.err = nil
			stop_polling()
			M.discover(root, function()
				set_state("not_running", off_processes())
				finish()
			end)
			return
		else
			M.state.err = devenv.summarize_errors(stderr)
		end
		finish()
	end)
end

---@alias DevenvProcessesCallback fun(ok: boolean, state: DevenvProcessesState)

---@param names string|string[]|nil
---@return string[]
local function to_list(names)
	if names == nil then
		return {}
	end
	if type(names) == "string" then
		return { names }
	end
	return names
end

---Run `devenv processes <subcommand> <name>` for each name, one after the
---other (`start`/`stop` only accept a single name), collecting failures.
---@param root string
---@param subcommand "restart"|"stop"
---@param names string[]
---@param callback fun(errors: string[])
local function run_each(root, subcommand, names, callback)
	local errors = {}
	local i = 0
	local function next_one()
		i = i + 1
		local name = names[i]
		if not name then
			callback(errors)
			return
		end
		run(root, { subcommand, name }, function(res, stderr)
			if res.code ~= 0 then
				errors[#errors + 1] = ("%s: %s"):format(name, devenv.summarize_errors(stderr))
			end
			next_one()
		end)
	end
	next_one()
end

---@param on_done DevenvProcessesCallback|nil
---@param ok boolean
local function done(on_done, ok)
	if on_done then
		on_done(ok, M.state)
	end
end

---Start processes in the background.
---Manager not running: `devenv processes up -d [names]`
---(not_running -> initializing -> running).
---Manager running: the named processes (or all known ones) are (re)started
---with `devenv processes restart <name>`, which also starts stopped ones.
---@param root string
---@param names string|string[]|nil
---@param on_done DevenvProcessesCallback|nil
function M.up(root, names, on_done)
	names = to_list(names)
	if M.state.status == "initializing" or M.state.status == "shutting_down" then
		notify("processes are " .. M.state.status, vim.log.levels.WARN)
		done(on_done, false)
		return
	end
	M.state.err = nil

	if M.state.status == "running" then
		if #names == 0 then
			names = vim.tbl_keys(M.state.processes)
			table.sort(names)
		end
		set_state("running", with_phase(names, "starting"))
		run_each(root, "restart", names, function(errors)
			-- refresh() clears err on a successful list, so record ours afterwards.
			M.refresh(root, function()
				if #errors > 0 then
					M.state.err = "failed to restart:\n" .. table.concat(errors, "\n")
					notify(M.state.err, vim.log.levels.ERROR)
				end
				done(on_done, #errors == 0)
			end)
		end)
		return
	end

	-- Show the requested processes (or all of them) as starting right away;
	-- the manager cannot be queried until `up -d` returns.
	M.state.processes = off_processes()
	set_state("initializing", with_phase(names, "starting"))
	run(root, vim.list_extend({ "up", "-d" }, names), function(res, stderr)
		if res.code ~= 0 then
			M.state.err = ("devenv processes up exited with code %d:\n%s"):format(res.code, devenv.summarize_errors(stderr))
			set_state("not_running", off_processes())
			notify("failed to start processes\n" .. M.state.err, vim.log.levels.ERROR)
			done(on_done, false)
			return
		end
		-- Mark running without an event; refresh() emits it with the process list.
		M.state.status = "running"
		M.refresh(root, function(state)
			notify(("processes up (%d)"):format(vim.tbl_count(state.processes)), vim.log.levels.INFO)
			done(on_done, state.status == "running")
		end)
	end)
end

---Stop processes.
---No names: everything including the manager, via `devenv processes down`
---(running -> shutting_down -> not_running).
---Names: only those, via `devenv processes stop <name>` each; the manager and
---the remaining processes keep running and the status stays `running`.
---@param root string
---@param names string|string[]|nil
---@param on_done DevenvProcessesCallback|nil
function M.down(root, names, on_done)
	names = to_list(names)
	if M.state.status == "initializing" or M.state.status == "shutting_down" then
		notify("processes are " .. M.state.status, vim.log.levels.WARN)
		done(on_done, false)
		return
	end
	M.state.err = nil

	if #names > 0 then
		if M.state.status ~= "running" then
			notify("processes are not running", vim.log.levels.WARN)
			done(on_done, false)
			return
		end
		set_state("running", with_phase(names, "stopping"))
		run_each(root, "stop", names, function(errors)
			-- refresh() clears err on a successful list, so record ours afterwards.
			M.refresh(root, function()
				if #errors > 0 then
					M.state.err = "failed to stop:\n" .. table.concat(errors, "\n")
					notify(M.state.err, vim.log.levels.ERROR)
				end
				done(on_done, #errors == 0)
			end)
		end)
		return
	end

	set_state("shutting_down", with_phase({}, "stopping"))
	stop_polling()
	run(root, { "down" }, function(res, stderr)
		if res.code ~= 0 and not stderr:find(NO_MANAGER, 1, true) then
			M.state.err = ("devenv processes down exited with code %d:\n%s"):format(res.code, devenv.summarize_errors(stderr))
			notify("failed to stop processes\n" .. M.state.err, vim.log.levels.ERROR)
			-- Unknown state; ask devenv.
			M.state.status = "running"
			M.refresh(root, function()
				done(on_done, false)
			end)
			return
		end
		set_state("not_running", off_processes())
		notify("processes down", vim.log.levels.INFO)
		done(on_done, true)
	end)
end

---Start the process manager without starting any configured process.
---Status goes not_running -> initializing -> running; all processes end up in
---devenv's `not_started` phase, ready for individual `up(name)` calls.
---No-op unless the status is `not_running`.
---@param root string
---@param on_done DevenvProcessesCallback|nil
function M.start_manager(root, on_done)
	if M.state.status ~= "not_running" then
		done(on_done, M.state.status == "running")
		return
	end
	M.state.err = nil
	set_state("initializing", off_processes())
	local args = {
		"--option", ("processes.%s.exec:string"):format(MANAGER_PROCESS), "true",
		"up", "-d", MANAGER_PROCESS,
	}
	run(root, args, function(res, stderr)
		if res.code ~= 0 then
			M.state.err = ("failed to start the process manager (exit %d):\n%s"):format(res.code, devenv.summarize_errors(stderr))
			set_state("not_running", off_processes())
			notify(M.state.err, vim.log.levels.ERROR)
			done(on_done, false)
			return
		end
		-- Mark running without an event; refresh() emits it with the process list.
		M.state.status = "running"
		M.refresh(root, function(state)
			done(on_done, state.status == "running")
		end)
	end)
end

-- Phases that mean "the user wants this process running".
local ACTIVE_PHASES = { ready = true, running = true, starting = true, pending = true, restarting = true }

---Re-read the process configuration and make the manager follow it. The
---manager only reads process definitions when it starts, so when the
---configuration changed while it is running it is taken down and brought back
---with the processes that were active before. Nothing is recycled when the
---configuration is unchanged or fails to evaluate.
---@param root string
---@param on_done DevenvProcessesCallback|nil
function M.reload(root, on_done)
	if M.state.status == "initializing" or M.state.status == "shutting_down" then
		done(on_done, false)
		return
	end
	M.discover(root, function(ok, changed)
		if not ok then
			-- Broken configuration: leave whatever is running alone.
			notify(M.state.err, vim.log.levels.ERROR)
			done(on_done, false)
			return
		end
		if M.state.status ~= "running" or not changed then
			M.refresh(root, function(state)
				done(on_done, state.status ~= "initializing")
			end)
			return
		end
		notify("process configuration changed, restarting the process manager", vim.log.levels.INFO)
		local active = {}
		for name, p in pairs(M.state.processes) do
			if ACTIVE_PHASES[p.phase] then
				active[#active + 1] = name
			end
		end
		table.sort(active)
		M.down(root, nil, function(ok)
			if not ok then
				done(on_done, false)
			elseif #active > 0 then
				M.up(root, active, on_done)
			elseif config.get("eager_manager") then
				-- Nothing was running, but the user did not ask for the manager to
				-- stop: bring it back on the new configuration.
				M.start_manager(root, on_done)
			else
				done(on_done, true)
			end
		end)
	end)
end

---Eager startup, run once from setup(): resolve the project containing `cwd`
---and, if it has processes but no running manager, start one. Nothing else
---ever starts the manager unasked, so a manager taken down later stays down.
---
---The project root is resolved with devenv's own check rather than taken from
---`cwd` directly: outside a project, devenv evaluates the `--option` override
---on its own and would start a manager knowing only the throwaway process.
---@param cwd string
function M.start_manager_if_down(cwd)
	devenv.check({ cwd = cwd, devenv = config.get("devenv") }, function(check)
		if check.state ~= "ok" or not check.root then
			return
		end
		local root = vim.fs.normalize(check.root)
		vim.schedule(function()
			M.refresh(root, function(state)
				if state.status == "not_running" and #state.configured > 0 then
					M.start_manager(root)
				end
			end)
		end)
	end)
end

---@return DevenvProcessesStatus
function M.status()
	return M.state.status
end

return M
