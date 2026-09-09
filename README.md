# mdcat.nvim

Markdown preview in Neovim using [mdcat](https://github.com/swsnr/mdcat) (available in Arch's repos: `sudo pacman -S mdcat`).

## Install (lazy.nvim)

```lua
{
  dir = "~/path/to/mdcat.nvim", -- or "you/mdcat.nvim" once on GitHub
  name = "mdcat.nvim",
  ft = "markdown",
  opts = {
    columns = 80, -- wrap width passed to mdcat --columns
  },
  keys = {
    { "<leader>mm", desc = "Markdown preview (mdcat)" },
  },
}
```

Or with local config instead of the plugin's setup:

```lua
require("mdcat").setup({ columns = 100 })
```

## Usage

- In a `.md` buffer press `<leader>mm` — a **vsplit** opens to the right showing the file rendered by mdcat, and focus jumps to it immediately.
- Press `q` in the preview to close it and return to your markdown buffer.

The buffer is saved silently before previewing so the render always reflects the current content.
