Config = {}

-- ========================================================================
-- BUSSE: Spawnnamen der Fahrzeuge, mit denen man Bus fahren darf
-- ========================================================================
Config.Buses = {
    'bus',
    'coach',
    'airbus',
    'tourbus',
    'rentalbus',
}

-- ========================================================================
-- TERMINAL (IBIS)
-- ========================================================================
Config.OpenKey = 'F3'                 -- Standardtaste (Spieler kann sie in den FiveM-Tastenzuweisungen ändern)

-- ========================================================================
-- HALTESTELLEN-ANZEIGE OBEN LINKS (HUD)
-- ========================================================================
Config.ShowStopHud = true             -- Liste aller Haltestellen oben links während der Schicht
                                      -- (im Terminal mit der "H"-Taste ein-/ausblendbar)

-- ========================================================================
-- 3D-TEXT AM BUS (aktuelle + nächste Haltestelle)
-- ========================================================================
Config.BusText = {
    enabled  = true,
    offset   = vector3(0.0, 0.0, 0.0),  -- Versatz zum Nullpunkt (Ursprung) des Busses; z.B. z = 2.5 um den Text über das Dach zu setzen
    distance = 25.0,                    -- Sichtweite in Metern (für alle Spieler)
    scale    = 0.35
}

-- ========================================================================
-- VERWALTUNG (/busjobverwaltung)
-- ========================================================================
Config.ManagementCommand  = 'busjobverwaltung'
Config.ManagementJob      = 'busdriver'   -- Job, der die Verwaltung öffnen darf
Config.ManagementMinGrade = 3             -- ab diesem Rang (grade) hat man Zugriff

-- Gruppen, die zusätzlich die Kategorie "Routen" sehen und Routen erstellen dürfen
Config.AdminGroups = { 'admin', 'superadmin' }
-- true  = Admins dürfen den Command auch ohne den Job benutzen
-- false = Admins brauchen zusätzlich den Job + Rang
Config.AdminIgnoresJob = true

-- ========================================================================
-- FAHRBETRIEB
-- ========================================================================
Config.PayAccount       = 'money'   -- 'money' (Bargeld) oder 'bank'
Config.DefaultPay       = 150       -- Standard-Bezahlung pro Haltestelle
Config.MaxPay           = 1000      -- Höchstwert, der beim Routen-Erstellen eingetragen werden darf
Config.StopRadius       = 8.0       -- Radius der Haltestelle (Meter)
Config.MaxSpeedAtStop   = 3.0       -- maximale Geschwindigkeit (m/s), damit der Halt zählt
Config.StopWaitTime     = 5000      -- Wartezeit an der Haltestelle (ms)
Config.LeaveBusTimeout  = 30        -- Sekunden, die man den Bus verlassen darf, bevor die Schicht endet
Config.LoopRoute        = true      -- true = Route beginnt nach der letzten Haltestelle von vorn

-- ========================================================================
-- LOG
-- ========================================================================
Config.MaxLogs = 300                -- wie viele Log-Einträge im Tablet geladen werden

-- ========================================================================
-- BLIP der nächsten Haltestelle
-- ========================================================================
Config.Blip = {
    sprite = 513,
    colour = 5,
    scale  = 0.9
}

-- ========================================================================
-- PANIK-BUTTON (Warnsymbol im Fahrer-Terminal)
-- ========================================================================
Config.Panic = {
    enabled   = true,
    jobs      = { 'busdriver', 'police' },  -- diese Jobs bekommen den Alarm (Bus-Job + Polizei)
    cooldown  = 60,                          -- Sekunden Sperre nach einem Alarm (pro Fahrer)
    duration  = 180,                         -- Sekunden, die Blip + Markierung in der Leitstelle sichtbar bleiben
    blip      = { sprite = 161, colour = 1, scale = 1.2 },
    sound     = true
}

-- Optional: Hier kannst du ein Dispatch-System anbinden (ps-dispatch, cd_dispatch, ...).
-- data = { source, driver, line, course, coords = vector3, street, plate }
Config.OnPanic = function(data)
    -- Beispiel:
    -- exports['ps-dispatch']:...
end

-- ========================================================================
-- LEITSTELLE
-- ========================================================================
Config.Leitstelle = {
    seats            = 1,          -- wie viele Personen die Leitstelle gleichzeitig besetzen dürfen
    defaultMinGrade  = 3,          -- Start-Wert für den Mindest-Rang (später in /busjobverwaltung -> Einstellungen änderbar)
    allowOutsideBus  = true,       -- Terminal (F3) auch außerhalb eines Busses öffnen (Anmelden, Leitstelle besetzen)
    mouseKey         = 'NUMPAD0',  -- Maus ein-/ausblenden, um in der Leitstellen-Liste zu klicken
    refresh          = 2000,       -- Aktualisierung der Liste (ms)
    talkCooldown     = 10          -- Sekunden Sperre zwischen zwei Sprechwünschen
}

-- Optional: Sprachsystem anbinden (pma-voice, SaltyChat, ...)
-- Wird aufgerufen, wenn die Leitstelle einen Sprechwunsch annimmt oder den Fahrer anruft.
Config.OnTalk = function(operatorSrc, driverSrc)
    -- Beispiel (pma-voice Anruf): exports['pma-voice']:...
end
