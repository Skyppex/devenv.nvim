local M = {}

---Every option may also be a function returning a value of the option's type.
---Functions are evaluated each time the option is read (i.e. on every load()).
---@class DevenvConfig
---@field auto_load boolean|fun():boolean Load the environment on setup().
---@field root string|nil|fun():string|nil Directory containing devenv.nix. Defaults to the cwd at load time.
---@field devenv string|string[]|fun():string|string[] The devenv command. A list lets you pass extra arguments.
---@field bash string|fun():string Bash executable used to evaluate the devenv shell script.
---@field ignore string[]|fun():string[] Environment variables never written back into Neovim.
---@field notify boolean|fun():boolean Emit vim.notify messages on load/failure.
---@field auto_reload boolean|fun():boolean After a load, watch the files devenv evaluated and reload when they change.
---@field reload_debounce_ms integer|fun():integer Delay between a file change and the reload.

---@type DevenvConfig
M.default_config = {
	auto_load = false,
	root = nil,
	devenv = "devenv",
	bash = "bash",
	ignore = { "PWD", "OLDPWD", "SHLVL", "_", "PS1", "PS4", "NVIM" },
	notify = true,
	auto_reload = false,
	reload_debounce_ms = 200,
}

---@type DevenvConfig
M.config = vim.deepcopy(M.default_config)

---@param opts DevenvConfig|nil
function M.configure(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.default_config), opts or {})
end

---Read an option, calling it first if it is a function.
---@generic K: string
---@param name K
---@return any
function M.get(name)
	local value = M.config[name]
	if type(value) == "function" then
		return value()
	end
	return value
end

return M
