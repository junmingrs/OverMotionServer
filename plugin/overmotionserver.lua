vim.api.nvim_create_user_command('OverMotionServerListen', function(opts)
  local args = vim.split(opts.args, '%s+', { trimempty = true })
  local port = args[1] and tonumber(args[1])
  if args[1] and (not port or port < 1 or port > 65535 or port % 1 ~= 0) then
    vim.notify('[OverMotionServer] invalid port: ' .. args[1], vim.log.levels.ERROR)
    return
  end
  require('overmotionserver.server').listen(port, args[2])
end, { nargs = '*', desc = 'Listen on [port] [host]' })

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
