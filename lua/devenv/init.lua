local config = require("devenv.config")
local devenv = require("devenv.devenv")
local watch = require("devenv.watch")
local processes = require("devenv.processes")
local panel = require("devenv.panel")

local M = {}

---@alias DevenvStatus
---| "not_loaded" # load() has not been called yet.
---| "loading"    # A load is in progress.
---| "loaded"     # The devenv environment is applied.
---| "none"       # No devenv project was found for the root.
---| "blocked"    # The project exists but has not been trusted with `devenv allow`.
---| "failed"     # devenv ran but failed; see `err`.

---@class DevenvState
---@field status DevenvStatus
---@field root string|nil Root the environment was last loaded from.
---@field base table<string, string>|nil Neovim's environment before devenv was first loaded.
---@field changed string[] Variables set or overwritten by the last load.
---@field removed string[] Variables unset by the last load.
---@field err string|nil Short error from the last failed load ("error:" lines only).
---@field stderr string|nil Full devenv stderr from the last failed load.
---@field inputs string[] Files devenv's last evaluation depended on (from input-paths.txt).
---@field watching boolean Whether a change to `inputs` triggers a reload.
---@field processes DevenvProcessesState Process manager state; see `up()`, `down()`, `processes_status()`.

---@type DevenvState
M.state = {
	status = "not_loaded",
	root = nil,
	base = nil,
	changed = {},
	removed = {},
	err = nil,
	stderr = nil,
	inputs = {},
	watching = false,
	processes = processes.state,
}

local reload_pending = false

---@param opts DevenvConfig|nil
function M.setup(opts)
	config.configure(opts)

	if config.get("eager_manager") then
		processes.start_manager_if_down(vim.fs.normalize(config.get("root") or vim.fn.getcwd()))
	end

	if config.get("auto_load") then
		M.load()
	end
end

---@param msg string
---@param level integer
local function notify(msg, level)
	if config.get("notify") then
		vim.notify(msg, level, { title = "devenv" })
	end
end

---@return table<string, boolean>
local function ignored()
	local set = {}
	for _, key in ipairs(config.get("ignore")) do
		set[key] = true
	end
	return set
end

---Trust the project (`devenv allow`) after a load reported `blocked`, then
---load its environment. `on_done` is handed to that load.
---@param opts DevenvLoadOpts|nil
function M.allow(opts)
	opts = opts or {}
	local root = vim.fs.normalize(opts.root or config.get("root") or vim.fn.getcwd())

	if M.state.status ~= "blocked" then
		notify(("nothing to allow: status is %s, not blocked"):format(M.state.status), vim.log.levels.WARN)
		if opts.on_done then
			opts.on_done(false, M.state)
		end
		return
	end

	devenv.allow({
		cwd = root,
		devenv = config.get("devenv"),
		env = M.state.base,
	}, function(result)
		vim.schedule(function()
			if not result.ok then
				M.state.err = result.err
				notify("failed to allow " .. root .. "\n" .. result.err, vim.log.levels.ERROR)
				if opts.on_done then
					opts.on_done(false, M.state)
				end
				return
			end
			notify("allowed " .. root, vim.log.levels.INFO)
			M.load({ root = root, on_done = opts.on_done })
		end)
	end)
end

---Withdraw trust from the project (`devenv revoke`). The environment already
---applied stays in place; the status becomes `blocked` so the next load() is
---refused until allow() is called again.
---@param opts DevenvLoadOpts|nil
function M.revoke(opts)
	opts = opts or {}
	local root = vim.fs.normalize(opts.root or config.get("root") or vim.fn.getcwd())

	devenv.revoke({
		cwd = root,
		devenv = config.get("devenv"),
		env = M.state.base,
	}, function(result)
		vim.schedule(function()
			if not result.ok then
				M.state.err = result.err
				notify("failed to revoke " .. root .. "\n" .. result.err, vim.log.levels.ERROR)
			else
				M.state.status = "blocked"
				M.state.root = root
				M.state.err = nil
				notify("revoked " .. root, vim.log.levels.INFO)
			end
			if opts.on_done then
				opts.on_done(result.ok, M.state)
			end
		end)
	end)
