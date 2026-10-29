# Changelog

Alle wichtigen Änderungen an diesem Projekt stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

## 2.1.1 – 2026-10-29

### Geändert
- Das Script ist wieder **eine einzige Datei**: Gruppenrichtlinien [G] und DHCP [H] stecken direkt in `AD-Schnellanlage.ps1`, der Ordner `Module` entfällt. Zum Installieren genügt es, diese eine Datei auf den Server zu kopieren; Bedienung und Menüs bleiben gleich (#19).

## 2.1.0 – 2026-10-29

### Hinzugefügt
- Hauptmenü [G] Gruppenrichtlinien per Menü anlegen: Netzlaufwerke einbinden (z. B. `H:` → `\\server\freigabe`, optional nur für eine Gruppe, fehlende Freigabe auf diesem Server gleich mit anlegen) und einfache Standard-Richtlinien setzen (Systemsteuerung, Desktophintergrund, Eingabeaufforderung, USB-Speicher, Bildschirmsperre – über `GPO-Richtlinien.json` erweiterbar); GPOs erstellen, mit OUs verknüpfen, anzeigen und entfernen. Nichts wird doppelt angelegt, am Ende kurzer Bericht und optional `Invoke-GPUpdate` (#11).
- Hauptmenü [H] DHCP: Einrichtung als geführter Assistent mit AD-Autorisierung (Rolle, Sicherheitsgruppen, Dienst-Neustart, Hinweis im Server-Manager verschwindet), Prüfungen (Netz, Grenzen, Router und Server-IP automatisch ausschließen, keine überlappenden Bereiche), Reservierungen (MAC in jeder Schreibweise), Übersicht über Bereiche, Leases und Reservierungen und Vorschlägen aus der Netzwerkkarte; ganze Konfiguration auch aus einer Datei (`DHCP-Konfiguration.json`) (#12).
- DHCP trägt Clients automatisch ins DNS ein (inkl. Reverse-Zone und Dienstkonto): [H][8] stellt dynamische Updates auf „immer“, löscht Einträge bei Ablauf der Lease, trägt auch ältere Clients ein, legt fehlende Reverse-Zonen mit „nur sicheren“ Updates an und hinterlegt ein eigenes Dienstkonto (Passwort wird nie protokolliert); optional Alterung/Bereinigung. [H][9] prüft Einstellungen und ob jede Lease A- und PTR-Eintrag hat. Wird am Ende des DHCP-Assistenten angeboten (#13).

### Geändert
- Installation: neben `AD-Schnellanlage.ps1` gehört jetzt der Ordner `Module` (Teilmodule `GPO.psm1`, `DHCP.psm1`) – einfach den ganzen Inhalt von `src/` kopieren (#11, #12).
- Entwicklung: Die automatische Prüfung bei jedem Pull Request untersucht den Code zusätzlich mit PSScriptAnalyzer und prüft auch Teilmodule (`.psm1`, `.psd1`) auf Syntaxfehler und UTF-8 mit BOM (#10).

## 2.0.0 – 2026-10-29

### Hinzugefügt
- [D][6] PTR auffüllen: Fehlen Reverse-Zonen, fragt das Script, ob sie gleich angelegt werden sollen. Auswahl je Netz (Vorschlag /24, `(alle)` möglich, auf /16 oder /8 anpassbar); danach werden die PTR-Einträge für die neuen Zonen automatisch geplant und nach Bestätigung erstellt. Zonen und Einträge lassen sich mit Rückgängig entfernen.
- Hauptmenü [S] Subnetzrechner (IPv4): Maske als `255.255.252.0`, `255.255.252`, `/22` oder gleich mit IP (`192.168.10.37/26`); zeigt Maske, Wildcard, binär, Netz, Broadcast, erster/letzter Host, Anzahl Hosts und Bereich. Läuft ohne AD und DNS, unter [E] abschaltbar.

### Geändert
- Hauptmenü fortlaufend nummeriert: [3] Globale Gruppen, [4] Domänenlokale Gruppen, [5] AGDLP, [6] Abteilung, [7] Mitglieder, [8] Rückgängig.
- Ein veralteter Eintrag `Funktionen.CsvImport` in `Einstellungen.json` wird still ignoriert und fällt beim nächsten Speichern weg.

### Behoben
- [D][6] PTR auffüllen: PTR-Einträge zeigen immer auf den vollständigen Namen (`gc._msdcs.lutefisk.local.` statt `gc._msdcs.`), auch in der Liste „Keine passende Reverse-Zone“. Dienst-Namen wie `gc._msdcs` oder `_ldap._tcp` werden kein PTR-Ziel; IPs mit nur Dienst-Namen stehen separat. Die Namen aus allen gewählten Zonen werden gemeinsam sortiert (echte Hostnamen zuerst).
- [D][5] Automatischer PTR: Namen mit Punkt (z. B. `srv01.sub`) bekommen jetzt ebenfalls den vollständigen Namen.

### Entfernt
- CSV-Import für Benutzer (Menüpunkt [3]) und CSV-Vorlage ([V]) samt Schalter `Funktionen.CsvImport`. Benutzer anlegen geht weiter einzeln oder per Schnelleingabe unter [2]. CSV-Protokoll, Passwortliste und Rückgängig bleiben.

## 1.1.0 – 2026-10-29

### Geändert
- Das Script startet jetzt auch auf Servern ohne Active Directory und zeigt nur die Funktionen an, die dort möglich sind; beim Start stehen Version, erkannte Rollen und Auswahlmodus (#2).

### Hinzugefügt
- Menü [E] Einstellungen: Präfixe, Namensmuster, DNS-Standards und Module direkt im Script ändern und dauerhaft speichern (#4).
- DNS-Menü [D]: DNS-Rolle installieren, Forward- und Reverse-Zonen anlegen, A/AAAA/CNAME/MX-Einträge per Schnelleingabe mit automatischem PTR, fehlende PTR auffüllen, Weiterleitungen setzen, Namensauflösung testen; alles im Protokoll und rückgängig machbar (#3).
- Repo-Struktur (src, tests, docs, scripts), Syntax-Prüfung und automatische Tests bei jedem Pull Request.

## 1.0.0 – Ausgangsstand

### Hinzugefügt
- Konsolenmenü zum schnellen Anlegen von OUs, Benutzern (einzeln, Schnelleingabe, CSV), globalen und domänenlokalen Gruppen, AGDLP-Paketen und ganzen Abteilungen.
- Mitgliedschaften setzen, CSV-Protokoll jeder Sitzung und Rückgängig machen anhand des Protokolls.
