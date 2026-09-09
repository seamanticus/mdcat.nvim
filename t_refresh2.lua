-- Simulate "focus back to source, edit, refresh" and verify the preview
-- window is NOT collapsed/resized after the refresh.
vim.opt.rtp:prepend("/home/jon/.agentty/sandbox/mdcat.nvim")
vim.cmd("filetype on")
require("mdcat").setup({ columns = 50, mode = "vsplit", auto_refresh = true, refresh_delay = 100 })

vim.cmd("edit /tmp/t.md")
local src = vim.api.nvim_get_current_buf()

require("mdcat").preview()

vim.defer_fn(function()
	-- find preview window
	local pwin
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "mdcat" then
			pwin = w
		end
	end
	if not pwin then
		print("FAIL: no preview window after open")
		vim.cmd("cquit!")
	end
	local width_before = vim.api.nvim_win_get_width(pwin)
	local wins_before = #vim.api.nvim_tabpage_list_wins(0)

	-- move focus to the source buffer and edit it
	vim.cmd("wincmd h")
	vim.api.nvim_buf_set_lines(src, 3, 3, false, { "changed line!" })
	vim.cmd("doautocmd TextChanged")

	vim.defer_fn(function()
		local width_after = vim.api.nvim_win_is_valid(pwin) and vim.api.nvim_win_get_width(pwin) or -1
		local wins_after = #vim.api.nvim_tabpage_list_wins(0)
		local pbuf = vim.api.nvim_win_is_valid(pwin) and vim.api.nvim_win_get_buf(pwin)
		print(string.format("wins before=%d after=%d | width %d -> %s | preview ft=%s",
			wins_before, wins_after, width_before,
			tostring(width_after), pbuf and vim.bo[pbuf].filetype or "?"))
		require("mdcat").close_preview()
		vim.cmd("qall!")
	end, 600)
end, 300)
