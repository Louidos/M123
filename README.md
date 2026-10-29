# AD-Schnellanlage

Interaktives PowerShell-Script für Windows Server: OUs, Benutzer und Gruppen
(inkl. AGDLP, Ordnerrechte und Freigaben) in Sekunden anlegen – mit Vorschau,
CSV-Protokoll und Rückgängig-Funktion.

- **Eine Datei:** `src/AD-Schnellanlage.ps1`, direkt auf den Server kopierbar
- **Nur Bordmittel:** Windows PowerShell 5.1, Module `ActiveDirectory`, `DnsServer`, `ServerManager`, `SmbShare`, `DnsClient`, .NET, `Out-GridView` (falls vorhanden)
- **Offline:** kein Internet, kein `Install-Module`, keine externen Programme

## Installation

1. `src/AD-Schnellanlage.ps1` auf den Server kopieren (z. B. nach `C:\Scripts`).
2. Optional: Voreinstellungen im Menü **[E]** ändern und speichern (landet in `Einstellungen.json`
   neben dem Script, Beispiel: `config/Einstellungen.example.json`) – oder direkt im Block
   `KONFIGURATION` am Anfang des Scripts.

## Start

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AD-Schnellanlage.ps1
```

Das Script startet auf jedem Windows Server mit PowerShell 5.1. Beim Start prüft es,
was vorhanden ist (Active Directory, DNS-Rolle, SMB, Auswahlfenster, Adminrechte), und
zeigt Version, erkannte Rollen und Auswahlmodus an. Menüpunkte, die auf diesem Server
nicht laufen können, stehen unter „Nicht verfügbar“ mit Grund.

Für die AD-Punkte braucht es einen Domänencontroller oder das Windows-Feature
`RSAT-AD-PowerShell`. Enter übernimmt immer den Vorschlag in `[eckigen Klammern]`.

## Menü

| Taste | Funktion |
|-------|----------|
| 1 | OUs erstellen (auch verschachtelt: `Firma/Buchhaltung`) |
| 2 | Benutzer erstellen (einzeln oder Schnelleingabe in einer Zeile) |
| 3 | Globale Gruppen `GG_Name` |
| 4 | Domänenlokale Gruppen + Rechte `DL_Name_M` |
| 5 | AGDLP-Paket: GG + DL + Verschachtelung + Ordnerrechte |
| 6 | Abteilung komplett: OU + Unter-OUs + Gruppen + Ordner + Benutzer |
| 7 | Mitglieder zu Gruppen hinzufügen |
| 8 | Rückgängig machen anhand des Protokolls (AD und DNS) |
| D | DNS: Rolle installieren, Forward-/Reverse-Zonen, Einträge per Schnelleingabe mit automatischem PTR, fehlende PTR auffüllen (fehlende Reverse-Zonen gleich mit anlegen), Weiterleitungen, Namensauflösung testen |
| E | Einstellungen: Präfixe, Namensmuster, Benutzer-Standards, DNS und Module ändern und dauerhaft speichern |
| P | Protokoll der Sitzung anzeigen |

Ausführliche Bedienung: [docs/Bedienung.md](docs/Bedienung.md) · DNS: [docs/DNS.md](docs/DNS.md) · Einstellungen: [docs/Einstellungen.md](docs/Einstellungen.md)

## Entwicklung

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Run-Tests.ps1
```

Prüft alle Scripts auf Syntaxfehler (Windows PowerShell 5.1) und führt die
Pester-Tests in `tests/` aus (Pester 3.4 ist in Windows enthalten). Die CI macht
dasselbe bei jedem Pull Request auf `windows-latest`.

Ablauf: pro Änderung ein Branch vom aktuellen `main`, Conventional Commits auf
Deutsch, Eintrag in [CHANGELOG.md](CHANGELOG.md), Pull Request, Squash-Merge
bei grüner CI.

## Projektstand

Version **1.1.0** – DNS-Modul [D], Einstellungen [E], Start auch ohne Active Directory. Änderungen siehe [CHANGELOG.md](CHANGELOG.md).

## Lizenz

[MIT](LICENSE)
