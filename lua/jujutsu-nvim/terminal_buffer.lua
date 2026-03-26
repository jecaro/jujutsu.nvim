local M = {}

-- Buffer-local fold state: maps buffer -> { expanded_commits = {change_id = true}, commit_data = {...} }
local buffer_state = {}

--- Strip ANSI escape codes from a string
--- @param str string
--- @return string
local function strip_ansi(str)
  return str:gsub("\27%[[0-9;]*m", "")
end

--- Check if a line is a commit header (contains @○◆◉ followed by change_id)
--- @param line string
--- @return string? change_id if this is a commit header
local function get_commit_header_change_id(line)
  -- Match: marker (@○◆◉) followed by spaces and 8-letter change_id
  return line:match("[@○◆◉]%s+(%a+)")
end

--- Check if a line is a file change line (M/A/D/R followed by path)
--- @param line string
--- @return boolean
local function is_file_line(line)
  -- File lines look like: "│  M path/to/file" or "│  A path" etc
  -- They have graph chars, then spaces, then a single letter (M/A/D/R/C), then space, then a file path
  -- The file path typically contains / or . (like lua/foo.lua or README.md)
  -- We need to distinguish from description lines like "│  (no description set)"
  local after_graph = line:match("^[│├─╯╰┌└┐┘╮╭╋┼┬┴~]+%s+(.*)$")
  if not after_graph then return false end
  -- Check if it starts with a single status letter followed by space and a path-like string
  return after_graph:match("^[MADRC]%s+[%w_./%-]+$") ~= nil
end

--- Check if a line is the working copy (has @ marker)
--- @param line string
--- @return boolean
local function is_working_copy(line)
  return line:match("^[│├─╯╰┌└┐┘╮╭╋┼┬┴ ]*@") ~= nil
end

