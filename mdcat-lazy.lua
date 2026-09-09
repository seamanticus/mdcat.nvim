return {
	"mdcat",
	dir = vim.fn.stdpath("config") .. "/lua/mdcat",
	name = "mdcat.nvim",
	opts = {
		columns = 90,
		auto_refresh = true, -- re-run mdcat when the markdown buffer changes
		refresh_delay = 200, -- debounce ms for auto_refresh
	},
	-- dir layout doesn't match what lazy expects for auto-detecting the main
	-- module, so setup() never runs and opts is silently dropped without this.
	config = function(_, opts)
		require("mdcat").setup(opts)
	end,
	keys = {
		{ "<leader>mv", function() require("mdcat").preview("vsplit") end, ft = "markdown", desc = "Markdown preview (vsplit)" },
		{ "<leader>mp", function() require("mdcat").preview("float") end, ft = "markdown", desc = "Markdown preview (float)" },
	},
}
