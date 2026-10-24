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
local current_host = '0.0.0.0'
local timer = nil
local ui_timer = nil

local VIRTUAL_IFACE = {
  '^docker', '^br%-', '^veth', '^virbr', '^vmnet', '^vboxnet', '^tun', '^tap', '^wg', '^zt',
}

local function is_virtual_iface(name)
  for _, pat in ipairs(VIRTUAL_IFACE) do
    if name:match(pat) then
      return true
    end
  end
  return false
end

-- Higher rank wins. Prefer real LAN ranges over tunnels/containers.
local function ip_rank(ip, iface)
  if is_virtual_iface(iface) then
    return 0
  end
  if ip:match('^192%.168%.') then
    return 40
  end
  if ip:match('^10%.') then
    return 30
  end
  local second = tonumber(ip:match('^172%.(%d+)%.'))
  if second and second >= 16 and second <= 31 then
    return 20
  end
  if ip:match('^100%.') then
    return 10 -- CGNAT / Tailscale
  end
  return 5
end

-- Best-guess IPv4 address participants should connect to. nil when offline.
function M.local_ip()
  local ok, ifaces = pcall(uv.interface_addresses)
  if not ok or type(ifaces) ~= 'table' then
    return nil
  end
  local best, best_rank = nil, -1
  for name, addrs in pairs(ifaces) do
    for _, a in ipairs(addrs) do
      if a.family == 'inet' and not a.internal and a.ip then
        local rank = ip_rank(a.ip, name)
        if rank > best_rank then
          best, best_rank = a.ip, rank
        end
      end
    end
  end
  return best
end

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
    send(player, { type = 'joined', name = player.name })
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

local MAX_BUFFER = 64 * 1024

local function escape_bytes(s, max)
  s = s:sub(1, max)
  return (s:gsub('[^\32-\126]', function(c)
    return string.format('\\x%02x', c:byte())
  end))
end

