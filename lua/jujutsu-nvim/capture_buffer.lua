local u = require("jujutsu-nvim.utils")

local M = {}

--- @class CaptureBufferOpts
--- @field content string? Initial content to display
--- @field filetype string? Buffer filetype (e.g., 'jjdescription', 'text')
--- @field extra_help_text string? Extra help text shown at top of buffer
--- @field on_submit fun(content: string) Callback with user content (without help lines)
--- @field on_abort function? Optional callback on abort
--- @field on_ready fun(window: number, buffer: number)? Callback invoked when buffer is ready

--- Open an editor buffer meant to capture user input
--- @param opts CaptureBufferOpts
M.open = function(opts)
  local buf = vim.api.nvim_create_buf(false, false)

  -- Set buffer options
  vim.api.nvim_buf_set_name(buf, 'jj://describe')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype or 'text'

  -- Set content (just the description, like jj describe in shell)
  local lines = vim.split(opts.content or "", "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Open buffer in a split
  vim.cmd('topleft split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * 0.4))
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  -- Extract user content from buffer (filter JJ: lines like jj does)
  local function get_user_content()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Filter out lines starting with "JJ:"
    local filtered = {}
    for _, line in ipairs(all_lines) do
      if not line:match("^JJ:") then
        table.insert(filtered, line)
      end
    end
    -- Trim leading and trailing empty lines (matches jj's trim_matches('\n') behavior)
    while #filtered > 0 and filtered[1]:match("^%s*$") do
      table.remove(filtered, 1)
    end
    while #filtered > 0 and filtered[#filtered]:match("^%s*$") do
      table.remove(filtered)
    end
    return table.concat(filtered, "\n")
  end

  -- :w saves the description
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    callback = function()
      opts.on_submit(get_user_content())
      vim.bo[buf].modified = false
    end,
    buffer = buf,
  })

  -- Closing without saving triggers abort
  vim.api.nvim_create_autocmd('BufUnload', {
    callback = function()
      if vim.bo[buf].modified then
        vim.schedule(function()
          if opts.on_abort then
            opts.on_abort()
          end
        end)
      end
    end,
    buffer = buf,
  })
end

return M
