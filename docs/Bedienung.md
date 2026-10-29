# Bedienung

## Start und Rollen-Erkennung

Beim Start zeigt das Script:

```
  AD-Schnellanlage 1.0.0
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

[9] liest ein Protokoll und entfernt in dieser Reihenfolge: Mitgliedschaften, Freigaben,
Benutzer, Gruppen, OUs (nur leere). Ordner, NTFS-Rechte und Home-Ordner werden **nicht**
gelöscht, sondern nur aufgelistet.

Zufallspasswörter werden als `Passwoerter_<Datum>.csv` im selben Ordner gespeichert –
nach dem Verteilen löschen!

## CSV-Import

Spalten: `Vorname;Nachname;Anmeldename;Passwort;OU;Abteilung;Gruppen`
(Trennzeichen `;` oder `,`, UTF-8 oder ANSI). Pflicht sind nur Vorname und Nachname.
Mehrere Gruppen mit `|` trennen. Eine Vorlage erzeugt Menüpunkt [V].

## Namensregeln

| Einstellung | Standard | Beispiel |
|-------------|----------|----------|
| `$PrefixGG` | `GG_` | `GG_Vertrieb` |
| `$PrefixDL` | `DL_` | `DL_Vertrieb_M` |
| `$BenutzernameMuster` | `{vorname}.{nachname}` | `max.muster` |
| `$EmailMuster` | `{anmeldename}@{domain}` | `max.muster@firma.local` |

Umlaute werden für Anmeldenamen ersetzt (`ä` → `ae`, `ß` → `ss`), Akzente entfernt.
