# DNS-Modul [D]

Das DNS-Menü erreicht man im Hauptmenü mit **[D]**. Es arbeitet mit dem DNS-Server dieses
Rechners oder – wenn `$DnsServerName` gesetzt ist – mit einem anderen DNS-Server
(alle `*-DnsServer*`-Aufrufe bekommen dann `-ComputerName`). Alles läuft offline mit den
Bordmitteln `DnsServer`, `ServerManager` und `DnsClient`.

| Taste | Funktion | sichtbar, wenn … |
|-------|----------|------------------|
| 1 | Status: Rolle, Dienst, Zonen (Name, Typ, Forward/Reverse, AD-integriert, Anzahl Einträge), Weiterleitungen | immer |
| 2 | DNS-Rolle installieren | Rolle fehlt (nur lokal) |
| 3 | Forward-Zone(n) erstellen | DNS nutzbar |
| 4 | Reverse-Zone(n) erstellen | DNS nutzbar |
| 5 | Einträge per Schnelleingabe (A, AAAA, CNAME, MX + automatischer PTR) | DNS nutzbar |
| 6 | Fehlende PTR-Einträge auffüllen | DNS nutzbar |
| 7 | Weiterleitungen (Forwarder) anzeigen, ergänzen, ersetzen | DNS nutzbar |
| 8 | Namensauflösung testen (`Resolve-DnsName -DnsOnly`) | DNS nutzbar |

Ohne DNS-Rolle erscheinen nur **[1]** und **[2]**. Nach der Installation sind sofort alle
Punkte da – ohne Neustart des Scripts.

## Einstellungen (Block KONFIGURATION → DNS)

| Einstellung | Standard | Bedeutung |
|-------------|----------|-----------|
| `$DnsServerName` | `''` | leer = dieser Server (auf einem DC der DC selbst), sonst Name des DNS-Servers |
| `$DnsReplikation` | `'Domain'` | Replikation AD-integrierter Zonen: `Domain`, `Forest` oder `Legacy` |
| `$DnsStandardTTL` | `'01:00:00'` | Vorschlag für die TTL neuer Einträge |
| `$DnsAutoPTR` | `$true` | bei A/AAAA den PTR automatisch mit anlegen |
| `$DnsWeiterleitungen` | `@()` | Vorschlag für [7], z. B. `@('192.168.10.1')` |

Einzelne Punkte lassen sich in `$Funktionen` abschalten: `DNS` (ganzes Menü), `DnsRolle`,
`DnsZonen`, `DnsEintraege`, `DnsPTRAuffuellen`, `DnsWeiterleitung`, `DnsTest`.

## [2] DNS-Rolle installieren

Führt nach Bestätigung `Install-WindowsFeature DNS -IncludeManagementTools` aus.
Ist der Server offline und fehlen die Feature-Dateien (Fehler `0x800f081f`), fragt das Script
nach einer Quelle: Windows-Server-ISO einbinden und den Ordner `\sources\sxs` angeben,
z. B. `D:\sources\sxs`. Danach werden die Fähigkeiten neu geprüft; läuft der Dienst nicht,
bietet das Script an, ihn zu starten.

## [3] Forward-Zonen

Mehrere Namen mit Komma: `firma.local, test.local`.

- **DNS-Server ist ein Domänencontroller:** Vorschlag AD-integriert
  (`Add-DnsServerPrimaryZone -ReplicationScope $DnsReplikation`), dynamische Updates `Secure`.
- **Sonst:** dateibasiert (`-ZoneFile "<name>.dns"`), dynamische Updates `None`.
- `Secure` geht nur bei AD-integrierten Zonen.

## [4] Reverse-Zonen

Eingabe als Netz – das Script zeigt zuerst den Zonennamen:

