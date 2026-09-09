local M = {}

M.config = {
	columns = 90,
	-- re-render the preview when the source markdown buffer changes.
	auto_refresh = true,
	-- debounce for auto_refresh (ms). mdcat runs once the buffer is quiet.
	refresh_delay = 200,
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
	-- {count}vnew makes the new window exactly `cols` wide.
	vim.cmd("rightbelow " .. cols .. "vnew")
	return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function open_float(cols)
	local width = math.min(cols, vim.o.columns - 4)
	local height = math.max(10, math.floor(vim.o.lines * 0.85))
	local buf = vim.api.nvim_create_buf(true, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
	})
	return win, buf
end

-- (Re)spawn mdcat in the preview window. Returns the buffer used.
-- Every render gets a BRAND-NEW buffer: reusing a terminal buffer is racy
-- (the dying job's exit callback flips 'modified' back on asynchronously,
-- and termopen refuses modified buffers). The old buffer is wiped by the
-- window's bufhidden=wipe only AFTER the new one is displayed, so the split
-- layout stays untouched.
--
-- scroll: fraction [0,1] of the document the preview should show after the
-- render lands (0 = top). Lets refresh keep the view in sync with the source.
local function spawn(bin, cols, file, win, current_buf, srcbuf, scroll)
	local old = current_buf
	if old and vim.api.nvim_buf_is_valid(old) then
		local channel = vim.bo[old].channel
		if channel and channel > 0 then
			pcall(vim.fn.jobstop, channel)
		end
	end

	local buf = vim.api.nvim_create_buf(true, true) -- listed scratch buffer
	vim.bo[buf].filetype = "mdcat"
	vim.bo[buf].bufhidden = "wipe"
	if vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_buf(win, buf)
	end

	-- Sync the source to disk so the render sees current content.
	-- noautocmd: this write must not re-trigger our own BufWritePost.
	if srcbuf and vim.api.nvim_buf_is_valid(srcbuf) and vim.bo[srcbuf].modified then
		vim.api.nvim_buf_call(srcbuf, function()
			vim.cmd("silent noautocmd write")
		end)
	end

	-- termopen attaches to the CURRENT buffer; pin it to ours.
	local job_id
	vim.api.nvim_buf_call(buf, function()
		job_id = vim.fn.termopen({ bin, "--columns", tostring(cols), file }, {
			on_exit = function()
				if not vim.api.nvim_win_is_valid(win) then
					return
				end
				-- Render finished: position the view. Applying scroll here (after the
				-- full output exists) is deterministic; schedules racing the render
				-- were not.
				vim.schedule(function()
					if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
						return
					end
					vim.api.nvim_win_call(win, function()
						vim.cmd("stopinsert")
						if scroll and scroll > 0 then
							local lines = vim.api.nvim_buf_line_count(buf)
							local target = math.max(1, math.floor(lines * scroll))
							local max_top = math.max(1, lines - vim.api.nvim_win_get_height(win) + 1)
							target = math.min(target, max_top)
							pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
							vim.cmd("normal! zt")
						else
							vim.cmd("normal! gg")
						end
					end)
				end)
			end,
		})
	end)

	if job_id and job_id > 0 then
		local height = 22
		if vim.api.nvim_win_is_valid(win) then
			height = vim.api.nvim_win_get_height(win)
		end
		vim.fn.jobresize(job_id, cols, height)
	end

	return buf
end

-- Source window's top visible line as a fraction 0..1 of the source buffer.
local function source_top_fraction(src)
	local ok, winid = pcall(vim.fn.bufwinid, src)
	if not ok or winid < 0 then
		return nil
	end
	local view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
	local total = vim.api.nvim_buf_line_count(src)
	if total <= 1 then
		return 0
	end
	return math.min(1, view.topline / total)
end

