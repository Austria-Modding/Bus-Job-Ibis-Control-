# BUSJOB – IBIS-Terminal

Abhängigkeiten: es_extended, oxmysql

## Installation
1. Ordner `busjob` in `resources` legen (alte Version ersetzen).
2. `ensure busjob` in die server.cfg (nach es_extended und oxmysql).
3. Tabellen werden automatisch erstellt bzw. migriert (alternativ `install.sql`).
   Bestehende Routen bekommen automatisch **Linie = Routen-ID, Kurs = 1** und können im Routeneditor angepasst werden.
4. `config.lua` anpassen: Busse, Job, Rang, Admin-Gruppen, HUD, 3D-Text.

## Ablauf für Fahrer
1. In einen Bus auf den Fahrersitz setzen und **F3** drücken -> IBIS-Terminal.
2. **Name + Passwort** eingeben, mit `>` bestätigen.
3. **Linie/Kurs** über das Tastenfeld eingeben (z.B. `61` `>` `1` `>`).
   Auch mit der Tastatur möglich (Ziffern, Backspace, Enter, Tab = Feld wechseln).
4. Das Terminal schließt sich, die erste Haltestelle wird markiert.

Seitentasten im Terminal: **X** = Abmelden, **H** = Haltestellen-Liste ein/aus, **Pfeil** = Schließen.
Bei aktiver Schicht zeigt F3 die Übersicht mit "Fahrplan wechseln" und "Abmelden".

## Anzeigen
- **Oben links (HUD):** alle Haltestellen der Route. Erledigte sind abgehakt, "Aktuell" grün, "Nächste" gelb.
- **3D-Text am Nullpunkt des Busses:** Linie/Kurs, aktuelle und nächste Haltestelle (für alle Spieler in der Nähe sichtbar).
  Position und Sichtweite: `Config.BusText` (z.B. `offset = vector3(0.0, 0.0, 2.5)` für Text über dem Dach).

## Verwaltung
- **/busjobverwaltung**: Userverwaltung + Aktionslog (Job + Rang aus der Config).
- Admin-Gruppe: zusätzlich Kategorie **Routen** (Name, **Linie**, **Kurs**, Bezahlung, Haltestellen per aktueller Position).
  Die Kombination Linie/Kurs muss eindeutig sein.

## Neu in 2.1: Startseite, Panik, Sprechwunsch, Leitstelle
- **Startseite** (nach der Anmeldung, auch ohne Bus möglich): `Route festlegen`, `Leitstelle besetzen`, `Abmelden`.
- **Panik** (rotes Warnsymbol im Terminal): Alarm mit Blip + Benachrichtigung an alle Jobs aus `Config.Panic.jobs`
  (Standard: `busdriver` + `police`). Cooldown/Dauer in der Config. Dispatch-Anbindung über `Config.OnPanic`.
- **Sprechwunsch** (gelbes Telefon-Symbol): wird der Leitstelle angezeigt, **nur wenn sie besetzt ist**. Erneut drücken = zurückziehen.
- **Leitstelle**: Liste aller angemeldeten Fahrer rechts am Bildschirm. **Numpad 0** blendet die Maus ein/aus,
  dann Klick auf `Sprechwunsch` (nimmt an, Fahrer bekommt eine Benachrichtigung), Telefon-Symbol (Fahrer anrufen), `Quittieren` (Panik).
- **Rang für die Leitstelle**: `/busjobverwaltung` -> **Einstellungen** (nur Admin). Start-Wert: `Config.Leitstelle.defaultMinGrade`.
- Sprachsystem anbinden: `Config.OnTalk(operatorSrc, driverSrc)`.
