local M = {}

local uv = vim.uv

local server = nil
local players = {}
local next_player_id = 1
local next_prompt_id = 1
local running = false
local duration_ms = 300000
local started_at = nil
local current_port = 7777
local timer = nil
local ui_timer = nil

local function log(msg)
  vim.schedule(function()
    vim.notify('[OverMotionServer] ' .. msg)
  end)
end

local function send(player, msg)
  local ok, encoded = pcall(vim.json.encode, msg)
  if ok and player.handle and not player.handle:is_closing() then
    player.handle:write(encoded .. '\n')
  end
end

local function broadcast(msg)
  for _, p in pairs(players) do
    send(p, msg)
  end
end

local function new_prompt(player)
  local sentences = require('overmotionserver.sentences')
  local target = sentences.random()
  local broken = sentences.corrupt(target)
  player.current_id = next_prompt_id
  next_prompt_id = next_prompt_id + 1
  return { type = 'prompt', id = player.current_id, target = target, broken = broken }
end

local function print_scores()
  local lines = { 'Final scores:' }
  local sorted = {}
  for _, p in pairs(players) do
    table.insert(sorted, p)
  end
  table.sort(sorted, function(a, b)
    return a.score.solved > b.score.solved
  end)
  for i, p in ipairs(sorted) do
    table.insert(lines, string.format('%d. %s — %d solved, %d keys, %dms', i, p.name, p.score.solved, p.score.keystrokes, p.score.elapsed_ms))
  end
  log(table.concat(lines, '\n'))
end

local function stop_round()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if ui_timer then
    ui_timer:stop()
    ui_timer:close()
    ui_timer = nil
  end
  running = false
  broadcast({ type = 'end' })
  print_scores()
  M.refresh()
end

local function handle_message(player, msg)
  if msg.type == 'join' then
    player.name = msg.name or ('player' .. player.id)
    log('join: ' .. player.name)
    M.refresh()
    if running then
      local remaining = math.max(0, duration_ms - (uv.now() - started_at))
      send(player, { type = 'start', duration_ms = remaining })
      send(player, new_prompt(player))
    end
  elseif msg.type == 'solved' and running then
    if msg.id == player.current_id then
      player.score.solved = player.score.solved + 1
      player.score.keystrokes = player.score.keystrokes + (msg.keystrokes or 0)
      player.score.elapsed_ms = player.score.elapsed_ms + (msg.elapsed_ms or 0)
      log(string.format('solved: %s (%d keys, %dms)', player.name, msg.keystrokes or 0, msg.elapsed_ms or 0))
      M.refresh()
      send(player, new_prompt(player))
    else
      log('stale solved from ' .. player.name .. ' (id ' .. tostring(msg.id) .. ')')
    end
  end
end

local function on_client(client)
  local player = {
    id = next_player_id,
    name = 'player' .. next_player_id,
    handle = client,
    buffer = '',
    score = { solved = 0, keystrokes = 0, elapsed_ms = 0 },
    current_id = nil,
  }
  next_player_id = next_player_id + 1
  players[player.id] = player
  log('connected: ' .. player.name)

  client:read_start(function(err, chunk)
    if err then
      log('read error: ' .. tostring(err))
      return
    end
    if not chunk then
      players[player.id] = nil
      client:close()
      log('disconnected: ' .. player.name)
      vim.schedule(M.refresh)
      return
    end
    player.buffer = player.buffer .. chunk
    while true do
      local nl = player.buffer:find('\n', 1, true)
      if not nl then
        break
      end
      local line = player.buffer:sub(1, nl - 1)
      player.buffer = player.buffer:sub(nl + 1)
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == 'table' and msg.type then
        vim.schedule(function()
          handle_message(player, msg)
        end)
      end
    end
  end)
end

function M.players()
  return players
end

function M.status()
  local remaining = nil
  if running and started_at then
    remaining = math.max(0, duration_ms - (uv.now() - started_at))
  end
  return { running = running, remaining_ms = remaining, port = current_port }
end

function M.listen(port)
  port = port or 7777
  if server then
    log('already listening')
    return
  end
  server = uv.new_tcp()
  local ok, err = pcall(function()
    server:bind('0.0.0.0', port)
    server:listen(128, function(listen_err)
      if listen_err then
        log('listen error: ' .. tostring(listen_err))
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      on_client(client)
    end)
  end)
  if not ok then
    log('bind failed: ' .. tostring(err))
    server = nil
    return
  end
  current_port = port
  log('listening on 0.0.0.0:' .. port)
  require('overmotionserver.ui').show()
  M.refresh()
end

function M.refresh()
  require('overmotionserver.ui').refresh()
end

function M.start(seconds)
  if running then
    log('round already running')
    return
  end
  seconds = seconds or math.floor(duration_ms / 1000)
  duration_ms = seconds * 1000
  started_at = uv.now()
  running = true
  broadcast({ type = 'start', duration_ms = duration_ms })
  for _, p in pairs(players) do
    p.score = { solved = 0, keystrokes = 0, elapsed_ms = 0 }
    send(p, new_prompt(p))
  end
  timer = uv.new_timer()
  timer:start(duration_ms, 0, function()
    vim.schedule(stop_round)
  end)
  ui_timer = uv.new_timer()
  ui_timer:start(1000, 1000, function()
    vim.schedule(M.refresh)
  end)
  log('round started: ' .. seconds .. 's')
  M.refresh()
end

function M.stop()
  if running then
    stop_round()
  end
end

return M
