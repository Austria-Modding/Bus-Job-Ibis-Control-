fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'busjob'
description 'ESX Bus Job mit IBIS-Terminal (Linie/Kurs), Haltestellen-HUD, Userverwaltung, Aktionslog und Routeneditor'
version '2.1.0'

shared_scripts {
    '@es_extended/imports.lua',
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}

dependencies {
    'es_extended',
    'oxmysql'
}
