-- File watching for automatic reloads.
--
-- devenv records every file its evaluation read in `$DEVENV_DOTFILE/input-paths.txt`
-- (devenv.nix, devenv.yaml, devenv.lock, imported modules, devenv.local.nix, ...).
-- This is the same list devenv's direnv integration watches. We watch the parent
-- directory of each path rather than the file itself so that editors writing via
-- rename and files that do not exist yet (e.g. devenv.local.nix) are both handled.
local M = {}

---@type table<string, uv.uv_fs_event_t> parent dir -> handle
local handles = {}
---@type table<string, boolean> absolute path -> true
local watched = {}
---@type uv.uv_timer_t|nil
local timer

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

---Stop watching everything.
function M.stop()
	for _, handle in pairs(handles) do
		handle:stop()
		handle:close()
	end
	handles = {}
	watched = {}
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

---Watch `paths`, calling `on_change` (debounced, on the main loop) when any changes.
---Replaces any previous watch.
---@param paths string[]
---@param on_change fun(path: string)
---@param debounce_ms integer
function M.start(paths, on_change, debounce_ms)
	M.stop()
	timer = vim.uv.new_timer()

	local function trigger(path)
		if not timer then
			return
		end
		timer:stop()
		timer:start(debounce_ms, 0, function()
			vim.schedule(function()
				on_change(path)
			end)
		end)
	end

	for _, path in ipairs(paths) do
		watched[path] = true
		local dir = vim.fs.dirname(path)
		if not handles[dir] and vim.uv.fs_stat(dir) then
			local handle = vim.uv.new_fs_event()
			if handle then
				local ok = handle:start(dir, {}, function(err, fname)
					if err or not fname then
						return
					end
					local changed = vim.fs.joinpath(dir, fname)
					if watched[changed] then
						trigger(changed)
					end
				end)
				if ok then
					handles[dir] = handle
				else
					handle:close()
				end
			end
		end
	end
end

---@return string[] Paths currently being watched, sorted.
function M.paths()
	local paths = vim.tbl_keys(watched)
	table.sort(paths)
	return paths
end

return M
