# Einstellungen [E]

Im Hauptmenü öffnet **[E]** die Einstellungen. Damit lassen sich die Voreinstellungen ansehen
und ändern, ohne das Script zu bearbeiten. Änderungen gelten **sofort**, z. B. stehen neue
Präfixe gleich im Menütext. **[S] Speichern** schreibt sie dauerhaft nach `Einstellungen.json`
neben dem Script.

```
  [1] Namensregeln
  [2] Benutzer-Standards
  [3] OU / Abteilung
  [4] DNS
  [5] Module ein/aus
  [S] Speichern in Einstellungen.json (2 vom Standard abweichende Werte)
  [R] Auf Standard zurücksetzen
  [0] Zurück zum Hauptmenü
```

In jeder Gruppe steht pro Wert der aktuelle Wert. Weicht er vom Standard im Script ab, steht
der Standard in Klammern dahinter. Nummer eingeben = Wert ändern:

- **Ja/Nein-Werte** werden mit einer Eingabe umgeschaltet.
- **Andere Werte:** Der aktuelle Wert steht als Vorschlag in `[ ]`. Enter behält ihn,
  `leer` leert ihn (bei Listen geht auch `-`).
- Jede Eingabe wird geprüft. Danach kommt eine Vorschau mit Beispiel und dann die Frage
  „Übernehmen?“.

| Gruppe | Werte | Prüfung / Beispiel |
|--------|-------|--------------------|
| Namensregeln | `$PrefixGG`, `$PrefixDL`, `$TrennerRechte`, `$VerbinderRechte` | keine AD-unzulässigen Zeichen (`" / \ [ ] : ; \| = , + * ? < > @`, Leerzeichen), max. 20 Zeichen – „Globale Gruppe heißt dann: GG-Vertrieb“, „Domänenlokale Gruppe heißt dann: DL_Vertrieb_R-W“ |
| | `$BenutzernameMuster` | muss `{vorname}` oder `{nachname}` enthalten – „Anmeldename für Max Müller: max.mueller“ |
| | `$EmailMuster` | leer (= keine E-Mail) oder mit `@` und `{anmeldename}`/`{vorname}`/`{nachname}` |
| | `$MailDomain`, `$UPNSuffix` | leer (= DNS-Name der Domäne) oder gültiger DNS-Name |
| | `$NamenKleinschreiben` | Ja/Nein |
| Benutzer-Standards | `$EinstellungenFragen`, `$StandardKonto` (Aktiviert, PwAendern, PwNieAb) | Ja/Nein |
| | `$PasswortLaenge` | 8 bis 128 |
| | `$HomeBasisPfad`, `$HomeLaufwerk` (`H:`), `$HomeRecht` (NTFS-Recht, z. B. `Modify`) | |
| OU / Abteilung | `$OUSchutzVorLoeschen`, `$AbteilungsUnterOUs` (Liste), `$AbteilungBenutzerOU`, `$AbteilungGruppenOU` | gültige OU-Namen |
| DNS | `$DnsServerName`, `$DnsReplikation` (Domain/Forest/Legacy), `$DnsStandardTTL` (`hh:mm:ss`), `$DnsAutoPTR`, `$DnsWeiterleitungen` (IP-Liste) | |
| Module ein/aus | alle Schalter aus `$Funktionen` | Ja/Nein, Menü passt sich sofort an |

Ändert man `$DnsServerName`, prüft das Script die DNS-Fähigkeiten sofort neu.

## Einstellungen.json

- **Speichern [S]** zeigt zuerst die Liste „Standard → neu“ und fragt nach. Gespeichert werden
  **nur Werte, die vom Standard im Script abweichen** (UTF-8). Weicht nichts mehr ab, wird eine
  vorhandene Datei gelöscht.
- **Beim Start** wird die Datei, falls vorhanden, über die Standardwerte im Script gelegt.
- **Fehler:** Ist die Datei kaputt (kein gültiges JSON), kommt eine Warnung, und es gelten die
  Standards. Unbekannte oder ungültige Einträge erzeugen je eine Warnung und werden ignoriert.
  Das Script bricht dabei nicht ab.
- **Zurücksetzen [R]** setzt nach Bestätigung alle Werte auf die Standards im Script zurück und
  löscht `Einstellungen.json`.
- Einträge, die mit `_` beginnen (z. B. `_Hinweis`), sind Kommentare.
- Schlüssel: Variablenname ohne `$`, z. B. `"PrefixGG"`; bei Tabellen mit Punkt,
  z. B. `"StandardKonto.PwNieAb"` oder `"Funktionen.DNS"`.

Beispiel: [config/Einstellungen.example.json](../config/Einstellungen.example.json)

```json
{
  "PrefixGG": "GG-",
  "BenutzernameMuster": "{v}{nachname}",
  "AbteilungsUnterOUs": ["Benutzer", "Gruppen"],
  "Funktionen.FensterAuswahl": false
}
```

`Einstellungen.json` steht in `.gitignore` und wird nicht committet.
