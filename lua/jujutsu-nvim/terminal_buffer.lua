local M = {}

-- Buffer-local fold state: maps buffer -> { expanded_commits = {change_id = true}, commit_data = {...} }
local buffer_state = {}

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace("jujutsu_prefix_highlights")

--- Strip ANSI escape codes from a string
--- @param str string
--- @return string
local function strip_ansi(str)
  return str:gsub("\27%[[0-9;]*m", "")
end

--- Parse ANSI codes to extract prefix lengths for change IDs and commit hashes
--- jj uses different colors for working copy vs other commits:
---   Working copy: 38;5;13 (bright magenta) for change_id, 38;5;12 (bright blue) for commit_id
---   Other commits: 38;5;5 (magenta) for change_id, 38;5;4 (blue) for commit_id
--- Suffix is dim gray (38;5;8) for all commits
--- Sequence for working copy: prefix_color -> suffix_color (38;5;8) -> reset (39m)
--- Sequence for others: prefix_color -> reset (0m) -> suffix_color (38;5;8) -> reset (39m)
--- @param line string Raw line with ANSI codes
--- @return string stripped_line Line without ANSI codes
--- @return table prefix_info Array of {col, prefix_len, total_len} for IDs found
local function parse_ansi_prefixes(line)
  local prefix_info = {}
  local stripped = ""
  local col = 0  -- 0-indexed column in stripped string

  -- Track current state
  local current_id_start = nil   -- Column where current ID started
  local current_prefix_len = nil -- Length of the unique prefix (set when prefix ends)
  local in_suffix = false        -- Whether we're currently reading the suffix

  local i = 1
  while i <= #line do
    -- Check for ANSI escape sequence
    if line:sub(i, i) == "\27" then
      local seq_end = line:find("m", i)
      if seq_end then
        local seq = line:sub(i, seq_end)
        -- Check for ID prefix colors:
        -- magenta (change_id): 38;5;13 (bright) or 38;5;5 (normal)
        -- blue (commit_id): 38;5;12 (bright) or 38;5;4 (normal)
        if seq:match("38;5;13") or seq:match("38;5;12") or
           seq:match("38;5;5[m;]") or seq:match("38;5;5$") or
           seq:match("38;5;4[m;]") or seq:match("38;5;4$") then
          -- Starting a new ID prefix
          current_id_start = col
          current_prefix_len = nil
          in_suffix = false
        -- Check for dim gray (suffix color): 38;5;8
        elseif seq:match("38;5;8") then
          -- If we have an ID start but no prefix length yet, record it now
          if current_id_start ~= nil and current_prefix_len == nil then
            current_prefix_len = col - current_id_start
          end
          -- Now we're in the suffix
          in_suffix = true
        -- Check for reset: 39m
        elseif seq:match("%[39m") then
          -- This ends the current ID (either suffix or full ID)
          if current_id_start ~= nil then
            local total_len = col - current_id_start
            -- If we never got a prefix_len, the whole thing is the prefix
            local prefix_len = current_prefix_len or total_len
            if total_len > 0 and prefix_len > 0 then
              prefix_info[#prefix_info + 1] = {
                col = current_id_start,
                prefix_len = prefix_len,
                total_len = total_len,
              }
            end
            current_id_start = nil
            current_prefix_len = nil
            in_suffix = false
          end
        -- Check for full reset: 0m (used between prefix and suffix in non-working-copy)
        elseif seq:match("%[0m") then
          -- If we're in a prefix, record the prefix length (suffix comes next)
          if current_id_start ~= nil and current_prefix_len == nil and not in_suffix then
            current_prefix_len = col - current_id_start
          end
          -- Don't reset current_id_start - we're still tracking this ID
        end
        i = seq_end + 1
      else
        i = i + 1
      end
    else
      -- Regular character
      stripped = stripped .. line:sub(i, i)
      col = col + 1
      i = i + 1
    end
  end

  return stripped, prefix_info
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
  -- File lines look like: "│  M path/to/file" or "│ │    M README.md" (with branches)
  -- Key: status letter is preceded by 2+ spaces and followed by a filepath (no spaces in path)
  -- This distinguishes from description text where words have other chars before them
  -- Also handle renames: "R old/path{old => new}suffix" or "R {old => new}/path"
  return line:match("%s%s+[MADRC] [%w_./{}<>= %-]+$") ~= nil
end

--- Check if a line is the working copy (has @ marker)
--- @param line string
--- @return boolean
local function is_working_copy(line)
  return line:match("^[│├─╯╰┌└┐┘╮╭╋┼┬┴ ]*@") ~= nil
end

