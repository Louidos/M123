# Changelog

Alle wichtigen Änderungen an diesem Projekt stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

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
