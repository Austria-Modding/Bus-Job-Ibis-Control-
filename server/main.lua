local sessions    = {}   -- [source] = { userId, userName, route, nextStop, current, lastStop, rounds, vehicle }
local activeUsers = {}   -- [lower(userName)] = source
local operators   = {}   -- [source] = true  (besetzte Leitstellen-Plätze)
local operatorCount = 0
local leitMinGrade = Config.Leitstelle.defaultMinGrade

local allowedModels = {}
for _, m in ipairs(Config.Buses) do allowedModels[joaat(m)] = true end

-- ========================================================================
-- Datenbank
-- ========================================================================
local function hasColumn(tbl, col)
    local n = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tbl, col })
    return (tonumber(n) or 0) > 0
end

MySQL.ready(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bus_users` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(32) NOT NULL,
            `password` CHAR(64) NOT NULL,
            `created_by` VARCHAR(100) NOT NULL DEFAULT '',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `name` (`name`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bus_routes` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(64) NOT NULL,
            `line_no` INT NOT NULL DEFAULT 0,
            `course_no` INT NOT NULL DEFAULT 0,
            `pay` INT NOT NULL DEFAULT 150,
            `stops` LONGTEXT NOT NULL,
            PRIMARY KEY (`id`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bus_logs` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `actor` VARCHAR(100) NOT NULL DEFAULT '',
            `action` VARCHAR(60) NOT NULL DEFAULT '',
            `details` VARCHAR(255) NOT NULL DEFAULT '',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        )
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bus_settings` (
            `skey` VARCHAR(40) NOT NULL,
            `svalue` VARCHAR(255) NOT NULL DEFAULT '',
            PRIMARY KEY (`skey`)
        )
    ]])
    local g = MySQL.scalar.await('SELECT svalue FROM bus_settings WHERE skey = ?', { 'leit_min_grade' })
    if g and tonumber(g) then leitMinGrade = math.floor(tonumber(g)) end

    -- Migration: alte Routen (ohne Linie/Kurs) bekommen Linie = ID, Kurs = 1
    if not hasColumn('bus_routes', 'line_no') then
        MySQL.query.await('ALTER TABLE `bus_routes` ADD COLUMN `line_no` INT NOT NULL DEFAULT 0')
        MySQL.query.await('ALTER TABLE `bus_routes` ADD COLUMN `course_no` INT NOT NULL DEFAULT 0')
        MySQL.query.await('UPDATE `bus_routes` SET `line_no` = `id`, `course_no` = 1 WHERE `line_no` = 0')
        print('^3[busjob]^7 Bestehende Routen wurden migriert (Linie = Routen-ID, Kurs = 1). Bitte im Routeneditor anpassen.')
    end

    print('^2[busjob]^7 Datenbank bereit.')
end)

-- ========================================================================
-- Helfer
-- ========================================================================
local ROUTE_COLUMNS = 'id, name, pay, stops, line_no AS lineNo, course_no AS courseNo'

local function clean(v, max)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if #v == 0 or #v > max then return nil end
    return v
end

local function isAdmin(xPlayer)
    if not xPlayer then return false end
    local group = xPlayer.getGroup()
    for _, g in ipairs(Config.AdminGroups) do
        if g == group then return true end
    end
    return false
end

local function hasAccess(xPlayer)
    if not xPlayer then return false end
    if Config.AdminIgnoresJob and isAdmin(xPlayer) then return true end
    local job = xPlayer.getJob()
    return job.name == Config.ManagementJob and job.grade >= Config.ManagementMinGrade
end

local function guard(src, needAdmin)
    local xPlayer = ESX.GetPlayerFromId(src)
    if not hasAccess(xPlayer) then return nil end
    if needAdmin and not isAdmin(xPlayer) then return nil end
    return xPlayer
end

local function actorOf(xPlayer)
    return ('%s (ID %s)'):format(xPlayer.getName(), xPlayer.source)
end

local function addLog(actor, action, details)
    MySQL.insert('INSERT INTO bus_logs (actor, action, details) VALUES (?, ?, ?)', {
        tostring(actor):sub(1, 100), tostring(action):sub(1, 60), tostring(details or ''):sub(1, 255)
    })
end

-- Bus, in dem der Spieler auf dem Fahrersitz sitzt (oder nil)
local function driverBus(src)
    local ped = GetPlayerPed(src)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped or not allowedModels[GetEntityModel(veh)] then
        return nil
    end
    return veh
