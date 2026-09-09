local M = {}

M.config = {
	columns = 80,
	-- "vsplit" (default): split in the current tab, exactly `columns` wide.
	-- "float": centered floating window, `columns` wide (width fallback for
	-- narrow screens).
	mode = "vsplit",
	-- re-render the preview when the source markdown buffer changes.
	auto_refresh = false,
	-- debounce for auto_refresh (ms). mdcat runs once the buffer is quiet.
	refresh_delay = 400,
}

local function find_mdcat()
	if vim.fn.executable("mdcat") == 1 then
		return "mdcat"
	end
	return nil
end

local function apply_window_opts(win)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].cursorcolumn = false
	vim.wo[win].list = false
	vim.wo[win].wrap = false
	vim.wo[win].spell = false
	vim.wo[win].winfixwidth = true
end

local function open_vsplit(cols)
	vim.cmd("rightbelow " .. cols .. "vnew")
	return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function open_float(cols)
	local width = math.min(cols, vim.o.columns - 4)
	local height = math.floor(vim.o.lines * 0.85)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2 - 1),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
	})
	return win, buf
end

-- (Re)spawn mdcat inside an existing preview buffer.
local function spawn(bin, cols, file, win, current_buf)
	-- For a respawn (refresh), the window already exists: wipe the old buffer
	-- and swap in a fresh one, because termopen requires an unmodified buffer.
	if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
		local channel = vim.bo[current_buf].channel
		if channel and channel > 0 then
			vim.fn.jobstop(channel)
		end
		vim.api.nvim_buf_delete(current_buf, { force = true })
	end
	local buf = current_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
	end
	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_buf(win, buf)
	end
	vim.bo[buf].filetype = "mdcat"
	vim.bo[buf].bufhidden = "wipe"

	-- When the current window IS the preview (float path), don't try to write
	-- the nofile preview buffer; the source was already saved in preview().
	if vim.api.nvim_get_current_buf() ~= buf then
		vim.cmd("silent write")
	end

	local job_id = vim.fn.termopen({ bin, "--columns", tostring(cols), file }, {
		on_exit = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_call(win, function()
					vim.cmd("stopinsert")
				end)
			end
		end,
	})

	-- Safety: resize the pty after spawn in case the window manager adjusted
	-- the split width before termopen attached.
	if job_id and job_id > 0 then
		local height = 22
		if vim.api.nvim_win_is_valid(win) then
			height = vim.api.nvim_win_get_height(win)
		end
		vim.fn.jobresize(job_id, cols, height)
	end

	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				vim.cmd("stopinsert")
				vim.cmd("normal! G") -- start at bottom like a pager
				vim.cmd("normal! gg") -- then top; removes the blank tail
			end)
		end
	end)

	return buf
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
	local cols = M.config.columns

	local win, buf
	if M.config.mode == "float" then
		win, buf = open_float(cols)
	else
		win, buf = open_vsplit(cols)
	end

	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "mdcat"
	apply_window_opts(win)

	-- Focus goes to the preview immediately
	vim.api.nvim_set_current_win(win)

	-- For the vsplit path, spawn directly into the vnew-provided buffer.
	-- For the float path, spawn returns a buffer (creates one if needed).
	local preview_buf = buf
	if M.config.mode == "float" then
		preview_buf = nil -- let spawn pick/create
	end
	preview_buf = spawn(bin, cols, file, win, preview_buf)

	-- Scrollback so you can read past the first screenful.
	vim.bo[preview_buf].scrollback = 10000

	-- Local refs for autocmds and keymaps.
	local pbuf = preview_buf

	local augroup
	if M.config.auto_refresh then
		augroup = vim.api.nvim_create_augroup("mdcat_preview" .. pbuf, { clear = true })
		local timer = vim.uv.new_timer()
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
			group = augroup,
			buffer = src,
			callback = function(ev)
				if not vim.api.nvim_buf_is_valid(pbuf) then
					return true -- preview closed: remove autocmds
				end
				if ev.event == "BufWritePost" then
					pbuf = spawn(bin, cols, file, win, nil)
					return
				end
				timer:stop()
				timer:start(M.config.refresh_delay, 0, function()
					timer:stop()
					if vim.api.nvim_buf_is_valid(pbuf) and vim.api.nvim_buf_is_valid(src) then
						vim.schedule(function()
							pbuf = spawn(bin, cols, file, win, nil)
						end)
					end
				end)
			end,
		})
	end

	local function close()
		if augroup then
			pcall(vim.api.nvim_del_augroup_by_id, augroup)
		end
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
		end
	end

	vim.keymap.set("n", "q", close, { buffer = pbuf, nowait = true, silent = true, desc = "Close mdcat preview" })
	vim.keymap.set("t", "q", [[<C-\><C-n>:lua require("mdcat").close_preview()<CR>]], { buffer = pbuf, silent = true })

	M._close = close
end

function M.close_preview()
	if M._close then
		M._close()
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	if M.config.mode ~= "vsplit" and M.config.mode ~= "float" then
		vim.notify("mdcat.nvim: unknown mode '" .. tostring(M.config.mode) .. "' (expected vsplit/float)", vim.log.levels.WARN)
		M.config.mode = "vsplit"
	end

	vim.keymap.set("n", "<leader>mm", M.preview, { desc = "Markdown preview with mdcat" })
end

return M
