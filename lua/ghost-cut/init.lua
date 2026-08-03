-- ghost-cut.nvim --------------------------------------------------------------
--
-- Will McGugan's "ghost cut" idea: cutting text normally removes it right away
-- and the document reflows, so you lose your place. Ghost cut instead leaves the
-- cut text in place but dimmed + struck through (nothing reflows). The text only
-- actually leaves its original spot once you PASTE it somewhere else.
--
-- Flow:
--   * visual select -> `gX`      ghost-cut the selection (stays visible, ghosted)
--   * move cursor   -> `p` / `P` paste at the new spot AND remove the ghost
--   * while ghosted -> `<Esc>`   cancel (un-ghost, leave the text where it is)
--
-- `p`/`P`/`<Esc>` are only overridden while a cut is pending, and buffer-local,
-- so any existing global mappings (e.g. yanky.nvim) are untouched otherwise.

local api = vim.api

local M = {}

---@class GhostCut.Config
local defaults = {
  -- Visual-mode key that ghost-cuts the selection.
  -- (Default is gX, not gx: gx is Neovim's built-in "open with system app",
  -- and gc is the built-in comment toggle.)
  cut_key = "gX",
  -- Normal-mode keys, active ONLY while a cut is pending, that paste the ghost
  -- at the cursor and remove it from its origin.
  paste_after_key = "p",
  paste_before_key = "P",
  -- Normal-mode key, active only while pending, that cancels (keeps the text).
  cancel_key = "<Esc>",
  -- Also clear search highlight when cancelling with the cancel key.
  cancel_clears_search = true,
  -- Highlight for ghosted text. A table of :highlight attrs, or a string naming
  -- a group to link "GhostCut" to (e.g. "Comment").
  highlight = { fg = "#808080", strikethrough = true, italic = true },
  -- Restrict to these filetypes. nil / empty = every normal buffer.
  ---@type string[]|nil
  filetypes = nil,
  -- Create :GhostCutPaste and :GhostCutCancel.
  commands = true,
}

---@type GhostCut.Config
local cfg = vim.deepcopy(defaults)

local ns = api.nvim_create_namespace("ghost-cut")
-- Single pending slot: { buf, mark_id, lines, linewise, n }
local pending = nil
-- Buffers the pending override is installed on, and the pending-scoped augroup
-- that follows the cursor across buffers.
local installed = {}
local pend_grp = nil

-- Is `buf` a buffer we're willing to ghost in? (normal buffer + filetype gate)
local function eligible(buf)
  if vim.bo[buf].buftype ~= "" then return false end
  if cfg.filetypes and #cfg.filetypes > 0 then
    return vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype)
  end
  return true
end

local function set_hl()
  if type(cfg.highlight) == "string" then
    api.nvim_set_hl(0, "GhostCut", { link = cfg.highlight })
  else
    api.nvim_set_hl(0, "GhostCut", cfg.highlight)
  end
end

-- The normal-mode keys that exist only while a cut is pending. One definition
-- drives both install and removal, so the two can't drift apart.
local function pending_keys()
  return {
    { lhs = cfg.paste_after_key, desc = "Ghost paste (after)", rhs = function() M.paste(true) end },
    { lhs = cfg.paste_before_key, desc = "Ghost paste (before)", rhs = function() M.paste(false) end },
    {
      lhs = cfg.cancel_key,
      desc = "Cancel ghost cut",
      rhs = function()
        M.cancel()
        if cfg.cancel_clears_search then vim.cmd("nohlsearch") end
      end,
    },
  }
end

-- Buffer-local override installed while a cut is pending. Kept buffer-local so it
-- merely shadows any global `p`/`P` and reverts cleanly when removed.
local function install_put_maps(buf)
  if installed[buf] or not api.nvim_buf_is_valid(buf) then return end
  for _, k in ipairs(pending_keys()) do
    vim.keymap.set("n", k.lhs, k.rhs, { buffer = buf, silent = true, desc = k.desc })
  end
  installed[buf] = true
end

local function remove_put_maps()
  local keys = pending_keys()
  for buf in pairs(installed) do
    if api.nvim_buf_is_valid(buf) then
      for _, k in ipairs(keys) do
        pcall(vim.keymap.del, "n", k.lhs, { buffer = buf })
      end
    end
  end
  installed = {}
end

-- Drop the pending ghost: remove the highlight and restore the overridden keys
-- everywhere. Leaves the buffer text untouched (it was never removed).
local function clear()
  if not pending then return end
  if api.nvim_buf_is_valid(pending.buf) then
    pcall(api.nvim_buf_del_extmark, pending.buf, ns, pending.mark_id)
  end
  remove_put_maps()
  if pend_grp then
    pcall(api.nvim_del_augroup_by_id, pend_grp)
    pend_grp = nil
  end
  pending = nil
end

-- Exclusive byte column just past the (possibly multibyte) char at col0.
local function char_end_col(buf, row0, col0)
  local line = api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
  if col0 >= #line then return #line end
  local w = vim.fn.byteidx(line:sub(col0 + 1), 1) -- bytes of the first char
  return col0 + (w > 0 and w or 1)
