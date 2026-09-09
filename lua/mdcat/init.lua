local M = {}

M.config = {
	columns = 80,
}

local function find_mdcat()
	if vim.fn.executable("mdcat") == 1 then
		return "mdcat"
	end
	return nil
end

function M.preview()
	local bin = find_mdcat()
	if not bin then
		vim.notify("mdcat not found. Install it: sudo pacman -S mdcat", vim.log.levels.ERROR)
		return
	end

	if vim.bo.filetype ~= "markdown" then
		vim.notify("Not a markdown file", vim.log.levels.WARN)
		return
	end

	local src = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(src)
	if file == "" then
		vim.notify("Buffer has no file on disk", vim.log.levels.WARN)
		return
	end

	-- Save so mdcat sees the current content
	vim.cmd("silent write")

	local prev_win = vim.api.nvim_get_current_win()

	vim.cmd("vsplit")
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(win, buf)

	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "mdcat"

	local cols = M.config.columns

	-- A less "squiggly" surface: no cursor flicker, no line noise.
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].cursorcolumn = false
	vim.wo[win].list = false
	vim.wo[win].wrap = false
	vim.wo[win].spell = false

	-- Size the split to the requested columns; mdcat wraps to the pty width.
	vim.api.nvim_win_set_width(win, cols)

	-- Focus goes to the preview immediately
	vim.api.nvim_set_current_win(win)

	vim.fn.termopen({ bin, "--columns", tostring(cols), file }, {
		env = { COLUMNS = tostring(cols) },
		on_exit = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_call(win, function()
					vim.cmd("stopinsert")
				end)
			end
		end,
	})

	-- Terminal buffers spawn in insert mode, which is what makes the output
	-- look squiggly (block cursor, pending-input state). Drop to normal mode.
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				vim.cmd("stopinsert")
			end)
		end
	end)

	-- Scrollback so you can read past the first screenful.
	vim.api.nvim_buf_set_option(buf, "scrollback", 10000)

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
		end
	end

	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true, desc = "Close mdcat preview" })
	vim.keymap.set("t", "q", [[<C-\><C-n>:lua require("mdcat").close_preview()<CR>]], { buffer = buf, silent = true })

	M._close = close
end

function M.close_preview()
	if M._close then
		M._close()
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set("n", "<leader>mm", M.preview, { desc = "Markdown preview with mdcat" })
end

return M