end

local function routePayload(s)
    local r = s.route
    return {
        id = r.id, line = r.lineNo, course = r.courseNo, name = r.name, pay = r.pay,
        stops = r.stops, nextStop = s.nextStop, current = s.current
    }
end

-- ------------------------------------------------------------------------
-- 3D-Text am Bus: Daten per State Bag an alle Spieler in der Nähe
-- ------------------------------------------------------------------------
local function clearBusState(s)
    if s.vehicle and DoesEntityExist(s.vehicle) then
        Entity(s.vehicle).state:set('busjob', nil, true)
    end
    s.vehicle = nil
end

local function updateBusState(s)
    if not s.vehicle or not DoesEntityExist(s.vehicle) then return end
    if not s.route then
        Entity(s.vehicle).state:set('busjob', nil, true)
        return
    end
    local stops = s.route.stops
    local cur = s.current > 0 and stops[s.current] or nil
    local nxt = stops[s.nextStop]
    Entity(s.vehicle).state:set('busjob', {
        line    = s.route.lineNo,
        course  = s.route.courseNo,
        current = cur and cur.name or nil,
        next    = nxt and nxt.name or nil
    }, true)
end

-- Falls der Fahrer den Bus gewechselt hat, wandert der Text mit
local function refreshVehicle(src, s)
    local veh = driverBus(src)
    if not veh or veh == s.vehicle then return end
    if s.vehicle and DoesEntityExist(s.vehicle) then
        Entity(s.vehicle).state:set('busjob', nil, true)
    end
    s.vehicle = veh
end

local releaseSeat
-- ------------------------------------------------------------------------
-- Leitstelle: Platz freigeben (muss vor endSession stehen)
-- ------------------------------------------------------------------------
releaseSeat = function(src)
    if not operators[src] then return end
    operators[src] = nil
    operatorCount = operatorCount - 1
    local s = sessions[src]
    if s then s.leit = false end
    -- Niemand mehr in der Leitstelle: offene Sprechwünsche verfallen
    if operatorCount <= 0 then
        operatorCount = 0
        for dsrc, ds in pairs(sessions) do
            if ds.talk then
                ds.talk = false
                TriggerClientEvent('bus:client:notify', dsrc, '~y~Die Leitstelle ist nicht mehr besetzt. Sprechwunsch zurückgezogen.')
            end
        end
    end
end

local function endSession(src, reason, notifyClient)
    local s = sessions[src]
    if not s then return end
    sessions[src] = nil
    activeUsers[s.userName:lower()] = nil
    clearBusState(s)
    if s.leit then releaseSeat(src) end
    addLog(s.userName, 'Abmeldung', ('%s – %s'):format(
        s.route and ('Linie %s / Kurs %s'):format(s.route.lineNo, s.route.courseNo) or 'ohne Route',
        reason or 'Abgemeldet'))
    if notifyClient then
        TriggerClientEvent('bus:client:sessionEnded', src, reason or 'Schicht beendet.')
    end
end

local function kickUser(name, reason)
    local src = activeUsers[name:lower()]
    if src then endSession(src, reason, true) end
end

local function kickRoute(routeId, reason)
    for src, s in pairs(sessions) do
        if s.route and s.route.id == routeId then endSession(src, reason, true) end
    end
end

-- ========================================================================
-- Fahrer: Status, Login, Linie/Kurs, Logout, Haltestellen
-- ========================================================================
ESX.RegisterServerCallback('bus:getState', function(src, cb)
    local s = sessions[src]
    if not s then return cb({ session = nil }) end
    cb({
        session = { user = s.userName, route = s.route and routePayload(s) or nil, leit = s.leit, talk = s.talk },
        leitOpen = operatorCount > 0,
        panicEnabled = Config.Panic.enabled,
        outsideBus = Config.Leitstelle.allowOutsideBus
    })
end)