end

---@class DevenvLoadOpts
---@field root string|nil Directory containing devenv.nix. Defaults to config.root, then cwd.
---@field on_done fun(ok: boolean, state: DevenvState)|nil Called after the environment has been applied.

---Replace Neovim's environment with the one produced by devenv.
---Variables devenv defines overwrite the current ones, new ones are added,
---and variables devenv removes (e.g. stdenv build vars) are unset.
---
---The environment Neovim had before the first load is remembered, and every
---load evaluates devenv against that snapshot, so reloading is idempotent
---(PATH does not grow) and variables dropped from devenv.nix disappear.
---@param opts DevenvLoadOpts|nil
function M.load(opts)
	opts = opts or {}
	local root = vim.fs.normalize(opts.root or config.get("root") or vim.fn.getcwd())

	if M.state.status == "loading" then
		notify("already loading", vim.log.levels.WARN)
		return
	end

	M.state.status = "loading"
	M.state.err = nil
	M.state.stderr = nil

	local ignore = ignored()

	if not M.state.base then
		M.state.base = vim.fn.environ()
	end

	---Runs after every load attempt, whatever the outcome.
	local function finish()
		if config.get("auto_reload") then
			M.watch()
		end
		if reload_pending then
			reload_pending = false
			M.load({ root = root })
		end
	end

	---@param status DevenvStatus
	---@param err string|nil
	---@param msg string
	---@param level integer
	local function fail(status, err, msg, level)
		M.state.status = status
		M.state.err = err
		notify(msg, level)
		if opts.on_done then
			opts.on_done(false, M.state)
		end
		finish()
	end

	local devenv_cmd = config.get("devenv")

	---@param result DevenvExportResult
	local function apply(result)
		vim.schedule(function()
			-- Remember what devenv read, even on failure, so a fix to a broken
			-- module can still trigger a reload (mirrors devenv's direnvrc).
			local dotfile = (result.env and result.env.DEVENV_DOTFILE) or vim.fs.joinpath(root, ".devenv")
			local inputs = watch.read_input_paths(dotfile)
			if #inputs > 0 then
				M.state.inputs = inputs
			end

			if not result.ok then
				M.state.stderr = result.stderr
				fail(
					"failed",
					result.err,
					"failed to load environment from " .. root .. "\n" .. result.err,
					vim.log.levels.ERROR
				)
				return
			end

			local current = vim.fn.environ()
			local changed, removed = {}, {}
			for key, value in pairs(result.env) do
				if not ignore[key] and current[key] ~= value then
					vim.env[key] = value
					changed[#changed + 1] = key
				end
			end
			for key in pairs(current) do
				if not ignore[key] and result.env[key] == nil then
					vim.env[key] = nil
					removed[#removed + 1] = key
				end
			end
			table.sort(changed)
			table.sort(removed)

			M.state.status = "loaded"
			M.state.root = root
			M.state.changed = changed
			M.state.removed = removed

			notify(("loaded %s (%d set, %d unset)"):format(root, #changed, #removed), vim.log.levels.INFO)
			vim.api.nvim_exec_autocmds("User", { pattern = "DevenvLoaded", data = { root = root } })
			-- Re-read the process configuration; recycles the manager only if it changed.
			processes.reload(root)

			if opts.on_done then
				opts.on_done(true, M.state)
			end
			finish()
		end)
	end

	devenv.check({ cwd = root, devenv = devenv_cmd, env = M.state.base }, function(check)
		if check.state == "none" then
			vim.schedule(function()
				fail("none", nil, "no devenv project found in " .. root, vim.log.levels.WARN)
			end)
			return
		elseif check.state == "blocked" then
			vim.schedule(function()
				fail(
					"blocked",
					check.err,
					root .. " is not trusted; run `devenv allow` there first",
					vim.log.levels.WARN
				)
			end)
			return
		end
		if check.root then
			root = vim.fs.normalize(check.root)
		end
		-- "ok", or "unknown" (older devenv without the check command): let the
		-- real load decide, it reports its own errors.
		devenv.export({ cwd = root, bash = config.get("bash"), devenv = devenv_cmd, env = M.state.base }, apply)
	end)
end

---Reload when any file from the last evaluation changes.
---Called automatically after each load when `auto_reload` is set. Safe to call
---repeatedly; the watch list is refreshed from the latest evaluation.
function M.watch()
	if #M.state.inputs == 0 then
		return
	end
	watch.start(M.state.inputs, function(path)
		if M.state.status == "loading" then
			reload_pending = true
			return
		end
		notify("reloading: " .. vim.fn.fnamemodify(path, ":~:."), vim.log.levels.INFO)
		M.load({ root = M.state.root })
	end, config.get("reload_debounce_ms"))
	M.state.watching = true
end

---Stop reloading on file changes.
function M.unwatch()
	watch.stop()
	M.state.watching = false
end

---@return DevenvStatus
function M.status()
	return M.state.status
end

---@return string
local function project_root()
	return M.state.root or vim.fs.normalize(config.get("root") or vim.fn.getcwd())
end

---Start processes and services in the background.
---Manager not running: `devenv processes up -d [names]`, not_running -> initializing -> running.
---Manager running: restarts the named processes (or all of them); stopped ones are started.
---@param names string|string[]|nil
---@param on_done DevenvProcessesCallback|nil Called once the processes are running, or on failure.
function M.up(names, on_done)
	processes.up(project_root(), names, on_done)
end

---Stop processes.
---No names: everything (`devenv processes down`), running -> shutting_down -> not_running.
---Names: only those (`devenv processes stop <name>` each); the rest keep running.
---@param names string|string[]|nil
---@param on_done DevenvProcessesCallback|nil
function M.down(names, on_done)
	processes.down(project_root(), names, on_done)
end

---@return DevenvProcessesStatus
function M.processes_status()
	return processes.status()
end

---Start the process manager without starting any process, so individual
---processes can be started quickly afterwards. Done automatically when the
---`eager_manager` option is set.
---@param on_done DevenvProcessesCallback|nil
function M.start_manager(on_done)
	processes.start_manager(project_root(), on_done)
end

---Open the process panel: a read-only buffer with one process per line,
---kept in sync with the process state. Focuses it if already open.
function M.process_panel_open()
	panel.open(project_root())
end

---Close the process panel window.
function M.process_panel_close()
	panel.close()
end

---Open the process panel if closed, close it if open.
function M.process_panel_toggle()
	panel.toggle(project_root())
end

---@param action fun(name: string)
local function with_line_process(action)
	local name, err = panel.line_name()
	if not name then
		if err then
			notify(err, vim.log.levels.WARN)
		end
		return
	end
	action(name)
end

---Start the process on the cursor line of the process panel.
---Restarts it if it is already running.
---@param on_done DevenvProcessesCallback|nil
function M.process_panel_line_start(on_done)
	with_line_process(function(name)
		M.up(name, on_done)
	end)
end

---Stop the process on the cursor line of the process panel.
---@param on_done DevenvProcessesCallback|nil
function M.process_panel_line_stop(on_done)
	with_line_process(function(name)
		M.down(name, on_done)
	end)
end

---Re-query devenv for the process state (also done automatically after
---load() and periodically while running).
---@param callback fun(state: DevenvProcessesState)|nil
function M.processes_refresh(callback)
	processes.refresh(project_root(), callback)
end

---Re-read the process configuration. If it changed while the manager is
---running, the manager is recycled with the processes that were active.
---Done automatically after every successful load().
---@param on_done DevenvProcessesCallback|nil
function M.processes_reload(on_done)
	processes.reload(project_root(), on_done)
end

return M