--- Parse jj log output into structured commit data
--- @param lines string[]
--- @return table[] commits Array of {header_idx, description_lines, file_lines, is_working_copy}
local function parse_commits(lines)
  local commits = {}
  local current_commit = nil

  for i, line in ipairs(lines) do
    local change_id = get_commit_header_change_id(line)
    if change_id then
      -- Start a new commit
      if current_commit then
        commits[#commits + 1] = current_commit
      end
      current_commit = {
        change_id = change_id,
        header_idx = i,
        header_line = line,
        description_lines = {},
        file_lines = {},
        is_working_copy = is_working_copy(line),
      }
    elseif current_commit then
      if is_file_line(line) then
        current_commit.file_lines[#current_commit.file_lines + 1] = line
      else
        current_commit.description_lines[#current_commit.description_lines + 1] = line
      end
    end
  end

  -- Don't forget the last commit
  if current_commit then
    commits[#commits + 1] = current_commit
  end

  return commits
end

--- Build display lines from commits based on fold state
--- @param commits table[]
--- @param expanded_commits table<string, boolean>
--- @return string[] lines to display
--- @return table<number, string> line_to_commit maps line number to change_id
local function build_display_lines(commits, expanded_commits)
  local lines = {}
  local line_to_commit = {}

  for _, commit in ipairs(commits) do
    -- Add header line
    lines[#lines + 1] = commit.header_line
    line_to_commit[#lines] = commit.change_id

    -- Add description lines
    for _, desc_line in ipairs(commit.description_lines) do
      lines[#lines + 1] = desc_line
      line_to_commit[#lines] = commit.change_id
    end

    -- Add file lines only if expanded
    if expanded_commits[commit.change_id] then
      for _, file_line in ipairs(commit.file_lines) do
        lines[#lines + 1] = file_line
        line_to_commit[#lines] = commit.change_id
      end
    end
  end

  return lines, line_to_commit
end

--- Toggle fold for commit at cursor
--- @param buf number
M.toggle_fold = function(buf)
  local state = buffer_state[buf]
  if not state then return end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local change_id = state.line_to_commit[cursor_line]
  if not change_id then return end

  -- Toggle expanded state
  if state.expanded_commits[change_id] then
    state.expanded_commits[change_id] = nil
  else
    state.expanded_commits[change_id] = true
  end

  -- Rebuild display
  local lines, line_to_commit = build_display_lines(state.commits, state.expanded_commits)
  state.line_to_commit = line_to_commit

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Re-apply highlights
  apply_highlights(buf)
end

--- Setup highlight groups for jj log output
--- Colors match jj's default colors from cli/src/config/colors.toml
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  -- Use explicit colors matching jj defaults, with fallback links for compatibility
  hl(0, "JJChangeMarkerCurrent", { bold = true })                    -- @ symbol (working_copy = bold)
  hl(0, "JJChangeMarker", { fg = "NvimLightCyan" })                   -- ○◆◉ symbols
  hl(0, "JJChangeId", { fg = "NvimLightMagenta" })                    -- change_id = magenta
  hl(0, "JJEmail", { fg = "NvimLightYellow" })                        -- author = yellow
  hl(0, "JJDate", { fg = "NvimLightCyan" })                           -- timestamp = cyan
  hl(0, "JJBookmark", { fg = "NvimLightMagenta" })                    -- bookmarks = magenta
  hl(0, "JJGitRef", { fg = "NvimLightGreen" })                        -- git_refs = green
  hl(0, "JJCommitHash", { fg = "NvimLightBlue" })                     -- commit_id = blue
  hl(0, "JJEmpty", { fg = "NvimLightGreen" })                         -- empty = green
  hl(0, "JJGraph", { fg = "NvimDarkGrey4" })                          -- separator = bright black
  hl(0, "JJDescription", { link = "Normal" })                         -- description text
  hl(0, "JJFileModified", { fg = "NvimLightCyan" })                   -- M = modified
  hl(0, "JJFileAdded", { fg = "NvimLightGreen" })                     -- A = added
  hl(0, "JJFileDeleted", { fg = "NvimLightRed" })                     -- D = deleted
end

--- Apply syntax highlighting to the buffer
--- @param buf number Buffer handle
function apply_highlights(buf)
  setup_highlights()

  -- Clear any existing matches
  vim.fn.clearmatches()

  -- Apply matches to the buffer window
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return end

  -- Graph characters (│├─╯╰┌└┐┘╮╭)
  vim.fn.matchadd("JJGraph", "[│├─╯╰┌└┐┘╮╭╋┼┬┴~]", 10, -1, { window = win })

  -- Email addresses (high priority to avoid @ conflict)
  vim.fn.matchadd("JJEmail", "\\v[a-zA-Z0-9._%+-]+\\@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", 15, -1, { window = win })

  -- Current change marker @ (only at start of line or after graph chars)
  vim.fn.matchadd("JJChangeMarkerCurrent", "\\v^[│├─╯╰┌└┐┘╮╭╋┼┬┴ ]*\\zs\\@", 11, -1, { window = win })

  -- Change markers ○◆◉
  vim.fn.matchadd("JJChangeMarker", "[○◆◉]", 11, -1, { window = win })

  -- Change ID (8 lowercase letters after marker)
  vim.fn.matchadd("JJChangeId", "\\v([○◆◉@]\\s+)@<=[a-z]{8}", 12, -1, { window = win })

  -- Date/time (YYYY-MM-DD HH:MM:SS)
  vim.fn.matchadd("JJDate", "\\v\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}", 10, -1, { window = win })

  -- Commit hash (8 hex chars at end of line) - higher priority than bookmarks
  vim.fn.matchadd("JJCommitHash", "\\v[a-f0-9]{8}$", 15, -1, { window = win })

  -- Git refs (git_head()) - green
  vim.fn.matchadd("JJGitRef", "\\vgit_head\\(\\)", 10, -1, { window = win })

  -- Bookmarks and branch names - magenta (must contain at least one non-hex char or be longer than 8)
  vim.fn.matchadd("JJBookmark", "\\v(\\d{2}:\\d{2}:\\d{2}\\s+)@<=[a-zA-Z][a-zA-Z0-9/_-]*[g-zG-Z/_-][a-zA-Z0-9/_-]*", 10, -1, { window = win })
  vim.fn.matchadd("JJBookmark", "\\v(\\d{2}:\\d{2}:\\d{2}\\s+)@<=[a-zA-Z][a-zA-Z0-9/_-]{8,}", 10, -1, { window = win })

  -- (empty) marker
  vim.fn.matchadd("JJEmpty", "(empty)", 10, -1, { window = win })

  -- (no description set)
  vim.fn.matchadd("JJEmpty", "(no description set)", 10, -1, { window = win })

  -- File change indicators
  vim.fn.matchadd("JJFileModified", "\\v^[│├─╯╰┌└┐┘╮╭╋┼┬┴~ ]+\\zsM\\ze\\s", 12, -1, { window = win })
  vim.fn.matchadd("JJFileAdded", "\\v^[│├─╯╰┌└┐┘╮╭╋┼┬┴~ ]+\\zsA\\ze\\s", 12, -1, { window = win })
  vim.fn.matchadd("JJFileDeleted", "\\v^[│├─╯╰┌└┐┘╮╭╋┼┬┴~ ]+\\zsD\\ze\\s", 12, -1, { window = win })
end

--- @class TerminalWindowOpts
--- @field split_mode "reuse"|"vsplit"|"hsplit"|nil How to create/reuse window
--- @field buf number? Existing buffer to replace (if window is reused)
--- @field window number? Existing window to reuse
--- @field title string? Buffer name to display (defaults to "[JJ]")
--- @field on_exit fun(exit_code: number)? Callback invoked when the command completes
--- @field on_close function? Callback invoked when the buffer is wiped out
--- @field on_ready fun(window: number, buffer: number)? Callback invoked when buffer is ready
--- @field on_content_loaded fun(window: number, buffer: number)? Callback invoked after content is loaded

--- Runs a jj command and displays output in a plain buffer.
--- If a window is provided and valid, reuses it by replacing the buffer.
--- Otherwise, creates a new split window with the output buffer.
---
--- @param args string[] Command arguments to pass to jj (e.g., {"log", "--summary"})
--- @param opts TerminalWindowOpts Options for the window
M.run_command_in_terminal_window = function(args, opts)
  local buffer = opts.buf
  local window = opts.window

  -- Add -s flag for log commands to get file summary
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
      callback = function()
        -- Clean up buffer state
        buffer_state[buffer] = nil
        opts.on_close()
      end
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
        local all_lines = stdout_lines
        for _, line in ipairs(stderr_lines) do
          all_lines[#all_lines + 1] = line
        end

        -- Write lines to buffer if it still exists
        if vim.api.nvim_buf_is_valid(buffer) then
          -- Check if this is a log command (has commit structure)
          local is_log = args[1] == "log"

          if is_log then
            -- Parse commits and set up fold state
            local commits = parse_commits(all_lines)
            local expanded_commits = {}

            -- Preserve expanded state from previous buffer if any
            local old_state = buffer_state[opts.buf]
            if old_state then
              expanded_commits = old_state.expanded_commits
            else
              -- Auto-expand working copy commit by default
              for _, commit in ipairs(commits) do
                if commit.is_working_copy and #commit.file_lines > 0 then
                  expanded_commits[commit.change_id] = true
                end
              end
            end

            local display_lines, line_to_commit = build_display_lines(commits, expanded_commits)

            buffer_state[buffer] = {
              commits = commits,
              expanded_commits = expanded_commits,
              line_to_commit = line_to_commit,
            }

            vim.bo[buffer].modifiable = true
            vim.api.nvim_buf_set_lines(buffer, 0, -1, false, display_lines)
            vim.bo[buffer].modifiable = false
          else
            vim.bo[buffer].modifiable = true
            vim.api.nvim_buf_set_lines(buffer, 0, -1, false, all_lines)
            vim.bo[buffer].modifiable = false
          end

          -- Apply syntax highlighting
          apply_highlights(buffer)

          -- Notify that content is loaded
          if opts.on_content_loaded then
            opts.on_content_loaded(window, buffer)
          end
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
