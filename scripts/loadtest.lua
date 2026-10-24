-- Standalone load test for OverMotionServer.
--
-- Usage:
--   HOST=16.176.140.127 PORT=7777 N=20 nvim -l scripts/loadtest.lua
--   ROUNDS=2 HOLD=120 ... (keep clients connected for two rounds)
--
-- Optional env:
--   SOLVE=1          simulate solving prompts (sends "solved" every 1-3s)
--   HOLD=45          seconds to keep clients connected (time for all rounds)
--   ROUNDS=1         number of rounds to keep the clients connected for (0 = join-only)
--   JOIN_TIMEOUT=10  seconds to wait for all initial joins
--   SOLVE_MIN=1      minimum solve delay in seconds
--   SOLVE_MAX=3      maximum solve delay in seconds
--   CLEAN_CLOSE=0    number of clients to disconnect cleanly mid-round
--   CLOSE_AFTER=5    seconds after round start to do that
--   LATE=0           number of late joiners during the round
--   LATE_AFTER=3     seconds after round start for late joiners
--
-- The script exits Neovim when done (exit code 1 on failure).

local uv = vim.uv

local function env(name, default)
  local v = vim.env[name]
  if v == nil or v == '' then
    return default
  end
  return v
end

local HOST = env('HOST', '16.176.140.127')
local PORT = tonumber(env('PORT', '7777'))
local N = tonumber(env('N', '20'))
local SOLVE = env('SOLVE', '0') == '1'
local HOLD_MS = tonumber(env('HOLD', '45')) * 1000
local ROUNDS = tonumber(env('ROUNDS', '1'))
local JOIN_TIMEOUT_MS = tonumber(env('JOIN_TIMEOUT', '10')) * 1000
local SOLVE_MIN_MS = tonumber(env('SOLVE_MIN', '1')) * 1000
local SOLVE_MAX_MS = tonumber(env('SOLVE_MAX', '3')) * 1000
local CLEAN_CLOSE = tonumber(env('CLEAN_CLOSE', '0'))
local CLOSE_AFTER_MS = tonumber(env('CLOSE_AFTER', '5')) * 1000
local LATE = tonumber(env('LATE', '0'))
local LATE_AFTER_MS = tonumber(env('LATE_AFTER', '3')) * 1000

assert(PORT and PORT > 0 and PORT <= 65535, 'invalid PORT')
assert(N and N > 0, 'invalid N')
assert(ROUNDS and ROUNDS >= 0, 'invalid ROUNDS')
if SOLVE_MAX_MS < SOLVE_MIN_MS then
  SOLVE_MAX_MS = SOLVE_MIN_MS
end

math.randomseed((os.time() + math.floor(uv.hrtime() % 1000000)) % 2147483647)

local start_ns = uv.hrtime()
local function elapsed_ms()
  return (uv.hrtime() - start_ns) / 1e6
end

local function log(fmt, ...)
  print(string.format('[%8.1fms] %s', elapsed_ms(), string.format(fmt, ...)))
end

local stats = {
  joined = 0,
  late_joined = 0,
  prompts = 0,
  solves = 0,
  ended = 0,
  errors = 0,
}
local join_latencies = {}
local clients = {}
local rounds_started = 0
local rounds_ended = 0
local round_active = false
local all_rounds_done = ROUNDS == 0
local round_prompt_base = 0
local round_solve_base = 0
local round_stats = {}
local burst_done = false
local extras_scheduled = false
local add_client

local function send(c, msg)
  if c.closed or not c.handle or c.handle:is_closing() then
    return false
  end
  c.handle:write(vim.json.encode(msg) .. '\n')
  return true
end

local function close_client(c)
  if not c or c.closed then
    return
  end
  c.closed = true
  if c.handle and not c.handle:is_closing() then
    pcall(function()
      c.handle:read_stop()
    end)
    c.handle:close()
  end
end

