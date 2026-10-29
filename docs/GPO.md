# Gruppenrichtlinien [G]

Das Menü **[G]** legt einfache Gruppenrichtlinien (GPOs) an, ordnet Netzlaufwerke zu und
setzt Standard-Richtlinien. Es ist Teil von `AD-Schnellanlage.ps1` (eine Datei).

Voraussetzungen: Active Directory und das Modul `GroupPolicy` (Windows-Feature **GPMC**,
auf einem Domänencontroller meist schon da). Fehlt es, bietet **[G][7]** die Installation
an – offline mit `-Source D:\sources\sxs` vom Server-ISO.

| Taste | Funktion |
|-------|----------|
| 1 | GPO erstellen (`New-GPO`), optional gleich mit einer OU verknüpfen |
| 2 | Netzlaufwerk zuordnen (Benutzerkonfiguration > Einstellungen > Laufwerkszuordnungen) |
| 3 | Standard-Richtlinie anwenden (`Set-GPRegistryValue`) |
| 4 | GPO mit OU verknüpfen (`New-GPLink`, Link aktiviert) |
| 5 | Vorhandene GPOs anzeigen (Status, Änderung, Verknüpfungen) |
| 6 | GPO entfernen (`Remove-GPO`, Bestätigung mit `JA`) |
| 7 | Gruppenrichtlinienverwaltung (GPMC) installieren – nur sichtbar, wenn das Modul fehlt |

Alles ist **idempotent**: Eine GPO mit gleichem Namen wird wiederverwendet, ein bestehender
Link nicht doppelt angelegt (ein deaktivierter wird aktiviert), ein Laufwerk mit gleichem
Buchstaben nie doppelt eingetragen, ein schon gesetzter Registry-Wert als `VORHANDEN`
gemeldet. Vor jeder Änderung kommt eine Vorschau mit Bestätigung, alles landet im
CSV-Protokoll (Typen `GPO`, `GPO-Link`, `GPO-Laufwerk`, `GPO-Wert`, `GPO-Rolle`,
`Freigabe`, `Ordner`, `NTFS`).

## Ablauf: Netzlaufwerk H: für eine OU

1. **[G][2]** → `(neue GPO anlegen)` → Name `[Netzlaufwerke]` mit Enter übernehmen.
2. Laufwerksbuchstabe `[H]` (D bis Z, `h`, `H` oder `H:`), UNC-Pfad `\\server\freigabe`,
   Bezeichnung (Vorschlag: Name der Freigabe), Aktion `[2] Aktualisieren`.
3. Optional **Zielgruppenadressierung**: nur Mitglieder einer Sicherheitsgruppe bekommen
   das Laufwerk (Item-Level-Targeting).
4. Ist der Pfad nicht erreichbar (`Test-Path`) und liegt die Freigabe auf diesem Server,
   bietet das Script an, Ordner und Freigabe anzulegen: Freigaberecht *Ändern* für die
   Gruppe (ohne Gruppe: Authentifizierte Benutzer), *Vollzugriff* für Administratoren,
   NTFS *Ändern* für die Gruppe.
5. Weitere Laufwerke in dieselbe GPO sind möglich (eine bestehende `Drives.xml` wird
   erweitert, nicht überschrieben).
6. Vorschau bestätigen → `Drives.xml` wird geschrieben, die Erweiterung eingetragen und die
   Benutzerversion erhöht.
7. Ist die GPO noch nirgends verknüpft, fragt das Script nach der OU.
8. Zum Schluss: kurzer Bericht aus `Get-GPOReport` (Version AD/SYSVOL, Laufwerke,
   Verknüpfungen) und auf Wunsch `Invoke-GPUpdate` für einen Client. Sonst am Client
   `gpupdate /force`, danach ab- und wieder anmelden.

Ein zweiter Lauf mit denselben Angaben meldet `VORHANDEN` und schreibt nichts.

## Wie die Laufwerkszuordnung geschrieben wird

Das Modul `GroupPolicy` kann keine Group Policy Preferences. Das Script macht deshalb das,
was die GPMC beim Speichern einer Laufwerkszuordnung tut:

**1. Datei** `\\<PDC-Emulator>\SYSVOL\<Domäne>\Policies\{GPO-GUID}\User\Preferences\Drives\Drives.xml`

Geschrieben wird auf den PDC-Emulator, weil auch `New-GPO` und `Set-GPRegistryValue` dort
arbeiten – so passen AD-Objekt und SYSVOL sofort zusammen. Die DFS-Replikation verteilt die
Datei an die anderen DCs (`\\<Domäne>\SYSVOL\...` zeigt danach dasselbe).

```xml
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}"><Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="H:" status="H:" image="2" changed="2026-10-29 12:00:00" uid="{…neue GUID…}"><Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\server\freigabe" label="Daten" persistent="0" useLetter="1" letter="H"/><Filters><FilterGroup bool="AND" not="0" name="FIRMA\GG_Vertrieb" sid="S-1-5-21-…" userContext="1" primaryGroup="0" localGroup="0"/></Filters></Drive></Drives>
```

| Feld | Bedeutung |
|------|-----------|
| `Drives clsid` | `{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}` – Sammlung Laufwerkszuordnungen |
| `Drive clsid` | `{935D1B74-9CB8-4e3c-9914-7DD559B7A417}` – ein Laufwerk |
| `action` / `image` | `C`/0 Erstellen, `R`/1 Ersetzen, `U`/2 Aktualisieren (Standard) |
| `uid` | eigene GUID je Laufwerk; bleibt beim Ersetzen eines Eintrags erhalten |
| `persistent` | `0` = „Verbindung wiederherstellen“ aus (die GPO verbindet bei jeder Anmeldung) |
| `Filters/FilterGroup` | nur bei Zielgruppe: Name `DOMÄNE\Gruppe` und SID |

