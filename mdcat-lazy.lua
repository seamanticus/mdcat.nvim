return {
	"mdcat",
	dir = vim.fn.stdpath("config") .. "/lua/mdcat",
	name = "mdcat.nvim",
	opts = { columns = 100 },
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
