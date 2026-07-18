# ghost-cut.nvim
A "ghost cut" plugin for Neovim, inspired by [Will McGugan's prose-editor concept](https://x.com/willmcgugan/status/2074177362636538304) and programmed by Claude Fable.

## Usage

| Key | When | Does |
|-----|------|------|
| `gX` | visual mode | Ghost-cut the selection (stays visible, ghosted) |
| `p` / `P` | while a cut is pending | Paste at the cursor **and** remove the ghost from its origin |
| `<Esc>` | while a cut is pending | Cancel — un-ghost, leave the text where it is |

- Works across buffers: ghost-cut in one file, paste in another.
- A same-buffer moves are a single undo (`u` puts it back).
- A new `gX` supersedes an un-pasted ghost.
- `p` / `P` / `<Esc>` are only overridden while a cut is pending, and only
  buffer-locally, so your normal paste/escape (and plugins like
  [yanky.nvim](https://github.com/gbprod/yanky.nvim)) are untouched otherwise.

## Installation
### lazy.nvim
```lua
{
  "Bajortski/ghost-cut.nvim",
  keys = { { "gX", mode = "x", desc = "Ghost cut selection" } },
  opts = {},
}
```

Local checkout (dev):
```lua
{
  dir = "~/Projects/ghost-cut.nvim",
  keys = { { "gX", mode = "x", desc = "Ghost cut selection" } },
  opts = {},
}
```

If you don't pass `keys`, add `event = "VeryLazy"` (or drop lazy-loading) so the
mapping is created before you need it.

## Configuration
`opts` is passed to `require("ghost-cut").setup()`. Defaults:

```lua
opts = {
  cut_key          = "gX",   -- visual-mode key to ghost-cut the selection
  paste_after_key  = "p",    -- pending-only: paste after cursor + un-ghost
  paste_before_key = "P",    -- pending-only: paste before cursor + un-ghost
  cancel_key       = "<Esc>",-- pending-only: cancel, keep the text
  cancel_clears_search = true,
  -- Ghost appearance: a table of :highlight attrs, or a group name to link to.
  highlight = { fg = "#808080", strikethrough = true, italic = true },
  -- Restrict to these filetypes; nil/empty = every normal buffer.
  filetypes = nil,           -- e.g. { "markdown", "text" }
  commands  = true,          -- create :GhostCutPaste / :GhostCutCancel
}
```

The default is `gX` rather than `gx` or `gc`, since those are Neovim's built-in
"open with system app" and comment-toggle bindings.

Restrict to prose and link the ghost to your `Comment` colour, for example:
```lua
opts = {
  filetypes = { "markdown", "text", "tex" },
  highlight = "Comment",
}
```

## API
```lua
local gc = require("ghost-cut")
gc.cut()      -- ghost-cut the current visual selection
gc.paste(true)  -- paste the pending ghost after the cursor (false = before)
gc.cancel()   -- cancel the pending ghost
gc.pending()  -- boolean: is a ghost cut in flight?
```

Also `:GhostCutPaste` and `:GhostCutCancel`.

## Notes / limits
- Blockwise (`<C-v>`) selections aren't supported (it warns and no-ops).
- The ghosted text still lives in the buffer while pending — it's real text,
  just highlighted — so searches, line counts, etc. still include it until you
  paste or cancel.
- Special buffers (terminals, pickers, help) are skipped.

## License
I do not care what you do with this.
