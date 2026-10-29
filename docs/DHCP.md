# DHCP [H]

Das Menü **[H]** richtet den DHCP-Server vollständig ein – inklusive Autorisierung im AD –
und führt mit Vorschlägen durch jeden Bereich. Es steckt im Teilmodul `Module\DHCP.psm1`
neben `AD-Schnellanlage.ps1`.

Annahmen: DHCP läuft auf **diesem** Server (typisch: Domänencontroller mit DNS), nur IPv4.

| Taste | Funktion |
|-------|----------|
| 1 | Status: Rolle, Dienst, Autorisierung, Server-Manager-Hinweis, Bereiche |
| 2 | **Einrichtungs-Assistent**: Server vorbereiten, danach Bereich(e) anlegen |
| 3 | Bereich hinzufügen (Assistent mit Prüfungen) |
| 4 | Reservierung hinzufügen |
| 5 | Bereiche, Ausschlüsse, Reservierungen und Leases als Tabellen |
| 6 | Bereich entfernen (Bestätigung mit `JA`) |
| 7 | Ganze Konfiguration aus einer Datei laden (ohne Fragen) |
| 8 | **DNS-Integration** einrichten: dynamische Updates, Reverse-Zone, Dienstkonto, optional Alterung |
| 9 | DNS-Integration prüfen: Einstellungen und A-/PTR-Einträge aller Leases |

Punkte 3 bis 6 erscheinen erst, wenn Rolle, Dienst und Modul `DhcpServer` da sind –
sonst zeigt das Menü den Grund und verweist auf **[2]**.

## Server vorbereiten ([2] bzw. [7])

Vor der Änderung zeigt das Script, was schon erledigt ist und was passiert:

1. **Rolle** `DHCP` – fehlt sie: `Install-WindowsFeature DHCP -IncludeManagementTools`.
   Offline fragt das Script nach dem Ordner `\sources\sxs` des Server-ISOs (`-Source`).
2. **Sicherheitsgruppen** DHCP-Administratoren / DHCP-Benutzer (`Add-DhcpServerSecurityGroup`).
3. **Autorisierung im AD** (`Add-DhcpServerInDC -DnsName <server.domäne> -IPAddress <IP>`);
   ist der Server schon autorisiert (`Get-DhcpServerInDC`), wird nichts doppelt angelegt.
   Ohne AD wird der Schritt mit Hinweis übersprungen.
4. **Dienst** `DHCPServer` auf „Automatisch“ und neu starten, damit Gruppen und
   Autorisierung greifen.
5. **Server-Manager**: der gelbe Hinweis „Konfiguration für DHCP abschließen“ verschwindet
   (`HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12`, `ConfigurationState = 2`).

Die IP-Adresse des Servers schlägt das Script aus der **aktiven Netzwerkkarte** vor (die mit
Standardgateway, sonst die erste mit fester IPv4).

## Bereich-Assistent ([2] / [3])

Enter übernimmt jeden Vorschlag:

| Frage | Vorschlag |
|-------|-----------|
| Name | `LAN <Netz>` |
| Netz, Subnetzmaske | aus der IP der Netzwerkkarte, z. B. `192.168.10.0` / `255.255.255.0` (auch `/24`) |
| Erste / letzte verteilte Adresse | bei /24 und größer `.100` bis `.200`, bei kleineren Netzen die obere Hälfte |
| Ausschlüsse | keine (`192.168.10.150-192.168.10.155, 192.168.10.180`, `-` = keine) |
| Lease-Dauer | `8` Tage (auch `12h`, `30m`, `1.12:00:00`) |
| Router (Option 003) | erste Adresse im Netz (`.1`) |
| DNS-Server (Option 006) | IP dieses Servers |
| DNS-Domänenname (Option 015) | Domäne aus dem AD |

**Prüfungen** – jede Eingabe wird sofort geprüft, am Ende der ganze Bereich:

- Netz ist wirklich eine Netzadresse zur Maske (sonst: „gemeint ist wohl 192.168.10.0“).
- Maske gültig und zwischen /8 und /30.
- Start und Ende liegen im Netz (nicht Netz- oder Broadcast-Adresse), Start ≤ Ende.
- Router liegt im Netz; DNS-Server sind gültige IPv4-Adressen; Domänenname ist gültig.
- Ausschlüsse liegen im Verteilbereich.
- **Router und Server-IP** im Verteilbereich werden automatisch als Ausschluss
  vorgeschlagen (Enter = übernehmen).
- **Kein überlappender Bereich**: überschneidet sich das Netz mit einem vorhandenen
  Bereich, wird es abgelehnt. Gibt es genau dieses Netz schon, bietet das Script an, den
  vorhandenen Bereich zu ergänzen (Ausschlüsse, Optionen, aktivieren) – der Verteilbereich
  bleibt dann unverändert.
- Hinweis, wenn der Server keine Adresse im Netz hat (dann braucht es ein DHCP-Relay).

Bei Fehlern erklärt das Script, was falsch ist, und fragt alles erneut – mit den bisherigen
Antworten als Vorschlag. Danach Vorschau, Bestätigung, Anlage: Bereich aktiv
(`Add-DhcpServerv4Scope -State Active`), Ausschlüsse, Optionen 003/006/015
(`Set-DhcpServerv4OptionValue`, nur wenn anders). Ein zweiter Lauf legt nichts doppelt an.

## Reservierungen ([4])

