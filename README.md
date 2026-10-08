# mdcat.nvim

**Realtime markdown preview for Neovim — rendered inside your terminal, not a browser.**

[mdcat](https://github.com/swsnr/mdcat) does the rendering. mdcat.nvim wires it into a live preview that keeps up with your edits **and** your cursor.

## Why mdcat.nvim?

Every other markdown preview asks you to compromise. Browser-based previewers drag in Node, a dev server, a websocket and a Chrome tab that steals your focus. Snapshot TUI tools render once and go stale the moment you type. In-buffer conceal plugins only *decorate* your text — you never actually see rendered markdown.

**mdcat.nvim renders in your terminal, live:**

- ⚡ **Realtime refresh** — the preview re-renders automatically as the source buffer changes (debounced, default 200 ms). No `:w`, no manual refresh command, no "is this stale?" — what you see is always what you just typed.
- 🪟 **Two views, one keystroke each** — a centered **floating window** (`<leader>mp`) when you want a quick full-width look, or a persistent **vertical split** (`<leader>mv`) when you're writing side-by-side.
- 🎯 **Cursor-anchored scroll sync** — the preview tracks your cursor line *exactly*. mdcat.nvim renders the source rows above your cursor through mdcat itself and uses the resulting line count as the anchor, so the mapping survives line wrapping, tables, code fences and emphasis transforms — precisely the constructs that break fraction- and text-search-based sync everywhere else.
- 🖥️ **Terminal-native rendering** — syntax-highlighted code blocks, tables, rule lines, colors, and images on Kitty / WezTerm / iTerm-class terminals. A real render in a real Neovim buffer.
- 🧹 **Zero ceremony** — the buffer is saved silently before each render, `q` closes the preview, and closing the markdown buffer collapses the preview with it. No orphaned windows, ever.
- 🪶 **Featherweight** — one Lua module, one CLI dependency. No Node, no Deno, no yarn build, no browser extension.

### How it stacks up

| | mdcat.nvim | markdown-preview.nvim | peek.nvim | glow.nvim | render-markdown.nvim |
|---|---|---|---|---|---|
| Where it renders | Neovim buffer (terminal) | external browser | external browser | floating TUI | in-buffer conceal |
| Live refresh while editing | ✅ automatic | on save | on save | ❌ | decorations only |
| Follows your cursor | ✅ anchored, exact | scroll-linked | ❌ | ❌ | n/a |
| vsplit + floating views | ✅ both | browser window | browser window | float only | n/a |
| Runtime dependencies | `mdcat` | Node.js + server | Deno | `glow` | none |

## Requirements

- Neovim ≥ 0.10
- [`mdcat`](https://github.com/swsnr/mdcat) ≥ 2.0 on your `$PATH` — Arch: `sudo pacman -S mdcat`; elsewhere: `cargo install mdcat` or grab a [release](https://github.com/swsnr/mdcat/releases)

## Install

### lazy.nvim

```lua
{
  "seamanticus/mdcat.nvim",
  ft = "markdown",
  opts = {
    columns = 90, -- render width; the preview window is sized to match
  },
  keys = {
    { "<leader>mv", function() require("mdcat").preview("vsplit") end, ft = "markdown", desc = "Markdown preview (vsplit)" },
    { "<leader>mp", function() require("mdcat").preview("float") end, ft = "markdown", desc = "Markdown preview (float)" },
  },
}
```

lazy.nvim auto-detects `lua/mdcat/init.lua` as the main module, so `opts` flow straight into `setup()` — no `config` hook needed.

Loading it locally instead (development checkout):

```lua
{ dir = "~/repos/seamanticus/mdcat.nvim", ft = "markdown", opts = {} },
```

Any other plugin manager or a manual setup works too:

```lua
require("mdcat").setup({ columns = 90 })
```

### Configuration

All options, with their defaults:

```lua
opts = {
  columns = 90,           -- render width passed to `mdcat --columns`
  auto_refresh = true,    -- re-render the preview as the source buffer changes
  refresh_delay = 200,    -- debounce (ms) for auto_refresh
  scroll_sync = true,     -- keep the preview anchored to the source cursor line
  scroll_sync_delay = 40, -- debounce (ms) for scroll sync
}
```

## Usage

| Key | Action |
|-----|--------|
| `<leader>mv` | open a **vsplit** preview |
| `<leader>mp` | open a **floating window** preview |
| `q` | close the preview |

- The source buffer is saved silently before every render, so the preview always reflects the live buffer — never a stale file on disk.
- Edit the source and the preview updates itself; move the cursor and the preview scrolls to the matching position in the document.
- Close the markdown buffer — or `:q` its window — and the preview collapses with it.

## How scroll sync works

Naive sync maps source line → preview position by fraction, or by searching for the source line's text in the preview. Both fail with a wrapping renderer: fractions diverge the moment one wrapped paragraph changes the rendered line count, and text search misses exactly the lines a renderer transforms (fences, tables, rules, emphasis).

mdcat.nvim does it the only exact way: it renders source rows `1..cursor` through **mdcat itself** (a few milliseconds over stdin) and uses the resulting line count as the preview's anchor line, refined by a small bounded text match. The anchor is correct for every construct, every wrap width, every cursor position.