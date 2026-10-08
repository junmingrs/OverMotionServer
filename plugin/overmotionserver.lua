vim.api.nvim_create_user_command('OverMotionServerListen', function(opts)
  require('overmotionserver.server').listen(opts.args ~= '' and tonumber(opts.args) or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('OverMotionServerStart', function(opts)
  require('overmotionserver.server').start(opts.args ~= '' and tonumber(opts.args) or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('OverMotionServerStop', function()
  require('overmotionserver.server').stop()
end, {})
