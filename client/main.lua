local isOpen      = false
local session     = nil     -- { user, route = {...} | nil, nextStop = n, current = n }
local stopBlip    = nil
local leaveTimer  = nil
local waiting     = false
local leitActive  = false   -- Leitstelle besetzt (von mir)
local leitMouse   = false   -- Maus für die Leitstelle aktiv (Numpad 0)
local panicBlips  = {}
local toggleLeitMouse   -- weiter unten definiert

local allowedModels = {}
for _, m in ipairs(Config.Buses) do allowedModels[joaat(m)] = true end

-- ========================================================================
-- Helfer
-- ========================================================================
local function notify(msg)
    ESX.ShowNotification(msg)
end

local function getBus()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 and allowedModels[GetEntityModel(veh)] then return veh end
    return nil
end

local function isDriver(veh)
    return veh and GetPedInVehicleSeat(veh, -1) == PlayerPedId()
end

local function removeBlip()
    if stopBlip and DoesBlipExist(stopBlip) then RemoveBlip(stopBlip) end
    stopBlip = nil
end

local function setStopBlip(stop)
    removeBlip()
    stopBlip = AddBlipForCoord(stop.x, stop.y, stop.z)
    SetBlipSprite(stopBlip, Config.Blip.sprite)
    SetBlipColour(stopBlip, Config.Blip.colour)
    SetBlipScale(stopBlip, Config.Blip.scale)
    SetBlipRoute(stopBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Bushaltestelle: ' .. (stop.name or ''))
    EndTextCommandSetBlipName(stopBlip)
end

local function closeUI()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })
end

-- Haltestellen-Liste oben links (HUD)
local function sendHud()
    if Config.ShowStopHud and session and session.route then
        local names = {}
        for i, s in ipairs(session.route.stops) do names[i] = s.name end
        SendNUIMessage({
            action  = 'hud',
            show    = true,
            line    = session.route.line,
            course  = session.route.course,
            name    = session.route.name,
            stops   = names,
            current = session.current,
            next    = session.nextStop
        })
    else
        SendNUIMessage({ action = 'hud', show = false })
    end
end

local function setLeitUI(active)
    leitActive = active
    if not active and leitMouse then
        leitMouse = false
        if not isOpen then SetNuiFocus(false, false) end
        SetNuiFocusKeepInput(false)
    end
    SendNUIMessage({ action = 'leit', active = active })
end

local function endSessionClient(msg)
    setLeitUI(false)
    session = nil
    waiting = false
    leaveTimer = nil
    removeBlip()
    sendHud()
    if msg then notify(msg) end
    if isOpen then
        ESX.TriggerServerCallback('bus:getState', function(state)
            SendNUIMessage({ action = 'state', state = state })
        end)
    end
end

-- ========================================================================
-- Terminal (F3)
-- ========================================================================
local function openTablet()
    if isOpen then return closeUI() end

    local veh = getBus()
    if not Config.Leitstelle.allowOutsideBus then
        if not veh then
            return notify('~r~Du musst in einem Bus sitzen.')
        end
        if not isDriver(veh) then
            return notify('~r~Du musst auf dem Fahrersitz sitzen.')
        end
    elseif veh and not isDriver(veh) then
        return notify('~r~Du musst auf dem Fahrersitz sitzen.')
    end

    ESX.TriggerServerCallback('bus:getState', function(state)
        isOpen = true
        if leitMouse then
            leitMouse = false
            SetNuiFocusKeepInput(false)
        end
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', mode = 'driver', state = state })
    end)
end

RegisterCommand('+bustablet', openTablet, false)
RegisterCommand('-bustablet', function() end, false)
RegisterKeyMapping('+bustablet', 'Bus-Terminal öffnen', 'keyboard', Config.OpenKey)

-- ========================================================================
-- Verwaltung (/busjobverwaltung)
-- ========================================================================
RegisterNetEvent('bus:client:openAdmin', function(isAdmin)
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', mode = 'admin', isAdmin = isAdmin })
end)

-- ========================================================================
-- NUI Callbacks
-- ========================================================================
RegisterNUICallback('close', function(_, cb)
    if leitMouse and not isOpen then toggleLeitMouse() end   -- ESC beendet den Maus-Modus der Leitstelle
    closeUI()
    cb('ok')
end)

-- Schritt 1: Name + Passwort
RegisterNUICallback('login', function(data, cb)
    if not Config.Leitstelle.allowOutsideBus and not isDriver(getBus()) then
        return cb({ ok = false, msg = 'Du musst auf dem Fahrersitz eines Busses sitzen.' })
    end

    ESX.TriggerServerCallback('bus:login', function(res)
        if res.ok then
            session = { user = res.user, route = nil, nextStop = 1, current = 0 }
        end
        cb(res)
    end, data.name, data.password)
end)

