local M = {}

-- Points for one solved sentence. Time is measured in milliseconds and
-- converted to seconds before applying the formula. Whole numbers keep the
-- displayed score and the ranking consistent.
function M.sentence_points(keystrokes, elapsed_ms)
  local keys = tonumber(keystrokes) or 0
  local ms = tonumber(elapsed_ms) or 0
  if keys <= 0 or ms <= 0 then
    return 0
  end
  local seconds = ms / 1000
  local points = 10000 / ((keys * 0.7) * (seconds * 0.3))
  return math.floor(points + 0.5)
end

function M.average_seconds(solved, elapsed_ms)
  local count = tonumber(solved) or 0
  if count <= 0 then
    return 0
  end
  return (tonumber(elapsed_ms) or 0) / count / 1000
end

function M.sort_scores(entries)
  table.sort(entries, function(a, b)
    if a.points ~= b.points then
      return a.points > b.points
    end
    if a.solved ~= b.solved then
      return a.solved > b.solved
    end
    if a.avg_seconds ~= b.avg_seconds then
      return a.avg_seconds < b.avg_seconds
    end
    if a.keystrokes ~= b.keystrokes then
      return a.keystrokes < b.keystrokes
    end
    return (a.name or '') < (b.name or '')
  end)
  return entries
end

return M
