fx_version 'cerulean'
game 'gta5'

name 'spz-update'
description 'SPiceZ-Core — Version report and update checker'
version '1.0.2'
author 'SPiceZ-Core'
lua54 'on'

shared_scripts {
  '@spz-core/shared/events.lua',
  'config.lua',
  'shared/semver.lua',
}

server_scripts {
  'server/versions.lua',   -- local scan first: the checker compares against it
  'server/github.lua',     -- defines FetchGitHub, which checker.lua calls
  'server/checker.lua',
  'server/commands.lua',
}

dependencies {
  'spz-core',
}