function M.preview(mode)
	mode = mode or "vsplit"
	if mode ~= "vsplit" and mode ~= "float" then
		mode = "vsplit"
	end

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
	local src_win = vim.api.nvim_get_current_win()
	local file = vim.api.nvim_buf_get_name(src)
	if file == "" then
		vim.notify("Buffer has no file on disk", vim.log.levels.WARN)
		return
	end

	-- Save so mdcat sees the current content
	vim.cmd("silent write")

	local prev_win = src_win
	-- Clamp: the split can never be wider than the screen itself.
	local cols = math.max(20, math.min(M.config.columns, vim.o.columns - 2))

	local win
	if mode == "float" then
		win = open_float(cols)
	else
		win = open_vsplit(cols)
	end

	apply_window_opts(win)

	-- Focus goes to the preview immediately
	vim.api.nvim_set_current_win(win)

	local pbuf = spawn(bin, cols, file, win, nil, src, 0)
	vim.bo[pbuf].scrollback = 10000

	local augroup = vim.api.nvim_create_augroup("mdcat_preview" .. pbuf, { clear = true })
	local close

	local function bind_q(b)
		vim.keymap.set("n", "q", function()
			close()
		end, { buffer = b, nowait = true, silent = true, desc = "Close mdcat preview" })
		vim.keymap.set("t", "q", [[<C-\><C-n>:lua require("mdcat").close_preview()<CR>]], { buffer = b, silent = true })
	end

	if M.config.auto_refresh then
		local timer = vim.uv.new_timer()
		local function refresh()
			if not vim.api.nvim_buf_is_valid(pbuf) or not vim.api.nvim_buf_is_valid(src) then
				return
			end
			local scroll = source_top_fraction(src)
			pbuf = spawn(bin, cols, file, win, pbuf, src, scroll)
			vim.bo[pbuf].scrollback = 10000
			bind_q(pbuf)
		end
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
			group = augroup,
			buffer = src,
			callback = function(ev)
				-- schedule NOW: API checks must not run in the libuv timer's
				-- fast-event context.
				if ev.event == "BufWritePost" then
					vim.schedule(refresh)
					return
				end
				timer:stop()
				timer:start(M.config.refresh_delay, 0, function()
					timer:stop()
					vim.schedule(refresh)
				end)
			end,
		})
	end

	-- Live scroll sync: whenever the source window scrolls or the cursor moves,
	-- slide the preview window to the matching rendered top line. No re-render.
	local scroll_timer = vim.uv.new_timer()
	local function sync_scroll()
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(pbuf) then
			return
		end
		if not vim.api.nvim_buf_is_valid(src) then
			return
		end
		local frac = source_top_fraction(src)
		if frac and frac > 0 then
			local lines = vim.api.nvim_buf_line_count(pbuf)
			local target = math.max(1, math.floor(lines * frac))
			local max_top = math.max(1, lines - vim.api.nvim_win_get_height(win) + 1)
			target = math.min(target, max_top)
			if vim.fn.line("w0", win) ~= target then
				vim.api.nvim_win_call(win, function()
					vim.cmd("stopinsert")
					pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
					vim.cmd("normal! zt")
				end)
			end
		end
	end
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
		group = augroup,
		buffer = src,
		callback = function()
			scroll_timer:stop()
			scroll_timer:start(80, 0, function()
				scroll_timer:stop()
				vim.schedule(sync_scroll)
			end)
		end,
	})
	-- WinScrolled is global (pattern matches window id); also catch it for src's
	-- window when it scrolls without cursor move:
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = augroup,
		callback = function(ev)
			local swin = vim.fn.bufwinid(src)
			if swin > 0 and (ev.win == tostring(swin) or ev.match == tostring(swin)) then
				scroll_timer:stop()
				scroll_timer:start(80, 0, function()
					scroll_timer:stop()
					vim.schedule(sync_scroll)
				end)
			end
		end,
	})

	close = function()
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
		end
	end

	-- Collapse the preview when the source buffer or its window goes away.
	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		buffer = src,
		callback = function()
			-- BufDelete runs inside the delete; defer to a safe point.
			vim.schedule(close)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(ev)
			if tonumber(ev.match) == src_win then
				vim.schedule(close)
			end
		end,
	})

	bind_q(pbuf)
	M._close = close
end

function M.close_preview()
	if M._close then
		M._close()
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.keymap.set("n", "<leader>mv", function()
		M.preview("vsplit")
	end, { desc = "Markdown preview (vsplit)" })
	vim.keymap.set("n", "<leader>mp", function()
		M.preview("float")
	end, { desc = "Markdown preview (float)" })
end

return M