Bereich wählen, dann MAC-Adresse in **beliebiger Schreibweise** – `00:11:22:AA:BB:CC`,
`00-11-22-aa-bb-cc`, `0011.22aa.bbcc`, `001122AABBCC` – sie wird zu `00-11-22-aa-bb-cc`.
Mit `L` lässt sich ein aktueller Lease übernehmen (MAC, IP und Hostname als Vorschlag).
Die IP muss im Verteilbereich liegen (so verlangt es Windows). Doppelte IP oder MAC werden
abgelehnt, eine schon vorhandene identische Reservierung als `VORHANDEN` gemeldet. Ist die
IP gerade an ein anderes Gerät vergeben, fragt das Script nach.

## Konfiguration aus Datei ([7])

`DHCP-Konfiguration.json` neben das Script legen (Beispiel:
[`config/DHCP.example.json`](../config/DHCP.example.json)). Weggelassene Werte kommen aus
den Vorschlägen oben (`ServerIp` leer = aktive Netzwerkkarte, `Netz` darf `192.168.20.0/24`
sein). Das Script prüft die ganze Datei, schließt Router/Server-IP im Verteilbereich
automatisch aus, zeigt eine Vorschau und richtet nach einer Bestätigung alles ein: Server
vorbereiten, Bereiche, Ausschlüsse, Optionen, Reservierungen. Hat die Datei Fehler, wird
nichts geändert und jeder Fehler mit Bereich genannt.

## DNS-Integration ([8], [9])

Ziel: Jeder DHCP-Client steht automatisch mit **A- und PTR-Eintrag** im DNS, und alte Einträge
verschwinden wieder. **[8]** wird auch am Ende des Assistenten [2] angeboten und bei [7]
ausgeführt, wenn in der Datei `"DnsIntegration": true` steht.

1. **DHCP-Einstellungen** (`Set-DhcpServerv4DnsSetting`, Serverebene – Bereiche mit eigener
   abweichender Einstellung werden mit angepasst):
   - `DynamicUpdates Always` – DHCP trägt immer ein, nicht nur auf Wunsch des Clients
   - `DeleteDnsRROnLeaseExpiry $true` – Einträge verschwinden, wenn die Lease abläuft oder gelöscht wird
   - `UpdateDnsRRForOlderClients $true` – auch Geräte, die selbst kein DNS-Update können (Drucker, Linux …)
   - PTR-Updates eingeschaltet (`DisableDnsPtrRRUpdate $false`)
2. **Reverse-Zone** für jedes DHCP-Netz (/24-Zone; bei größeren Netzen bis zu vier /24-Zonen,
   sonst /16 bzw. /8): fehlt sie, wird sie angelegt (`Add-DnsServerPrimaryZone -NetworkId …
   -ReplicationScope Domain`, dynamische Updates **nur sichere**). Hat eine vorhandene
   AD-integrierte Zone andere Updates, wird sie auf „nur sichere“ gestellt.
3. **Dienstkonto** für die Updates (Vorschlag `svc-dhcp-dns`): vorhandenes Konto wählen oder neu
   anlegen – normaler Domänenbenutzer ohne weitere Rechte, Passwort läuft nicht ab, Benutzer
   kann es nicht ändern. Das Passwort wird nur per `Read-Host -AsSecureString` gelesen (bei
   neuen Konten zweimal und gegen die Kennwortrichtlinie geprüft, bei vorhandenen gegen das
   AD geprüft) und mit `Set-DhcpServerDnsCredential` hinterlegt. Es steht **nie** im
   Protokoll, in einer Datei oder im Code.
4. Optional **Alterung/Bereinigung** (Scavenging) – mit Erklärung und Bestätigung, Standard
   *nein*: Reverse-Zone(n) und Domänen-Zone mit 7 Tagen kein Refresh + 7 Tagen Refresh,
   Server-Bereinigung alle 7 Tage. Dynamische Einträge, die 14 Tage nicht erneuert wurden,
   verschwinden; statische Einträge bleiben.

**Warum ein eigenes Dienstkonto?** Läuft DHCP auf einem Domänencontroller und trägt ohne
Anmeldedaten ein, gehören alle Einträge dem Computerkonto des DCs. Das ist ein bekanntes
Sicherheitsproblem (der DC hat volle Rechte auf alle DNS-Einträge in AD-integrierten Zonen,
Einträge können „gekapert“ werden) und macht Einträge nach einem DC-Wechsel unveränderbar.
Mit einem einfachen Dienstkonto gehören die Einträge diesem Konto. Den DC **nicht** in die
Gruppe `DnsUpdateProxy` aufnehmen.

**[9] Prüfen** zeigt die aktuellen Einstellungen, das hinterlegte Konto, ob die Reverse-Zonen
da sind und für jede Lease mit Hostname, ob A- und PTR-Eintrag existieren (`ja`, `nein`,
`andere IP`/`anderer Name`, `keine Zone`). Fehlt etwas: am Client `ipconfig /release` und
`ipconfig /renew`, dann erneut prüfen.

## Protokoll und Rückgängig

Alles landet im CSV-Protokoll (Typen `DHCP-Rolle`, `DHCP-Gruppen`, `DHCP-Autorisierung`,
`DHCP-Dienst`, `DHCP-Nachkonfig`, `DHCP-Bereich`, `DHCP-Ausschluss`, `DHCP-Option`,
`DHCP-Reservierung`, `DHCP-DNS`, `DHCP-DNS-Konto`, `DNS-Zone`, `DNS-Zone-Updates`,
`DNS-Alterung`, `Benutzer` für ein neues Dienstkonto). Das Hauptmenü **[8]** baut DHCP-Einstellungen nicht
automatisch zurück, sondern listet sie nur – einen Bereich entfernt man gezielt mit
**[H][6]**. Neu angelegte (leere) Reverse-Zonen und ein neu angelegtes Dienstkonto entfernt
[8] wie gewohnt; danach unter [H][8] ein anderes Konto hinterlegen.