local function schedule_solve(c)
  local delay = SOLVE_MIN_MS
  if SOLVE_MAX_MS > SOLVE_MIN_MS then
    delay = SOLVE_MIN_MS + math.random(0, SOLVE_MAX_MS - SOLVE_MIN_MS)
  end
  local prompt_id = c.prompt_id
  local timer = uv.new_timer()
  timer:start(delay, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(function()
      if c.closed or c.ended or c.prompt_id ~= prompt_id then
        return
      end
      local ok = send(c, {
        type = 'solved',
        id = prompt_id,
        elapsed_ms = delay,
        keystrokes = math.random(60, 140),
      })
      if ok then
        stats.solves = stats.solves + 1
        if stats.solves % 10 == 0 then
          log('%d solves sent', stats.solves)
        end
      end
    end)
  end)
end

local function schedule_extras()
  if extras_scheduled then
    return
  end
  extras_scheduled = true

  if CLEAN_CLOSE > 0 then
    local timer = uv.new_timer()
    timer:start(CLOSE_AFTER_MS, 0, function()
      timer:stop()
      timer:close()
      vim.schedule(function()
        local count = math.min(CLEAN_CLOSE, N)
        for i = 1, count do
          close_client(clients[i])
        end
        log('disconnected %d clients cleanly', count)
      end)
    end)
  end

  if LATE > 0 then
    local timer = uv.new_timer()
    timer:start(LATE_AFTER_MS, 0, function()
      timer:stop()
      timer:close()
      vim.schedule(function()
        log('connecting %d late joiners', LATE)
        for j = 1, LATE do
          add_client(N + j, true)
        end
      end)
    end)
  end
end