| Eingabe | Netz | Zone |
|---------|------|------|
| `192.168.10.0/24` | 192.168.10.0/24 | `10.168.192.in-addr.arpa` |
| `192.168.10` | 192.168.10.0/24 | `10.168.192.in-addr.arpa` |
| `172.16.0.0/16` | 172.16.0.0/16 | `16.172.in-addr.arpa` |
| `10.0.0.0/8` | 10.0.0.0/8 | `10.in-addr.arpa` |
| `192.168.10.0/25` | – | abgelehnt: nur /8, /16, /24 |

Klassenlose Reverse-Delegation (z. B. /25, /27) ist nicht enthalten.

## [5] Einträge per Schnelleingabe

Erst die Zone wählen, dann alles in **einer Zeile**, Teile mit `,` oder `;` getrennt:

| Eingabe | Ergebnis |
|---------|----------|
| `srv01=192.168.10.5` | A-Eintrag `srv01` (+ PTR `5` in `10.168.192.in-addr.arpa`) |
| `srv02=fd00::5` | AAAA-Eintrag (PTR nur, wenn eine passende `ip6.arpa`-Zone existiert) |
| `www=srv01` | CNAME `www` → `srv01.<zone>.` (Ziel ohne Punkt = in dieser Zone) |
| `www=srv01.firma.local` | CNAME auf den vollständigen Namen (Ziel mit Punkt) |
| `@=MX:mail:10` | MX am Zonenstamm, Ziel `mail.<zone>.`, Priorität 10 |
| `@=MX:mail` | wie oben, Priorität fehlt → 10 (mit Hinweis) |
| `@=192.168.10.5` | A-Eintrag am Zonenstamm |
| `srv03.firma.local=10.0.0.3` | vollständige Namen der Zone werden gekürzt → `srv03` |

Beispiel: `srv01=192.168.10.5, srv02=192.168.10.6, www=srv01, @=MX:mail:10`

**Prüfung je Teil** – ungültige Teile werden mit Grund übersprungen, der Rest läuft weiter:

- IP-Adressen streng geprüft (`192.168.10` oder `192.168.010.5` sind keine IPv4-Adressen)
- Hostnamen nach RFC 1123: nur `a-z`, `0-9`, `-`, kein `-` am Anfang/Ende, max. 63 Zeichen
  pro Namensteil, max. 253 gesamt. Umlaute werden abgelehnt (mit Vorschlag `ä` → `ae`).
- CNAME am Zonenstamm (`@`) ist nicht erlaubt.

**Konflikte**

| Lage | Ergebnis |
|------|----------|
| exakt gleicher Eintrag existiert | `VORHANDEN`, nichts wird geändert |
| gleicher Name, gleicher Typ, anderer Wert | Warnung + Frage „zusätzlich anlegen?“ (Standard: nein → `UEBERSPRUNGEN`) |
| CNAME auf einen Namen, der schon andere Einträge hat | `FEHLER` (DNS erlaubt das nicht) |
| weiterer Eintrag auf einen Namen, der ein CNAME ist | `FEHLER` |

**Automatischer PTR** (`$DnsAutoPTR`): Für jede A/AAAA-Adresse wird die genaueste vorhandene
Reverse-Zone gesucht. Fehlt sie, schlägt das Script das /24-Netz vor (z. B. `192.168.10.0/24`),
man kann ein anderes Netz eingeben oder mit `-` ohne PTR weitermachen. Die neue Reverse-Zone
erscheint in der Vorschau und wird vor den Einträgen angelegt.

Die TTL wird mit `$DnsStandardTTL` vorgeschlagen (Format `hh:mm:ss`).

Ein zweiter Lauf mit derselben Eingabe zeigt alles als `VORHANDEN`.

## [6] Fehlende PTR auffüllen

Geht alle A/AAAA-Einträge einer oder aller Forward-Zonen durch. Für jede Adresse ohne PTR
in einer vorhandenen Reverse-Zone wird ein PTR geplant. Pro IP nur einer: Die Namen aus allen
gewählten Zonen werden gemeinsam sortiert, echte Hostnamen haben Vorrang vor `@`,
`DomainDnsZones` und `ForestDnsZones`. Der PTR zeigt immer auf den vollständigen Namen,
z. B. `dc01.lutefisk.local.`.

