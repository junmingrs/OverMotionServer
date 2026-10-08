vim.api.nvim_create_user_command('OverMotionServerListen', function(opts)
  require('overmotionserver.server').listen(opts.args ~= '' and tonumber(opts.args) or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('OverMotionServerStart', function(opts)
  require('overmotionserver.server').start(opts.args ~= '' and tonumber(opts.args) or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('OverMotionServerStop', function()
  require('overmotionserver.server').stop()
end, {})

vim.api.nvim_create_user_command('OverMotionServerUI', function()
  require('overmotionserver.ui').show()
  require('overmotionserver.ui').refresh()
end, {})
