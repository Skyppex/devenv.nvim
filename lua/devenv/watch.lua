-- File watching.
--
-- A watcher observes a set of paths and calls back (debounced, on the main
-- loop) when any of them changes. It watches the parent directory of each path
-- rather than the file itself so that editors writing via rename and files that
-- do not exist yet (e.g. devenv.local.nix) are both handled.
--
-- The module also keeps a default watcher for devenv's evaluation inputs:
-- devenv records every file its evaluation read in
-- `$DEVENV_DOTFILE/input-paths.txt` (devenv.nix, devenv.yaml, devenv.lock,
-- imported modules, devenv.local.nix, ...), the same list devenv's direnv
-- integration watches.
local M = {}

---@class DevenvWatcher
---@field private handles table<string, uv.uv_fs_event_t> parent dir -> handle
---@field private watched table<string, boolean> absolute path -> true
---@field private timer uv.uv_timer_t|nil
local Watcher = {}
Watcher.__index = Watcher

---Create an independent watcher.
---@return DevenvWatcher
function M.new()
	return setmetatable({ handles = {}, watched = {}, timer = nil }, Watcher)
end

---Stop watching everything.
function Watcher:stop()
	for _, handle in pairs(self.handles) do
		handle:stop()
		handle:close()
	end
	self.handles = {}
	self.watched = {}
	if self.timer then
		self.timer:stop()
		self.timer:close()
		self.timer = nil
	end
end

---Watch `paths`, calling `on_change` (debounced, on the main loop) when any changes.
---Replaces any previous watch on this watcher.
---@param paths string[]
---@param on_change fun(path: string)
---@param debounce_ms integer
function Watcher:start(paths, on_change, debounce_ms)
	self:stop()
	self.timer = vim.uv.new_timer()

	local function trigger(path)
		if not self.timer then
			return
		end
		self.timer:stop()
		self.timer:start(debounce_ms, 0, function()
			vim.schedule(function()
				on_change(path)
			end)
		end)
	end

	for _, path in ipairs(paths) do
		self.watched[path] = true
		local dir = vim.fs.dirname(path)
		if not self.handles[dir] and vim.uv.fs_stat(dir) then
			local handle = vim.uv.new_fs_event()
			if handle then
				local ok = handle:start(dir, {}, function(err, fname)
					if err or not fname then
						return
					end
					local changed = vim.fs.joinpath(dir, fname)
					if self.watched[changed] then
						trigger(changed)
					end
				end)
				if ok then
					self.handles[dir] = handle
				else
					handle:close()
				end
			end
		end
	end
end

---@return string[] Paths currently being watched, sorted.
function Watcher:paths()
	local paths = vim.tbl_keys(self.watched)
	table.sort(paths)
	return paths
end

---Read devenv's list of evaluation inputs.
---@param dotfile string DEVENV_DOTFILE directory (usually <root>/.devenv).
---@return string[]
function M.read_input_paths(dotfile)
	local f = io.open(dotfile .. "/input-paths.txt", "r")
	if not f then
		return {}
	end
	local paths = {}
	for line in f:lines() do
		line = vim.trim(line)
		if line ~= "" then
			paths[#paths + 1] = vim.fs.normalize(line)
		end
	end
	f:close()
	return paths
end

-- Default watcher for the evaluation inputs (used by auto_reload).
local inputs = M.new()

---Stop watching the evaluation inputs.
function M.stop()
	inputs:stop()
end

---Watch the evaluation inputs; see Watcher:start().
---@param paths string[]
---@param on_change fun(path: string)
---@param debounce_ms integer
function M.start(paths, on_change, debounce_ms)
	inputs:start(paths, on_change, debounce_ms)
end

---@return string[] Evaluation inputs currently being watched, sorted.
function M.paths()
	return inputs:paths()
end

return M