end

-- Start position and extmark options covering the last visual selection.
local function selection_range(buf, linewise)
  local sp, ep = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local s_row, s_col = sp[2] - 1, sp[3] - 1
  local e_row, e_col = ep[2] - 1, ep[3] - 1

  if linewise then
    local last = api.nvim_buf_get_lines(buf, e_row, e_row + 1, false)[1] or ""
    return s_row, 0, { end_row = e_row, end_col = #last, hl_group = "GhostCut" }
  end
  return s_row, s_col, { end_row = e_row, end_col = char_end_col(buf, e_row, e_col), hl_group = "GhostCut" }
end

--- Ghost-cut the current visual selection.
function M.cut()
  local buf = api.nvim_get_current_buf()
  if not eligible(buf) then return end

  -- Yank the selection: fills the unnamed register (so a plain copy still exists)
  -- and sets the '< / '> marks for us to read.
  vim.cmd("silent normal! y")

  local rt = vim.fn.getregtype('"')
  if rt ~= "v" and rt ~= "V" then
    vim.notify("Ghost cut: blockwise selections aren't supported", vim.log.levels.WARN, { title = "ghost-cut" })
    return
  end
  local linewise = rt == "V"
  local lines = vim.fn.getreg('"', 1, true)

  -- A new cut supersedes any un-pasted one.
  if pending then clear() end

  local s_row, s_col, opts = selection_range(buf, linewise)
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns, s_row, s_col, opts)
  if not ok then return end

  pending = { buf = buf, mark_id = id, lines = lines, linewise = linewise, n = #lines }
  install_put_maps(buf)

  -- Follow the cursor across buffers: install the override on any eligible buffer
  -- entered while the cut is pending, so the ghost can be pasted anywhere.
  pend_grp = api.nvim_create_augroup("ghost-cut-pending", { clear = true })
  api.nvim_create_autocmd("BufEnter", {
    group = pend_grp,
    callback = function(ev)
      if pending and eligible(ev.buf) then install_put_maps(ev.buf) end
    end,
  })
end

--- Paste the ghost at the cursor (after=true for `p`, false for `P`) and remove
--- the original from its old spot.
---@param after boolean
function M.paste(after)
  local st = pending
  if not st then return end
  local cur = api.nvim_get_current_buf()

  -- Insert at the cursor like a real paste (cursor follows to the moved text).
  api.nvim_put(st.lines, st.linewise and "l" or "c", after, true)

  -- Delete the original. Read the extmark's *current* position (it auto-shifts if
  -- the insert above pushed it). For a same-buffer move, join the delete to the
  -- insert so one `u` undoes the whole thing; across buffers they live in
  -- separate undo histories, so don't (a dangling undojoin could mis-join later).
  if api.nvim_buf_is_valid(st.buf) then
    local pos = api.nvim_buf_get_extmark_by_id(st.buf, ns, st.mark_id, { details = true })
    if pos and pos[1] then
      local s_row, s_col, details = pos[1], pos[2], pos[3]
      if st.buf == cur then vim.cmd("silent! undojoin") end
      if st.linewise then
        api.nvim_buf_set_lines(st.buf, s_row, s_row + st.n, false, {})
      else
        api.nvim_buf_set_text(st.buf, s_row, s_col, details.end_row or s_row, details.end_col or s_col, {})
      end
    end
  end

  clear()
end

--- Cancel a pending ghost: un-highlight, keep the text where it is.
function M.cancel()
  clear()
end

--- Is a ghost cut currently pending?
---@return boolean
function M.pending()
  return pending ~= nil
end

--- Set up ghost-cut. Safe to call more than once (reconfigures cleanly).
---@param opts GhostCut.Config|nil
function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  clear() -- drop any in-flight ghost if reconfiguring

  local grp = api.nvim_create_augroup("ghost-cut", { clear = true })
  set_hl()
  api.nvim_create_autocmd("ColorScheme", { group = grp, callback = set_hl })

  local function map_cut(buf)
    vim.keymap.set("x", cfg.cut_key, M.cut,
      { buffer = buf, silent = true, desc = "Ghost cut selection" })
  end

  if cfg.filetypes and #cfg.filetypes > 0 then
    -- Buffer-local trigger on the configured filetypes only, so any global
    -- binding on the key is preserved elsewhere.
    api.nvim_create_autocmd("FileType", {
      group = grp,
      pattern = cfg.filetypes,
      callback = function(ev) map_cut(ev.buf) end,
    })
    if vim.tbl_contains(cfg.filetypes, vim.bo.filetype) then map_cut(0) end
  else
    -- Global trigger.
    map_cut(nil)
  end

  if cfg.commands then
    api.nvim_create_user_command("GhostCutPaste", function() M.paste(true) end,
      { desc = "Paste the pending ghost cut" })
    api.nvim_create_user_command("GhostCutCancel", function() M.cancel() end,
      { desc = "Cancel the pending ghost cut" })
  end
end

return M
