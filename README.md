# mdcat.nvim

Markdown preview in Neovim using [mdcat](https://github.com/swsnr/mdcat) (available in Arch's repos: `sudo pacman -S mdcat`).

## Install (lazy.nvim)

The plugin lives at `~/src/mdcat.nvim` on the machine running Neovim (adjust the path to wherever you put it):

```lua
{
  dir = "~/src/mdcat.nvim", -- REAL path to the cloned/copied folder, NOT a placeholder
  ft = "markdown",
  opts = {
    columns = 80, -- wrap width passed to mdcat --columns
  },
  keys = {
    { "<leader>mm", function() require("mdcat").preview() end, desc = "Markdown preview (mdcat)" },
  },
}
```

(The explicit `function()` handler makes the very first press preview immediately. `setup()` also binds `<leader>mm`, so with `ft = "markdown"` loading alone it works without a `keys` block too.)

If you published it to GitHub as `<youruser>/mdcat.nvim`, use that instead:

```lua
{ "<youruser>/mdcat.nvim", ft = "markdown", opts = { columns = 80 } }
```

### Getting the folder onto your machine

```bash
# from this machine (scp the whole folder):
scp -r mdcat.nvim/ yourmachine:~/src/
# or, once it's a git repo you've pushed:
git clone https://github.com/<youruser>/mdcat.nvim ~/src/mdcat.nvim
```

Verify inside Neovim with `:Lazy` — the plugin should be listed as loaded; then `require("mdcat").setup({ columns = 80 })` is already done by `opts`.

## Usage

- In a `.md` buffer press `<leader>mm` — a **vsplit** opens to the right showing the file rendered by mdcat, and focus jumps to it immediately.
- Press `q` in the preview to close it and return to your markdown buffer.

The buffer is saved silently before previewing so the render always reflects the current content.
