return {
	"mdcat",
	dir = vim.fn.stdpath("config") .. "/lua/mdcat",
	name = "mdcat.nvim",
	opts = {
		columns = 80,
		mode = "vsplit", -- "vsplit" in the current tab, or "float" for a centered floating window
		auto_refresh = true, -- re-run mdcat when the markdown buffer changes
		refresh_delay = 400, -- debounce ms for auto_refresh
	},
	-- dir layout doesn't match what lazy expects for auto-detecting the main
	-- module, so setup() never runs and opts is silently dropped without this.
	config = function(_, opts)
		require("mdcat").setup(opts)
	end,
	keys = {
		{
			"<leader>mm",
			function()
				require("mdcat").preview()
			end,
			ft = "markdown",
		},
	},
}