-- Schritt 1: Name + Passwort
ESX.RegisterServerCallback('bus:login', function(src, cb, name, password)
    if sessions[src] then return cb({ ok = false, msg = 'Du bist bereits angemeldet.' }) end

    name = clean(name, 32)
    if not name or type(password) ~= 'string' or password == '' or #password > 64 then
        return cb({ ok = false, msg = 'Bitte Name und Passwort angeben.' })
    end

    local veh = driverBus(src)
    if not veh and not Config.Leitstelle.allowOutsideBus then
        return cb({ ok = false, msg = 'Du musst auf dem Fahrersitz eines Busses sitzen.' })
    end

    local user = MySQL.single.await(
        'SELECT id, name FROM bus_users WHERE name = ? AND password = SHA2(?, 256)', { name, password })
    if not user then
        addLog(name, 'Login fehlgeschlagen', ('Spieler ID %s'):format(src))
        return cb({ ok = false, msg = 'Name oder Passwort falsch.' })
    end

    if activeUsers[user.name:lower()] then
        return cb({ ok = false, msg = 'Dieser Zugang ist bereits in Benutzung.' })
    end

    sessions[src] = {
        userId = user.id, userName = user.name, route = nil,
        nextStop = 1, current = 0, lastStop = 0, rounds = 0, vehicle = veh,
        leit = false, talk = false, lastTalk = 0, lastPanic = 0, panicUntil = 0, lastStopTime = os.time()
    }
    activeUsers[user.name:lower()] = src

    addLog(user.name, 'Anmeldung', ('Spieler ID %s'):format(src))
    cb({ ok = true, user = user.name })
end)

-- Schritt 2: Linie + Kurs (Tastenfeld im Terminal)
ESX.RegisterServerCallback('bus:selectRoute', function(src, cb, line, course)
    local s = sessions[src]
    if not s then return cb({ ok = false, msg = 'Nicht angemeldet.' }) end

    line, course = tonumber(line), tonumber(course)
    if not line or not course or line < 1 or course < 1 then
        return cb({ ok = false, msg = 'Bitte Linie und Kurs eingeben.' })
    end
    line, course = math.floor(line), math.floor(course)

    local veh = driverBus(src)
    if not veh then
        return cb({ ok = false, msg = 'Du musst auf dem Fahrersitz eines Busses sitzen.' })
    end

    local route = MySQL.single.await(
        ('SELECT %s FROM bus_routes WHERE line_no = ? AND course_no = ?'):format(ROUTE_COLUMNS), { line, course })
    if not route then
        addLog(s.userName, 'Fahrplan nicht gefunden', ('Linie %s / Kurs %s'):format(line, course))
        return cb({ ok = false, msg = ('Fahrplan %s/%s nicht vorhanden.'):format(line, course) })
    end

    route.stops = json.decode(route.stops) or {}
    if #route.stops < 2 then return cb({ ok = false, msg = 'Dieser Fahrplan ist fehlerhaft.' }) end

    s.route, s.nextStop, s.current, s.lastStop = route, 1, 0, 0
    s.lastStopTime = os.time()
    refreshVehicle(src, s)
    updateBusState(s)

    addLog(s.userName, 'Fahrplan gewählt', ('Linie %s / Kurs %s – %s'):format(route.lineNo, route.courseNo, route.name))
    cb({ ok = true, route = routePayload(s) })
end)

RegisterNetEvent('bus:server:logout', function(reason)
    local src = source
    reason = type(reason) == 'string' and reason:sub(1, 60) or 'Abgemeldet'
    endSession(src, reason, false)
end)

RegisterNetEvent('bus:server:stopReached', function(idx)
    local src = source
    local s = sessions[src]
    if not s or not s.route or type(idx) ~= 'number' or idx ~= s.nextStop then return end

    local stop = s.route.stops[idx]
    if not stop then return end

    -- Serverseitige Prüfung: Spieler muss wirklich in der Nähe sein
    local pc = GetEntityCoords(GetPlayerPed(src))
    if #(pc - vector3(stop.x, stop.y, stop.z)) > (Config.StopRadius + 20.0) then return end

    -- Mindestabstand zwischen zwei Haltestellen (Anti-Spam)
    local now = os.time()
    if now - s.lastStop < math.max(1, math.floor(Config.StopWaitTime / 1000) - 1) then return end
    s.lastStop = now

    local pay = tonumber(s.route.pay) or Config.DefaultPay
    local xPlayer = ESX.GetPlayerFromId(src)
    if xPlayer and pay > 0 then
        xPlayer.addAccountMoney(Config.PayAccount, pay, 'Busjob')
    end

    local finished, ended = false, false
    s.current = idx
    s.lastStopTime = now
    s.nextStop = idx + 1
    if s.nextStop > #s.route.stops then
        finished = true
        s.nextStop = 1
        s.rounds = s.rounds + 1
        addLog(s.userName, 'Route abgeschlossen', ('Linie %s / Kurs %s (Runde %s)'):format(
            s.route.lineNo, s.route.courseNo, s.rounds))
        if not Config.LoopRoute then ended = true end
    end

    refreshVehicle(src, s)
    updateBusState(s)

    TriggerClientEvent('bus:client:stopConfirmed', src, s.nextStop, pay, finished, ended, s.current)
    if ended then endSession(src, 'Route beendet', false) end
end)