**2. AD-Objekt der GPO** (`CN={GUID},CN=Policies,CN=System,DC=…`), Attribut
`gPCUserExtensionNames` – ergänzt um

```
[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]
```

`{5794DAFD-…}` ist die Client-Erweiterung „Drive Maps“, `{2EA1A81B-…}` das zugehörige
GPMC-Werkzeug, `{00000000-…}` der Sammeleintrag aller Preferences-Werkzeuge. Vorhandene
Einträge (z. B. Registry `{35378EAC-683F-11D2-A89A-00C04FBBCFA2}` von den
Standard-Richtlinien) bleiben erhalten; alles wird nach GUID sortiert, Tool-GUIDs
innerhalb eines Eintrags ebenfalls.

**3. Version** – die Clients laden eine GPO nur neu, wenn die Version steigt.
`versionNumber` im AD: obere 16 Bit = Benutzerversion, untere 16 Bit = Computerversion. Das
Script erhöht die Benutzerversion um 1 (Computerversion bleibt) und schreibt **dieselbe
Zahl** in `GPT.ini` (`Version=`) im SYSVOL-Ordner der GPO.

### Abgleich mit einer GPMC-GPO (vor dem ersten Einsatz)

Die Werte oben entsprechen dem, was die GPMC unter Windows Server 2016–2025 schreibt.
Auf dem Zielserver einmal gegenprüfen:

1. In der GPMC eine Test-GPO anlegen, unter *Benutzerkonfiguration > Einstellungen >
   Windows-Einstellungen > Laufwerkszuordnungen* das Laufwerk `H:` → `\\server\freigabe`
   (Aktualisieren) anlegen, optional mit Zielgruppenadressierung „Sicherheitsgruppe“.
2. Mit **[G][2]** eine zweite GPO mit denselben Angaben anlegen.
3. Beide `Drives.xml` vergleichen (bis auf `uid`, `changed` und Reihenfolge der Attribute
   gleich):
   ```powershell
   Get-Content "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies\{GUID}\User\Preferences\Drives\Drives.xml"
   ```
4. Beide AD-Objekte vergleichen:
   ```powershell
   Get-ADObject "CN={GUID},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)" -Properties gPCUserExtensionNames, versionNumber
   ```
5. In der GPMC → Einstellungen der Script-GPO: das Laufwerk muss unter
   *Laufwerkszuordnungen* erscheinen.

Weicht etwas ab, das Ergebnis hier festhalten und als Issue melden.

## Standard-Richtlinien [G][3]

Mehrfachauswahl, Werte werden mit `Set-GPRegistryValue` in die gewählte (oder neue) GPO
geschrieben. Eingebaut:

| Name | Wirkung | Registry (Benutzerkonfiguration) |
|------|---------|-----------------------------------|
| Systemsteuerung | Systemsteuerung und PC-Einstellungen sperren | `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` `NoControlPanel` = 1 |
| Desktophintergrund | Bild festlegen (Pfad wird gefragt, Stil „Ausfüllen“) | `…\Policies\System` `Wallpaper` = Pfad, `WallpaperStyle` = 4 |
| Eingabeaufforderung | cmd sperren, Anmeldescripts laufen weiter | `HKCU\Software\Policies\Microsoft\Windows\System` `DisableCMD` = 2 |
| USB-Speicher | alle Wechselmedien sperren | `HKCU\Software\Policies\Microsoft\Windows\RemovableStorageDevices` `Deny_All` = 1 |
| Bildschirmsperre | nach X Minuten (gefragt, Standard 10) mit Kennwort | `HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop` `ScreenSaveActive`, `ScreenSaverIsSecure` = 1, `ScreenSaveTimeOut` = Sekunden, `SCRNSAVE.EXE` = scrnsave.scr |

Alle fünf sind Benutzereinstellungen und wirken, wenn die GPO mit der OU der **Benutzer**
verknüpft ist. Vorlagen mit `HKLM\` (Computerkonfiguration) wirken nur auf Computerkonten
in der verknüpften OU – das Script weist darauf hin.

### Eigene Vorlagen

`GPO-Richtlinien.json` neben das Script legen (Beispiel:
[`config/GPO-Richtlinien.example.json`](../config/GPO-Richtlinien.example.json)). Jede
Vorlage hat `Name`, `Text`, optional `Hinweis`, optional `Eingabe`
(`Frage`, `Art` = `Zahl`/`Pfad`/`Text`, `Standard`, bei Zahl `Min`, `Max`, `Faktor`) und
eine Liste `Werte` (`Schluessel`, `Name`, `Typ` = `String`/`ExpandString`/`DWord`/`QWord`/`MultiString`,
`Wert`). `{eingabe}` im Wert wird durch die Antwort ersetzt (bei `Zahl` mal `Faktor`).
Gleicher `Name` ersetzt eine eingebaute Vorlage. Fehlerhafte Einträge werden mit Grund
gemeldet und übersprungen.

## Rückgängig [8]

GPOs, Links und Einstellungen werden von **[8]** nicht automatisch zurückgebaut, sondern nur
aufgelistet – eine GPO entfernt man gezielt mit **[G][6]** (löscht auch ihre Verknüpfungen).
Eine vom Script angelegte Freigabe entfernt **[8]** wie gewohnt.