Dienst-Namen (ein Namensteil beginnt mit `_`, z. B. `gc._msdcs`, `_ldap._tcp`) werden nie
PTR-Ziel. Hat eine IP nur solche Namen, steht sie grau unter „Nur Dienst-Namen - kein PTR“.

Adressen ohne passende Reverse-Zone werden gesammelt gemeldet (mit vollständigem Namen).
Ist `$Funktionen.DnsZonen` an, fragt das Script „Passende Reverse-Zone(n) jetzt erstellen?“:

1. Auswahl der Netze (Vorschlag /24), mehrere möglich, `(alle)` = alle Netze:
   ```
     [  1] (alle)
     [  2] 192.168.8.0/24     ->  8.168.192.in-addr.arpa     (2 Adressen: dc01.lutefisk.local., dc02.lutefisk.local.)
     [  3] 192.168.9.0/24     ->  9.168.192.in-addr.arpa     (1 Adresse: srv01.lutefisk.local.)
   ```
2. Optional „Netze anpassen (z. B. /16 statt /24)?“ – pro Netz ein anderes Netz eingeben
   (`/8`, `/16`, `/24`; alle Adressen müssen darin liegen, `-` = Netz weglassen). Gleiche Zonen
   werden nur einmal angelegt.
3. AD-Integration und dynamische Updates wie unter [4], Vorschau, dann werden die Zonen angelegt.
4. Danach sucht das Script neu – die PTR-Einträge für die neuen Zonen stehen sofort in der Liste.

IPv6-Adressen ohne Reverse-Zone erscheinen nur als Hinweis (Zone von Hand anlegen). Bei Nein
oder leerer Auswahl geht es nur mit den Adressen weiter, die schon eine Reverse-Zone haben.

Zum Schluss die Liste der fehlenden PTR-Einträge und „Diese PTR-Einträge jetzt erstellen?“.
Neue Zonen und PTR-Einträge stehen im Protokoll; [8] Rückgängig entfernt zuerst die Einträge,
dann die leeren Zonen.

## [7] Weiterleitungen

Zeigt die aktuellen Forwarder. **Ergänzen** (`Add-DnsServerForwarder`) oder **Ersetzen**
(`Set-DnsServerForwarder`). Es wird nur geprüft, ob es gültige IP-Adressen sind – kein Test
ins Internet.

## [8] Namensauflösung testen

`Resolve-DnsName -Server <DNS-Server> -DnsOnly` für einen Namen oder eine IP
(IP = Rückwärtssuche). Ergebnis als Tabelle; Enter = zurück.

## Protokoll und Rückgängig [9]

| Typ | Name | DN | Bezug |
|-----|------|----|-------|
| `DNS-Eintrag` | Hostname (`srv01`, `@`, beim PTR z. B. `5`) | Zone | `<Typ>\|<Daten>`, z. B. `A\|192.168.10.5`, `CNAME\|srv01.firma.local.`, `MX\|mail.firma.local.\|10` |
| `DNS-Zone` | Zone | Zone | `Forward` / `Reverse` |
| `DNS-Rolle` | `DNS` | Server | – |
| `DNS-Forwarder` | IP(s) | Server | – |

[9] entfernt zuerst genau die protokollierten DNS-Einträge (Name + Typ + Daten müssen passen,
andere Einträge mit gleichem Namen bleiben), dann die protokollierten Zonen – aber nur, wenn
außer SOA/NS nichts mehr drin ist. Die DNS-Rolle und die Weiterleitungen werden **nicht**
zurückgebaut, nur als Hinweis aufgelistet. Stehen AD-Objekte im Protokoll, aber AD ist hier
nicht verfügbar, werden diese mit `FEHLER` und Grund übersprungen; DNS wird trotzdem zurückgebaut.
