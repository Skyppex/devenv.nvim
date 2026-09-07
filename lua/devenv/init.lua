local config = require("devenv.config")
local devenv = require("devenv.devenv")
local watch = require("devenv.watch")

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
}

local reload_pending = false

---@param opts DevenvConfig|nil
function M.setup(opts)
	config.configure(opts)

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
				fail("failed", result.err, "failed to load environment from " .. root .. "\n" .. result.err, vim.log.levels.ERROR)
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
				fail("blocked", check.err, root .. " is not trusted; run `devenv allow` there first", vim.log.levels.WARN)
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

return M
