package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local scoring = require('overmotionserver.scoring')

local function eq(actual, expected, label)
  if actual ~= expected then
    error(string.format('%s: expected %s, got %s', label, tostring(expected), tostring(actual)))
  end
end

eq(scoring.sentence_points(100, 2000), 238, '100 keys in 2s')
eq(scoring.sentence_points(50, 1000), 952, '50 keys in 1s')
eq(scoring.sentence_points(0, 2000), 0, 'zero keys')
eq(scoring.sentence_points(100, 0), 0, 'zero time')
eq(scoring.sentence_points(-1, 2000), 0, 'negative keys')
eq(scoring.sentence_points(100, -1), 0, 'negative time')

eq(scoring.average_seconds(2, 6000), 3, 'average seconds')
eq(scoring.average_seconds(0, 6000), 0, 'average seconds with zero solves')
eq(scoring.average_seconds(nil, 6000), 0, 'average seconds with nil solves')

local entries = {
  { name = 'alice', points = 10, solved = 1, avg_seconds = 2.0, keystrokes = 100 },
  { name = 'bob', points = 20, solved = 1, avg_seconds = 3.0, keystrokes = 80 },
  { name = 'carol', points = 20, solved = 2, avg_seconds = 4.0, keystrokes = 120 },
}
scoring.sort_scores(entries)
eq(entries[1].name, 'carol', 'sort by solved tiebreak')
eq(entries[2].name, 'bob', 'sort by points')
eq(entries[3].name, 'alice', 'sort by points last')

print('scoring tests passed')
