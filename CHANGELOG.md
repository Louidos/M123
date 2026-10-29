# Changelog

Alle wichtigen Änderungen an diesem Projekt stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

### Hinzugefügt
- [D][6] PTR auffüllen: Fehlen Reverse-Zonen, fragt das Script, ob sie gleich angelegt werden sollen. Auswahl je Netz (Vorschlag /24, `(alle)` möglich, auf /16 oder /8 anpassbar); danach werden die PTR-Einträge für die neuen Zonen automatisch geplant und nach Bestätigung erstellt. Zonen und Einträge lassen sich mit Rückgängig entfernen.

### Behoben
- [D][6] PTR auffüllen: PTR-Einträge zeigen immer auf den vollständigen Namen (`gc._msdcs.lutefisk.local.` statt `gc._msdcs.`), auch in der Liste „Keine passende Reverse-Zone“. Dienst-Namen wie `gc._msdcs` oder `_ldap._tcp` werden kein PTR-Ziel; IPs mit nur Dienst-Namen stehen separat. Die Namen aus allen gewählten Zonen werden gemeinsam sortiert (echte Hostnamen zuerst).
- [D][5] Automatischer PTR: Namen mit Punkt (z. B. `srv01.sub`) bekommen jetzt ebenfalls den vollständigen Namen.

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
