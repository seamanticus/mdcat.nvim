local M = {}

M.config = {
	columns = 90,
	-- re-render the preview when the source markdown buffer changes.
	auto_refresh = true,
	-- debounce for auto_refresh (ms). mdcat runs once the buffer is quiet.
	refresh_delay = 200,
	-- Sync the preview's top line to the source's cursor line on scroll.
	-- Anchors by matching the (stripped) current source line in the rendered
	-- terminal buffer; the first match becomes the preview's top line.
	scroll_sync = true,
	-- Coalesce cursor moves (ms) before re-anchoring the preview.
	scroll_sync_delay = 40,
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
-- on_done: called (in the main loop, render fully landed) with the new
-- buffer so the caller can re-anchor the view to the source cursor.
local function spawn(bin, cols, file, win, current_buf, srcbuf, on_done)
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
				-- Render finished: hand the fresh buffer to the caller so it can
				-- re-anchor the view to the source cursor. Positioning here (after
				-- the full output exists) is deterministic; schedules racing the
				-- render were not.
				vim.schedule(function()
					if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
						return
					end
					vim.api.nvim_win_call(win, function()
						vim.cmd("stopinsert")
					end)
					if on_done then
						on_done(buf)
					end
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

-- (source_top_fraction removed: the fraction-based sync was the cause of
-- random jumps to the top of the preview — narrow columns change the
-- rendered line count, so the fraction no longer corresponds to the
-- source's position. All positioning is now anchor-based.)

-- mdcat renders the SAME prefix of the document identically in a
-- standalone render as it does in the full-document render. So to find
-- where source row N lands in the rendered preview, render rows 1..N
-- through stdin and look at the tail: the last content line of that render
-- is exactly the rendered form of the content at/above the cursor row.
-- This works for every construct mdcat transforms (fences, tables, rules,
-- emphasis) because mdcat itself does the mapping — no fragile guessing
-- about how `|`, ``` or `---` lines render.
--
-- Returns via callback the rendered anchor line (string) and the CONTENT
-- line count of the prefix render (number) for rows 1..cursor_row.
local function render_prefix_anchor(bin, cols, src_lines, cursor_row, callback)
	if cursor_row < 1 then
		callback(nil, nil)
		return
	end
	local prefix = table.concat(src_lines, "\n", 1, cursor_row)
	vim.system({ bin, "--columns", tostring(cols), "--no-colour", "-" }, {
		stdin = prefix,
		text = true,
	}, function(res)
		vim.schedule(function()
			if res.code ~= 0 or not res.stdout then
				callback(nil, nil)
				return
			end
			local lines = vim.split(res.stdout, "\n", { plain = true })
			-- Walk the tail, skipping: trailing blank, the footnote block
			-- ([n]: url), and table/fence border lines. What remains is the
			-- rendered form of the content at the cursor row (or the nearest
			-- content above it if the cursor is on a blank/border row).
			local i = #lines
			while i >= 1 do
				local t = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
				if t == "" or t:match("^%[%d+%]:") or t:match("^[─══—_-]+$") then
					i = i - 1
				else
					break
				end
			end
			if i < 1 then
				callback(nil, nil)
				return
			end
			callback(lines[i]:gsub("^%s+", ""):gsub("%s+$", ""), i)
		end)
	end)
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

	-- Set by the sync block below once sync_scroll exists: re-anchors the
	-- freshly-rendered preview to the source cursor instead of the old
	-- top-fraction jump (which caused random jumps to the top).
	local on_render = {}
	local pbuf = spawn(bin, cols, file, win, nil, src, function(buf)
		if on_render[1] then
			on_render[1](buf)
		end
	end)
	vim.bo[pbuf].scrollback = 10000

	-- Forwarding reference: refresh() reassigns the preview buffer (each render
	-- gets a brand-new terminal buffer; reusing one is racy). All closures
	-- below must go through pbuf_box[1], not the captured local, or they'll
	-- keep talking to the now-hidden old buffer.
	local pbuf_box = { pbuf }

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
			local cur = pbuf_box[1]
			if not vim.api.nvim_buf_is_valid(cur) or not vim.api.nvim_buf_is_valid(src) then
				return
			end
			local new_pbuf = spawn(bin, cols, file, win, cur, src, function(buf)
				if on_render[1] then
					on_render[1](buf)
				end
			end)
			vim.bo[new_pbuf].scrollback = 10000
			pbuf_box[1] = new_pbuf
			bind_q(new_pbuf)
			-- Re-register the cache-rebuild autocmd on the NEW preview buffer;
			-- the old one was scoped to the now-hidden buffer.
			vim.api.nvim_create_autocmd({ "BufModifiedSet", "TextChanged", "TextChangedT" }, {
				group = augroup,
				buffer = new_pbuf,
				callback = function()
					rendered_lines = vim.api.nvim_buf_get_lines(new_pbuf, 0, -1, false)
				end,
			})
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
	-- Cache of the rendered terminal-buffer lines, refreshed whenever the
	-- preview buffer changes (initial render, refresh). Used by sync_scroll
	-- to anchor the preview's top line to the source cursor's content
	-- without re-running mdcat.
	local rendered_lines = {}
	local function refresh_rendered_cache()
		local cur = pbuf_box[1]
		if cur and vim.api.nvim_buf_is_valid(cur) then
			rendered_lines = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
		end
	end
	vim.api.nvim_create_autocmd({ "BufModifiedSet", "TextChanged", "TextChangedT" }, {
		group = augroup,
		buffer = pbuf_box[1],
		callback = refresh_rendered_cache,
	})
	local sync_seq = 0
	local function sync_scroll()
		local cur = pbuf_box[1]
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(cur) then
			return
		end
		if not vim.api.nvim_buf_is_valid(src) then
			return
		end
		if #rendered_lines == 0 then
			refresh_rendered_cache()
			if #rendered_lines == 0 then
				return -- render not landed yet
			end
		end
		local ok_sw, src_winid = pcall(vim.fn.bufwinid, src)
		if not ok_sw or src_winid < 0 then
			return
		end
		local cursor = vim.api.nvim_win_get_cursor(src_winid)
		local src_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
		-- Cancel any in-flight prefix render: rapid cursor moves must not
		-- stack stale async queries.
		if sync_seq then
			sync_seq = sync_seq + 1
		else
			sync_seq = 1
		end
		local seq = sync_seq
		render_prefix_anchor(bin, cols, src_lines, cursor[1], function(anchor, count)
			if seq ~= sync_seq then
				return -- a newer cursor move superseded this query
			end
			if not anchor or not count then
				return -- leave the view untouched
			end
			local target = count
			-- Bounded text refinement ±4 lines: truncation can add/subtract a
			-- couple of artifact lines at construct boundaries, and repeated
			-- identical content must not jump to the first match.
			local norm_anchor = anchor:gsub("%s+", " ")
			for d = 0, 4 do
				for _, cand in ipairs({ count - d, count + d }) do
					if cand >= 1 and cand <= #rendered_lines then
						local norm = rendered_lines[cand]:gsub("%s+", " ")
						if norm:find(norm_anchor, 1, true) then
							target = cand
							break
						end
					end
				end
				if target ~= count then
					break
				end
			end
			local max_top = math.max(1, #rendered_lines - vim.api.nvim_win_get_height(win) + 1)
			target = math.max(1, math.min(target, max_top))
			if vim.fn.line("w0", win) ~= target then
				vim.api.nvim_win_call(win, function()
					vim.cmd("stopinsert")
					pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
				vim.cmd("normal! zt")
				end)
			end
		end)
	end
	-- After each render lands, re-anchor to the cursor (replaces the old
	-- fraction-based positioning that jumped to the top).
	on_render[1] = function()
		refresh_rendered_cache()
		if M.config.scroll_sync then
			sync_scroll()
		end
	end
	if M.config.scroll_sync then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
			group = augroup,
			buffer = src,
			callback = function()
				scroll_timer:stop()
				scroll_timer:start(M.config.scroll_sync_delay, 0, function()
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
					scroll_timer:start(M.config.scroll_sync_delay, 0, function()
						scroll_timer:stop()
						vim.schedule(sync_scroll)
					end)
				end
			end,
		})
	end

	close = function()
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		if vim.api.nvim_win_is_valid(win) then
			local ok = pcall(vim.api.nvim_win_close, win, true)
			if not ok then
				-- E444: the preview is the last window — the markdown buffer was :q'd
				-- and nothing else is left. Mirror the float behavior (quitting the
				-- source exits Neovim and the float dies with it): quit instead of
				-- leaving a hollow empty window behind.
				local normal = 0
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_get_config(w).relative == "" then
						normal = normal + 1
					end
				end
				if normal == 1 then
					-- The user already quit the source; if it lingers hidden and
					-- modified, it was abandoned (:q!) — drop it so :qall doesn't
					-- trip over E37.
					if vim.api.nvim_buf_is_valid(src) and vim.bo[src].modified
						and vim.fn.bufwinid(src) == -1 then
						pcall(vim.api.nvim_buf_delete, src, { force = true })
					end
					ok = pcall(vim.cmd, "qall")
				end
				if not ok and vim.api.nvim_buf_is_valid(pbuf_box[1]) then
					-- Exit blocked (e.g. a hidden modified buffer elsewhere): don't
					-- force-discard the user's changes; leave an empty window.
					pcall(vim.api.nvim_buf_delete, pbuf_box[1], { force = true })
				end
			end
		end
		if vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
		end
	end

	-- Collapse the preview when the source disappears: buffer deleted, its
	-- window closed, or (float case — floats don't trigger WinClosed on the
	-- source) the source simply stops being displayed.
	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		buffer = src,
		callback = function()
			-- BufDelete runs inside the delete; defer to a safe point.
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(src)
					or vim.fn.bufwinid(src) == -1
				then
					close()
				end
			end)
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
	-- Wipeout covers :bw / :bdelete! paths BufDelete sometimes misses for
	-- modified buffers.
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		buffer = src,
		callback = function()
			vim.schedule(close)
		end,
	})
	-- Float case: quitting the source window doesn't fire WinClosed for it in a
	-- way we reliably see before the float is orphaned. Recheck on every window
	-- switch: if the source buffer is gone or no longer displayed, close.
	vim.api.nvim_create_autocmd("WinEnter", {
		group = augroup,
		callback = function()
			vim.schedule(function()
				if not vim.api.nvim_win_is_valid(win) then
					return
				end
				if not vim.api.nvim_buf_is_valid(src) or vim.fn.bufwinid(src) == -1 then
					close()
				end
			end)
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
