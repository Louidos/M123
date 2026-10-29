# Changelog

Alle wichtigen Änderungen an diesem Projekt stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

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