local function handle_line(c, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= 'table' or not msg.type then
    c.errors = c.errors + 1
    stats.errors = stats.errors + 1
    log('client %d bad message: %s', c.idx, line)
    return
  end

  if msg.type == 'joined' then
    c.joined = true
    c.join_ms = (uv.hrtime() - c.connect_started) / 1e6
    if c.late then
      stats.late_joined = stats.late_joined + 1
    else
      stats.joined = stats.joined + 1
      join_latencies[#join_latencies + 1] = c.join_ms
    end
    log('client %d joined as %s (%.1fms)', c.idx, c.name, c.join_ms)
    if not c.late and stats.joined >= N and not burst_done then
      burst_done = true
      log('ALL %d JOINED in %.1fms — start the round on the server', N, elapsed_ms())
    end
  elseif msg.type == 'start' then
    c.started = true
    if not round_active then
      round_active = true
      rounds_started = rounds_started + 1
      round_prompt_base = stats.prompts
      round_solve_base = stats.solves
      for _, other in pairs(clients) do
        other.ended = false
        other.prompt_id = nil
        other.first_prompt = false
      end
      log('ROUND %d STARTED (%ds)', rounds_started, math.floor((msg.duration_ms or 0) / 1000))
      schedule_extras()
    end
  elseif msg.type == 'prompt' then
    c.prompts = c.prompts + 1
    c.prompt_id = msg.id
    stats.prompts = stats.prompts + 1
    if not c.first_prompt then
      c.first_prompt = true
      log('client %d got first prompt (id %s)', c.idx, tostring(msg.id))
    end
    if SOLVE then
      schedule_solve(c)
    end
  elseif msg.type == 'end' then
    c.ended = true
    stats.ended = stats.ended + 1
    if round_active then
      round_active = false
      rounds_ended = rounds_ended + 1
      local prompts = stats.prompts - round_prompt_base
      local solves = stats.solves - round_solve_base
      round_stats[rounds_ended] = { prompts = prompts, solves = solves }
      log('ROUND %d OVER (%d prompts, %d solves)', rounds_ended, prompts, solves)
      if rounds_ended >= ROUNDS then
        all_rounds_done = true
      else
        log('waiting for round %d — start it on the server', rounds_ended + 1)
      end
    end
  end
end

add_client = function(idx, late)
  local c = {
    idx = idx,
    late = late or false,
    name = string.format('load_%02d_%04x', idx, math.random(0, 0xffff)),
    buffer = '',
    prompts = 0,
    errors = 0,
    closed = false,
    ended = false,
    connect_started = uv.hrtime(),
  }
  clients[idx] = c

  local handle = uv.new_tcp()
  c.handle = handle
  handle:connect(HOST, PORT, function(err)
    if c.closed then
      return
    end
    if err then
      c.errors = c.errors + 1
      stats.errors = stats.errors + 1
      log('client %d connect error: %s', idx, tostring(err))
      return
    end
    log('client %d connected', idx)
    handle:read_start(function(read_err, chunk)
      if read_err then
        c.errors = c.errors + 1
        stats.errors = stats.errors + 1
        log('client %d read error: %s', idx, tostring(read_err))
        return
      end
      if not chunk then
        log('client %d closed by server', idx)
        return
      end
      c.buffer = c.buffer .. chunk
      while true do
        local nl = c.buffer:find('\n', 1, true)
        if not nl then
          break
        end
        local line = c.buffer:sub(1, nl - 1)
        c.buffer = c.buffer:sub(nl + 1)
        if #line > 0 then
          handle_line(c, line)
        end
      end
    end)
    send(c, { type = 'join', name = c.name })
  end)
end

log('connecting %d clients to %s:%d (solve=%s)', N, HOST, PORT, tostring(SOLVE))
for i = 1, N do
  add_client(i, false)
end

local burst_ok = vim.wait(JOIN_TIMEOUT_MS, function()
  return stats.joined >= N
end, 20)
if not burst_ok then
  log('JOIN TIMEOUT: only %d/%d joined', stats.joined, N)
end

if HOLD_MS > 0 then
  if ROUNDS > 0 then
    log('holding up to %ds — start round 1 on the server', math.floor(HOLD_MS / 1000))
  end
  vim.wait(HOLD_MS, function()
    return all_rounds_done
  end, 50)
  if not all_rounds_done then
    log('HOLD expired after %d/%d rounds', rounds_ended, ROUNDS)
  else
    vim.wait(500)
  end
end

log('closing all clients')
for _, c in pairs(clients) do
  close_client(c)
end
vim.wait(300)

table.sort(join_latencies)
local function percentile(p)
  if #join_latencies == 0 then
    return 0
  end
  local i = math.max(1, math.ceil(#join_latencies * p))
  return join_latencies[math.min(i, #join_latencies)]
end
local total = 0
for _, value in ipairs(join_latencies) do
  total = total + value
end
local avg = #join_latencies > 0 and (total / #join_latencies) or 0
local with_prompts = 0
for _, c in pairs(clients) do
  if c.prompts > 0 then
    with_prompts = with_prompts + 1
  end
end

print('')
print('=== SUMMARY ===')
print(string.format('target           : %s:%d', HOST, PORT))
print(string.format('initial joins    : %d/%d', stats.joined, N))
print(string.format('join latency     : avg %.1fms  p50 %.1fms  p95 %.1fms  max %.1fms', avg, percentile(0.5), percentile(0.95), percentile(1)))
if ROUNDS > 0 then
  print(string.format('rounds           : %d started, %d/%d ended', rounds_started, rounds_ended, ROUNDS))
  for i = 1, ROUNDS do
    local round = round_stats[i] or {}
    print(string.format('  round %d        : %d prompts, %d solves', i, round.prompts or 0, round.solves or 0))
  end
end
if LATE > 0 then
  print(string.format('late joins       : %d/%d', stats.late_joined, LATE))
end
print(string.format('prompts          : %d', stats.prompts))
print(string.format('clients w/prompt : %d/%d', with_prompts, stats.joined + stats.late_joined))
print(string.format('solves           : %d', stats.solves))
print(string.format('end messages     : %d', stats.ended))
print(string.format('errors           : %d', stats.errors))

local failures = 0
if stats.joined < N then
  failures = failures + 1
end
if stats.errors > 0 then
  failures = failures + 1
end
if ROUNDS > 0 then
  if rounds_started < ROUNDS then
    failures = failures + 1
  end
  if rounds_ended < ROUNDS then
    failures = failures + 1
  end
  if SOLVE then
    for i = 1, ROUNDS do
      local round = round_stats[i]
      if not round or round.prompts == 0 or round.solves == 0 then
        failures = failures + 1
      end
    end
  end
end
if LATE > 0 and stats.late_joined < LATE then
  failures = failures + 1
end

print(string.format('RESULT: %s', failures == 0 and 'PASS' or ('FAIL (' .. failures .. ')')))
print('Check the server panel: it should return to "waiting for players...".')

io.stdout:flush()
vim.cmd(failures == 0 and 'qa!' or 'cq')