-- Schritt 2: Linie / Kurs
RegisterNUICallback('selectRoute', function(data, cb)
    if not session then
        return cb({ ok = false, msg = 'Nicht angemeldet.' })
    end
    if not isDriver(getBus()) then
        return cb({ ok = false, msg = 'Setze dich auf den Fahrersitz eines Busses.' })
    end

    ESX.TriggerServerCallback('bus:selectRoute', function(res)
        if res.ok and session then
            waiting = false
            session.route    = res.route
            session.nextStop = res.route.nextStop
            session.current  = res.route.current
            setStopBlip(session.route.stops[session.nextStop])
            sendHud()
            notify(('~g~Linie ~w~%s~g~ / Kurs ~w~%s~g~ gewählt. Fahre zur ersten Haltestelle.'):format(
                res.route.line, res.route.course))
            CreateThread(function()
                Wait(400)
                closeUI()
            end)
        end
        cb(res)
    end, data.line, data.course)
end)

RegisterNUICallback('logout', function(_, cb)
    if session then
        TriggerServerEvent('bus:server:logout', 'Abgemeldet')
        endSessionClient('~y~Du hast dich abgemeldet.')
    end
    cb('ok')
end)

RegisterNUICallback('getState', function(_, cb)
    ESX.TriggerServerCallback('bus:getState', function(state) cb(state or {}) end)
end)

-- Panik-Button (Warnsymbol)
RegisterNUICallback('panic', function(_, cb)
    if not session then return cb({ ok = false, msg = 'Nicht angemeldet.' }) end
    local c = GetEntityCoords(PlayerPedId())
    local street = GetStreetNameFromHashKey((GetStreetNameAtCoord(c.x, c.y, c.z)))
    TriggerServerEvent('bus:server:panic', street)
    cb({ ok = true })
end)

-- Sprechwunsch (gelbes Telefon)
RegisterNUICallback('requestTalk', function(_, cb)
    ESX.TriggerServerCallback('bus:requestTalk', function(res)
        cb(res or { ok = false, msg = 'Fehler.' })
    end)
end)

-- Startseite: Leitstelle besetzen / verlassen
RegisterNUICallback('leitEnter', function(_, cb)
    ESX.TriggerServerCallback('bus:leitEnter', function(res)
        if res and res.ok then
            setLeitUI(true)
            notify('~g~Du hast die Leitstelle besetzt. ~s~Mit ~y~Numpad 0~s~ blendest du die Maus ein.')
            CreateThread(function() Wait(400) closeUI() end)
        end
        cb(res or { ok = false, msg = 'Fehler.' })
    end)
end)

RegisterNUICallback('leitLeave', function(_, cb)
    ESX.TriggerServerCallback('bus:leitLeave', function(res)
        setLeitUI(false)
        notify('~y~Du hast die Leitstelle verlassen.')
        cb(res or { ok = true })
    end)
end)

-- Leitstelle: Aktionen aus der Liste
RegisterNUICallback('leitAccept', function(data, cb)
    TriggerServerEvent('bus:server:leitAccept', data.src)
    cb('ok')
end)
RegisterNUICallback('leitCall', function(data, cb)
    TriggerServerEvent('bus:server:leitCall', data.src)
    cb('ok')
end)
RegisterNUICallback('leitClearPanic', function(data, cb)
    TriggerServerEvent('bus:server:leitClearPanic', data.src)
    cb('ok')
end)

RegisterNUICallback('getCoords', function(_, cb)
    local c = GetEntityCoords(PlayerPedId())
    local street = GetStreetNameFromHashKey((GetStreetNameAtCoord(c.x, c.y, c.z)))
    cb({
        x = math.floor(c.x * 100) / 100,
        y = math.floor(c.y * 100) / 100,
        z = math.floor(c.z * 100) / 100,
        street = street or ''
    })
end)

-- Admin: Server-Callbacks durchreichen
local adminCallbacks = {
    { 'adminUsers',       'bus:admin:getUsers'   },
    { 'adminSaveUser',    'bus:admin:saveUser'   },
    { 'adminDeleteUser',  'bus:admin:deleteUser' },
    { 'adminLogs',        'bus:admin:getLogs'    },
    { 'adminRoutes',      'bus:admin:getRoutes'  },
    { 'adminSaveRoute',   'bus:admin:saveRoute'  },
    { 'adminDeleteRoute', 'bus:admin:deleteRoute'},
    { 'adminSettings',    'bus:admin:getSettings'},
    { 'adminSaveSettings','bus:admin:saveSettings'},
}

