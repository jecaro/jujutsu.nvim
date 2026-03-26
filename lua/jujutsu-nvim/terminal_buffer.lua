local M = {}

--- Strip ANSI escape codes from a string
--- @param str string
--- @return string
local function strip_ansi(str)
  return str:gsub("\27%[[0-9;]*m", "")
end

--- @class TerminalWindowOpts
--- @field split_mode "reuse"|"vsplit"|"hsplit"|nil How to create/reuse window
--- @field buf number? Existing buffer to replace (if window is reused)
--- @field window number? Existing window to reuse
--- @field title string? Buffer name to display (defaults to "[JJ]")
--- @field on_exit fun(exit_code: number)? Callback invoked when the command completes
--- @field on_close function? Callback invoked when the buffer is wiped out
--- @field on_ready fun(window: number, buffer: number)? Callback invoked when buffer is ready

--- Runs a jj command and displays output in a plain buffer.
--- If a window is provided and valid, reuses it by replacing the buffer.
--- Otherwise, creates a new split window with the output buffer.
---
--- @param args string[] Command arguments to pass to jj (e.g., {"log", "--summary"})
--- @param opts TerminalWindowOpts Options for the window
M.run_command_in_terminal_window = function(args, opts)
  local buffer = opts.buf
  local window = opts.window

  local cmd = vim.list_extend({ "jj", "--no-pager" }, args)

  -- Create or reuse buffer
  if window and vim.api.nvim_win_is_valid(window) then
    -- Reuse existing window - create new buffer
    local current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(window)

    -- Create a new empty buffer
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(window, buffer)

    -- Restore focus
    if current_win ~= window and vim.api.nvim_win_is_valid(current_win) then
      vim.api.nvim_set_current_win(current_win)
    end
  else
    -- Create new split based on split_mode
    local split_cmd
    if opts.split_mode == "vsplit" then
      split_cmd = "vsplit"
    elseif opts.split_mode == "hsplit" then
      split_cmd = "botright split"
    else
      -- Default to hsplit for backward compatibility
      split_cmd = "botright split"
    end

    -- Create split and buffer
    vim.cmd(split_cmd)
    window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(window, buffer)
  end

  -- Configure buffer
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].buflisted = false
  vim.bo[buffer].buftype = 'nofile'
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buffer, opts.title or "[JJ]")

  -- BufWipeout fires when the buffer is closed/wiped
  if opts.on_close then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buffer,
      once = true,
      callback = opts.on_close
    })
  end

  -- Notify that buffer is ready (keymaps can be set up)
  if opts.on_ready then
    opts.on_ready(window, buffer)
  end

  -- Collect output lines
  local stdout_lines = {}
  local stderr_lines = {}

  -- Run the command asynchronously
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for i, line in ipairs(data) do
          -- Skip the last empty string that jobstart always appends
          if line ~= "" or i < #data then
            if line ~= "" then
              stdout_lines[#stdout_lines + 1] = strip_ansi(line)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for i, line in ipairs(data) do
          if line ~= "" or i < #data then
            if line ~= "" then
              stderr_lines[#stderr_lines + 1] = strip_ansi(line)
            end
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        -- Combine stdout and stderr
        local lines = stdout_lines
        for _, line in ipairs(stderr_lines) do
          lines[#lines + 1] = line
        end

        -- Write lines to buffer if it still exists
        if vim.api.nvim_buf_is_valid(buffer) then
          vim.bo[buffer].modifiable = true
          vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
          vim.bo[buffer].modifiable = false
        end

        -- Call exit callback
        if opts.on_exit then
          opts.on_exit(exit_code)
        end
      end)
    end,
  })
end

return M
