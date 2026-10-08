local M = {}

local buf = nil
local win = nil

function M.show()
  if win and vim.api.nvim_win_is_valid(win) then
    return
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local width = 52
  local height = 16
  local ok, w = pcall(vim.api.nvim_open_win, buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'single',
  })
  if not ok then
    win = nil
    return
  end
  win = w
  vim.wo[win].cursorline = true
  vim.keymap.set('n', 'q', function()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      win = nil
    end
  end, { buffer = buf, nowait = true })
  vim.keymap.set('n', 's', function()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local seconds = nil
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local n = l:match('duration:%s*(%d+)')
      if n then
        seconds = tonumber(n)
        break
      end
    end
    if not seconds or seconds <= 0 then
      vim.notify('[OverMotionServer] invalid duration, using 300s', vim.log.levels.WARN)
      seconds = 300
    end
    require('overmotionserver.server').start(seconds)
  end, { buffer = buf, nowait = true })
end

function M.refresh()
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local server = require('overmotionserver.server')
  local status = server.status()

  -- preserve the user's editable duration line across refreshes
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local duration_line = '  duration: 300s'
  for _, l in ipairs(current) do
    if l:match('duration:') then
      duration_line = l
      break
    end
  end

  local lines = {
    '  OVERMOTION SERVER — port ' .. status.port,
    '',
  }
  if status.running and status.remaining_ms then
    table.insert(lines, string.format('  status: running, %ds left', math.floor(status.remaining_ms / 1000)))
  else
    table.insert(lines, '  status: idle')
  end
  table.insert(lines, duration_line)
  table.insert(lines, '')

  local sorted = {}
  for _, p in pairs(server.players()) do
    table.insert(sorted, p)
  end
  table.sort(sorted, function(a, b)
    return a.score.solved > b.score.solved
  end)
  if #sorted == 0 then
    table.insert(lines, '  waiting for players...')
  else
    for i, p in ipairs(sorted) do
      table.insert(lines, string.format('  %d. %-12s %2d solved  %4d keys  %5dms', i, p.name, p.score.solved, p.score.keystrokes, p.score.elapsed_ms))
    end
  end
  table.insert(lines, '')
  table.insert(lines, '  [s] start round   [q] close ui')

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = true
end

return M
