local M = {}

local sentences = {}
local loaded = false
local last_index = -1

local function load()
  if loaded then
    return
  end
  local path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h') .. '/data/sentences.txt'
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and lines then
    for _, line in ipairs(lines) do
      local s = vim.trim(line)
      if #s > 0 then
        table.insert(sentences, s)
      end
    end
  end
  if #sentences == 0 then
    sentences = { 'the quick brown fox jumps over the lazy dog.' }
  end
  loaded = true
end

function M.random()
  load()
  local idx
  repeat
    idx = math.random(#sentences)
  until idx ~= last_index or #sentences == 1
  last_index = idx
  return sentences[idx]
end

function M.corrupt(text)
  local function mutate(t)
    local kind = math.random(4)
    local i = math.random(#t)
    if kind == 1 or #t < 3 then
      -- replace a letter with a random one
      local c = string.char(math.random(97, 122))
      return t:sub(1, i - 1) .. c .. t:sub(i + 1)
    elseif kind == 2 then
      -- delete a character
      return t:sub(1, i - 1) .. t:sub(i + 1)
    elseif kind == 3 and i < #t then
      -- swap two adjacent characters
      return t:sub(1, i - 1) .. t:sub(i + 1, i + 1) .. t:sub(i, i) .. t:sub(i + 2)
    else
      -- duplicate a character
      return t:sub(1, i) .. t:sub(i, i) .. t:sub(i + 1)
    end
  end

  local corrupted = text
  local times = math.max(2, math.min(4, math.floor(#text / 20)))
  for _ = 1, times do
    corrupted = mutate(corrupted)
  end
  if corrupted == text then
    corrupted = mutate(corrupted)
  end
  return corrupted
end

return M