for _, entry in ipairs(adminCallbacks) do
    RegisterNUICallback(entry[1], function(data, cb)
        ESX.TriggerServerCallback(entry[2], function(res) cb(res) end, data)
    end)
end

-- ========================================================================
-- Server-Events
-- ========================================================================
RegisterNetEvent('bus:client:sessionEnded', function(msg)
    endSessionClient('~r~' .. (msg or 'Schicht beendet.'))
end)

RegisterNetEvent('bus:client:notify', function(msg)
    notify(msg)
end)

RegisterNetEvent('bus:client:leitList', function(list)
    if leitActive then SendNUIMessage({ action = 'leitList', list = list }) end
end)

RegisterNetEvent('bus:client:leitKicked', function()
    setLeitUI(false)
end)

-- Panik-Alarm (Bus-Job + Polizei)
local function addPanicBlip(data)
    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, Config.Panic.blip.sprite)
    SetBlipColour(blip, Config.Panic.blip.colour)
    SetBlipScale(blip, Config.Panic.blip.scale)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('PANIK Bus Nr. %s'):format(data.nr or '?'))
    EndTextCommandSetBlipName(blip)
    panicBlips[#panicBlips + 1] = blip

    SetTimeout((data.duration or 180) * 1000, function()
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end)
end

RegisterNetEvent('bus:client:panic', function(data)
    addPanicBlip(data)
    if Config.Panic.sound then
        PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
    end
    local where = (data.street and data.street ~= '') and data.street or 'unbekannter Ort'
    notify(('~r~PANIK-ALARM~s~ Bus Nr. ~y~%s~s~ (%s)%s\n~s~Ort: ~y~%s'):format(
        data.nr or '?', data.driver or '?',
        (data.line and data.line > 0) and (' Linie %s/%s'):format(data.line, data.course) or '', where))
end)

RegisterNetEvent('bus:client:panicSelf', function()
    PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
end)

RegisterNetEvent('bus:client:stopConfirmed', function(nextIdx, pay, finished, ended, current)
    if not session or not session.route then return end
    waiting = false
    PlaySoundFrontend(-1, 'PURCHASE', 'HUD_LIEUTENANT_SOUNDSET', true)

    if ended then
        notify(('~g~Route beendet! ~w~+%s$'):format(pay))
        endSessionClient()
        return
    end

    session.nextStop = nextIdx
    session.current  = current or session.current
    setStopBlip(session.route.stops[nextIdx])
    sendHud()

    if finished then
        notify(('~g~Runde abgeschlossen! ~w~+%s$ ~s~– die Route beginnt von vorn.'):format(pay))
    else
        notify(('~g~Haltestelle erreicht ~w~+%s$'):format(pay))
    end
end)

-- ========================================================================
-- Fahrbetrieb
-- ========================================================================
CreateThread(function()
    while true do
        local sleep = 1000

        if session and session.route then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            local inBus = veh ~= 0 and allowedModels[GetEntityModel(veh)] and GetPedInVehicleSeat(veh, -1) == ped

            if inBus then
                leaveTimer = nil
                local route = session.route
                local stop = route and route.stops[session.nextStop]
                if stop then
                    local pos = GetEntityCoords(ped)
                    local dist = #(pos - vector3(stop.x, stop.y, stop.z))

                    if dist < 120.0 then
                        sleep = 0
                        DrawMarker(1, stop.x, stop.y, stop.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            Config.StopRadius * 2.0, Config.StopRadius * 2.0, 1.5,
                            255, 200, 0, 140, false, false, 2, false, nil, nil, false)
                    end

                    if dist <= Config.StopRadius and not waiting then
                        if GetEntitySpeed(veh) <= Config.MaxSpeedAtStop then
                            waiting = true
                            local idx = session.nextStop
                            CreateThread(function()
                                local waited = 0
                                while waited < Config.StopWaitTime and session
                                    and session.route == route and session.nextStop == idx do
                                    local v = GetVehiclePedIsIn(PlayerPedId(), false)
                                    if v == 0 or GetEntitySpeed(v) > Config.MaxSpeedAtStop
                                        or #(GetEntityCoords(PlayerPedId()) - vector3(stop.x, stop.y, stop.z)) > Config.StopRadius then
                                        waiting = false
                                        notify('~r~Halt abgebrochen – bleib an der Haltestelle stehen.')
                                        return
                                    end
                                    ESX.ShowHelpNotification(('Fahrgäste steigen ein... (%ss)'):format(
                                        math.ceil((Config.StopWaitTime - waited) / 1000)))
                                    Wait(100)
                                    waited = waited + 100
                                end
                                if session and session.route == route and session.nextStop == idx then
                                    TriggerServerEvent('bus:server:stopReached', idx)
                                else
                                    waiting = false
                                end
                            end)
                        else
                            sleep = 0
                            ESX.ShowHelpNotification('Halte den Bus an, damit Fahrgäste einsteigen können.')
                        end
                    end
                end
            else
                -- Bus verlassen: Timer läuft
                sleep = 1000
                if not leaveTimer then
                    leaveTimer = GetGameTimer()
                    notify(('~y~Steige innerhalb von %s Sekunden wieder in den Bus, sonst endet deine Schicht.'):format(Config.LeaveBusTimeout))
                elseif (GetGameTimer() - leaveTimer) > (Config.LeaveBusTimeout * 1000) then
                    TriggerServerEvent('bus:server:logout', 'Bus verlassen')
                    endSessionClient('~r~Schicht beendet – du hast den Bus verlassen.')
                end
            end
        end

        Wait(sleep)
    end
end)

-- ========================================================================
-- 3D-Text am Nullpunkt des Busses: aktuelle + nächste Haltestelle
-- (Daten kommen per State Bag "busjob" vom Server -> für alle Spieler sichtbar)
-- ========================================================================
local nearBuses = {}

local function strip(text)
    return (tostring(text or '-'):gsub('~', ''))
end

local function drawBusText(veh, info)
    local o = Config.BusText.offset
    local pos = GetOffsetFromEntityInWorldCoords(veh, o.x, o.y, o.z)

    local lines = {
        { text = ('Linie %s  |  Kurs %s'):format(info.line or '-', info.course or '-'), r = 255, g = 200, b = 0 },
        { text = 'Aktuell: ' .. strip(info.current or 'Fahrtbeginn'),                   r = 255, g = 255, b = 255 },
        { text = 'Nächste: ' .. strip(info.next),                                       r = 120, g = 230, b = 150 },
    }

    SetDrawOrigin(pos.x, pos.y, pos.z, 0)

    local lineH = Config.BusText.scale * 0.075
    local boxH  = lineH * #lines + 0.006
    DrawRect(0.0, lineH * #lines * 0.5 - 0.0015, 0.19 * (Config.BusText.scale / 0.35), boxH, 8, 14, 24, 170)

    for i, l in ipairs(lines) do
        SetTextFont(4)
        SetTextProportional(true)
        SetTextScale(0.0, Config.BusText.scale)
        SetTextColour(l.r, l.g, l.b, 255)
        SetTextCentre(true)
        SetTextOutline()
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(l.text)
        EndTextCommandDisplayText(0.0, (i - 1) * lineH)
    end

    ClearDrawOrigin()
end

if Config.BusText.enabled then
    -- Busse in der Nähe einsammeln (selten, spart Performance)
    CreateThread(function()
        while true do
            local list = {}
            local pcoords = GetEntityCoords(PlayerPedId())
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if allowedModels[GetEntityModel(veh)] and NetworkGetEntityIsNetworked(veh) then
                    local info = Entity(veh).state.busjob
                    if info and #(GetEntityCoords(veh) - pcoords) <= Config.BusText.distance then
                        list[#list + 1] = { veh = veh, info = info }
                    end
                end
            end
            nearBuses = list
            Wait(500)
        end
    end)

    -- Zeichnen
    CreateThread(function()
        while true do
            if #nearBuses > 0 then
                for _, b in ipairs(nearBuses) do
                    if DoesEntityExist(b.veh) then drawBusText(b.veh, b.info) end
                end
                Wait(0)
            else
                Wait(250)
            end
        end
    end)
end

-- ========================================================================
-- Leitstelle: Maus per Numpad 0 ein-/ausblenden
-- ========================================================================
toggleLeitMouse = function()
    if not leitActive or isOpen then return end
    leitMouse = not leitMouse
    SetNuiFocus(leitMouse, leitMouse)
    SetNuiFocusKeepInput(leitMouse)
    SendNUIMessage({ action = 'leitMouse', on = leitMouse })
end

RegisterCommand('+busleitmouse', toggleLeitMouse, false)
RegisterCommand('-busleitmouse', function() end, false)
RegisterKeyMapping('+busleitmouse', 'Bus-Leitstelle: Maus ein/aus', 'keyboard', Config.Leitstelle.mouseKey)

-- Solange die Maus aktiv ist, Kamera/Angriff sperren (Bewegung bleibt möglich)
CreateThread(function()
    while true do
        if leitMouse then
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 106, true)
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- UI schließen, wenn der Spieler stirbt
CreateThread(function()
    while true do
        Wait(500)
        if isOpen and IsEntityDead(PlayerPedId()) then closeUI() end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeBlip()
    for _, b in ipairs(panicBlips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    if isOpen or leitMouse then SetNuiFocus(false, false) SetNuiFocusKeepInput(false) end
end)