local function utf16_to_utf8(s, be)
  local out = {}
  local i = 1
  local n = #s - (#s % 2)
  while i < n do
    local b1, b2 = s:byte(i), s:byte(i + 1)
    local unit = be and (b1 * 256 + b2) or (b2 * 256 + b1)
    i = i + 2
    local cp = unit
    if unit >= 0xD800 and unit <= 0xDBFF and i < n then
      local c1, c2 = s:byte(i), s:byte(i + 1)
      local low = be and (c1 * 256 + c2) or (c2 * 256 + c1)
      if low >= 0xDC00 and low <= 0xDFFF then
        cp = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
        i = i + 2
      end
    end
    if cp < 0x80 then
      out[#out + 1] = string.char(cp)
    elseif cp < 0x800 then
      out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      out[#out + 1] = string.char(
        0xE0 + math.floor(cp / 0x1000),
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
      )
    else
      out[#out + 1] = string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
      )
    end
  end
  return table.concat(out)
end

-- Number of bytes that can be decoded now. Holds back a dangling odd byte or
-- high surrogate so the next chunk can complete it.
local function utf16_ready(s, be)
  local n = #s - (#s % 2)
  if n >= 2 then
    local b1, b2 = s:byte(n - 1), s:byte(n)
    local unit = be and (b1 * 256 + b2) or (b2 * 256 + b1)
    if unit >= 0xD800 and unit <= 0xDBFF then
      n = n - 2
    end
  end
  return n
end

local function detect_encoding(player, bytes)
  if bytes:sub(1, 3) == '\239\187\191' then
    player.encoding = 'utf-8'
    return bytes:sub(4)
  end
  if bytes:sub(1, 2) == '\255\254' then
    player.encoding = 'utf-16le'
    return bytes:sub(3)
  end
  if bytes:sub(1, 2) == '\254\255' then
    player.encoding = 'utf-16be'
    return bytes:sub(3)
  end
  local sample = bytes:sub(1, 256)
  local _, nuls = sample:gsub('%z', '')
  if #sample >= 4 and nuls > #sample * 0.3 then
    player.encoding = sample:byte(1) == 0 and 'utf-16be' or 'utf-16le'
    return bytes
  end
  player.encoding = 'utf-8'
  return bytes
end

local function dispatch(player, line)
  line = line:gsub('^\239\187\191', '')
  line = vim.trim(line)
  if line == '' then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= 'table' or not msg.type then
    player.bad = (player.bad or 0) + 1
    if player.bad <= 3 then
      log(('bad message from %s: %s'):format(player.name, escape_bytes(line, 120)))
    end
    return
  end
  vim.schedule(function()
    if players[player.id] == player then
      handle_message(player, msg)
    end
  end)
end

local function feed_text(player, text)
  player.buffer = player.buffer .. text
  while true do
    local s, e, sep = player.buffer:find('([\r\n])')
    if not s then
      break
    end
    if sep == '\r' and e == #player.buffer then
      break -- might be a CRLF split across reads
    end
    local line = player.buffer:sub(1, s - 1)
    local nxt = e + 1
    if sep == '\r' and player.buffer:sub(nxt, nxt) == '\n' then
      nxt = nxt + 1
    end
    player.buffer = player.buffer:sub(nxt)
    dispatch(player, line)
  end

  if #player.buffer > MAX_BUFFER then
    log('buffer overflow from ' .. player.name .. ', dropping connection')
    players[player.id] = nil
    player.buffer = ''
    if player.handle and not player.handle:is_closing() then
      player.handle:close()
    end
    vim.schedule(M.refresh)
    return
  end

  -- For clients that never send a delimiter: accept a complete JSON object.
  local rest = vim.trim(player.buffer)
  if rest ~= '' and rest:sub(1, 1) == '{' then
    local ok, msg = pcall(vim.json.decode, rest)
    if ok and type(msg) == 'table' and msg.type then
      player.buffer = ''
      dispatch(player, rest)
    end
  end
end

local function feed_raw(player, chunk)
  player.raw = player.raw .. chunk
  local be = player.encoding == 'utf-16be'
  local ready = utf16_ready(player.raw, be)
  if ready <= 0 then
    return
  end
  local text = utf16_to_utf8(player.raw:sub(1, ready), be)
  player.raw = player.raw:sub(ready + 1)
  feed_text(player, text)
end

local function on_client(client)
  local player = {
    id = next_player_id,
    name = 'player' .. next_player_id,
    handle = client,
    buffer = '',
    raw = '',
    encoding = nil,
    bad = 0,
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
    if chunk == '' then
      return
    end
    if player.encoding == nil then
      player.raw = player.raw .. chunk
      local first = player.raw:byte(1)
      local maybe_bom = first == 0xEF or first == 0xFF or first == 0xFE
      if maybe_bom and #player.raw < 3 then
        return -- wait for the rest of a possible BOM
      end
      chunk = detect_encoding(player, player.raw)
      player.raw = ''
    end
    if player.encoding == 'utf-8' then
      feed_text(player, chunk)
    else
      feed_raw(player, chunk)
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
  return {
    running = running,
    remaining_ms = remaining,
    port = current_port,
    host = current_host,
    ip = M.local_ip(),
  }
end

function M.listen(port, host)
  port = port or 7777
  host = host or '0.0.0.0'
  if server then
    log('already listening on ' .. current_host .. ':' .. current_port)
    return
  end
  server = uv.new_tcp()
  local ok, err = pcall(function()
    local bound, bind_err = server:bind(host, port)
    if not bound then
      error(bind_err or 'bind failed', 0)
    end
    local listening, listen_err = server:listen(128, function(accept_err)
      if accept_err then
        log('listen error: ' .. tostring(accept_err))
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      on_client(client)
    end)
    if not listening then
      error(listen_err or 'listen failed', 0)
    end
  end)
  if not ok then
    log('bind failed on ' .. host .. ':' .. port .. ': ' .. tostring(err))
    server:close()
    server = nil
    return
  end
  current_port = port
  current_host = host
  log('listening on ' .. host .. ':' .. port)
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

function M.shutdown()
  if not server then
    return false
  end

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
  started_at = nil

  for id, player in pairs(players) do
    players[id] = nil
    local handle = player.handle
    if handle and not handle:is_closing() then
      handle:read_stop()
      handle:close()
    end
  end

  server:close()
  server = nil
  log('stopped listening on ' .. current_host .. ':' .. current_port)
  M.refresh()
  return true
end

return M