AddEventHandler('playerDropped', function()
    endSession(source, 'Verbindung getrennt', false)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, s in pairs(sessions) do clearBusState(s) end
end)

-- ========================================================================
-- Leitstelle + Panik + Sprechwunsch
-- ========================================================================
local function notifyPlayer(src, msg)
    TriggerClientEvent('bus:client:notify', src, msg)
end

local function canOperate(xPlayer)
    if not xPlayer then return false end
    if Config.AdminIgnoresJob and isAdmin(xPlayer) then return true end
    local job = xPlayer.getJob()
    return job.name == Config.ManagementJob and job.grade >= leitMinGrade
end

local function gradeLabel(grade)
    local ok, jobs = pcall(function() return ESX.GetJobs() end)
    if ok and jobs and jobs[Config.ManagementJob] then
        local g = jobs[Config.ManagementJob].grades
        local entry = g and (g[tostring(grade)] or g[grade])
        if entry and entry.label then return entry.label end
    end
    return tostring(grade)
end

-- Liste für die Leitstelle zusammenbauen
local function buildList()
    local now, list = os.time(), {}
    for src, s in pairs(sessions) do
        if not s.leit then
            local r = s.route
            local row = {
                src = src, nr = s.userId, name = s.userName,
                line = r and r.lineNo or 0, course = r and r.courseNo or 0,
                since = nil,
                talk = s.talk, panic = s.panicUntil > now
            }
            if r and r.stops and #r.stops > 0 then
                local stops = r.stops
                row.from, row.to = stops[1].name, stops[#stops].name
                local cur = s.current > 0 and stops[s.current] or nil
                local nxt = stops[s.nextStop]
                row.cur, row.nxt = cur and cur.name or nil, nxt and nxt.name or nil
                row.since = now - (s.lastStopTime or now)
            end
            list[#list + 1] = row
        end
    end
    table.sort(list, function(a, b)
        if a.panic ~= b.panic then return a.panic end
        if a.talk ~= b.talk then return a.talk end
        return a.nr < b.nr
    end)
    return list
end

local function pushList(onlySrc)
    if operatorCount == 0 then return end
    local list = buildList()
    if onlySrc then
        TriggerClientEvent('bus:client:leitList', onlySrc, list)
        return
    end
    for op in pairs(operators) do
        TriggerClientEvent('bus:client:leitList', op, list)
    end
end

CreateThread(function()
    while true do
        Wait(Config.Leitstelle.refresh)
        pushList()
    end
end)

-- Leitstelle besetzen
ESX.RegisterServerCallback('bus:leitEnter', function(src, cb)
    local s = sessions[src]
    if not s then return cb({ ok = false, msg = 'Nicht angemeldet.' }) end
    if s.leit then return cb({ ok = true }) end

    local xPlayer = ESX.GetPlayerFromId(src)
    if not canOperate(xPlayer) then
        return cb({ ok = false, msg = ('Dafür brauchst du mindestens den Rang: %s'):format(gradeLabel(leitMinGrade)) })
    end
    if operatorCount >= Config.Leitstelle.seats then
        return cb({ ok = false, msg = 'Die Leitstelle ist bereits besetzt.' })
    end

    s.leit = true
    operators[src] = true
    operatorCount = operatorCount + 1
    addLog(s.userName, 'Leitstelle besetzt', ('Spieler ID %s'):format(src))
    cb({ ok = true })
    pushList(src)
end)

-- Leitstelle verlassen
ESX.RegisterServerCallback('bus:leitLeave', function(src, cb)
    local s = sessions[src]
    if not s or not s.leit then return cb({ ok = true }) end
    releaseSeat(src)
    addLog(s.userName, 'Leitstelle verlassen', ('Spieler ID %s'):format(src))
    cb({ ok = true })
end)

-- Fahrer: Sprechwunsch (gelbes Telefon-Symbol), erneut drücken = zurückziehen
ESX.RegisterServerCallback('bus:requestTalk', function(src, cb)
    local s = sessions[src]
    if not s or s.leit then return cb({ ok = false, msg = 'Nicht angemeldet.' }) end

    if s.talk then
        s.talk = false
        pushList()
        return cb({ ok = true, talk = false, msg = 'Sprechwunsch zurückgezogen.' })
    end

    if operatorCount == 0 then
        return cb({ ok = false, msg = 'Die Leitstelle ist nicht besetzt.' })
    end

    local now = os.time()
    if now - s.lastTalk < Config.Leitstelle.talkCooldown then
        return cb({ ok = false, msg = 'Bitte kurz warten, bevor du erneut einen Sprechwunsch sendest.' })
    end

    s.talk, s.lastTalk = true, now
    for op in pairs(operators) do
        notifyPlayer(op, ('~y~Sprechwunsch von Nr. %s (%s)'):format(s.userId, s.userName))
    end
    addLog(s.userName, 'Sprechwunsch', s.route and ('Linie %s / Kurs %s'):format(s.route.lineNo, s.route.courseNo) or 'ohne Route')
    pushList()
    cb({ ok = true, talk = true, msg = 'Sprechwunsch an die Leitstelle gesendet.' })
end)

-- Leitstelle: Sprechwunsch annehmen
RegisterNetEvent('bus:server:leitAccept', function(target)
    local src = source
    target = tonumber(target)
    if not operators[src] or not target then return end
    local ds = sessions[target]
    if not ds or not ds.talk then return end

    ds.talk = false
    notifyPlayer(target, '~g~Die Leitstelle hat deinen Sprechwunsch angenommen.')
    notifyPlayer(src, ('~g~Sprechwunsch von Nr. %s angenommen.'):format(ds.userId))
    addLog(sessions[src] and sessions[src].userName or src, 'Sprechwunsch angenommen', ('Nr. %s (%s)'):format(ds.userId, ds.userName))
    pcall(Config.OnTalk, src, target)
    pushList()
end)

-- Leitstelle: Fahrer anrufen (Telefon-Symbol)
RegisterNetEvent('bus:server:leitCall', function(target)
    local src = source
    target = tonumber(target)
    if not operators[src] or not target then return end
    local ds = sessions[target]
    if not ds then return end

    ds.talk = false
    notifyPlayer(target, '~y~Die Leitstelle möchte dich sprechen.')
    notifyPlayer(src, ('~y~Rufe Nr. %s an...'):format(ds.userId))
    pcall(Config.OnTalk, src, target)
    pushList()
end)

-- Leitstelle: Panik als erledigt markieren
RegisterNetEvent('bus:server:leitClearPanic', function(target)
    local src = source
    target = tonumber(target)
    if not operators[src] or not target then return end
    local ds = sessions[target]
    if not ds then return end
    ds.panicUntil = 0
    addLog(sessions[src] and sessions[src].userName or src, 'Panik quittiert', ('Nr. %s (%s)'):format(ds.userId, ds.userName))
    pushList()
end)

-- ------------------------------------------------------------------------
-- Panik-Button
-- ------------------------------------------------------------------------
local panicJobs = {}
for _, j in ipairs(Config.Panic.jobs) do panicJobs[j] = true end

RegisterNetEvent('bus:server:panic', function(street)
    local src = source
    local s = sessions[src]
    if not Config.Panic.enabled or not s or (s.leit and not s.route) then return end

    local now = os.time()
    local wait = Config.Panic.cooldown - (now - s.lastPanic)
    if wait > 0 then
        return notifyPlayer(src, ('~r~Panik-Alarm gesperrt. Bitte warte noch %s Sekunden.'):format(wait))
    end
    s.lastPanic, s.panicUntil = now, now + Config.Panic.duration

    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    local plate = veh ~= 0 and (GetVehicleNumberPlateText(veh) or '') or ''
    street = type(street) == 'string' and street:gsub('~', ''):sub(1, 60) or ''

    local data = {
        source = src, driver = s.userName, nr = s.userId,
        line = s.route and s.route.lineNo or 0, course = s.route and s.route.courseNo or 0,
        coords = { x = coords.x, y = coords.y, z = coords.z },
        street = street, plate = plate, duration = Config.Panic.duration
    }

    local sent = 0
    for _, id in ipairs(ESX.GetPlayers()) do
        local xp = ESX.GetPlayerFromId(id)
        if xp and id ~= src and panicJobs[xp.getJob().name] then
            TriggerClientEvent('bus:client:panic', id, data)
            sent = sent + 1
        end
    end

    notifyPlayer(src, '~r~PANIK-ALARM ausgelöst! ~s~Bus-Job und Polizei wurden informiert.')
    TriggerClientEvent('bus:client:panicSelf', src)
    addLog(s.userName, 'PANIK ausgelöst', ('%s%s – %s Empfänger'):format(
        s.route and ('Linie %s / Kurs %s – '):format(s.route.lineNo, s.route.courseNo) or '',
        street ~= '' and street or 'unbekannter Ort', sent))
    pcall(Config.OnPanic, { source = src, driver = s.userName, line = data.line, course = data.course,
        coords = coords, street = street, plate = plate })
    pushList()
end)

-- ========================================================================
-- Verwaltung: Command
-- ========================================================================
RegisterCommand(Config.ManagementCommand, function(src)
    if src == 0 then return end
    local xPlayer = ESX.GetPlayerFromId(src)
    if not hasAccess(xPlayer) then
        xPlayer.showNotification('~r~Du hast keinen Zugriff auf die Busjob-Verwaltung.')
        return
    end
    TriggerClientEvent('bus:client:openAdmin', src, isAdmin(xPlayer))
end, false)

-- ========================================================================
-- Verwaltung: Userverwaltung
-- ========================================================================
ESX.RegisterServerCallback('bus:admin:getUsers', function(src, cb)
    if not guard(src) then return cb({}) end
    cb(MySQL.query.await([[
        SELECT id, name, created_by, DATE_FORMAT(created_at, '%d.%m.%Y %H:%i') AS created
        FROM bus_users ORDER BY name ASC
    ]]) or {})
end)

ESX.RegisterServerCallback('bus:admin:saveUser', function(src, cb, d)
    local xPlayer = guard(src)
    if not xPlayer then return cb({ ok = false, msg = 'Keine Berechtigung.' }) end
    if type(d) ~= 'table' then return cb({ ok = false, msg = 'Ungültige Daten.' }) end

    local name = clean(d.name, 32)
    if not name or #name < 3 then return cb({ ok = false, msg = 'Der Name muss 3–32 Zeichen lang sein.' }) end

    local pw = type(d.password) == 'string' and d.password or ''
    local id = tonumber(d.id)

    if id then
        -- Bearbeiten
        local old = MySQL.single.await('SELECT name FROM bus_users WHERE id = ?', { id })
        if not old then return cb({ ok = false, msg = 'Benutzer nicht gefunden.' }) end
        if MySQL.scalar.await('SELECT id FROM bus_users WHERE name = ? AND id <> ?', { name, id }) then
            return cb({ ok = false, msg = 'Dieser Name ist bereits vergeben.' })
        end
        if pw ~= '' then
            if #pw < 4 or #pw > 64 then return cb({ ok = false, msg = 'Das Passwort muss 4–64 Zeichen lang sein.' }) end
            MySQL.update.await('UPDATE bus_users SET name = ?, password = SHA2(?, 256) WHERE id = ?', { name, pw, id })
        else
            MySQL.update.await('UPDATE bus_users SET name = ? WHERE id = ?', { name, id })
        end
        kickUser(old.name, 'Zugangsdaten wurden geändert.')
        addLog(actorOf(xPlayer), 'User bearbeitet',
            ('%s -> %s%s'):format(old.name, name, pw ~= '' and ' (Passwort geändert)' or ''))
        return cb({ ok = true })
    end

    -- Erstellen
    if #pw < 4 or #pw > 64 then return cb({ ok = false, msg = 'Das Passwort muss 4–64 Zeichen lang sein.' }) end
    if MySQL.scalar.await('SELECT id FROM bus_users WHERE name = ?', { name }) then
        return cb({ ok = false, msg = 'Dieser Name ist bereits vergeben.' })
    end
    MySQL.insert.await('INSERT INTO bus_users (name, password, created_by) VALUES (?, SHA2(?, 256), ?)',
        { name, pw, xPlayer.getName() })
    addLog(actorOf(xPlayer), 'User erstellt', name)
    cb({ ok = true })
end)

ESX.RegisterServerCallback('bus:admin:deleteUser', function(src, cb, d)
    local xPlayer = guard(src)
    if not xPlayer then return cb({ ok = false, msg = 'Keine Berechtigung.' }) end
    local id = type(d) == 'table' and tonumber(d.id)
    if not id then return cb({ ok = false, msg = 'Ungültige Daten.' }) end

    local user = MySQL.single.await('SELECT name FROM bus_users WHERE id = ?', { id })
    if not user then return cb({ ok = false, msg = 'Benutzer nicht gefunden.' }) end

    MySQL.update.await('DELETE FROM bus_users WHERE id = ?', { id })
    kickUser(user.name, 'Dein Zugang wurde gelöscht.')
    addLog(actorOf(xPlayer), 'User gelöscht', user.name)
    cb({ ok = true })
end)

-- ========================================================================
-- Verwaltung: Aktionslog
-- ========================================================================
ESX.RegisterServerCallback('bus:admin:getLogs', function(src, cb)
    if not guard(src) then return cb({}) end
    cb(MySQL.query.await([[
        SELECT id, actor, action, details, DATE_FORMAT(created_at, '%d.%m.%Y %H:%i:%s') AS time
        FROM bus_logs ORDER BY id DESC LIMIT ?
    ]], { Config.MaxLogs }) or {})
end)

-- ========================================================================
-- Verwaltung: Routen (nur Admin)
-- ========================================================================
ESX.RegisterServerCallback('bus:admin:getRoutes', function(src, cb)
    if not guard(src, true) then return cb({}) end
    local rows = MySQL.query.await(
        ('SELECT %s FROM bus_routes ORDER BY line_no ASC, course_no ASC'):format(ROUTE_COLUMNS)) or {}
    for _, r in ipairs(rows) do
        r.stops  = json.decode(r.stops) or {}
        r.line   = r.lineNo
        r.course = r.courseNo
    end
    cb(rows)
end)

ESX.RegisterServerCallback('bus:admin:saveRoute', function(src, cb, d)
    local xPlayer = guard(src, true)
    if not xPlayer then return cb({ ok = false, msg = 'Keine Berechtigung.' }) end
    if type(d) ~= 'table' then return cb({ ok = false, msg = 'Ungültige Daten.' }) end

    local name = clean(d.name, 64)
    if not name then return cb({ ok = false, msg = 'Bitte einen Routennamen angeben.' }) end

    local line, course = math.floor(tonumber(d.line) or 0), math.floor(tonumber(d.course) or 0)
    if line < 1 or line > 9999 then return cb({ ok = false, msg = 'Die Linie muss zwischen 1 und 9999 liegen.' }) end
    if course < 1 or course > 999 then return cb({ ok = false, msg = 'Der Kurs muss zwischen 1 und 999 liegen.' }) end

    local pay = math.floor(tonumber(d.pay) or Config.DefaultPay)
    if pay < 0 or pay > Config.MaxPay then
        return cb({ ok = false, msg = ('Bezahlung muss zwischen 0 und %s liegen.'):format(Config.MaxPay) })
    end

    if type(d.stops) ~= 'table' or #d.stops < 2 or #d.stops > 50 then
        return cb({ ok = false, msg = 'Eine Route braucht 2–50 Haltestellen.' })
    end

    local stops = {}
    for i, s in ipairs(d.stops) do
        if type(s) ~= 'table' then return cb({ ok = false, msg = 'Ungültige Haltestelle.' }) end
        local x, y, z = tonumber(s.x), tonumber(s.y), tonumber(s.z)
        if not (x and y and z) then return cb({ ok = false, msg = 'Ungültige Koordinaten.' }) end
        -- "~" würde im GTA-Text als Formatierungscode interpretiert
        local sname = clean(s.name, 50)
        stops[i] = { name = sname and sname:gsub('~', '') or ('Haltestelle ' .. i), x = x, y = y, z = z }
    end

    local id = tonumber(d.id)

    if MySQL.scalar.await('SELECT id FROM bus_routes WHERE line_no = ? AND course_no = ? AND id <> ?',
        { line, course, id or 0 }) then
        return cb({ ok = false, msg = ('Linie %s / Kurs %s existiert bereits.'):format(line, course) })
    end

    local encoded = json.encode(stops)
    if id then
        if not MySQL.scalar.await('SELECT id FROM bus_routes WHERE id = ?', { id }) then
            return cb({ ok = false, msg = 'Route nicht gefunden.' })
        end
        MySQL.update.await('UPDATE bus_routes SET name = ?, line_no = ?, course_no = ?, pay = ?, stops = ? WHERE id = ?',
            { name, line, course, pay, encoded, id })
        kickRoute(id, 'Die Route wurde bearbeitet.')
        addLog(actorOf(xPlayer), 'Route bearbeitet',
            ('%s (Linie %s / Kurs %s, %s Haltestellen, %s$)'):format(name, line, course, #stops, pay))
    else
        MySQL.insert.await('INSERT INTO bus_routes (name, line_no, course_no, pay, stops) VALUES (?, ?, ?, ?, ?)',
            { name, line, course, pay, encoded })
        addLog(actorOf(xPlayer), 'Route erstellt',
            ('%s (Linie %s / Kurs %s, %s Haltestellen, %s$)'):format(name, line, course, #stops, pay))
    end
    cb({ ok = true })
end)

ESX.RegisterServerCallback('bus:admin:deleteRoute', function(src, cb, d)
    local xPlayer = guard(src, true)
    if not xPlayer then return cb({ ok = false, msg = 'Keine Berechtigung.' }) end
    local id = type(d) == 'table' and tonumber(d.id)
    if not id then return cb({ ok = false, msg = 'Ungültige Daten.' }) end

    local route = MySQL.single.await('SELECT name, line_no, course_no FROM bus_routes WHERE id = ?', { id })
    if not route then return cb({ ok = false, msg = 'Route nicht gefunden.' }) end

    MySQL.update.await('DELETE FROM bus_routes WHERE id = ?', { id })
    kickRoute(id, 'Die Route wurde gelöscht.')
    addLog(actorOf(xPlayer), 'Route gelöscht',
        ('%s (Linie %s / Kurs %s)'):format(route.name, route.line_no, route.course_no))
    cb({ ok = true })
end)

-- ========================================================================
-- Verwaltung: Einstellungen (nur Admin) – Mindest-Rang der Leitstelle
-- ========================================================================
ESX.RegisterServerCallback('bus:admin:getSettings', function(src, cb)
    if not guard(src, true) then return cb({}) end
    local grades = {}
    local ok, jobs = pcall(function() return ESX.GetJobs() end)
    if ok and jobs and jobs[Config.ManagementJob] and jobs[Config.ManagementJob].grades then
        for k, g in pairs(jobs[Config.ManagementJob].grades) do
            grades[#grades + 1] = { grade = tonumber(g.grade or k) or 0, label = g.label or tostring(k) }
        end
        table.sort(grades, function(a, b) return a.grade < b.grade end)
    end
    cb({ leitGrade = leitMinGrade, job = Config.ManagementJob, grades = grades })
end)

ESX.RegisterServerCallback('bus:admin:saveSettings', function(src, cb, d)
    local xPlayer = guard(src, true)
    if not xPlayer then return cb({ ok = false, msg = 'Keine Berechtigung.' }) end
    local grade = type(d) == 'table' and tonumber(d.leitGrade)
    if not grade or grade < 0 or grade > 99 then return cb({ ok = false, msg = 'Ungültiger Rang.' }) end
    grade = math.floor(grade)

    leitMinGrade = grade
    MySQL.update.await([[
        INSERT INTO bus_settings (skey, svalue) VALUES ('leit_min_grade', ?)
        ON DUPLICATE KEY UPDATE svalue = VALUES(svalue)
    ]], { tostring(grade) })

    -- Wer den neuen Rang nicht mehr hat, verliert seinen Platz
    for op in pairs(operators) do
        if not canOperate(ESX.GetPlayerFromId(op)) then
            releaseSeat(op)
            TriggerClientEvent('bus:client:leitKicked', op)
            notifyPlayer(op, '~r~Dein Rang reicht für die Leitstelle nicht mehr aus.')
        end
    end

    addLog(actorOf(xPlayer), 'Einstellung geändert', ('Leitstelle ab Rang %s (%s)'):format(grade, gradeLabel(grade)))
    cb({ ok = true })
end)
