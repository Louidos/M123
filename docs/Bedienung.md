# Bedienung

## Start und Rollen-Erkennung

Beim Start zeigt das Script:

```
  AD-Schnellanlage 2.0.0
  Active Directory: ja (firma.local)
  DNS-Server:       nein  (DNS - Rolle nicht installiert)
  Auswahlmodus:     Auswahlfenster (Out-GridView)
```

Geprüft wird: Lässt sich das Modul `ActiveDirectory` laden und ist die Domäne erreichbar?
Ist das Windows-Feature `DNS` installiert (über `ServerManager`), läuft der DNS-Dienst,
gibt es das Modul `DnsServer`? Gibt es `New-SmbShare` und `Out-GridView`? Laufen wir als
Administrator (sonst Hinweis)?

Menüpunkte, die auf diesem Server nicht gehen, erscheinen gesammelt unter
`Nicht verfügbar: [1] [2] … -> Grund`. Das Script bricht wegen einer fehlenden Rolle nie ab.
Mit `$Funktionen` abgeschaltete Punkte sind wie bisher ganz ausgeblendet.

## Grundregeln

- **Enter** übernimmt immer den Vorschlag in `[eckigen Klammern]`.
- **Ja/Nein-Fragen:** `[J/n]` = Standard Ja, `[j/N]` = Standard Nein.
- **Abbrechen:** leere Eingabe bei Pflichtnamen oder `0` in Auswahllisten springt zurück ins Menü.
- **Auswahl:** mit Out-GridView als Fenster (mehrere mit Strg/Shift), sonst in der Konsole
  mit Nummern, z. B. `1,3,5-7`.
- **Vorschau:** Vor jeder Änderung am Server wird alles angezeigt und muss bestätigt werden
  (abschaltbar mit `$Funktionen.Vorschau = $false`).
- Schon vorhandene Objekte werden nicht überschrieben, sondern als `VORHANDEN` gemeldet.

## Protokoll und Rückgängig

Jede Sitzung schreibt ein CSV-Protokoll nach `AD-Schnellanlage-Protokolle\AD-Anlage_<Datum>.csv`
neben dem Script (Spalten `Zeit;Typ;Name;Status;DN;Bezug;Info`).

GPOs, Links und GPO-Einstellungen aus **[G]** sowie DHCP-Bereiche und -Einstellungen aus
**[H]** werden nicht zurückgebaut, sondern nur aufgelistet – eine GPO entfernt man mit
[G][6] (siehe [GPO.md](GPO.md)), einen DHCP-Bereich mit [H][6] (siehe [DHCP.md](DHCP.md)).

[8] liest ein Protokoll und entfernt in dieser Reihenfolge: DNS-Einträge, DNS-Zonen (nur leere),
Mitgliedschaften, Freigaben, Benutzer, Gruppen, OUs (nur leere). Details zu DNS: [DNS.md](DNS.md). Ordner, NTFS-Rechte und Home-Ordner werden **nicht**
gelöscht, sondern nur aufgelistet.

Zufallspasswörter werden als `Passwoerter_<Datum>.csv` im selben Ordner gespeichert –
nach dem Verteilen löschen!

## Gruppenrichtlinien [G]

GPOs anlegen und verknüpfen, Netzlaufwerke (Group Policy Preferences) zuordnen und
Standard-Richtlinien setzen. Braucht AD, das Modul `GroupPolicy` (Feature GPMC, unter [G]
installierbar) und die Datei `Module\GPO.psm1` neben dem Script. Details: [GPO.md](GPO.md).

## DHCP [H]

DHCP in einem Durchlauf einrichten: Rolle, Sicherheitsgruppen, Autorisierung im AD,
Dienst-Neustart, Server-Manager-Hinweis, dann Bereiche mit Vorschlägen aus der aktiven
Netzwerkkarte und Prüfungen (Netz, Grenzen, Router/Server-IP ausschließen, keine
Überschneidung). Dazu Reservierungen, Übersicht und Laden aus einer Datei. Braucht die Datei
`Module\DHCP.psm1` neben dem Script; die Rolle installiert der Assistent. Details: [DHCP.md](DHCP.md).

## Subnetzrechner [S]

Reiner IPv4-Rechner, auch auf Servern ohne AD und ohne DNS-Rolle. Er ändert nichts am Server.

- Eingabe der Maske als `255.255.252.0`, `255.255.252` (fehlende Teile = 0), `/22` oder `22`,
  danach die IP-Adresse im Netz (Enter = `192.168.0.0`).
- Oder alles in einer Zeile: `192.168.10.37/26` bzw. `192.168.10.37 255.255.255.192`.
- Ausgabe: Maske, CIDR, Wildcard-Maske, Maske binär, Netz-/Host-Bits, Netz- und
  Broadcast-Adresse, erster/letzter Host, nutzbare Hosts, Adressen gesamt und Bereich.
  /31 (Punkt-zu-Punkt) und /32 (eine Adresse) werden als Sonderfälle angezeigt.
- Ungültige Eingaben werden gemeldet und neu gefragt, Enter geht zurück ins Hauptmenü.

Beispiel `192.168.10.37/26`: Netz `192.168.10.0`, Broadcast `192.168.10.63`,
Hosts `192.168.10.1` bis `192.168.10.62`, 62 nutzbare Hosts.

Abschaltbar unter [E] → Module ein/aus (`Funktionen.Subnetzrechner`).

## Namensregeln

Alle Werte lassen sich im Menü **[E]** ändern und dauerhaft speichern, siehe [Einstellungen.md](Einstellungen.md).

| Einstellung | Standard | Beispiel |
|-------------|----------|----------|
| `$PrefixGG` | `GG_` | `GG_Vertrieb` |
| `$PrefixDL` | `DL_` | `DL_Vertrieb_M` |
| `$BenutzernameMuster` | `{vorname}.{nachname}` | `max.muster` |
| `$EmailMuster` | `{anmeldename}@{domain}` | `max.muster@firma.local` |

Umlaute werden für Anmeldenamen ersetzt (`ä` → `ae`, `ß` → `ss`), Akzente entfernt.