--- Parse jj log output into structured commit data
--- @param lines string[]
--- @param line_prefix_info table? Optional mapping of line index to prefix info
--- @return table[] commits Array of {header_idx, description_lines, file_lines, is_working_copy, header_prefix_info}
local function parse_commits(lines, line_prefix_info)
  local commits = {}
  local current_commit = nil
  line_prefix_info = line_prefix_info or {}

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
        header_prefix_info = line_prefix_info[i],  -- Attach prefix info for this header
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
--- @return table<number, table> display_prefix_info maps display line number to prefix info
local function build_display_lines(commits, expanded_commits)
  local lines = {}
  local line_to_commit = {}
  local display_prefix_info = {}

  for _, commit in ipairs(commits) do
    -- Add header line
    lines[#lines + 1] = commit.header_line
    line_to_commit[#lines] = commit.change_id
    if commit.header_prefix_info then
      display_prefix_info[#lines] = commit.header_prefix_info
    end

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

  return lines, line_to_commit, display_prefix_info
end

--- Toggle fold for commit at cursor
--- @param buf number
--- @param on_redraw fun()? Optional callback called after buffer is redrawn
M.toggle_fold = function(buf, on_redraw)
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
  local lines, line_to_commit, display_prefix_info = build_display_lines(state.commits, state.expanded_commits)
  state.line_to_commit = line_to_commit
  state.display_prefix_info = display_prefix_info

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Re-apply highlights
  apply_highlights(buf)

  -- Call redraw callback if provided (e.g., to refresh selection display)
  if on_redraw then
    on_redraw()
  end
end

--- Setup highlight groups for jj log output
--- Colors match jj's default colors from cli/src/config/colors.toml
local function setup_highlights()
  local hl = vim.api.nvim_set_hl
  -- Use explicit colors matching jj defaults, with fallback links for compatibility
  hl(0, "JJChangeMarkerCurrent", { bold = true })                    -- @ symbol (working_copy = bold)
  hl(0, "JJChangeMarker", { fg = "NvimLightCyan" })                   -- ○◆◉ symbols
  hl(0, "JJChangeId", { fg = "NvimLightMagenta" })                    -- change_id = magenta (fallback)
  hl(0, "JJChangeIdPrefix", { fg = "NvimLightMagenta", bold = true }) -- change_id unique prefix
  hl(0, "JJChangeIdSuffix", { fg = "NvimDarkGrey4" })                 -- change_id rest (dim)
  hl(0, "JJEmail", { fg = "NvimLightYellow" })                        -- author = yellow
  hl(0, "JJDate", { fg = "NvimLightCyan" })                           -- timestamp = cyan
  hl(0, "JJBookmark", { fg = "NvimLightMagenta" })                    -- bookmarks = magenta
  hl(0, "JJGitRef", { fg = "NvimLightGreen" })                        -- git_refs = green
  hl(0, "JJCommitHash", { fg = "NvimLightBlue" })                     -- commit_id = blue (fallback)
  hl(0, "JJCommitHashPrefix", { fg = "NvimLightBlue", bold = true })  -- commit_id unique prefix
  hl(0, "JJCommitHashSuffix", { fg = "NvimDarkGrey4" })               -- commit_id rest (dim)
  hl(0, "JJEmpty", { fg = "NvimLightGreen" })                         -- empty = green
  hl(0, "JJGraph", { fg = "NvimDarkGrey4" })                          -- separator = bright black
  hl(0, "JJDescription", { link = "Normal" })                         -- description text
  hl(0, "JJFileModified", { link = "diffChanged" })                   -- M = modified (cyan)
  hl(0, "JJFileAdded", { link = "diffAdded" })                        -- A = added (green)
  hl(0, "JJFileDeleted", { link = "diffRemoved" })                    -- D = deleted (red)
  hl(0, "JJFileRenamed", { link = "diffChanged" })                    -- R = renamed (cyan)
  hl(0, "JJFileCopied", { link = "diffAdded" })                       -- C = copied (green)
end

--- Apply syntax highlighting to the buffer using vim syntax (buffer-local)
--- Also applies extmarks for change_id and commit_id prefix/suffix highlighting
--- @param buf number Buffer handle
function apply_highlights(buf)
  setup_highlights()

  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax enable
      syntax clear

      " Graph characters
      syntax match JJGraph /[│├─╯╰┌└┐┘╮╭╋┼┬┴~]/

      " Email addresses (high priority to avoid @ conflict)
      syntax match JJEmail /[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,}/

      " Current change marker @ (only at start of line or after graph chars)
      syntax match JJChangeMarkerCurrent /^[│├─╯╰┌└┐┘╮╭╋┼┬┴ ]*\zs@/

      " Change markers ○◆◉
      syntax match JJChangeMarker /[○◆◉]/

      " Date/time (YYYY-MM-DD HH:MM:SS)
      syntax match JJDate /\d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}:\d\{2}/

      " Change ID fallback (8 lowercase letters after marker) - may be overridden by extmarks
      syntax match JJChangeId /\([○◆◉@]\s\+\)\@<=[a-z]\{8}/

      " Commit hash fallback (8 hex chars at end of line) - may be overridden by extmarks
      syntax match JJCommitHash /[a-f0-9]\{8}$/

      " Git refs (git_head())
      syntax match JJGitRef /git_head()/

      " Bookmarks and branch names (after timestamp, contains non-hex or longer than 8)
      syntax match JJBookmark /\(\d\{2}:\d\{2}:\d\{2}\s\+\)\@<=[a-zA-Z][a-zA-Z0-9/_-]*[g-zG-Z/_-][a-zA-Z0-9/_-]*/
      syntax match JJBookmark /\(\d\{2}:\d\{2}:\d\{2}\s\+\)\@<=[a-zA-Z][a-zA-Z0-9/_-]\{8,}/

      " (empty) and (no description set) markers
      syntax match JJEmpty /(empty)/
      syntax match JJEmpty /(no description set)/

      " File change lines (status letter + filepath)
      " Match lines that end with: M/A/D/R/C + space + filepath
      syntax match JJFileModified /M [a-zA-Z0-9_./-]\+$/
      syntax match JJFileAdded /A [a-zA-Z0-9_./-]\+$/
      syntax match JJFileDeleted /D [a-zA-Z0-9_./-]\+$/
      syntax match JJFileRenamed /R [a-zA-Z0-9_./-]\+$/
      syntax match JJFileCopied /C [a-zA-Z0-9_./-]\+$/
    ]])
  end)

  -- Clear previous extmarks
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Apply extmarks for prefix/suffix highlighting
  local state = buffer_state[buf]
  if state and state.display_prefix_info then
    for line_num, prefix_infos in pairs(state.display_prefix_info) do
      for _, info in ipairs(prefix_infos) do
        local row = line_num - 1  -- 0-indexed for extmarks
        -- Apply prefix highlight (bright)
        if info.prefix_len > 0 then
          -- Determine if this is a change_id or commit_id based on content
          local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
          if line then
            local id_text = line:sub(info.col + 1, info.col + info.total_len)
            local is_change_id = id_text:match("^[a-z]+$")  -- change_id is lowercase letters
            local prefix_hl = is_change_id and "JJChangeIdPrefix" or "JJCommitHashPrefix"
            local suffix_hl = is_change_id and "JJChangeIdSuffix" or "JJCommitHashSuffix"

            -- Apply prefix highlight
            vim.api.nvim_buf_set_extmark(buf, ns_id, row, info.col, {
              end_col = info.col + info.prefix_len,
              hl_group = prefix_hl,
              priority = 200,  -- Higher priority than syntax
            })

            -- Apply suffix highlight
            if info.total_len > info.prefix_len then
              vim.api.nvim_buf_set_extmark(buf, ns_id, row, info.col + info.prefix_len, {
                end_col = info.col + info.total_len,
                hl_group = suffix_hl,
                priority = 200,
              })
            end
          end
        end
      end
    end
  end
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
      split_cmd = "topleft split"
    else
      -- Default to hsplit
      split_cmd = "topleft split"
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
  local line_prefix_info = {}  -- Maps line index to prefix info

  -- Run the command asynchronously with color output
  local cmd_with_color = vim.list_extend(vim.list_slice(cmd, 1, 2), { "--color=always" })
  cmd_with_color = vim.list_extend(cmd_with_color, vim.list_slice(cmd, 3))

  vim.fn.jobstart(cmd_with_color, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for i, line in ipairs(data) do
          -- Skip the last empty string that jobstart always appends
          if line ~= "" or i < #data then
            if line ~= "" then
              local stripped, prefix_info = parse_ansi_prefixes(line)
              stdout_lines[#stdout_lines + 1] = stripped
              if #prefix_info > 0 then
                line_prefix_info[#stdout_lines] = prefix_info
              end
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
            local commits = parse_commits(all_lines, line_prefix_info)
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

            local display_lines, line_to_commit, display_prefix_info = build_display_lines(commits, expanded_commits)

            buffer_state[buffer] = {
              commits = commits,
              expanded_commits = expanded_commits,
              line_to_commit = line_to_commit,
              display_prefix_info = display_prefix_info,
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

--- Get the change_id for a given line number in the buffer
--- @param buf number Buffer handle
--- @param line_num number Line number (1-indexed)
--- @return string? change_id
M.get_change_id_at_line = function(buf, line_num)
  local state = buffer_state[buf]
  if not state then return nil end
  return state.line_to_commit[line_num]
end

return M
