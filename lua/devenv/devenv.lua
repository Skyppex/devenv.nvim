-- Low-level interaction with the `devenv` CLI.
local M = {}

-- Mirrors what direnv's `use devenv` does: evaluate the shell script from
-- `devenv print-dev-env` inside bash, then dump the resulting environment.
-- The script itself merges PATH/XDG_DATA_DIRS with the inherited ones, fixes
-- TMPDIR/HOME and unsets stdenv build variables, so no filtering is needed here.
-- stdout of the evaluated script (enterShell output) is sent to stderr so it
-- does not pollute the NUL-separated env dump.
-- The devenv command is passed as positional arguments ("$@").
local SCRIPT = [[
out="$("$@" print-dev-env)" || exit $?
eval "$out" 1>&2
env -0
]]

---@param raw string NUL-separated KEY=VALUE pairs (output of `env -0`).
---@return table<string, string>
function M.parse_env(raw)
	local env = {}
	for entry in raw:gmatch("([^%z]+)") do
		local key, value = entry:match("^([^=]+)=(.*)$")
		if key then
			env[key] = value
		end
	end
	return env
end

---@param s string
---@return string
function M.strip_ansi(s)
	return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---Build a devenv command line from the configured command plus arguments.
---@param devenv string|string[]
---@param ... string
---@return string[]
function M.cmd(devenv, ...)
	local cmd = type(devenv) == "table" and vim.deepcopy(devenv) or { devenv }
	return vim.list_extend(cmd, { ... })
end

---@class DevenvCheckOpts
---@field cwd string Directory to check.
---@field devenv string|string[] The devenv command.
---@field env table<string, string>|nil Exact environment to run in. Defaults to the current one.

---@class DevenvCheckResult
---@field state "ok"|"none"|"blocked"|"unknown" `unknown` when devenv could not tell (e.g. old devenv without the check command).
---@field root string|nil Project root reported by devenv when `ok`.
---@field err string|nil

---Ask devenv whether `cwd` belongs to a project and whether it is allowed.
---Uses `devenv hook-should-activate`, the same check the shell hook performs:
---exit 0 + path => allowed project, exit 0 + empty => no devenv.nix,
---exit 2 + "not allowed" => needs `devenv allow`.
---@param opts DevenvCheckOpts
---@param callback fun(result: DevenvCheckResult)
function M.check(opts, callback)
	local ok, err = pcall(vim.system, M.cmd(opts.devenv, "hook-should-activate"), {
		cwd = opts.cwd,
		env = opts.env,
		clear_env = opts.env ~= nil,
		text = true,
	}, function(res)
		local stderr = vim.trim(M.strip_ansi(res.stderr or ""))
		local stdout = vim.trim(res.stdout or "")
		if res.code == 0 then
			if stdout == "" then
				callback({ state = "none" })
			else
				callback({ state = "ok", root = stdout })
			end
		elseif stderr:find("not allowed", 1, true) then
			callback({ state = "blocked", err = stderr })
		else
			callback({ state = "unknown", err = ("devenv exited with code %d:\n%s"):format(res.code, stderr) })
		end
	end)
	if not ok then
		callback({ state = "unknown", err = ("failed to spawn devenv: %s"):format(err) })
	end
end

-- Glyphs devenv puts in front of its own failure lines (e.g. "× failed to stop process").
local FAILURE_MARKERS = { "×", "✗" }

---Strip devenv's coloured gutter (whitespace and status glyphs) from a line.
---@param line string
---@return string
local function strip_gutter(line)
	line = vim.trim(line)
	for _, marker in ipairs(FAILURE_MARKERS) do
		if vim.startswith(line, marker) then
			return vim.trim(line:sub(#marker + 1))
		end
	end
	return line
end

---Reduce devenv's stderr to the lines that carry the failure: those containing
---"error:" (the `rg error:` equivalent) and those devenv itself marks with a
---failure glyph. Falls back to the full text when nothing matches, so that
---e.g. "command not found" from bash is not swallowed.
---@param stderr string Already ANSI-stripped stderr.
---@return string
function M.summarize_errors(stderr)
	local hits = {}
	for line in stderr:gmatch("[^\n]+") do
		local clean = strip_gutter(line)
		local marked = clean ~= vim.trim(line)
		if marked or clean:lower():find("error:", 1, true) then
			hits[#hits + 1] = clean
		end
	end
	if #hits == 0 then
		return vim.trim(stderr)
	end
	return table.concat(hits, "\n")
end

---@class DevenvExportOpts
---@field cwd string Directory containing devenv.nix.
---@field bash string Bash executable.
---@field devenv string|string[] The devenv command, optionally with extra arguments.
---@field env table<string, string>|nil Exact environment to evaluate devenv in. Defaults to the current one.

---@class DevenvExportResult
---@field ok boolean
---@field env table<string, string>|nil
---@field err string|nil Short error: exit code plus the "error:" lines from stderr.
---@field stderr string|nil Full (ANSI-stripped) stderr on failure.

---Evaluate the devenv shell and return the full resulting environment.
---@param opts DevenvExportOpts
---@param callback fun(result: DevenvExportResult)
function M.export(opts, callback)
	local cmd = vim.list_extend({ opts.bash, "-c", SCRIPT, opts.bash }, M.cmd(opts.devenv))

	local ok, err = pcall(vim.system, cmd, {
		cwd = opts.cwd,
		env = opts.env,
		clear_env = opts.env ~= nil,
		text = false,
	}, function(res)
		if res.code ~= 0 then
			local stderr = M.strip_ansi(res.stderr or "")
			callback({
				ok = false,
				err = ("devenv exited with code %d:\n%s"):format(res.code, M.summarize_errors(stderr)),
				stderr = vim.trim(stderr),
			})
			return
		end
		callback({ ok = true, env = M.parse_env(res.stdout or "") })
	end)
	if not ok then
		callback({ ok = false, err = ("failed to spawn %s: %s"):format(opts.bash, err) })
	end
end

return M
