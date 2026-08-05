-- Headless test suite. Run from the repo root:
--   nvim --headless -l tests/run.lua

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    failed = failed + 1
    io.write("  FAIL " .. name .. "\n       " .. tostring(err) .. "\n")
  end
end

local function eq(got, want, what)
  if got ~= want then
    error((what or "value") .. ": got " .. vim.inspect(got) .. ", want " .. vim.inspect(want), 2)
  end
end

local function truthy(v, what)
  if not v then
    error((what or "value") .. " should be truthy, got " .. vim.inspect(v), 2)
  end
end

local gc = require("ghost-cut")
gc.setup({})

local function buf_with(lines)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  -- Break undo, so the fixture write isn't lumped in with whatever the test does
  -- next; interactively that boundary appears on its own.
  vim.cmd("let &undolevels = &undolevels")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return vim.api.nvim_get_current_buf()
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local ns = vim.api.nvim_create_namespace("ghost-cut")
local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf or 0, ns, 0, -1, {})
end

io.write("cut\n")
test("charwise cut leaves the text in place and marks it pending", function()
  local buf = buf_with({ "alpha beta gamma" })
  feed("gg0vegX")
  truthy(gc.pending(), "a cut is pending")
  eq(lines()[1], "alpha beta gamma", "text is untouched while ghosted")
  eq(#marks(buf), 1, "one ghost extmark")
end)

test("cancel un-ghosts and keeps the text", function()
  local buf = buf_with({ "alpha beta gamma" })
  feed("gg0vegX")
  gc.cancel()
  eq(gc.pending(), false, "nothing pending")
  eq(lines()[1], "alpha beta gamma", "text unchanged")
  eq(#marks(buf), 0, "extmark removed")
end)

test("a second cut supersedes the first", function()
  local buf = buf_with({ "alpha beta gamma" })
  feed("gg0vegX")
  feed("wvegX")
  truthy(gc.pending(), "still pending")
  eq(#marks(buf), 1, "only one ghost at a time")
  gc.cancel()
end)

io.write("paste\n")
test("charwise paste moves the text and clears the ghost", function()
  buf_with({ "alpha beta" })
  feed("gg0vegX") -- ghost "alpha"
  feed("$p") -- paste after the last char
  eq(gc.pending(), false, "no longer pending")
  local text = table.concat(lines(), "\n")
  truthy(text:find("alpha"), "pasted text present: " .. vim.inspect(text))
  truthy(not text:find("alpha beta"), "original removed: " .. vim.inspect(text))
end)

test("linewise paste moves whole lines", function()
  buf_with({ "one", "two", "three" })
  feed("ggVgX") -- ghost the line "one"
  truthy(gc.pending(), "pending after linewise cut")
  feed("Gp") -- paste after the last line
  eq(gc.pending(), false, "cleared after paste")
  eq(table.concat(lines(), ","), "two,three,one", "line moved to the end")
end)

test("same-buffer move undoes in a single step", function()
  buf_with({ "one", "two", "three" })
  feed("ggVgX")
  feed("Gp")
  eq(table.concat(lines(), ","), "two,three,one", "moved")
  feed("u")
  eq(table.concat(lines(), ","), "one,two,three", "one undo restores it")
end)

io.write("guards\n")
test("paste with nothing pending is a no-op", function()
  buf_with({ "untouched" })
  gc.paste(true)
  eq(lines()[1], "untouched")
end)

test("blockwise selections are refused", function()
  buf_with({ "abc", "def" })
  feed("gg0<C-v>jlgX")
  eq(gc.pending(), false, "no pending cut for a blockwise selection")
end)

test("special buffers are ineligible", function()
  vim.cmd("enew!")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch text" })
  feed("gg0vegX")
  eq(gc.pending(), false, "no cut in a nofile buffer")
end)

test("filetype gating restricts the cut key", function()
  gc.setup({ filetypes = { "markdown" } })
  vim.cmd("enew!")
  vim.bo.filetype = "python"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha beta" })
  feed("gg0vegX")
  eq(gc.pending(), false, "no cut in a non-markdown buffer")
  gc.setup({})
end)

io.write("setup\n")
test("registers the cut key in visual mode", function()
  gc.setup({})
  eq(vim.fn.maparg("gX", "x", false, true).desc, "Ghost cut selection")
end)

test("honours a custom cut_key", function()
  gc.setup({ cut_key = "<leader>gc" })
  local buf = buf_with({ "alpha beta" })
  feed("gg0ve\\gc")
  truthy(gc.pending(), "custom key cuts")
  eq(#marks(buf), 1, "ghost rendered")
  gc.cancel()
  gc.setup({})
end)

test("creates the user commands", function()
  local cmds = vim.api.nvim_get_commands({})
  truthy(cmds.GhostCutPaste, "GhostCutPaste")
  truthy(cmds.GhostCutCancel, "GhostCutCancel")
end)

test("commands = false skips them", function()
  vim.api.nvim_del_user_command("GhostCutPaste")
  vim.api.nvim_del_user_command("GhostCutCancel")
  gc.setup({ commands = false })
  eq(vim.api.nvim_get_commands({}).GhostCutPaste, nil)
  gc.setup({})
end)

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
