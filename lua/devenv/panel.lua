-- Process panel: a read-only buffer with one line per process.
--
-- The buffer is re-rendered from `devenv.processes` state whenever the
-- `DevenvProcessesChanged` event fires, so it follows up/down/restart calls and
-- the background poll. The line under the cursor maps to a process name via
-- `M.line_name()`, which the `process_panel_line_*` APIs build on.
local config = require("devenv.config")
local processes = require("devenv.processes")

local M = {}

local FILETYPE = "devenv-processes"
local ns = vim.api.nvim_create_namespace("devenv.panel")

---@type integer|nil
local bufnr
---@type string[] line number (1-based) -> process name, from the last render
local line_names = {}

-- Default highlight groups per phase; users may override them.
local PHASE_HL = {
	ready = "DevenvProcessReady",
	running = "DevenvProcessReady",
	starting = "DevenvProcessStarting",
	pending = "DevenvProcessStarting",
	restarting = "DevenvProcessStarting",
	stopping = "DevenvProcessStarting",
	stopped = "DevenvProcessStopped",
	not_started = "DevenvProcessStopped",
	off = "DevenvProcessStopped",
	exited = "DevenvProcessStopped",
	completed = "DevenvProcessStopped",
	failed = "DevenvProcessFailed",
	crashed = "DevenvProcessFailed",
	gave_up = "DevenvProcessFailed",
}

local function define_highlights()
	local links = {
		DevenvProcessName = "Identifier",
		DevenvProcessReady = "DiagnosticOk",
		DevenvProcessStarting = "DiagnosticWarn",
		DevenvProcessStopped = "Comment",
		DevenvProcessFailed = "DiagnosticError",
		DevenvProcessRestarts = "Comment",
		DevenvProcessPort = "Number",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

---@return boolean
local function buf_valid()
	return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@return integer|nil
local function find_window()
	if not buf_valid() then
		return nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			return win
		end
	end
	return nil
end

---Rewrite the buffer from the current process state.
function M.render()
	if not buf_valid() then
		return
	end
	local state = processes.state

	local names = vim.tbl_keys(state.processes)
	table.sort(names)

	local width = 0
	for _, name in ipairs(names) do
		width = math.max(width, #name)
	end

	local lines, marks = {}, {}
	line_names = {}
	for i, name in ipairs(names) do
		local p = state.processes[name]
		local restarts = p.restarts > 0 and ("  restarts: %d"):format(p.restarts) or ""
		-- `main` is the conventional primary port: shown first and bare; the
		-- others follow in devenv's order, carrying their name.
		local ports = {}
		for _, port in ipairs(p.ports or {}) do
			if port.name == "main" then
				table.insert(ports, 1, ":" .. port.port)
			else
				ports[#ports + 1] = port.name .. ":" .. port.port
			end
		end
		local ports_text = #ports > 0 and ("  " .. table.concat(ports, " ")) or ""
		local padded = name .. string.rep(" ", width - #name)
		local head = ("%s  %s%s"):format(padded, p.phase, restarts)
		lines[i] = head .. ports_text
		line_names[i] = name
		marks[i] = {
			name_end = #padded,
			phase_start = #padded + 2,
			phase_end = #padded + 2 + #p.phase,
			phase_hl = PHASE_HL[p.phase] or "Normal",
			restarts_start = #padded + 2 + #p.phase,
			restarts_end = #head,
			ports_start = #head + 2,
		}
	end

	-- With no processes the panel is a single dimmed status line (not a process,
	-- so the line APIs refuse it).
	local placeholder = #lines == 0
	if placeholder then
		lines[1] = "devenv processes: " .. state.status
	end

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].modified = false

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	if placeholder then
		vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #lines[1], hl_group = "DevenvProcessStopped" })
	end
	for i, m in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, { end_col = m.name_end, hl_group = "DevenvProcessName" })
		vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, m.phase_start, { end_col = m.phase_end, hl_group = m.phase_hl })
		if m.restarts_start < m.restarts_end then
			vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, m.restarts_start, { end_col = m.restarts_end, hl_group = "DevenvProcessRestarts" })
		end
		if m.ports_start < #lines[i] then
			vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, m.ports_start, { end_col = #lines[i], hl_group = "DevenvProcessPort" })
		end
	end

	local win = find_window()
	if win then
		-- Exactly one screen line per process, capped by panel_max_height.
		local max_height = math.max(1, config.get("panel_max_height") or 10)
		vim.api.nvim_win_set_height(win, math.min(#lines, max_height))

		local title = "devenv processes: " .. state.status
		if state.err then
			title = title .. "  (error, see :lua =require('devenv').state.processes.err)"
		end
		vim.wo[win].statusline = title
	end
end

---@return integer
local function ensure_buffer()
	if bufnr and buf_valid() then
		return bufnr
	end
	define_highlights()
	bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "devenv://processes")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].buflisted = false
	vim.bo[bufnr].filetype = FILETYPE
	vim.bo[bufnr].modifiable = false

	local group = vim.api.nvim_create_augroup("devenv.panel", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DevenvProcessesChanged",
		callback = function()
			M.render()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = bufnr,
		callback = function()
			bufnr = nil
			line_names = {}
			vim.api.nvim_del_augroup_by_id(group)
		end,
	})
	return bufnr
end

---Open the panel (or focus it if already open) and refresh the process list.
---@param root string Project root used for the refresh.
function M.open(root)
	local buf = ensure_buffer()
	local win = find_window()
	if win then
		vim.api.nvim_set_current_win(win)
	else
		vim.cmd("botright 1split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.wo[win].winfixheight = true
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].wrap = false
		vim.wo[win].spell = false
		vim.wo[win].list = false
	end
	M.render()
	processes.refresh(root)
end

---Close the panel window if it is open. The buffer is kept for reuse.
function M.close()
	local win = find_window()
	if win then
		vim.api.nvim_win_close(win, true)
	end
end

---@return boolean
function M.is_open()
	return find_window() ~= nil
end

---@param root string
function M.toggle(root)
	if M.is_open() then
		M.close()
	else
		M.open(root)
	end
end

---Process name on the cursor line, if the current buffer is the panel.
---@return string|nil name
---@return string|nil err Why no name could be determined.
function M.line_name()
	if not buf_valid() or vim.api.nvim_get_current_buf() ~= bufnr then
		return nil, "cursor is not in the devenv process panel"
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local name = line_names[lnum]
	if not name then
		return nil, "no process on this line"
	end
	return name
end

return M
