#Requires -Version 5.1
<#
.SYNOPSIS
    AD-Schnellanlage - OUs, Benutzer und Gruppen in Sekunden anlegen.

.DESCRIPTION
    Interaktives Menue fuer Windows Server.
    Nutzt ausschliesslich Bordmittel: Module ActiveDirectory, DnsServer, GroupPolicy,
    DhcpServer, ServerManager, SmbShare, NetTCPIP, DnsClient, .NET und - wenn vorhanden -
    Out-GridView. Keine externen Programme, kein Internet.

    Groessere Bereiche liegen als Teilmodule in Module\<Name>.psm1 neben dem Script
    (GPO, DHCP). Fehlt eine Datei, fehlt nur der zugehoerige Menuepunkt.

    Das Script prueft beim Start, was auf dem Server vorhanden ist (Active Directory,
    DNS-Rolle, SMB, Auswahlfenster, Adminrechte). Menuepunkte, die hier nicht laufen
    koennen, werden mit Grund als "nicht verfuegbar" angezeigt.

    Menue (jeder Punkt einzeln ein-/ausschaltbar unter KONFIGURATION -> $Funktionen):
      [1] OUs erstellen (auch verschachtelt: Firma/Buchhaltung)
      [2] Benutzer erstellen (einzeln oder Schnelleingabe in einer Zeile)
      [3] Globale Gruppen               -> GG_Name
      [4] Domaenenlokale Gruppen + Rechte -> DL_Name_M
      [5] AGDLP-Paket: GG + DL + Verschachtelung + Ordnerrechte
      [6] Abteilung komplett: OU + Unter-OUs + Gruppen + Ordner + Benutzer
      [7] Mitglieder zu Gruppen hinzufuegen
      [8] Rueckgaengig machen anhand des Protokolls (AD und DNS)
      [D] DNS: Status, Rolle installieren, Forward-/Reverse-Zonen, Eintraege per
          Schnelleingabe (srv01=192.168.10.5, www=srv01, @=MX:mail:10) mit
          automatischem PTR, fehlende PTR auffuellen (fehlende Reverse-Zonen dabei
          gleich anlegen), Weiterleitungen, Namensaufloesung
      [G] Gruppenrichtlinien: GPO erstellen, Netzlaufwerk zuordnen (Laufwerkszuordnung
          per Group Policy Preferences, optional nur fuer eine Gruppe), Standard-
          Richtlinien (Systemsteuerung, Desktophintergrund, cmd, USB, Bildschirmsperre),
          mit OU verknuepfen, anzeigen, entfernen
      [H] DHCP: Einrichtungs-Assistent (Rolle, Sicherheitsgruppen, Autorisierung im AD,
          Server-Manager-Hinweis, Bereich mit Vorschlaegen aus der Netzwerkkarte und
          Pruefungen), Bereiche, Reservierungen (MAC in jeder Schreibweise), anzeigen,
          entfernen, ganze Konfiguration aus Datei
      [S] Subnetzrechner (IPv4): Maske, Netz, Broadcast, erster/letzter Host, Anzahl
          Hosts - braucht weder AD noch DNS
      [E] Einstellungen: Praefixe, Namensmuster, Benutzer-Standards, DNS und Module
          ansehen, aendern und dauerhaft in Einstellungen.json speichern
      [P] Protokoll der Sitzung anzeigen

.NOTES
    Version: 2.0.0 (CSV-Import fuer Benutzer entfernt)
    Start:   powershell.exe -ExecutionPolicy Bypass -File .\AD-Schnellanlage.ps1
    AD-Funktionen brauchen einen Domaenencontroller oder das Windows-Feature
    "RSAT-AD-PowerShell". Ohne AD startet das Script trotzdem.
    Enter uebernimmt immer den Vorschlag in [eckigen Klammern].
    Tests:   Pester laedt die Funktionen per Dot-Sourcing (". .\AD-Schnellanlage.ps1"),
             dabei startet das Menue nicht.
#>

$ScriptVersion = '2.0.0'

#region ======================= KONFIGURATION =======================
# Alles in diesem Block darf angepasst werden. Einfacher: Menüpunkt [E] Einstellungen -
# dort geänderte Werte landen in "Einstellungen.json" neben dem Script und gelten beim
# nächsten Start über diesen Standards.

# --- Namensregeln ----------------------------------------------------
$PrefixGG            = 'GG_'      # Praefix globale Gruppen             -> GG_Vertrieb
$PrefixDL            = 'DL_'      # Praefix domänenlokale Gruppen       -> DL_Vertrieb_M
$TrennerRechte       = '_'        # zwischen Name und Rechte-Kürzel     -> DL_Vertrieb_M
$VerbinderRechte     = '-'        # zwischen mehreren Rechte-Kürzeln    -> DL_Vertrieb_R-W
$BenutzernameMuster  = '{vorname}.{nachname}'   # Platzhalter: {vorname} {nachname} {v} {n}
$EmailMuster         = '{anmeldename}@{domain}' # zusätzlich {anmeldename} {domain}
$MailDomain          = ''         # leer = DNS-Name der Domäne
$UPNSuffix           = ''         # leer = DNS-Name der Domäne
$NamenKleinschreiben = $true      # Anmeldename / E-Mail in Kleinbuchstaben

# --- Rechte für DL-Gruppen: Kürzel = Anzeigetext + NTFS-Recht --------
$Rechte = [ordered]@{
    'F'  = @{ Text = 'Vollzugriff';           NTFS = 'FullControl';    NurOrdner = $false }
    'M'  = @{ Text = 'Ändern';                NTFS = 'Modify';         NurOrdner = $false }
    'RX' = @{ Text = 'Lesen & Ausführen';     NTFS = 'ReadAndExecute'; NurOrdner = $false }
    'L'  = @{ Text = 'Ordnerinhalt anzeigen'; NTFS = 'ReadAndExecute'; NurOrdner = $true  }
    'R'  = @{ Text = 'Lesen';                 NTFS = 'Read';           NurOrdner = $false }
    'W'  = @{ Text = 'Schreiben';             NTFS = 'Write';          NurOrdner = $false }
}

# --- Benutzer-Standards ----------------------------------------------
$EinstellungenFragen = $true      # $false = immer die Standards unten nehmen (schneller)
$StandardKonto = @{
    Aktiviert = $true             # Konto sofort aktiv
    PwAendern = $true             # Passwort bei der ersten Anmeldung ändern
    PwNieAb   = $false            # Passwort läuft nie ab
}
$PasswortLaenge      = 14         # Länge der zufälligen Passwörter
$HomeBasisPfad       = ''         # z.B. '\\SRV01\Home$' oder 'D:\Home' (leer = wird gefragt)
$HomeLaufwerk        = 'H:'
$HomeRecht           = 'Modify'   # NTFS-Recht des Benutzers auf seinem Home-Ordner

# --- OUs / Abteilungen -----------------------------------------------
$OUSchutzVorLoeschen = $true
$AbteilungsUnterOUs  = @('Benutzer', 'Gruppen', 'Computer')   # @() = keine Unter-OUs
$AbteilungBenutzerOU = 'Benutzer' # Unter-OU für neue Benutzer
$AbteilungGruppenOU  = 'Gruppen'  # Unter-OU für neue Gruppen

# --- DNS -------------------------------------------------------------
$DnsServerName       = ''         # leer = dieser Server (auf einem DC der DC selbst); sonst Name des DNS-Servers
$DnsReplikation      = 'Domain'   # AD-integrierte Zonen: Domain / Forest / Legacy
$DnsStandardTTL      = '01:00:00' # Vorschlag für neue Einträge (hh:mm:ss)
$DnsAutoPTR          = $true      # bei A/AAAA automatisch den PTR-Eintrag mit anlegen
$DnsWeiterleitungen  = @()        # Vorschlag für Weiterleitungen, z.B. @('192.168.10.1', '192.168.10.2')

# --- Protokoll -------------------------------------------------------
$LogOrdner           = ''         # leer = Ordner "AD-Schnellanlage-Protokolle" neben dem Script

# --- Module ein/aus ($false = ausgeblendet bzw. Schritt wird übersprungen)
$Funktionen = [ordered]@{
    # Menüpunkte
    OU                  = $true   # [1]
    Benutzer            = $true   # [2]
    GlobaleGruppen      = $true   # [3]
    DLGruppen           = $true   # [4]
    AGDLP               = $true   # [5]
    Abteilung           = $true   # [6]
    Mitgliedschaften    = $true   # [7]
    Rueckgaengig        = $true   # [8] (braucht Protokoll)
    DNS                 = $true   # [D] DNS-Menü
    GPO                 = $true   # [G] Gruppenrichtlinien-Menü (Teilmodul Module\GPO.psm1)
    DHCP                = $true   # [H] DHCP-Menü (Teilmodul Module\DHCP.psm1)
    Subnetzrechner      = $true   # [S] Subnetzrechner (braucht weder AD noch DNS)
    # Zusatzschritte in den Abläufen
    Schnelleingabe      = $true   # Benutzer: alle Namen in einer Zeile
    ZufallsPasswort     = $true   # Benutzer: zufällige Passwörter + Liste
    VorlageBenutzer     = $true   # Benutzer: Gruppen/Abteilung/Firma von Vorlage kopieren
    GruppenZuweisen     = $true   # direkt Mitglieder bzw. Gruppen zuweisen
    AbteilungAusfuellen = $true   # Benutzer: Feld "Abteilung" (Vorschlag = OU-Name)
    EmailAusfuellen     = $true   # Benutzer: E-Mail nach $EmailMuster
    HomeOrdner          = $true   # Benutzer: Home-Ordner anlegen
    NTFSRechte          = $true   # DL-Gruppen: Rechte auf Ordner setzen
    Freigabe            = $true   # DL-Gruppen: SMB-Freigabe erstellen
    FensterAuswahl      = $true   # Auswahlfenster (Out-GridView), sonst Konsole
    Vorschau            = $true   # vor dem Erstellen alles anzeigen + bestätigen
    Protokoll           = $true   # CSV-Protokoll jeder Sitzung
    # Punkte im DNS-Menü [D]
    DnsRolle            = $true   # [D][2] DNS-Rolle installieren
    DnsZonen            = $true   # [D][3] + [4] Forward- und Reverse-Zonen
    DnsEintraege        = $true   # [D][5] Einträge per Schnelleingabe
    DnsPTRAuffuellen    = $true   # [D][6] fehlende PTR-Einträge auffüllen
    DnsWeiterleitung    = $true   # [D][7] Weiterleitungen (Forwarder)
    DnsTest             = $true   # [D][8] Namensauflösung testen
}
#endregion

#region ======================= EIN-/AUSGABE ========================

function Write-Titel([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Info([string]$Text)    { Write-Host "  $Text" -ForegroundColor Gray }
function Write-Ok([string]$Text)      { Write-Host "  $Text" -ForegroundColor Green }
function Write-Warnung([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }

# Bricht die aktuelle Aktion ab und springt zurück ins Menü
function Stop-Aktion { throw [System.OperationCanceledException]::new('Abgebrochen') }

function Read-Text {
    param([string]$Frage, [string]$Standard = '', [switch]$Pflicht)
    $anzeige = if ($Standard) { "  $Frage [$Standard]" } else { "  $Frage" }
    while ($true) {
        $antwort = "$(Read-Host $anzeige)".Trim()
        if (-not $antwort) { $antwort = $Standard }
        if ($antwort -or -not $Pflicht) { return $antwort }
        Write-Warnung 'Eingabe darf nicht leer sein.'
    }
}

function Read-JaNein([string]$Frage, [bool]$Standard = $true) {
    $hinweis = if ($Standard) { '[J/n]' } else { '[j/N]' }
    while ($true) {
        $antwort = "$(Read-Host "  $Frage $hinweis")".Trim().ToLower()
        if (-not $antwort)                      { return $Standard }
        if ($antwort -in 'j', 'ja', 'y', 'yes') { return $true }
        if ($antwort -in 'n', 'nein', 'no')     { return $false }
        Write-Warnung 'Bitte j oder n eingeben.'
    }
}

function Read-Zahl([string]$Frage, [int]$Min, [int]$Max) {
    while ($true) {
        $antwort = "$(Read-Host "  $Frage ($Min-$Max)")".Trim()
        $zahl = 0
        if ([int]::TryParse($antwort, [ref]$zahl) -and $zahl -ge $Min -and $zahl -le $Max) { return $zahl }
        Write-Warnung "Bitte eine Zahl von $Min bis $Max eingeben."
    }
}

# Mehrere Namen mit Komma; Präfixe (z.B. GG_) werden entfernt, falls mit eingetippt
function Read-Namensliste {
    param([string]$Frage, [string[]]$Praefixe = @())
    $eingabe = Read-Text "$Frage - mehrere mit Komma (Enter = abbrechen)"
    if (-not $eingabe) { Stop-Aktion }
    $namen = foreach ($teil in ($eingabe -split ',')) {
        $name = $teil.Trim()
        foreach ($p in $Praefixe) {
            if ($p -and $name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring($p.Length) }
        }
        if ($name) { $name }
    }
    $namen = @($namen | Select-Object -Unique)
    if ($namen.Count -eq 0) { Stop-Aktion }
    return $namen
}

# "1,3,5-7" -> 1,3,5,6,7  (ungültig -> $null)
function ConvertFrom-NummernAuswahl([string]$Text, [int]$Max) {
    $nummern = [System.Collections.Generic.List[int]]::new()
    foreach ($teil in ($Text -split '[,; ]+' | Where-Object { $_ })) {
        if ($teil -match '^(\d+)-(\d+)$') {
            $von = [int]$Matches[1]; $bis = [int]$Matches[2]
            if ($von -gt $bis -or $bis -gt $Max) { return $null }
            for ($n = $von; $n -le $bis; $n++) { $nummern.Add($n) }
        }
        elseif ($teil -match '^\d+$') { $nummern.Add([int]$teil) }
        else { return $null }
    }
    if ($nummern.Count -eq 0) { return $null }
    if (@($nummern | Where-Object { $_ -lt 1 -or $_ -gt $Max }).Count) { return $null }
    return , ([int[]]@($nummern | Select-Object -Unique))
}

# Auswahl aus einer Liste: Fenster (Out-GridView) oder Konsole mit Nummern
function Select-AusListe {
    param(
        [object[]]$Eintraege,
        [string]$Titel,
        [switch]$Mehrfach,
        [switch]$Optional   # Enter = überspringen statt abbrechen
    )
    if (-not $Eintraege -or $Eintraege.Count -eq 0) { Write-Warnung 'Keine Einträge gefunden.'; return }

    if ($script:GuiVerfuegbar) {
        try {
            $modus = if ($Mehrfach) { 'Multiple' } else { 'Single' }
            $hinweis = if ($Mehrfach) { 'mehrere mit Strg/Shift' } else { 'eine Zeile' }
            Write-Info "Auswahlfenster offen: $Titel ($hinweis, Abbrechen = $(if ($Optional) {'überspringen'} else {'abbrechen'}))"
            return @($Eintraege | Out-GridView -Title $Titel -OutputMode $modus)
        }
        catch {
            $script:GuiVerfuegbar = $false
            Write-Warnung 'Auswahlfenster nicht verfügbar - weiter in der Konsole.'
        }
    }

    Write-Host ''
    Write-Host "  $Titel" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Eintraege.Count; $i++) {
        Write-Host ('  [{0,3}] {1}' -f ($i + 1), $Eintraege[$i].Anzeige)
    }
    $art   = if ($Mehrfach) { 'Nummern (z.B. 1,3,5-7)' } else { 'Nummer' }
    $leer  = if ($Optional) { 'Enter = überspringen' } else { '0 = abbrechen' }
    while ($true) {
        $eingabe = "$(Read-Host "  $art, $leer")".Trim()
        if (-not $eingabe -and $Optional) { return }
        if ($eingabe -eq '0') { if ($Optional) { return } else { Stop-Aktion } }
        $idx = ConvertFrom-NummernAuswahl $eingabe $Eintraege.Count
        if ($null -ne $idx -and ($Mehrfach -or $idx.Count -eq 1)) {
            return @($idx | ForEach-Object { $Eintraege[$_ - 1] })
        }
        Write-Warnung 'Ungültige Auswahl.'
    }
}
#endregion

#region ======================= NAMEN, PASSWÖRTER, PROTOKOLL ========

function ConvertTo-LdapWert([string]$Wert) {
    return $Wert.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

# Umlaute ersetzen, Akzente entfernen, nur A-Z 0-9 und Bindestrich behalten
function ConvertTo-AdName([string]$Text) {
    $t = $Text -creplace 'ä', 'ae' -creplace 'ö', 'oe' -creplace 'ü', 'ue' `
               -creplace 'Ä', 'Ae' -creplace 'Ö', 'Oe' -creplace 'Ü', 'Ue' -replace 'ß', 'ss'
    $t = $t.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    return ($t -replace '[^A-Za-z0-9\-]', '')
}

function Format-NamensMuster([string]$Muster, [string]$Vorname, [string]$Nachname, [string]$Anmeldename = '') {
    $v = ConvertTo-AdName $Vorname
    $n = ConvertTo-AdName $Nachname
    $ergebnis = $Muster.Replace('{vorname}', $v).Replace('{nachname}', $n).Replace('{anmeldename}', $Anmeldename)
    $ergebnis = $ergebnis.Replace('{v}', $(if ($v) { $v.Substring(0, 1) } else { '' }))
    $ergebnis = $ergebnis.Replace('{n}', $(if ($n) { $n.Substring(0, 1) } else { '' }))
    $ergebnis = $ergebnis.Replace('{domain}', $MailDomain)
    if ($NamenKleinschreiben) { $ergebnis = $ergebnis.ToLower() }
    return $ergebnis
}

function Test-SamVorhanden([string]$Sam) {
    return [bool](Get-ADObject -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapWert $Sam))" -ErrorAction SilentlyContinue)
}

function Test-AdObjekt([string]$DN) {
    try { $null = Get-ADObject -Identity $DN -ErrorAction Stop; return $true } catch { return $false }
}

# Freien Anmeldenamen finden (max. 20 Zeichen, bei Doppelten Zahl anhängen)
function Get-FreierAnmeldename([string]$Vorname, [string]$Nachname, $Vergeben) {
    $basis = (Format-NamensMuster $BenutzernameMuster $Vorname $Nachname).Trim('.')
    if (-not $basis) { $basis = 'benutzer' }
    if ($basis.Length -gt 20) { $basis = $basis.Substring(0, 20).TrimEnd('.') }
    $kandidat = $basis
    $zahl = 2
    while ($Vergeben.Contains($kandidat) -or (Test-SamVorhanden $kandidat)) {
        $endung   = [string]$zahl
        $kandidat = $basis.Substring(0, [Math]::Min($basis.Length, 20 - $endung.Length)) + $endung
        $zahl++
    }
    return $kandidat
}

function Read-Anmeldename([string]$Vorschlag, $Vergeben) {
    while ($true) {
        $sam = Read-Text 'Anmeldename' $Vorschlag -Pflicht
        if ($sam -match '["/\\\[\]:;|=,+*?<>\s]') { Write-Warnung 'Ungültige Zeichen im Anmeldenamen.'; continue }
        if ($sam.Length -gt 20)                    { Write-Warnung 'Maximal 20 Zeichen.'; continue }
        if ($Vergeben.Contains($sam) -or (Test-SamVorhanden $sam)) { Write-Warnung "'$sam' ist bereits vergeben."; continue }
        return $sam
    }
}

function Get-RdnWert([string]$DN) {
    return ((($DN -split '(?<!\\),')[0]) -replace '^[A-Za-z]+=', '') -replace '\\(.)', '$1'
}
function Get-OuName([string]$DN) {
    if ($DN -match '^OU=') { return (Get-RdnWert $DN) }
    return ''
}
# "OU=Buchhaltung,OU=Firma,DC=firma,DC=local" -> "firma.local/Firma/Buchhaltung"
function Get-Kurzpfad([string]$DN) {
    $teile = @($DN -split '(?<!\\),' | Where-Object { $_ -notmatch '^DC=' } |
               ForEach-Object { ($_ -replace '^[A-Za-z]+=', '') -replace '\\(.)', '$1' })
    [array]::Reverse($teile)
    if ($teile.Count -eq 0) { return $Domain.DNSRoot }
    return "$($Domain.DNSRoot)/$($teile -join '/')"
}

function ConvertTo-Klartext([securestring]$Sicher) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sicher)
    try     { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Prüft gegen die Standard-Kennwortrichtlinie der Domäne ('' = in Ordnung)
function Test-PasswortRichtlinie([string]$Klartext) {
    $min = [Math]::Max(1, [int]$script:PwRichtlinie.MinPasswordLength)
    if ($Klartext.Length -lt $min) { return "Passwort zu kurz (mindestens $min Zeichen)." }
    if ($script:PwRichtlinie.ComplexityEnabled) {
        $klassen = 0
        if ($Klartext -cmatch '[A-ZÄÖÜ]')        { $klassen++ }
        if ($Klartext -cmatch '[a-zäöüß]')       { $klassen++ }
        if ($Klartext -match '\d')               { $klassen++ }
        if ($Klartext -match '[^A-Za-z0-9ÄÖÜäöüß]') { $klassen++ }
        if ($klassen -lt 3) { return 'Passwort zu einfach (3 von 4: Großbuchstabe, Kleinbuchstabe, Zahl, Sonderzeichen).' }
    }
    return ''
}

function Read-Passwort([string]$Fuer) {
    while ($true) {
        $p1 = Read-Host "  Passwort für $Fuer" -AsSecureString
        $p2 = Read-Host '  Passwort wiederholen' -AsSecureString
        $k1 = ConvertTo-Klartext $p1
        if ($k1 -cne (ConvertTo-Klartext $p2)) { Write-Warnung 'Passwörter stimmen nicht überein.'; continue }
        $problem = Test-PasswortRichtlinie $k1
        if ($problem) { Write-Warnung $problem; continue }
        return $p1
    }
}

# Zufälliges Passwort mit Krypto-Zufall, mind. 1 Zeichen aus jeder Gruppe
function New-ZufallsPasswort {
    $saetze  = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!$%&*+-=?@#'
    $alle    = -join $saetze
    $laenge  = [Math]::Max($PasswortLaenge, [Math]::Max(8, [int]$script:PwRichtlinie.MinPasswordLength))
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $puffer  = [byte[]]::new(4)
    $zufall  = { param([int]$Max) $rng.GetBytes($puffer); [int]([BitConverter]::ToUInt32($puffer, 0) % [uint32]$Max) }
    $zeichen = [System.Collections.Generic.List[char]]::new()
    foreach ($satz in $saetze) { $zeichen.Add($satz[(& $zufall $satz.Length)]) }
    while ($zeichen.Count -lt $laenge) { $zeichen.Add($alle[(& $zufall $alle.Length)]) }
    for ($i = $zeichen.Count - 1; $i -gt 0; $i--) {
        $j = & $zufall ($i + 1)
        $tmp = $zeichen[$i]; $zeichen[$i] = $zeichen[$j]; $zeichen[$j] = $tmp
    }
    $rng.Dispose()
    return (-join $zeichen)
}

# Ergebnis anzeigen + ins CSV-Protokoll schreiben
function Add-Ergebnis {
    param([string]$Typ, [string]$Name, [string]$DN, [string]$Status = 'OK', [string]$Info = '', [string]$Bezug = '')
    $eintrag = [pscustomobject]@{
        Zeit   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Typ    = $Typ
        Name   = $Name
        Status = $Status
        DN     = $DN
        Bezug  = $Bezug
        Info   = $Info
    }
    $script:Ergebnisse.Add($eintrag)
    if ($Funktionen.Protokoll) {
        try { $eintrag | Export-Csv -LiteralPath $script:LogDatei -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8 -ErrorAction Stop }
        catch {
            if (-not $script:LogFehlerGemeldet) {
                Write-Warnung "Protokoll nicht schreibbar: $($_.Exception.Message)"
                $script:LogFehlerGemeldet = $true
            }
        }
    }
    $farbe = switch ($Status) {
        'OK'        { 'Green' }
        'VORHANDEN' { 'Yellow' }
        'ENTFERNT'  { 'Cyan' }
        'FEHLT'     { 'DarkYellow' }
        'UEBERSPRUNGEN' { 'DarkYellow' }
        default     { 'Red' }
    }
    $zeile = '    [{0}] {1,-9} {2}' -f $Status, $Typ, $Name
    if ($Info -and $Status -ne 'OK') { $zeile += "  ->  $Info" }
    Write-Host $zeile -ForegroundColor $farbe
}
#endregion

#region ======================= AD-AUSWAHL ==========================

function Get-ZielListe([switch]$OhneContainer) {
    $liste = [System.Collections.Generic.List[object]]::new()
    $liste.Add([pscustomobject]@{ Anzeige = "$($Domain.DNSRoot)   (Domänenstamm)"; Pfad = $Domain.DNSRoot; DN = $Domain.DistinguishedName })
    if (-not $OhneContainer) {
        $liste.Add([pscustomobject]@{ Anzeige = "$($Domain.DNSRoot)/Users   (Standard-Container)"; Pfad = "$($Domain.DNSRoot)/Users"; DN = $Domain.UsersContainer })
    }
    foreach ($ou in @(Get-ADOrganizationalUnit -Filter * -Properties CanonicalName | Sort-Object CanonicalName)) {
        $liste.Add([pscustomobject]@{ Anzeige = $ou.CanonicalName; Pfad = $ou.CanonicalName; DN = $ou.DistinguishedName })
    }
    return $liste.ToArray()
}

# Wo im AD soll etwas hin? Gibt den DN zurück
function Select-AdZiel([string]$Was, [switch]$OhneContainer) {
    $ziele = @(Get-ZielListe -OhneContainer:$OhneContainer)
    if (-not $script:GuiVerfuegbar) {
        $such = Read-Text 'Suchbegriff für die OU (Enter = alle anzeigen)'
        if ($such) {
            # nur im Teil nach dem Domänennamen suchen, sonst passt "firma" bei firma.local auf alles
            $domPraefix = '^' + [regex]::Escape($Domain.DNSRoot)
            $treffer = @($ziele | Where-Object { ($_.Pfad -replace $domPraefix, '') -like "*$such*" })
            if ($treffer.Count) { $ziele = $treffer } else { Write-Warnung "Nichts zu '$such' gefunden - zeige alle." }
        }
    }
    $wahl = @(Select-AusListe -Eintraege $ziele -Titel "Ziel für $Was wählen")
    if ($wahl.Count -eq 0) { Stop-Aktion }
    Write-Ok "Ziel: $($wahl[0].Pfad)"
    return $wahl[0].DN
}

# Benutzer oder Gruppen auswählen (mehrere möglich). Gibt DNs zurück, leer = übersprungen
function Select-AdObjekte {
    param([ValidateSet('Benutzer', 'Gruppe')][string]$Art, [string]$Titel)
    $such = ''
    if (-not $script:GuiVerfuegbar) {
        $such = Read-Text "Suchbegriff ($Art, Enter = alle, '-' = überspringen)"
        if ($such -eq '-') { return }
    }
    $teil = ''
    if ($such) { $esc = ConvertTo-LdapWert $such; $teil = "(|(name=*$esc*)(sAMAccountName=*$esc*))" }
    $basis = if ($Art -eq 'Gruppe') { '(objectCategory=group)' } else { '(objectCategory=person)(objectClass=user)' }
    $objekte = @(Get-ADObject -LDAPFilter "(&$basis$teil)" -Properties sAMAccountName | Sort-Object Name)
    if ($objekte.Count -eq 0) { Write-Warnung 'Nichts gefunden.'; return }
    $eintraege = @($objekte | ForEach-Object {
        [pscustomobject]@{
            Anzeige = '{0,-32} {1,-22} {2}' -f $_.Name, $_.sAMAccountName, (Get-Kurzpfad (($_.DistinguishedName -split '(?<!\\),', 2)[1]))
            DN      = $_.DistinguishedName
        }
    })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel $Titel -Mehrfach -Optional)
    return @($wahl | ForEach-Object { $_.DN })
}
#endregion

#region ======================= RECHTE, GRUPPEN, OUS, ORDNER =========

function Select-Rechte([string]$Fuer) {
    $kuerzel = @($Rechte.Keys)
    Write-Host ''
    Write-Host "  Rechte für '$Fuer' (mehrere mit Komma, z.B. 2,5 oder M,R):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $kuerzel.Count; $i++) {
        Write-Host ('  [{0}] {1,-3} {2}' -f ($i + 1), $kuerzel[$i], $Rechte[$kuerzel[$i]].Text)
    }
    while ($true) {
        $eingabe  = Read-Text 'Auswahl' -Pflicht
        $gewaehlt = [System.Collections.Generic.List[string]]::new()
        $gueltig  = $true
        foreach ($teil in ($eingabe -split '[,; ]+' | Where-Object { $_ })) {
            $zahl = 0
            if ([int]::TryParse($teil, [ref]$zahl) -and $zahl -ge 1 -and $zahl -le $kuerzel.Count) { $gewaehlt.Add($kuerzel[$zahl - 1]) }
            elseif ($kuerzel -contains $teil) { $gewaehlt.Add($teil) }
            else { $gueltig = $false }
        }
        if ($gueltig -and $gewaehlt.Count) {
            # Reihenfolge wie in der Konfiguration, ohne Doppelte
            $auswahl = @($kuerzel | Where-Object { $gewaehlt -contains $_ })
            Write-Ok ('Gewählt: ' + (($auswahl | ForEach-Object { "$_ ($($Rechte[$_].Text))" }) -join ', '))
            return $auswahl
        }
        Write-Warnung 'Ungültige Auswahl.'
    }
}

# Bei mehreren Namen: einmal für alle oder je Gruppe einzeln
function Read-RechteFuerNamen([string[]]$Namen) {
    $ergebnis = [ordered]@{}
    if ($Namen.Count -gt 1 -and (Read-JaNein 'Gleiche Rechte für alle Gruppen?' $true)) {
        $k = @(Select-Rechte 'alle Gruppen')
        foreach ($n in $Namen) { $ergebnis[$n] = $k }
    }
    else {
        foreach ($n in $Namen) { $ergebnis[$n] = @(Select-Rechte $n) }
    }
    return $ergebnis
}

function Get-DLName([string]$Basis, [string[]]$Kuerzel) {
    return "$PrefixDL$Basis$TrennerRechte$($Kuerzel -join $VerbinderRechte)"
}
function Get-RechteText([string[]]$Kuerzel) {
    return 'Rechte: ' + (($Kuerzel | ForEach-Object { "$_ = $($Rechte[$_].Text)" }) -join ', ')
}

function New-AdOU([string]$Name, [string]$Ziel) {
    $vorhanden = Get-ADOrganizationalUnit -LDAPFilter "(ou=$(ConvertTo-LdapWert $Name))" -SearchBase $Ziel -SearchScope OneLevel -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if ($vorhanden) { Add-Ergebnis 'OU' $Name $vorhanden.DistinguishedName 'VORHANDEN'; return $vorhanden.DistinguishedName }
    try {
        $ou = New-ADOrganizationalUnit -Name $Name -Path $Ziel -ProtectedFromAccidentalDeletion $OUSchutzVorLoeschen -PassThru -ErrorAction Stop
        Add-Ergebnis 'OU' $Name $ou.DistinguishedName 'OK'
        return $ou.DistinguishedName
    }
    catch {
        Add-Ergebnis 'OU' $Name $Ziel 'FEHLER' $_.Exception.Message
        return $null
    }
}

function New-AdGruppe {
    param(
        [string]$Name,
        [ValidateSet('Global', 'DomainLocal')][string]$Bereich,
        [string]$Ziel,
        [string]$Beschreibung = ''
    )
    $vorhanden = Get-ADGroup -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapWert $Name))" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vorhanden) {
        $info = if ("$($vorhanden.GroupScope)" -ne $Bereich) { "existiert bereits als $($vorhanden.GroupScope)" } else { '' }
        Add-Ergebnis 'Gruppe' $Name $vorhanden.DistinguishedName 'VORHANDEN' $info
        return $vorhanden
    }
    if (Test-SamVorhanden $Name) {
        Add-Ergebnis 'Gruppe' $Name $Ziel 'FEHLER' 'Name ist schon von einem anderen Objekt belegt'
        return $null
    }
    $param = @{
        Name           = $Name
        SamAccountName = $Name
        GroupScope     = $Bereich
        GroupCategory  = 'Security'
        Path           = $Ziel
        PassThru       = $true
        ErrorAction    = 'Stop'
    }
    if ($Beschreibung) { $param.Description = $Beschreibung }
    try {
        $gruppe = New-ADGroup @param
        Add-Ergebnis 'Gruppe' $Name $gruppe.DistinguishedName 'OK' $Bereich
        return $gruppe
    }
    catch {
        Add-Ergebnis 'Gruppe' $Name $Ziel 'FEHLER' $_.Exception.Message
        return $null
    }
}

function Add-AdMitglied([string]$GruppeDN, [string]$MitgliedDN) {
    $text = '{0} -> {1}' -f (Get-RdnWert $MitgliedDN), (Get-RdnWert $GruppeDN)
    try {
        $mitglied = Get-ADObject -Identity $MitgliedDN -Properties memberOf -ErrorAction Stop
        if (@($mitglied.memberOf) -contains $GruppeDN) { Add-Ergebnis 'Mitglied' $text $GruppeDN 'VORHANDEN'; return }
        Add-ADGroupMember -Identity $GruppeDN -Members $MitgliedDN -ErrorAction Stop
        Add-Ergebnis 'Mitglied' $text $GruppeDN 'OK' -Bezug $MitgliedDN
    }
    catch {
        Add-Ergebnis 'Mitglied' $text $GruppeDN 'FEHLER' $_.Exception.Message
    }
}

# NTFS-Berechtigung hinzufügen (nur DACL, Besitzer bleibt unberührt)
function Add-NtfsRegel {
    param(
        [string]$Pfad,
        [System.Security.Principal.IdentityReference]$Identitaet,
        [string]$Recht,
        [switch]$NurOrdner
    )
    $vererbung = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    if ($NurOrdner) { $vererbung = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit }
    $regel = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identitaet,
        [System.Security.AccessControl.FileSystemRights]$Recht,
        $vererbung,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $ordner = Get-Item -LiteralPath $Pfad -ErrorAction Stop
    if ($ordner.PSObject.Methods.Name -contains 'GetAccessControl') {
        $acl = $ordner.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $acl.AddAccessRule($regel)
        $ordner.SetAccessControl($acl)
    }
    else {
        $acl = Get-Acl -LiteralPath $Pfad
        $acl.AddAccessRule($regel)
        Set-Acl -LiteralPath $Pfad -AclObject $acl -ErrorAction Stop
    }
}

# Optional: Ordner wählen/erstellen und der DL-Gruppe die Rechte geben
function Invoke-OrdnerSchritt($Gruppe, [string[]]$Kuerzel) {
    if (-not $Funktionen.NTFSRechte -or -not $Gruppe) { return }
    $pfad = (Read-Text "Ordner für '$($Gruppe.Name)' - NTFS-Rechte setzen (Pfad, Enter = überspringen)").Trim('"')
    if (-not $pfad) { return }
    if (-not (Test-Path -LiteralPath $pfad -PathType Container)) {
        if (-not (Read-JaNein "Ordner '$pfad' existiert nicht. Erstellen?" $true)) { return }
        try {
            New-Item -ItemType Directory -Path $pfad -Force -ErrorAction Stop | Out-Null
            Add-Ergebnis 'Ordner' $pfad $pfad 'OK'
        }
        catch { Add-Ergebnis 'Ordner' $pfad $pfad 'FEHLER' $_.Exception.Message; return }
    }
    $pfad = (Resolve-Path -LiteralPath $pfad).ProviderPath
    foreach ($k in $Kuerzel) {
        $r = $Rechte[$k]
        try {
            Add-NtfsRegel -Pfad $pfad -Identitaet $Gruppe.SID -Recht $r.NTFS -NurOrdner:([bool]$r.NurOrdner)
            Add-Ergebnis 'NTFS' "$($Gruppe.Name) = $($r.Text)" $pfad 'OK' $k
        }
        catch { Add-Ergebnis 'NTFS' "$($Gruppe.Name) = $($r.Text)" $pfad 'FEHLER' $_.Exception.Message }
    }
    Invoke-FreigabeSchritt $pfad
}

# Name von "Authentifizierte Benutzer" in der Sprache des Servers (über die feste SID)
function Get-AuthentifizierteBenutzer {
    return ([System.Security.Principal.SecurityIdentifier]'S-1-5-11').Translate([System.Security.Principal.NTAccount]).Value
}

# Optional: SMB-Freigabe (Freigaberecht: Authentifizierte Benutzer, gesteuert wird über NTFS)
function Invoke-FreigabeSchritt([string]$Pfad) {
    if (-not $Funktionen.Freigabe) { return }
    if ($Pfad -like '\\*') { return }     # UNC-Pfad ist schon eine Freigabe
    if (-not (Get-Command New-SmbShare -ErrorAction SilentlyContinue)) { return }
    $name = Read-Text 'Freigabe erstellen? Freigabename (Enter = keine)'
    if (-not $name) { return }
    if (Get-SmbShare -Name $name -ErrorAction SilentlyContinue) { Add-Ergebnis 'Freigabe' $name $Pfad 'VORHANDEN'; return }
    try {
        New-SmbShare -Name $name -Path $Pfad -FullAccess (Get-AuthentifizierteBenutzer) -FolderEnumerationMode AccessBased -ErrorAction Stop | Out-Null
        Add-Ergebnis 'Freigabe' $name $Pfad 'OK'
        Write-Info "Freigabe erreichbar unter \\$env:COMPUTERNAME\$name"
    }
    catch { Add-Ergebnis 'Freigabe' $name $Pfad 'FEHLER' $_.Exception.Message }
}

function New-HomeOrdner($Benutzer, [string]$Basis) {
    $pfad = Join-Path $Basis $Benutzer.SamAccountName
    try {
        if (-not (Test-Path -LiteralPath $pfad)) { New-Item -ItemType Directory -Path $pfad -ErrorAction Stop | Out-Null }
        Add-NtfsRegel -Pfad $pfad -Identitaet $Benutzer.SID -Recht $HomeRecht
        Set-ADUser -Identity $Benutzer.DistinguishedName -HomeDirectory $pfad -HomeDrive $HomeLaufwerk -ErrorAction Stop
        Add-Ergebnis 'Home' $pfad $pfad 'OK' $Benutzer.SamAccountName
    }
    catch { Add-Ergebnis 'Home' $pfad $pfad 'FEHLER' $_.Exception.Message }
}
#endregion

#region ======================= BENUTZER-KERN ========================

function New-BenutzerPlan([string]$Vorname, [string]$Nachname, [string]$Ziel) {
    return [pscustomobject]@{
        Vorname          = $Vorname
        Nachname         = $Nachname
        Anzeigename      = "$Vorname $Nachname".Trim()
        CN               = ''
        Sam              = ''
        UPN              = ''
        Mail             = ''
        Ziel             = $Ziel
        Abteilung        = ''
        Firma            = ''
        Buero            = ''
        Passwort         = $null
        PasswortKlartext = ''
        PasswortArt      = ''
        Aktiviert        = $null
        PwAendern        = $null
        PwNieAb          = $null
        Gruppen          = [System.Collections.Generic.List[string]]::new()
        HomeBasis        = ''
        Erstellt         = $false
    }
}

function Set-PlanAnmeldename($Plan, [string]$Sam, $Vergeben) {
    $Plan.Sam = $Sam
    $Plan.UPN = "$Sam@$UPNSuffix"
    [void]$Vergeben.Add($Sam)
}

function Set-PlanEinstellungen($Plan, $Einstellungen) {
    $Plan.Aktiviert = [bool]$Einstellungen.Aktiviert
    $Plan.PwAendern = [bool]$Einstellungen.PwAendern
    $Plan.PwNieAb   = [bool]$Einstellungen.PwNieAb
}

function Get-KontoEinstellungen([string]$Fuer) {
    if (-not $EinstellungenFragen) {
        return [pscustomobject]@{
            Aktiviert = $StandardKonto.Aktiviert
            PwAendern = $StandardKonto.PwAendern
            PwNieAb   = ($StandardKonto.PwNieAb -and -not $StandardKonto.PwAendern)
        }
    }
    Write-Info "Kontoeinstellungen für ${Fuer}:"
    $aktiv   = Read-JaNein 'Konto aktivieren?' $StandardKonto.Aktiviert
    $aendern = Read-JaNein 'Passwort bei der ersten Anmeldung ändern?' $StandardKonto.PwAendern
    $nieAb   = $false
    if (-not $aendern) { $nieAb = Read-JaNein 'Passwort läuft nie ab?' $StandardKonto.PwNieAb }
    return [pscustomobject]@{ Aktiviert = $aktiv; PwAendern = $aendern; PwNieAb = $nieAb }
}

function Select-PasswortModus([int]$Anzahl) {
    $optionen = [System.Collections.Generic.List[object]]::new()
    if ($Anzahl -gt 1) {
        $optionen.Add([pscustomobject]@{ Modus = 'Gleich'; Text = 'Alle bekommen dasselbe Passwort (nur einmal eingeben)' })
        $optionen.Add([pscustomobject]@{ Modus = 'Einzeln'; Text = 'Jeder bekommt ein eigenes Passwort + eigene Einstellungen' })
    }
    else {
        $optionen.Add([pscustomobject]@{ Modus = 'Einzeln'; Text = 'Passwort selbst eingeben' })
    }
    if ($Funktionen.ZufallsPasswort) {
        $optionen.Add([pscustomobject]@{ Modus = 'Zufall'; Text = 'Zufällige sichere Passwörter erzeugen (Liste wird gespeichert)' })
    }
    if ($optionen.Count -eq 1) { return $optionen[0].Modus }
    Write-Host ''
    Write-Host '  Passwort:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $optionen.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $optionen[$i].Text) }
    $nr = Read-Zahl 'Auswahl' 1 $optionen.Count
    return $optionen[$nr - 1].Modus
}

function New-BenutzerAusPlan($Plan) {
    $param = @{
        Name                  = $Plan.CN
        GivenName             = $Plan.Vorname
        Surname               = $Plan.Nachname
        DisplayName           = $Plan.Anzeigename
        SamAccountName        = $Plan.Sam
        UserPrincipalName     = $Plan.UPN
        Path                  = $Plan.Ziel
        AccountPassword       = $Plan.Passwort
        Enabled               = $Plan.Aktiviert
        ChangePasswordAtLogon = $Plan.PwAendern
        PasswordNeverExpires  = $Plan.PwNieAb
        PassThru              = $true
        ErrorAction           = 'Stop'
    }
    if ($Plan.Mail)      { $param.EmailAddress = $Plan.Mail }
    if ($Plan.Abteilung) { $param.Department   = $Plan.Abteilung }
    if ($Plan.Firma)     { $param.Company      = $Plan.Firma }
    if ($Plan.Buero)     { $param.Office       = $Plan.Buero }

    try { $benutzer = New-ADUser @param }
    catch {
        $fehler = $_.Exception.Message
        # New-ADUser legt das Konto manchmal deaktiviert an, obwohl das Passwort abgelehnt wurde -> aufräumen
        $rest = Get-ADUser -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapWert $Plan.Sam))" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rest) {
            try   { Remove-ADUser -Identity $rest.DistinguishedName -Confirm:$false -ErrorAction Stop; $fehler += ' (halb angelegtes Konto wieder entfernt)' }
            catch { $fehler += " (Konto liegt deaktiviert unter $($rest.DistinguishedName))" }
        }
        Add-Ergebnis 'Benutzer' $Plan.Sam $Plan.Ziel 'FEHLER' $fehler
        return
    }
    if (-not $benutzer.SID) { $benutzer = Get-ADUser -Identity $benutzer.DistinguishedName }
    $Plan.Erstellt = $true
    Add-Ergebnis 'Benutzer' $Plan.Sam $benutzer.DistinguishedName 'OK' $Plan.CN
    foreach ($g in @($Plan.Gruppen | Select-Object -Unique)) { Add-AdMitglied $g $benutzer.DistinguishedName }
    if ($Plan.HomeBasis) { New-HomeOrdner $benutzer $Plan.HomeBasis }
}

# Gemeinsamer Abschluss für einzelne Eingabe und Schnelleingabe:
# Passwörter -> Einstellungen -> Extras -> Vorschau -> Erstellen
function Complete-BenutzerAnlage {
    # Zufallspasswörter entstehen im Script und müssen für die Passwortliste im Klartext vorliegen
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    param([object[]]$Plaene, [string]$PwModus, [securestring]$GleichesPw)

    # 1) Passwörter
    foreach ($p in @($Plaene | Where-Object { -not $_.Passwort })) {
        switch ($PwModus) {
            'Gleich' { $p.Passwort = $GleichesPw; $p.PasswortArt = 'gleich' }
            'Zufall' {
                $klar = New-ZufallsPasswort
                $p.PasswortKlartext = $klar
                $p.Passwort = ConvertTo-SecureString $klar -AsPlainText -Force
                $p.PasswortArt = 'zufällig'
            }
            default {
                $p.Passwort = Read-Passwort $p.Sam
                $p.PasswortArt = 'einzeln'
            }
        }
    }

    # 2) Kontoeinstellungen für alle, die noch keine haben
    $ohneEinst = @($Plaene | Where-Object { $null -eq $_.Aktiviert })
    if ($ohneEinst.Count) {
        $text = if ($ohneEinst.Count -eq 1) { $ohneEinst[0].Sam } else { "alle $($ohneEinst.Count) Benutzer" }
        $e = Get-KontoEinstellungen $text
        foreach ($p in $ohneEinst) { Set-PlanEinstellungen $p $e }
    }

    # 3) Vorlage-Benutzer kopieren
    if ($Funktionen.VorlageBenutzer) {
        $vorlageSam = Read-Text 'Vorlage-Benutzer kopieren (Gruppen, Abteilung, Firma)? Anmeldename (Enter = nein)'
        if ($vorlageSam) {
            $vorlage = Get-ADUser -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapWert $vorlageSam))" -Properties MemberOf, Department, Company, Office -ErrorAction SilentlyContinue |
                       Select-Object -First 1
            if (-not $vorlage) { Write-Warnung "Benutzer '$vorlageSam' nicht gefunden - keine Vorlage." }
            else {
                foreach ($p in $Plaene) {
                    foreach ($g in @($vorlage.MemberOf)) { $p.Gruppen.Add($g) }
                    if (-not $p.Abteilung) { $p.Abteilung = "$($vorlage.Department)" }
                    if (-not $p.Firma)     { $p.Firma     = "$($vorlage.Company)" }
                    if (-not $p.Buero)     { $p.Buero     = "$($vorlage.Office)" }
                }
                Write-Ok "Vorlage '$($vorlage.SamAccountName)': $(@($vorlage.MemberOf).Count) Gruppe(n) werden übernommen."
            }
        }
    }

    # 4) Gruppen direkt zuweisen
    if ($Funktionen.GruppenZuweisen -and (Read-JaNein 'Benutzer direkt Gruppen zuweisen?' $false)) {
        $gruppen = @(Select-AdObjekte -Art Gruppe -Titel 'Gruppen für die neuen Benutzer wählen')
        foreach ($p in $Plaene) { foreach ($g in $gruppen) { $p.Gruppen.Add($g) } }
        if ($gruppen.Count) { Write-Ok "$($gruppen.Count) Gruppe(n) gewählt." }
    }

    # 5) Abteilung
    $ohneAbt = @($Plaene | Where-Object { -not $_.Abteilung })
    if ($Funktionen.AbteilungAusfuellen -and $ohneAbt.Count) {
        $ouNamen   = @($ohneAbt | ForEach-Object { Get-OuName $_.Ziel } | Select-Object -Unique)
        $vorschlag = if ($ouNamen.Count -eq 1) { $ouNamen[0] } else { 'Name der jeweiligen OU' }
        if (-not $vorschlag) { $vorschlag = 'keine' }
        $antwort = Read-Text "Abteilung (Enter = $vorschlag, '-' = keine, oder Text eingeben)"
        if ($antwort -ne '-') {
            foreach ($p in $ohneAbt) { $p.Abteilung = if ($antwort) { $antwort } else { Get-OuName $p.Ziel } }
        }
    }

    # 6) E-Mail
    if ($Funktionen.EmailAusfuellen -and $EmailMuster) {
        foreach ($p in $Plaene) {
            if (-not $p.Mail) { $p.Mail = Format-NamensMuster $EmailMuster $p.Vorname $p.Nachname $p.Sam }
        }
    }

    # 7) Home-Ordner
    if ($Funktionen.HomeOrdner -and (Read-JaNein 'Home-Ordner anlegen?' ([bool]$HomeBasisPfad))) {
        $basis = (Read-Text 'Basis-Pfad (z.B. \\SRV01\Home$ oder D:\Home)' $HomeBasisPfad -Pflicht).Trim('"')
        if (Test-Path -LiteralPath $basis -PathType Container) { foreach ($p in $Plaene) { $p.HomeBasis = $basis } }
        else { Write-Warnung "Pfad '$basis' nicht gefunden - Home-Ordner werden übersprungen." }
    }

    # 8) Eindeutigen Objektnamen (CN) pro OU sicherstellen
    $cnSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Plaene) {
        $cn = $p.Anzeigename
        $belegt = $cnSet.Contains("$cn|$($p.Ziel)") -or
                  [bool](Get-ADObject -LDAPFilter "(cn=$(ConvertTo-LdapWert $cn))" -SearchBase $p.Ziel -SearchScope OneLevel -ErrorAction SilentlyContinue)
        if ($belegt) { $cn = "$($p.Anzeigename) ($($p.Sam))" }
        $p.CN = $cn
        [void]$cnSet.Add("$cn|$($p.Ziel)")
    }

    # 9) Vorschau
    if ($Funktionen.Vorschau) {
        Write-Titel "Vorschau: $($Plaene.Count) Benutzer"
        foreach ($p in $Plaene) {
            $konto = @(if ($p.Aktiviert) { 'aktiv' } else { 'deaktiviert' })
            if ($p.PwAendern) { $konto += 'PW ändern' }
            if ($p.PwNieAb)   { $konto += 'PW läuft nie ab' }
            Write-Host ('    {0,-21} {1}' -f $p.Sam, $p.CN) -ForegroundColor White
            Write-Host ('      OU: {0} | Passwort: {1} | {2} | Gruppen: {3}' -f (Get-Kurzpfad $p.Ziel), $p.PasswortArt, ($konto -join ', '), @($p.Gruppen | Select-Object -Unique).Count) -ForegroundColor Gray
            if ($p.Abteilung -or $p.Mail) {
                Write-Host ('      Abteilung: {0} | E-Mail: {1}' -f $(if ($p.Abteilung) { $p.Abteilung } else { '-' }), $(if ($p.Mail) { $p.Mail } else { '-' })) -ForegroundColor Gray
            }
        }
        if ($Plaene[0].HomeBasis) { Write-Info "Home-Ordner: $($Plaene[0].HomeBasis)\<Anmeldename>  als $HomeLaufwerk" }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }

    # 10) Erstellen
    Write-Titel 'Erstelle Benutzer'
    foreach ($p in $Plaene) { New-BenutzerAusPlan $p }

    # 11) Zufallspasswörter ausgeben + speichern
    $zufall = @($Plaene | Where-Object { $_.Erstellt -and $_.PasswortKlartext })
    if ($zufall.Count) {
        $liste = $zufall | Select-Object @{ n = 'Name'; e = { $_.Anzeigename } }, @{ n = 'Anmeldename'; e = { $_.Sam } }, @{ n = 'Passwort'; e = { $_.PasswortKlartext } }
        $liste | Format-Table -AutoSize | Out-Host
        $datei = Join-Path $LogOrdner ('Passwoerter_{0:yyyy-MM-dd_HH-mm-ss}.csv' -f (Get-Date))
        try {
            $liste | Export-Csv -LiteralPath $datei -NoTypeInformation -Delimiter ';' -Encoding UTF8 -ErrorAction Stop
            Write-Warnung "Passwortliste gespeichert: $datei  -> nach dem Verteilen LÖSCHEN!"
        }
        catch { Write-Warnung "Passwortliste konnte nicht gespeichert werden: $($_.Exception.Message)" }
    }
}
#endregion

#region ======================= MODUL [1] OUs ========================

function Start-OUs {
    Write-Titel 'Organisationseinheit(en) erstellen'
    $ziel = Select-AdZiel 'die neue(n) OU(s)' -OhneContainer
    Write-Info 'Tipp: Unter-OUs direkt mit / angeben, z.B.  Firma/Buchhaltung, Firma/Vertrieb'
    $namen = @(Read-Namensliste 'OU-Name(n)')
    if ($Funktionen.Vorschau) {
        $basis = Get-Kurzpfad $ziel
        foreach ($n in $namen) { Write-Host "    $basis/$($n.Trim('/'))" -ForegroundColor White }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    foreach ($n in $namen) {
        $aktuell = $ziel
        foreach ($teil in @($n -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $aktuell = New-AdOU $teil $aktuell
            if (-not $aktuell) { break }
        }
    }
}
#endregion

#region ======================= MODUL [2] BENUTZER ===================

function Start-BenutzerAnlage {
    param([string]$Ziel, [string[]]$StandardGruppen = @(), [string]$Abteilung = '')
    Write-Titel 'Benutzer erstellen'
    if (-not $Ziel) { $Ziel = Select-AdZiel 'die Benutzer' } else { Write-Ok "Ziel: $(Get-Kurzpfad $Ziel)" }

    $vergeben   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $plaene     = [System.Collections.Generic.List[object]]::new()
    $gleichesPw = $null
    $schnell    = $Funktionen.Schnelleingabe -and (Read-JaNein 'Schnelleingabe (alle Namen in einer Zeile)?' $false)

    if ($schnell) {
        Write-Info 'Format: Vorname Nachname, Vorname Nachname, ...   (letztes Wort = Nachname)'
        $zeile = Read-Text 'Namen' -Pflicht
        foreach ($teil in ($zeile -split '[,;]')) {
            $worte = @($teil.Trim() -split '\s+' | Where-Object { $_ })
            if ($worte.Count -eq 0) { continue }
            if ($worte.Count -lt 2) { Write-Warnung "'$($teil.Trim())' braucht Vor- und Nachnamen - übersprungen."; continue }
            $vn = $worte[0..($worte.Count - 2)] -join ' '
            $nn = $worte[-1]
            $p  = New-BenutzerPlan $vn $nn $Ziel
            Set-PlanAnmeldename $p (Get-FreierAnmeldename $vn $nn $vergeben) $vergeben
            $plaene.Add($p)
        }
        if ($plaene.Count -eq 0) { Stop-Aktion }
        Write-Ok "$($plaene.Count) Benutzer erkannt: $(($plaene | ForEach-Object { $_.Sam }) -join ', ')"
        $modus = Select-PasswortModus $plaene.Count
        if ($modus -eq 'Gleich') { $gleichesPw = Read-Passwort 'alle Benutzer' }
        elseif ($modus -eq 'Einzeln') {
            foreach ($p in $plaene) {
                Write-Host ''
                Write-Host "  -- $($p.Anzeigename) ($($p.Sam)) --" -ForegroundColor Cyan
                $p.Passwort = Read-Passwort $p.Sam
                $p.PasswortArt = 'einzeln'
                Set-PlanEinstellungen $p (Get-KontoEinstellungen $p.Sam)
            }
        }
    }
    else {
        $anzahl = Read-Zahl 'Wie viele Benutzer?' 1 500
        $modus  = Select-PasswortModus $anzahl
        if ($modus -eq 'Gleich') { $gleichesPw = Read-Passwort 'alle Benutzer' }
        for ($i = 1; $i -le $anzahl; $i++) {
            Write-Host ''
            Write-Host "  -- Benutzer $i von $anzahl --" -ForegroundColor Cyan
            $vn  = Read-Text 'Vorname' -Pflicht
            $nn  = Read-Text 'Nachname' -Pflicht
            $sam = Read-Anmeldename (Get-FreierAnmeldename $vn $nn $vergeben) $vergeben
            $p   = New-BenutzerPlan $vn $nn $Ziel
            Set-PlanAnmeldename $p $sam $vergeben
            if ($modus -eq 'Einzeln') {
                $p.Passwort = Read-Passwort $sam
                $p.PasswortArt = 'einzeln'
                Set-PlanEinstellungen $p (Get-KontoEinstellungen $sam)
            }
            $plaene.Add($p)
        }
    }

    foreach ($p in $plaene) {
        foreach ($g in $StandardGruppen) { $p.Gruppen.Add($g) }
        if ($Abteilung) { $p.Abteilung = $Abteilung }
    }
    Complete-BenutzerAnlage -Plaene $plaene.ToArray() -PwModus $modus -GleichesPw $gleichesPw
}
#endregion

#region ======================= MODUL [3] + [4] GRUPPEN ==============

function Start-GlobaleGruppen {
    Write-Titel "Globale Gruppe(n) erstellen   ($PrefixGG<Name>)"
    $ziel         = Select-AdZiel 'die Gruppe(n)'
    $namen        = @(Read-Namensliste "Gruppenname(n) ohne '$PrefixGG'" -Praefixe $PrefixGG)
    $beschreibung = Read-Text 'Beschreibung (optional, gilt für alle)'
    $mitglieder   = @()
    if ($Funktionen.GruppenZuweisen -and (Read-JaNein 'Gleich Benutzer als Mitglieder hinzufügen?' $false)) {
        $mitglieder = @(Select-AdObjekte -Art Benutzer -Titel 'Mitglieder wählen')
    }
    if ($Funktionen.Vorschau) {
        Write-Info 'Wird erstellt:'
        foreach ($n in $namen) { Write-Host "    $PrefixGG$n" -ForegroundColor White }
        if ($mitglieder.Count) { Write-Info "mit je $($mitglieder.Count) Mitglied(ern)" }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    foreach ($n in $namen) {
        $g = New-AdGruppe -Name "$PrefixGG$n" -Bereich Global -Ziel $ziel -Beschreibung $beschreibung
        if ($g) { foreach ($m in $mitglieder) { Add-AdMitglied $g.DistinguishedName $m } }
    }
}

function Start-DLGruppen {
    Write-Titel "Domänenlokale Gruppe(n) erstellen   ($PrefixDL<Name>$TrennerRechte<Rechte>)"
    $ziel   = Select-AdZiel 'die Gruppe(n)'
    $namen  = @(Read-Namensliste "Gruppenname(n) ohne '$PrefixDL'" -Praefixe $PrefixDL)
    $rechteJeName = Read-RechteFuerNamen $namen
    $ggs    = @()
    if ($Funktionen.GruppenZuweisen -and (Read-JaNein 'Globale Gruppen als Mitglied aufnehmen (AGDLP)?' $false)) {
        $ggs = @(Select-AdObjekte -Art Gruppe -Titel 'Gruppen wählen, die Mitglied werden')
    }
    if ($Funktionen.Vorschau) {
        Write-Info 'Wird erstellt:'
        foreach ($n in $namen) {
            Write-Host ('    {0,-35} {1}' -f (Get-DLName $n $rechteJeName[$n]), (Get-RechteText $rechteJeName[$n])) -ForegroundColor White
        }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    foreach ($n in $namen) {
        $k  = @($rechteJeName[$n])
        $dl = New-AdGruppe -Name (Get-DLName $n $k) -Bereich DomainLocal -Ziel $ziel -Beschreibung (Get-RechteText $k)
        if (-not $dl) { continue }
        foreach ($gg in $ggs) { Add-AdMitglied $dl.DistinguishedName $gg }
        Invoke-OrdnerSchritt $dl $k
    }
}
#endregion

#region ======================= MODUL [5] AGDLP ======================

function Start-AGDLP {
    Write-Titel 'AGDLP-Paket   (GG + DL + Verschachtelung + Ordnerrechte)'
    Write-Info "Pro Name: $PrefixGG<Name> wird Mitglied von $PrefixDL<Name>$TrennerRechte<Rechte>, danach optional Ordner + Freigabe."
    $ziel   = Select-AdZiel 'die Gruppen'
    $zielDL = $ziel
    if (-not (Read-JaNein 'DL-Gruppen in dieselbe OU?' $true)) { $zielDL = Select-AdZiel 'die DL-Gruppen' }
    $namen  = @(Read-Namensliste 'Name(n) ohne Präfix' -Praefixe $PrefixGG, $PrefixDL)
    $rechteJeName = Read-RechteFuerNamen $namen
    $benutzer = @()
    if ($Funktionen.GruppenZuweisen -and (Read-JaNein "Benutzer gleich in die $PrefixGG-Gruppe(n) aufnehmen?" $false)) {
        $benutzer = @(Select-AdObjekte -Art Benutzer -Titel 'Benutzer für die globale(n) Gruppe(n)')
    }
    if ($Funktionen.Vorschau) {
        Write-Info 'Wird erstellt:'
        foreach ($n in $namen) {
            Write-Host ('    {0,-28} ->  {1}' -f "$PrefixGG$n", (Get-DLName $n $rechteJeName[$n])) -ForegroundColor White
        }
        if ($benutzer.Count) { Write-Info "+ $($benutzer.Count) Benutzer in jede $PrefixGG-Gruppe" }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    foreach ($n in $namen) {
        $k  = @($rechteJeName[$n])
        $gg = New-AdGruppe -Name "$PrefixGG$n" -Bereich Global -Ziel $ziel -Beschreibung "AGDLP: $n"
        $dl = New-AdGruppe -Name (Get-DLName $n $k) -Bereich DomainLocal -Ziel $zielDL -Beschreibung (Get-RechteText $k)
        if ($gg -and $dl) { Add-AdMitglied $dl.DistinguishedName $gg.DistinguishedName }
        if ($gg) { foreach ($b in $benutzer) { Add-AdMitglied $gg.DistinguishedName $b } }
        if ($dl) { Invoke-OrdnerSchritt $dl $k }
    }
}
#endregion

#region ======================= MODUL [6] ABTEILUNG ==================

function Start-Abteilung {
    Write-Titel 'Abteilung komplett anlegen'
    $unterText = if ($AbteilungsUnterOUs.Count) { $AbteilungsUnterOUs -join ', ' } else { 'keine' }
    Write-Info "Erstellt: OU <Name> mit Unter-OUs ($unterText) + $PrefixGG<Name>, optional $PrefixDL, Ordner und Benutzer."
    $ziel = Select-AdZiel 'die Abteilungs-OU' -OhneContainer
    $name = Read-Text 'Name der Abteilung (Enter = abbrechen)'
    if (-not $name) { Stop-Aktion }
    $kuerzel = @()
    if (Read-JaNein "Auch $PrefixDL-Gruppe mit Rechten erstellen?" $true) { $kuerzel = @(Select-Rechte $name) }
    $gruppenOU = if ($AbteilungsUnterOUs -contains $AbteilungGruppenOU) { $AbteilungGruppenOU } else { '' }

    if ($Funktionen.Vorschau) {
        $basis = "$(Get-Kurzpfad $ziel)/$name"
        $gPfad = if ($gruppenOU) { "$basis/$gruppenOU" } else { $basis }
        Write-Info 'Wird erstellt:'
        Write-Host "    OU      $basis" -ForegroundColor White
        foreach ($u in $AbteilungsUnterOUs) { Write-Host "    OU      $basis/$u" -ForegroundColor White }
        Write-Host "    Gruppe  $PrefixGG$name   in $gPfad" -ForegroundColor White
        if ($kuerzel.Count) { Write-Host "    Gruppe  $(Get-DLName $name $kuerzel)   in $gPfad" -ForegroundColor White }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }

    $abtDN = New-AdOU $name $ziel
    if (-not $abtDN) { return }
    $unter = @{}
    foreach ($u in $AbteilungsUnterOUs) {
        $dn = New-AdOU $u $abtDN
        if ($dn) { $unter[$u] = $dn }
    }
    $gruppenZiel = if ($gruppenOU -and $unter[$gruppenOU]) { $unter[$gruppenOU] } else { $abtDN }
    $gg = New-AdGruppe -Name "$PrefixGG$name" -Bereich Global -Ziel $gruppenZiel -Beschreibung "Abteilung $name"
    if ($kuerzel.Count) {
        $dl = New-AdGruppe -Name (Get-DLName $name $kuerzel) -Bereich DomainLocal -Ziel $gruppenZiel -Beschreibung (Get-RechteText $kuerzel)
        if ($gg -and $dl) { Add-AdMitglied $dl.DistinguishedName $gg.DistinguishedName }
        Invoke-OrdnerSchritt $dl $kuerzel
    }
    if ($Funktionen.Benutzer -and (Read-JaNein 'Jetzt gleich Benutzer für diese Abteilung erstellen?' $true)) {
        $benutzerZiel = if ($unter[$AbteilungBenutzerOU]) { $unter[$AbteilungBenutzerOU] } else { $abtDN }
        $standard = @()
        if ($gg) { $standard = @($gg.DistinguishedName) }
        Start-BenutzerAnlage -Ziel $benutzerZiel -StandardGruppen $standard -Abteilung $name
    }
}
#endregion

#region ======================= MODUL [7] MITGLIEDSCHAFTEN ===========

function Start-Mitgliedschaften {
    Write-Titel 'Mitglieder zu Gruppen hinzufügen'
    $art = if (Read-JaNein 'Benutzer hinzufügen? (n = Gruppen verschachteln)' $true) { 'Benutzer' } else { 'Gruppe' }
    $mitglieder = @(Select-AdObjekte -Art $art -Titel "Mitglieder wählen ($art)")
    if ($mitglieder.Count -eq 0) { Stop-Aktion }
    $gruppen = @(Select-AdObjekte -Art Gruppe -Titel 'Zielgruppe(n) wählen')
    if ($gruppen.Count -eq 0) { Stop-Aktion }
    if ($Funktionen.Vorschau -and -not (Read-JaNein "$($mitglieder.Count) Mitglied(er) in $($gruppen.Count) Gruppe(n) aufnehmen?" $true)) { Stop-Aktion }
    foreach ($g in $gruppen) { foreach ($m in $mitglieder) { Add-AdMitglied $g $m } }
}
#endregion

#region ======================= MODUL [8] RÜCKGÄNGIG =================

function Start-Rueckgaengig {
    Write-Titel 'Rückgängig machen (aus Protokoll)'
    $dateien = @(Get-ChildItem -LiteralPath $LogOrdner -Filter 'AD-Anlage_*.csv' -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)
    if ($dateien.Count -eq 0) { Write-Warnung 'Keine Protokolle gefunden.'; return }
    $eintraege = @($dateien | ForEach-Object {
        [pscustomobject]@{ Anzeige = '{0:dd.MM.yyyy HH:mm}   {1}' -f $_.LastWriteTime, $_.Name; Datei = $_.FullName }
    })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel 'Welches Protokoll rückgängig machen?')
    if ($wahl.Count -eq 0) { Stop-Aktion }

    $daten   = @(Import-Csv -LiteralPath $wahl[0].Datei -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Status -eq 'OK' })
    # Reihenfolge: zuerst DNS-Einträge, dann DNS-Zonen, dann AD (Mitglieder vor Objekten, OUs zuletzt)
    $typen   = 'DNS-Eintrag', 'DNS-Zone', 'Mitglied', 'Freigabe', 'Benutzer', 'Gruppe', 'OU'
    $adTypen = 'Mitglied', 'Benutzer', 'Gruppe', 'OU'
    $rueck   = @($daten | Where-Object { $typen -contains $_.Typ })
    $manuell = @($daten | Where-Object { $_.Typ -in 'Ordner', 'NTFS', 'Home' } | Select-Object -ExpandProperty DN -Unique)
    $hinweis = @($daten | Where-Object { $_.Typ -in 'DNS-Rolle', 'DNS-Forwarder' -or $_.Typ -like 'GPO*' -or $_.Typ -like 'DHCP*' })
    if ($rueck.Count -eq 0) {
        Write-Warnung 'In diesem Protokoll gibt es nichts zum Rückgängigmachen.'
        foreach ($h in $hinweis) { Write-Info "Wird nicht zurückgebaut: $($h.Typ) $($h.Name)" }
        return
    }

    Write-Info 'Wird entfernt:'
    foreach ($gruppe in ($rueck | Group-Object Typ)) { Write-Host ('    {0,-12} {1}' -f $gruppe.Name, $gruppe.Count) -ForegroundColor White }
    Write-Warnung 'Achtung: Diese Objekte werden aus AD bzw. DNS GELÖSCHT (nicht leere OUs und Zonen bleiben stehen).'
    if ("$(Read-Host "  Zum Bestätigen 'JA' eingeben")".Trim() -cne 'JA') { Stop-Aktion }

    $dns = Get-DnsParameter
    foreach ($typ in $typen) {
        $liste = @($rueck | Where-Object { $_.Typ -eq $typ })
        if ($typ -eq 'OU') { $liste = @($liste | Sort-Object { ($_.DN -split '(?<!\\),').Count } -Descending) }
        foreach ($e in $liste) {
            if ($adTypen -contains $typ -and -not $script:Faehig.AD) {
                Add-Ergebnis $typ $e.Name $e.DN 'FEHLER' 'Active Directory auf diesem Server nicht verfügbar - übersprungen'
                continue
            }
            if ($typ -like 'DNS-*' -and -not $script:Faehig.DNS) {
                Add-Ergebnis $typ $e.Name $e.DN 'FEHLER' 'DNS auf diesem Server nicht verfügbar - übersprungen'
                continue
            }
            try {
                switch ($typ) {
                    'DNS-Eintrag' {
                        # genau den protokollierten Eintrag (Name + Typ + Daten) suchen
                        $b      = ConvertFrom-DnsBezug $e.Bezug
                        $gesucht = Get-DnsBezug $b.Typ $b.Daten $b.Prioritaet
                        $treffer = @(Get-DnsServerResourceRecord -ZoneName $e.DN -Name $e.Name -RRType $b.Typ @dns -ErrorAction SilentlyContinue |
                                     Where-Object { "$($_.HostName)" -eq $e.Name -and (Get-DnsBezugAusRecord $_) -eq $gesucht })
                        if ($treffer.Count -eq 0) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        foreach ($rr in $treffer) { Remove-DnsServerResourceRecord -ZoneName $e.DN -InputObject $rr -Force @dns -ErrorAction Stop }
                    }
                    'DNS-Zone' {
                        if (-not (Get-DnsServerZone -Name $e.DN @dns -ErrorAction SilentlyContinue)) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        $inhalt = @(Get-DnsServerResourceRecord -ZoneName $e.DN @dns -ErrorAction Stop | Where-Object { "$($_.RecordType)" -notin 'SOA', 'NS' })
                        if ($inhalt.Count) { throw "Zone ist nicht leer ($($inhalt.Count) Einträge) - bleibt stehen." }
                        Remove-DnsServerZone -Name $e.DN -Force @dns -ErrorAction Stop
                    }
                    'Mitglied' {
                        if (-not ((Test-AdObjekt $e.DN) -and (Test-AdObjekt $e.Bezug))) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        Remove-ADGroupMember -Identity $e.DN -Members $e.Bezug -Confirm:$false -ErrorAction Stop
                    }
                    'Freigabe' {
                        if (-not (Get-SmbShare -Name $e.Name -ErrorAction SilentlyContinue)) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        Remove-SmbShare -Name $e.Name -Force -ErrorAction Stop
                    }
                    'Benutzer' {
                        if (-not (Test-AdObjekt $e.DN)) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        Remove-ADUser -Identity $e.DN -Confirm:$false -ErrorAction Stop
                    }
                    'Gruppe' {
                        if (-not (Test-AdObjekt $e.DN)) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        Remove-ADGroup -Identity $e.DN -Confirm:$false -ErrorAction Stop
                    }
                    'OU' {
                        if (-not (Test-AdObjekt $e.DN)) { throw [System.Management.Automation.ItemNotFoundException]::new('existiert nicht mehr') }
                        if (Get-ADObject -SearchBase $e.DN -SearchScope OneLevel -Filter * | Select-Object -First 1) { throw 'OU ist nicht leer - bleibt stehen.' }
                        Set-ADOrganizationalUnit -Identity $e.DN -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
                        Remove-ADOrganizationalUnit -Identity $e.DN -Confirm:$false -ErrorAction Stop
                    }
                }
                Add-Ergebnis $typ $e.Name $e.DN 'ENTFERNT' -Bezug $e.Bezug
            }
            catch [System.Management.Automation.ItemNotFoundException] { Add-Ergebnis $typ $e.Name $e.DN 'FEHLT' 'existiert nicht mehr' }
            catch { Add-Ergebnis $typ $e.Name $e.DN 'FEHLER' $_.Exception.Message }
        }
    }
    if ($manuell.Count) {
        Write-Warnung 'Nicht automatisch entfernt (Ordner, NTFS-Rechte, Home-Ordner) - bei Bedarf von Hand löschen:'
        foreach ($m in $manuell) { Write-Info $m }
    }
    if ($hinweis.Count) {
        Write-Warnung 'Nicht zurückgebaut (bei Bedarf von Hand bzw. unter [G] / [H] entfernen): Rollen, Weiterleitungen, Gruppenrichtlinien, DHCP'
        foreach ($h in $hinweis) { Write-Info "$($h.Typ): $($h.Name)  $($h.Info)" }
    }
}
#endregion

#region ======================= DNS-HILFSFUNKTIONEN (ohne Server) ====

# 'IPv4', 'IPv6' oder '' (streng: 192.168.10 oder 010.1.1.1 gelten nicht als IPv4)
function Get-IpArt([string]$Text) {
    $t = "$Text".Trim()
    $oktett = '(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
    if ($t -match "^$oktett(\.$oktett){3}$") { return 'IPv4' }
    $adr = $null
    if ($t.Contains(':') -and [System.Net.IPAddress]::TryParse($t, [ref]$adr) -and
        $adr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return 'IPv6' }
    return ''
}

# Kommaliste von IP-Adressen prüfen -> Gueltig (normalisiert) und Ungueltig
function ConvertFrom-IpListe([string]$Text) {
    $gueltig   = [System.Collections.Generic.List[string]]::new()
    $ungueltig = [System.Collections.Generic.List[string]]::new()
    foreach ($teil in ($Text -split '[,; ]+' | Where-Object { $_ })) {
        if (Get-IpArt $teil) {
            $ip = ([System.Net.IPAddress]::Parse($teil)).ToString()
            if (-not $gueltig.Contains($ip)) { $gueltig.Add($ip) }
        }
        else { $ungueltig.Add($teil) }
    }
    return [pscustomobject]@{ Gueltig = $gueltig.ToArray(); Ungueltig = $ungueltig.ToArray() }
}

# Hostname nach RFC 1123 prüfen: '' = in Ordnung, sonst der Grund
function Get-DnsHostnameFehler([string]$Name) {
    if (-not $Name) { return 'Name ist leer' }
    $n = $Name
    if ($n.EndsWith('.')) { $n = $n.Substring(0, $n.Length - 1) }
    if (-not $n) { return 'Name ist leer' }
    if ($n.Length -gt 253) { return 'Name ist länger als 253 Zeichen' }
    foreach ($label in $n.Split('.')) {
        if (-not $label) { return 'leerer Namensteil (zwei Punkte hintereinander)' }
        if ($label.Length -gt 63) { return "Namensteil '$($label.Substring(0, 10))...' ist länger als 63 Zeichen ($($label.Length))" }
        if ($label -match '[^A-Za-z0-9\-]') {
            if ($label -match '[äöüÄÖÜß]') { return "Umlaute sind nicht erlaubt ('$label' -> '$(ConvertTo-AdName $label)')" }
            return "ungültige Zeichen in '$label' (erlaubt: a-z, 0-9 und -)"
        }
        if ($label.StartsWith('-') -or $label.EndsWith('-')) { return "'$label' darf nicht mit - beginnen oder enden" }
    }
    return ''
}

function Test-DnsHostname([string]$Name) {
    return (-not (Get-DnsHostnameFehler $Name))
}

# TTL-Text (hh:mm:ss oder t.hh:mm:ss) -> TimeSpan, ungültig oder 0 -> $null
function ConvertTo-DnsTtl([string]$Text) {
    $t = "$Text".Trim()
    if ($t -notmatch '^(\d{1,3}\.)?\d{1,2}:[0-5]\d:[0-5]\d$') { return $null }
    $ts = [timespan]::Zero
    if (-not [timespan]::TryParse($t, [ref]$ts)) { return $null }
    if ($ts -le [timespan]::Zero) { return $null }
    return $ts
}

# Ziel eines CNAME/MX vervollständigen: ohne Punkt = in dieser Zone, mit Punkt = vollständiger Name
function Resolve-DnsZielName([string]$Ziel, [string]$Zone) {
    $zoneNorm = $Zone.TrimEnd('.').ToLower()
    $z = $Ziel.Trim().ToLower()
    if ($z -eq '@') { return "$zoneNorm." }
    if ($z.Contains('.')) { return $z.TrimEnd('.') + '.' }
    return "$z.$zoneNorm."
}

# HostName eines Server-Eintrags (immer relativ zur Zone, auch mit Punkt: gc._msdcs) -> vollständiger Name
function Get-DnsFqdn([string]$HostName, [string]$Zone) {
    $zoneNorm = "$Zone".Trim().TrimEnd('.').ToLower()
    $h = "$HostName".Trim().TrimEnd('.').ToLower()
    if (-not $h -or $h -eq '@') { return "$zoneNorm." }
    return "$h.$zoneNorm."
}

# Dienst-Name: ein Namensteil beginnt mit _ (z.B. gc._msdcs, _ldap._tcp) -> nie PTR-Ziel
function Test-DnsDienstName([string]$HostName) {
    return [bool](@("$HostName".Split('.') | Where-Object { $_.StartsWith('_') }).Count)
}

# Rang als PTR-Ziel: 0 = echter Hostname, 1 = @ / DomainDnsZones / ForestDnsZones, 2 = Dienst-Name
function Get-DnsPtrRang([string]$HostName) {
    if (Test-DnsDienstName $HostName) { return 2 }
    if ("$HostName" -in '@', 'DomainDnsZones', 'ForestDnsZones') { return 1 }
    return 0
}

# A/AAAA-Kandidaten (Zone, HostName, Ip) aus allen Zonen global sortieren; pro Reverse-Name gewinnt
# der erste. Rückgabe: MitZone (Reverse-Zone vorhanden), OhneZone (mit Vorschlag), NurDienst (kein PTR)
function Select-DnsPtrKandidaten([object[]]$Kandidaten, [string[]]$ReverseZonen) {
    $mitZone   = [System.Collections.Generic.List[object]]::new()
    $ohneZone  = [System.Collections.Generic.List[object]]::new()
    $nurDienst = [System.Collections.Generic.List[object]]::new()
    $gesehen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liste = @($Kandidaten | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Fqdn = (Get-DnsFqdn $_.HostName $_.Zone); Rang = (Get-DnsPtrRang $_.HostName); Ziel = (Get-PtrZielFuerIp $_.Ip $ReverseZonen) }
    } | Where-Object { -not $_.Ziel.Fehler } | Sort-Object Rang, Fqdn)
    foreach ($k in $liste) {
        # Dienst-Namen stehen zuletzt: kommt eine IP erst hier vor, hat sie nur Dienst-Namen
        if (-not $gesehen.Add($k.Ziel.VollName)) { continue }
        $eintrag = [pscustomobject]@{
            Ip = $k.Ziel.Ip; Fqdn = $k.Fqdn; Zone = $k.Ziel.Zone; Name = $k.Ziel.Name
            VorschlagNetz = $k.Ziel.VorschlagNetz; VorschlagZone = $k.Ziel.VorschlagZone
        }
        if ($k.Rang -eq 2)    { $nurDienst.Add($eintrag) }
        elseif ($k.Ziel.Zone) { $mitZone.Add($eintrag) }
        else                  { $ohneZone.Add($eintrag) }
    }
    return [pscustomobject]@{ MitZone = $mitZone.ToArray(); OhneZone = $ohneZone.ToArray(); NurDienst = $nurDienst.ToArray() }
}

# Adressen ohne Reverse-Zone nach vorgeschlagenem Netz (/24) gruppieren, sortiert nach Netz.
# Ohne Vorschlag (IPv6) fallen sie weg. Je Netz: Anzeige, Netz, Zone, Adressen
function Group-DnsOhneZoneNachNetz([object[]]$OhneZone) {
    $liste = foreach ($g in @($OhneZone | Where-Object { $_ -and $_.VorschlagNetz } | Group-Object VorschlagNetz)) {
        $adressen = @($g.Group)
        $namen    = @($adressen | ForEach-Object { $_.Fqdn } | Select-Object -Unique)
        $text     = (@($namen | Select-Object -First 3) -join ', ') + $(if ($namen.Count -gt 3) { ', …' } else { '' })
        $wort     = if ($adressen.Count -eq 1) { 'Adresse' } else { 'Adressen' }
        $o        = $g.Name.Split('/')[0].Split('.')
        [pscustomobject]@{
            Anzeige  = '{0,-18} ->  {1,-26} ({2} {3}: {4})' -f $g.Name, $adressen[0].VorschlagZone, $adressen.Count, $wort, $text
            Netz     = $g.Name
            Zone     = $adressen[0].VorschlagZone
            Adressen = $adressen
            Sortierung = [int64]$o[0] * 16777216 + [int64]$o[1] * 65536 + [int64]$o[2] * 256
        }
    }
    return @($liste | Sort-Object Sortierung | Select-Object Anzeige, Netz, Zone, Adressen)
}

# Vergleichs- und Protokolltext "<Typ>|<Daten>" (MX: "MX|<Ziel>|<Priorität>"), normalisiert
function Get-DnsBezug([string]$Typ, [string]$Daten, [string]$Prioritaet = '') {
    $t = $Typ.ToUpper()
    $d = "$Daten".Trim()
    if ($t -eq 'A' -or $t -eq 'AAAA') {
        $adr = $null
        if ([System.Net.IPAddress]::TryParse($d, [ref]$adr)) { $d = $adr.ToString() }
    }
    elseif ($t -in 'CNAME', 'MX', 'PTR', 'NS') {
        $d = $d.ToLower()
        if ($d -and -not $d.EndsWith('.')) { $d += '.' }
    }
    if ($t -eq 'MX') {
        $p = 0
        [void][int]::TryParse("$Prioritaet", [ref]$p)
        return "MX|$d|$p"
    }
    return "$t|$d"
}

function ConvertFrom-DnsBezug([string]$Bezug) {
    $teile = @("$Bezug" -split '\|')
    $daten = ''
    $prio  = ''
    if ($teile.Count -gt 1) { $daten = $teile[1] }
    if ($teile.Count -gt 2) { $prio  = $teile[2] }
    return [pscustomobject]@{ Typ = $teile[0]; Daten = $daten; Prioritaet = $prio }
}

# DNS-Eintrag vom Server (Get-DnsServerResourceRecord) -> Typ/Name/Daten/Prioritaet
function ConvertFrom-DnsRecord($Record) {
    $d     = $Record.RecordData
    $typ   = "$($Record.RecordType)".ToUpper()
    $daten = ''
    $prio  = ''
    switch ($typ) {
        'A'     { $daten = "$($d.IPv4Address)" }
        'AAAA'  { $daten = "$($d.IPv6Address)" }
        'CNAME' { $daten = "$($d.HostNameAlias)" }
        'MX'    { $daten = "$($d.MailExchange)"; $prio = "$($d.Preference)" }
        'PTR'   { $daten = "$($d.PtrDomainName)" }
        'NS'    { $daten = "$($d.NameServer)" }
    }
    return [pscustomobject]@{ Typ = $typ; Name = "$($Record.HostName)"; Daten = $daten; Prioritaet = $prio }
}

function Get-DnsBezugAusRecord($Record) {
    $r = ConvertFrom-DnsRecord $Record
    return (Get-DnsBezug $r.Typ $r.Daten $r.Prioritaet)
}

# Neuer Eintrag gegen vorhandene Einträge mit gleichem Namen prüfen.
# Art: Neu | Vorhanden (exakt gleich) | Anders (gleicher Typ, anderer Wert) | Fehler (CNAME-Regel)
function Get-DnsKonflikt($Neu, [object[]]$Vorhandene) {
    $vorh     = @($Vorhandene | Where-Object { $_ })
    $schluessel = Get-DnsBezug $Neu.Typ $Neu.Daten $Neu.Prioritaet
    $ergebnis = [pscustomobject]@{ Art = 'Neu'; Grund = ''; Werte = '' }
    if (@($vorh | Where-Object { (Get-DnsBezug $_.Typ $_.Daten $_.Prioritaet) -eq $schluessel }).Count) {
        $ergebnis.Art = 'Vorhanden'
        return $ergebnis
    }
    $cnames = @($vorh | Where-Object { $_.Typ -eq 'CNAME' })
    $andere = @($vorh | Where-Object { $_.Typ -notin 'SOA', 'NS' })
    if ($Neu.Typ -eq 'CNAME') {
        if ($cnames.Count) {
            $ergebnis.Art = 'Fehler'; $ergebnis.Grund = "Name hat schon einen CNAME auf $($cnames[0].Daten)"
        }
        elseif ($andere.Count) {
            $typen = (@($andere | ForEach-Object { $_.Typ } | Select-Object -Unique) -join ', ')
            $ergebnis.Art = 'Fehler'; $ergebnis.Grund = "Name hat schon andere Einträge ($typen) - ein CNAME darf nicht neben anderen Einträgen stehen"
        }
        return $ergebnis
    }
    if ($cnames.Count) {
        $ergebnis.Art = 'Fehler'; $ergebnis.Grund = "Name ist ein CNAME auf $($cnames[0].Daten) - keine weiteren Einträge möglich"
        return $ergebnis
    }
    $gleicherTyp = @($vorh | Where-Object { $_.Typ -eq $Neu.Typ })
    if ($gleicherTyp.Count) {
        $ergebnis.Art   = 'Anders'
        $ergebnis.Werte = (@($gleicherTyp | ForEach-Object { if ($_.Prioritaet) { "$($_.Prioritaet) $($_.Daten)" } else { $_.Daten } }) -join ', ')
    }
    return $ergebnis
}

# Einen Teil der Schnelleingabe auswerten (name=wert)
function ConvertFrom-DnsSchnellTeil([string]$Teil, [string]$Zone) {
    $e = [pscustomobject]@{ Eingabe = $Teil; Typ = ''; Name = ''; Daten = ''; Prioritaet = ''; Fehler = ''; Hinweis = '' }
    $zoneNorm = $Zone.TrimEnd('.').ToLower()
    $pos = $Teil.IndexOf('=')
    if ($pos -lt 1) { $e.Fehler = 'Format: name=wert (z.B. srv01=192.168.10.5)'; return $e }
    $name = $Teil.Substring(0, $pos).Trim()
    $wert = $Teil.Substring($pos + 1).Trim()

    # Name: @ = Zonenstamm, vollständige Namen der Zone werden gekürzt
    if ($name -ne '@') {
        $nl = $name.TrimEnd('.').ToLower()
        if ($nl -eq $zoneNorm) { $name = '@' }
        elseif ($zoneNorm -and $nl.EndsWith(".$zoneNorm")) { $name = $name.TrimEnd('.').Substring(0, $nl.Length - $zoneNorm.Length - 1) }
        elseif ($name.EndsWith('.')) { $e.Fehler = "'$name' gehört nicht zur Zone $Zone"; return $e }
    }
    if ($name -ne '@') {
        $fehler = Get-DnsHostnameFehler $name
        if ($fehler) { $e.Fehler = $fehler; return $e }
        $name = $name.ToLower()
    }
    $e.Name = $name
    if (-not $wert) { $e.Fehler = 'Wert fehlt'; return $e }

    if ($wert -match '^MX:') {
        $mx   = @($wert.Substring(3) -split ':')
        $ziel = $mx[0].Trim()
        $prio = ''
        if ($mx.Count -gt 1) { $prio = $mx[1].Trim() }
        if (-not $ziel) { $e.Fehler = 'MX: Ziel fehlt (Format @=MX:mail:10)'; return $e }
        if ($ziel -ne '@') {
            $fehler = Get-DnsHostnameFehler $ziel
            if ($fehler) { $e.Fehler = "MX-Ziel: $fehler"; return $e }
        }
        if (-not $prio) { $prio = '10'; $e.Hinweis = 'Priorität fehlt - 10 angenommen' }
        elseif ($prio -notmatch '^\d{1,5}$' -or [int]$prio -gt 65535) { $e.Fehler = "MX-Priorität '$prio' muss eine Zahl von 0 bis 65535 sein"; return $e }
        $e.Typ        = 'MX'
        $e.Daten      = Resolve-DnsZielName $ziel $Zone
        $e.Prioritaet = [string][int]$prio
        return $e
    }

    $art = Get-IpArt $wert
    if ($art -eq 'IPv4') { $e.Typ = 'A';    $e.Daten = $wert; return $e }
    if ($art -eq 'IPv6') { $e.Typ = 'AAAA'; $e.Daten = ([System.Net.IPAddress]::Parse($wert)).ToString(); return $e }
    if ($wert -match '^[\d.]+$') { $e.Fehler = "'$wert' ist keine gültige IPv4-Adresse"; return $e }
    if ($wert.Contains(':'))     { $e.Fehler = "'$wert' ist keine gültige IPv6-Adresse"; return $e }

    # sonst: CNAME auf einen Hostnamen
    if ($name -eq '@') { $e.Fehler = 'CNAME am Zonenstamm (@) ist nicht erlaubt'; return $e }
    $fehler = Get-DnsHostnameFehler $wert
    if ($fehler) { $e.Fehler = "Ziel: $fehler"; return $e }
    $e.Typ   = 'CNAME'
    $e.Daten = Resolve-DnsZielName $wert $Zone
    if ($e.Daten -eq "$name.$zoneNorm.") { $e.Typ = ''; $e.Daten = ''; $e.Fehler = 'CNAME zeigt auf sich selbst'; return $e }
    return $e
}

# Schnelleingabe "srv01=192.168.10.5, www=srv01; @=MX:mail:10" -> ein Objekt je Teil
# (Typ/Name/Daten/Prioritaet/Fehler/Hinweis). Ungültige Teile haben Fehler gesetzt.
function ConvertFrom-DnsSchnelleingabe([string]$Text, [string]$Zone) {
    $liste = [System.Collections.Generic.List[object]]::new()
    foreach ($teil in ("$Text" -split '[,;]')) {
        $roh = $teil.Trim()
        if ($roh) { $liste.Add((ConvertFrom-DnsSchnellTeil $roh $Zone)) }
    }
    return $liste.ToArray()
}

# Netz "192.168.10.0/24", "192.168.10" oder "10.0.0.0/8" -> Reverse-Zone (nur /8, /16, /24)
function ConvertTo-ReverseZonenName([string]$Netz) {
    $e = [pscustomobject]@{ Eingabe = $Netz; Zone = ''; NetworkId = ''; Praefix = 0; Fehler = '' }
    $t = "$Netz".Trim()
    if ($t.Contains(':')) { $e.Fehler = 'Nur IPv4-Netze (192.168.10.0/24, 172.16.0.0/16, 10.0.0.0/8)'; return $e }
    if ($t -notmatch '^(\d{1,3}(?:\.\d{1,3}){0,3})(?:/(\d{1,2}))?$') { $e.Fehler = 'Format: 192.168.10.0/24, 192.168.10 oder 10.0.0.0/8'; return $e }
    $teilText = $Matches[1]
    $praefixText = $Matches[2]
    $oktette = @($teilText -split '\.' | ForEach-Object { [int]$_ })
    if (@($oktette | Where-Object { $_ -gt 255 }).Count) { $e.Fehler = "'$t': eine Zahl ist größer als 255"; return $e }
    if ($praefixText) { $praefix = [int]$praefixText } else { $praefix = [Math]::Min(3, $oktette.Count) * 8 }
    if ($praefix -notin 8, 16, 24) { $e.Fehler = "Präfix /$praefix geht nicht - nur /8, /16 oder /24 (klassenlose Reverse-Zonen sind nicht enthalten)"; return $e }
    $anzahl = [int]($praefix / 8)
    if ($oktette.Count -lt $anzahl) { $e.Fehler = "Für /$praefix braucht es mindestens $anzahl Zahlen vor dem /"; return $e }
    $voll  = @(0, 0, 0, 0)
    $rueck = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $anzahl; $i++) { $voll[$i] = [int]$oktette[$i] }
    for ($i = $anzahl - 1; $i -ge 0; $i--) { $rueck.Add([string]$oktette[$i]) }
    $e.Praefix   = $praefix
    $e.NetworkId = '{0}.{1}.{2}.{3}/{4}' -f $voll[0], $voll[1], $voll[2], $voll[3], $praefix
    $e.Zone      = ($rueck.ToArray() -join '.') + '.in-addr.arpa'
    return $e
}

# Vollständiger Reverse-Name einer IP: 192.168.10.5 -> 5.10.168.192.in-addr.arpa (IPv6: ip6.arpa)
function Get-ReverseName([string]$Ip) {
    $art = Get-IpArt $Ip
    if (-not $art) { return '' }
    $bytes = ([System.Net.IPAddress]::Parse($Ip.Trim())).GetAddressBytes()
    if ($art -eq 'IPv4') { return ('{0}.{1}.{2}.{3}.in-addr.arpa' -f $bytes[3], $bytes[2], $bytes[1], $bytes[0]) }
    $nibbles = (-join ($bytes | ForEach-Object { '{0:x2}' -f $_ })).ToCharArray()
    [array]::Reverse($nibbles)
    return (($nibbles -join '.') + '.ip6.arpa')
}

# Passende (längste) Reverse-Zone für eine IP finden. Ohne Treffer bei IPv4: Vorschlag /24
function Get-PtrZielFuerIp([string]$Ip, [string[]]$ReverseZonen) {
    $ergebnis = [pscustomobject]@{ Ip = $Ip; Zone = ''; Name = ''; VollName = ''; VorschlagNetz = ''; VorschlagZone = ''; Fehler = '' }
    $voll = Get-ReverseName $Ip
    if (-not $voll) { $ergebnis.Fehler = "'$Ip' ist keine gültige IP-Adresse"; return $ergebnis }
    $ergebnis.VollName = $voll
    $beste = @($ReverseZonen | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('.').ToLower() } |
               Where-Object { $voll -eq $_ -or $voll.EndsWith(".$_") } | Sort-Object Length -Descending) | Select-Object -First 1
    if ($beste) {
        $ergebnis.Zone = $beste
        $ergebnis.Name = if ($voll -eq $beste) { '@' } else { $voll.Substring(0, $voll.Length - $beste.Length - 1) }
    }
    elseif ((Get-IpArt $Ip) -eq 'IPv4') {
        $o = $Ip.Trim().Split('.')
        $ergebnis.VorschlagNetz = "$($o[0]).$($o[1]).$($o[2]).0/24"
        $ergebnis.VorschlagZone = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    }
    return $ergebnis
}

# Erkennt die Meldung "Quelldateien nicht gefunden" von Install-WindowsFeature (offline / Feature entfernt)
function Test-QuelleFehlt([string]$Meldung) {
    return ($Meldung -match '0x800f081f|0x800f0906|0x800f0907|0x800f0950|source files could not be (found|downloaded)|Quelldateien')
}
#endregion

#region ======================= DNS-SERVER ==========================

# Parameter für alle *-DnsServer*-Aufrufe (leer = dieser Server)
function Get-DnsParameter {
    if ($DnsServerName) { return @{ ComputerName = $DnsServerName } }
    return @{}
}

function Get-DnsServerAnzeige {
    if ($DnsServerName) { return $DnsServerName }
    return "$env:COMPUTERNAME (lokal)"
}

# Primäre Zonen des Servers (ohne automatisch erzeugte und TrustAnchors)
function Get-DnsZonen([switch]$Forward, [switch]$Reverse) {
    $dns = Get-DnsParameter
    $zonen = @(Get-DnsServerZone @dns -ErrorAction Stop |
               Where-Object { -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' -and "$($_.ZoneType)" -eq 'Primary' })
    if ($Forward) { $zonen = @($zonen | Where-Object { -not $_.IsReverseLookupZone }) }
    if ($Reverse) { $zonen = @($zonen | Where-Object { $_.IsReverseLookupZone }) }
    return @($zonen | Sort-Object ZoneName)
}

function Select-DnsZone([string]$Titel, [object[]]$Zonen) {
    if (-not $Zonen -or $Zonen.Count -eq 0) { Write-Warnung 'Keine passende Zone vorhanden - zuerst unter [3] bzw. [4] anlegen.'; Stop-Aktion }
    $eintraege = @($Zonen | ForEach-Object {
        $art = if ($_.IsDsIntegrated) { 'AD-integriert' } else { 'Datei' }
        [pscustomobject]@{ Anzeige = '{0,-40} {1}' -f $_.ZoneName, $art; Zone = $_.ZoneName }
    })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel $Titel)
    if ($wahl.Count -eq 0) { Stop-Aktion }
    Write-Ok "Zone: $($wahl[0].Zone)"
    return $wahl[0].Zone
}

# Ist der DNS-Server ein Domänencontroller? Nur dann sind AD-integrierte Zonen möglich
function Test-DnsServerIstDc {
    if (-not $script:Faehig.AD) { return $false }
    if (-not $script:Faehig.DnsEntfernt) {
        try   { return ((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 4) }
        catch { return $false }
    }
    try   { $null = Get-ADDomainController -Identity $DnsServerName -ErrorAction Stop; return $true }
    catch { return $false }
}

# Fragt AD-Integration und dynamische Updates für neue Zonen ab
function Read-DnsZonenOptionen {
    $ad = $false
    if (Test-DnsServerIstDc) { $ad = Read-JaNein "AD-integriert anlegen (Replikation: $DnsReplikation)?" $true }
    else { Write-Info 'DNS-Server ist kein Domänencontroller - Zonen werden als Datei angelegt (<name>.dns).' }
    $vorschlag = if ($ad) { 'Secure' } else { 'None' }
    $erlaubt   = 'Secure', 'NonsecureAndSecure', 'None'
    while ($true) {
        $antwort = Read-Text 'Dynamische Updates (Secure / NonsecureAndSecure / None)' $vorschlag
        $dyn = @($erlaubt | Where-Object { $_ -eq $antwort }) | Select-Object -First 1
        if ($dyn) { break }
        Write-Warnung 'Bitte Secure, NonsecureAndSecure oder None eingeben.'
    }
    if ($dyn -eq 'Secure' -and -not $ad) { Write-Warnung 'Secure geht nur bei AD-integrierten Zonen - nehme None.'; $dyn = 'None' }
    return [pscustomobject]@{ AdIntegriert = $ad; DynamicUpdate = $dyn }
}

# Zone anlegen (vorhanden -> VORHANDEN). $NetworkId gesetzt = Reverse-Zone
function New-DnsZone {
    param([string]$Zone, [string]$NetworkId = '', $Optionen)
    $dns      = Get-DnsParameter
    $richtung = if ($NetworkId) { 'Reverse' } else { 'Forward' }
    if (Get-DnsServerZone -Name $Zone @dns -ErrorAction SilentlyContinue) { Add-Ergebnis 'DNS-Zone' $Zone $Zone 'VORHANDEN' $richtung; return $true }
    $param = @{ DynamicUpdate = $Optionen.DynamicUpdate; ErrorAction = 'Stop' }
    if ($NetworkId) { $param.NetworkId = $NetworkId } else { $param.Name = $Zone }
    if ($Optionen.AdIntegriert) { $param.ReplicationScope = $DnsReplikation } else { $param.ZoneFile = "$Zone.dns" }
    $art = if ($Optionen.AdIntegriert) { "AD-integriert ($DnsReplikation)" } else { "Datei $Zone.dns" }
    try {
        Add-DnsServerPrimaryZone @param @dns
        Add-Ergebnis 'DNS-Zone' $Zone $Zone 'OK' "$richtung, $art, Updates: $($Optionen.DynamicUpdate)" -Bezug $richtung
        return $true
    }
    catch {
        Add-Ergebnis 'DNS-Zone' $Zone $Zone 'FEHLER' $_.Exception.Message
        return $false
    }
}

# Vorhandene Einträge mit genau diesem Namen (als Typ/Daten-Objekte)
function Get-DnsVorhandene([string]$Zone, [string]$Name) {
    $dns = Get-DnsParameter
    return @(Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name @dns -ErrorAction SilentlyContinue |
               Where-Object { "$($_.HostName)" -eq $Name } | ForEach-Object { ConvertFrom-DnsRecord $_ })
}

# Plan für einen Eintrag: Konflikte prüfen, bei anderem Wert nachfragen
function New-DnsEintragPlan([string]$Zone, [string]$Typ, [string]$Name, [string]$Daten, [string]$Prioritaet = '') {
    $plan = [pscustomobject]@{ Zone = $Zone; Typ = $Typ; Name = $Name; Daten = $Daten; Prioritaet = $Prioritaet; Art = 'Neu'; Grund = '' }
    $k = Get-DnsKonflikt $plan (Get-DnsVorhandene $Zone $Name)
    $plan.Art   = $k.Art
    $plan.Grund = $k.Grund
    if ($k.Art -eq 'Anders') {
        $anzeige = if ($Name -eq '@') { $Zone } else { "$Name.$Zone" }
        if ($Typ -eq 'PTR') {
            $plan.Art = 'Uebersprungen'; $plan.Grund = "PTR zeigt schon auf $($k.Werte)"
        }
        else {
            Write-Warnung "$anzeige hat schon $Typ = $($k.Werte)"
            if (Read-JaNein "Zusätzlich $Typ = $Daten anlegen?" $false) { $plan.Art = 'Neu' }
            else { $plan.Art = 'Uebersprungen'; $plan.Grund = "anderer Wert vorhanden ($($k.Werte)), nicht zusätzlich angelegt" }
        }
    }
    return $plan
}

function Write-DnsPlanZeile($Plan) {
    $wert = if ($Plan.Typ -eq 'MX') { "$($Plan.Prioritaet) $($Plan.Daten)" } else { $Plan.Daten }
    $text = '    {0,-6} {1,-24} -> {2,-32} {3}' -f $Plan.Typ, $Plan.Name, $wert, $Plan.Zone
    switch ($Plan.Art) {
        'Neu'           { Write-Host $text -ForegroundColor White }
        'Vorhanden'     { Write-Host "$text   (vorhanden)" -ForegroundColor Yellow }
        'Uebersprungen' { Write-Host "$text   (übersprungen: $($Plan.Grund))" -ForegroundColor DarkYellow }
        default         { Write-Host "$text   (FEHLER: $($Plan.Grund))" -ForegroundColor Red }
    }
}

# Plan ausführen und protokollieren: Name = Hostname, DN = Zone, Bezug = <Typ>|<Daten>
function Invoke-DnsEintragPlan($Plan, $Ttl) {
    $bezug = Get-DnsBezug $Plan.Typ $Plan.Daten $Plan.Prioritaet
    $info  = "$($Plan.Typ) $($Plan.Daten)"
    switch ($Plan.Art) {
        'Vorhanden'     { Add-Ergebnis 'DNS-Eintrag' $Plan.Name $Plan.Zone 'VORHANDEN' $info; return }
        'Uebersprungen' { Add-Ergebnis 'DNS-Eintrag' $Plan.Name $Plan.Zone 'UEBERSPRUNGEN' $Plan.Grund; return }
        'Fehler'        { Add-Ergebnis 'DNS-Eintrag' $Plan.Name $Plan.Zone 'FEHLER' $Plan.Grund; return }
    }
    $dns   = Get-DnsParameter
    $param = @{ ZoneName = $Plan.Zone; Name = $Plan.Name; ErrorAction = 'Stop' }
    if ($Ttl) { $param.TimeToLive = $Ttl }
    try {
        switch ($Plan.Typ) {
            'A'     { Add-DnsServerResourceRecordA     @param @dns -IPv4Address $Plan.Daten }
            'AAAA'  { Add-DnsServerResourceRecordAAAA  @param @dns -IPv6Address $Plan.Daten }
            'CNAME' { Add-DnsServerResourceRecordCName @param @dns -HostNameAlias $Plan.Daten }
            'MX'    { Add-DnsServerResourceRecordMX    @param @dns -MailExchange $Plan.Daten -Preference ([uint16]$Plan.Prioritaet) }
            'PTR'   { Add-DnsServerResourceRecordPtr   @param @dns -PtrDomainName $Plan.Daten }
        }
        Add-Ergebnis 'DNS-Eintrag' $Plan.Name $Plan.Zone 'OK' $info -Bezug $bezug
    }
    catch { Add-Ergebnis 'DNS-Eintrag' $Plan.Name $Plan.Zone 'FEHLER' $_.Exception.Message }
}

function Read-DnsTtl {
    while ($true) {
        $text = Read-Text 'TTL (hh:mm:ss)' $DnsStandardTTL -Pflicht
        $ttl  = ConvertTo-DnsTtl $text
        if ($ttl) { return $ttl }
        Write-Warnung 'Bitte im Format hh:mm:ss eingeben, z.B. 01:00:00.'
    }
}
#endregion

#region ======================= MODUL [D] DNS ========================

function Get-DnsMenue {
    $f = $script:Faehig
    return @(
        [pscustomobject]@{ Taste = '1'; Text = 'Status: Rolle, Dienst, Zonen';                    An = $true;                                                              Braucht = @();                 Aktion = { Show-DnsStatus } }
        [pscustomobject]@{ Taste = '2'; Text = 'DNS-Rolle installieren';                          An = ($Funktionen.DnsRolle -and -not $f.DnsRolle -and -not $f.DnsEntfernt); Braucht = @('ServerManager'); Aktion = { Install-DnsRolle } }
        [pscustomobject]@{ Taste = '3'; Text = 'Forward-Zone(n) erstellen';                       An = $Funktionen.DnsZonen;                                               Braucht = @('DNS');            Aktion = { Start-DnsForwardZonen } }
        [pscustomobject]@{ Taste = '4'; Text = 'Reverse-Zone(n) erstellen (Netz /8, /16, /24)';   An = $Funktionen.DnsZonen;                                               Braucht = @('DNS');            Aktion = { Start-DnsReverseZonen } }
        [pscustomobject]@{ Taste = '5'; Text = 'Einträge erstellen (Schnelleingabe, A/AAAA/CNAME/MX + PTR)'; An = $Funktionen.DnsEintraege;                                Braucht = @('DNS');            Aktion = { Start-DnsEintraege } }
        [pscustomobject]@{ Taste = '6'; Text = 'Fehlende PTR-Einträge auffüllen';                 An = $Funktionen.DnsPTRAuffuellen;                                       Braucht = @('DNS');            Aktion = { Start-DnsPtrAuffuellen } }
        [pscustomobject]@{ Taste = '7'; Text = 'Weiterleitungen (Forwarder)';                     An = $Funktionen.DnsWeiterleitung;                                       Braucht = @('DNS');            Aktion = { Start-DnsWeiterleitungen } }
        [pscustomobject]@{ Taste = '8'; Text = 'Namensauflösung testen';                          An = $Funktionen.DnsTest;                                                Braucht = @('DNS', 'DnsClient'); Aktion = { Start-DnsTest } }
    )
}

function Start-DnsMenue {
    while ($true) {
        $sichtbar = @()
        $gruende  = @()
        foreach ($m in @(Get-DnsMenue | Where-Object { $_.An })) {
            $grund = Get-FehlendeFaehigkeit $m.Braucht $script:Faehig
            if (-not $grund) { $sichtbar += $m }
            elseif ($gruende -notcontains $grund) { $gruende += $grund }
        }
        Write-Titel "DNS   Server: $(Get-DnsServerAnzeige)"
        foreach ($m in $sichtbar) { Write-Host ('  [{0}] {1}' -f $m.Taste, $m.Text) }
        Write-Host '  [0] Zurück zum Hauptmenü'
        if ($gruende.Count) { Write-Host "  Weitere Punkte ausgeblendet: $($gruende -join ' / ')" -ForegroundColor DarkGray }
        $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
        if (-not $wahl -or $wahl -eq '0') { return }
        $punkt = @($sichtbar | Where-Object { $_.Taste -eq $wahl }) | Select-Object -First 1
        if (-not $punkt) { Write-Warnung 'Ungültige Auswahl.'; continue }
        try { & $punkt.Aktion }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen - zurück zum DNS-Menü.' }
        catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# [D][1]
function Show-DnsStatus {
    Write-Titel 'DNS - Status'
    $f = $script:Faehig
    Write-Info "DNS-Server:        $(Get-DnsServerAnzeige)"
    if (-not $f.DnsEntfernt) {
        Write-Info "Rolle installiert: $(if ($f.DnsRolle) { 'ja' } else { 'nein' })"
        Write-Info "Dienst läuft:      $(if ($f.DnsDienst) { 'ja' } else { 'nein' })"
    }
    if (-not $f.DNS) { Write-Warnung $f.Grund.DNS; return }
    $dns = Get-DnsParameter
    $zonen = @(Get-DnsServerZone @dns -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' } | Sort-Object IsReverseLookupZone, ZoneName)
    if ($zonen.Count -eq 0) { Write-Info 'Noch keine Zonen vorhanden.' }
    else {
        $zonen | ForEach-Object {
            $anzahl = @(Get-DnsServerResourceRecord -ZoneName $_.ZoneName @dns -ErrorAction SilentlyContinue).Count
            [pscustomobject]@{
                Name           = $_.ZoneName
                Typ            = "$($_.ZoneType)"
                Richtung       = if ($_.IsReverseLookupZone) { 'Reverse' } else { 'Forward' }
                'AD-integriert' = if ($_.IsDsIntegrated) { 'ja' } else { 'nein' }
                Eintraege      = $anzahl
            }
        } | Format-Table -AutoSize | Out-Host
    }
    try {
        $fw = @((Get-DnsServerForwarder @dns -ErrorAction Stop).IPAddress | ForEach-Object { "$_" })
        Write-Info ('Weiterleitungen:   ' + $(if ($fw.Count) { $fw -join ', ' } else { 'keine' }))
    }
    catch { }
}

# [D][2]
function Install-DnsRolle {
    Write-Titel 'DNS-Rolle installieren'
    if ($script:Faehig.DnsRolle) { Write-Ok 'Die DNS-Rolle ist bereits installiert.'; return }
    if (-not $script:Faehig.Admin) { Write-Warnung 'Ohne Administratorrechte schlägt die Installation fehl.' }
    Write-Info 'Wird installiert: Windows-Feature DNS mit Verwaltungstools (Install-WindowsFeature DNS -IncludeManagementTools)'
    if ($Funktionen.Vorschau -and -not (Read-JaNein 'Jetzt installieren?' $true)) { Stop-Aktion }
    $quelle = ''
    while ($true) {
        $param = @{ Name = 'DNS'; IncludeManagementTools = $true; ErrorAction = 'Stop' }
        if ($quelle) { $param.Source = $quelle }
        try {
            Write-Info 'Installation läuft, das kann einige Minuten dauern ...'
            $erg = Install-WindowsFeature @param
            if (-not $erg.Success) { throw "Installation nicht erfolgreich (ExitCode $($erg.ExitCode))" }
            Add-Ergebnis 'DNS-Rolle' 'DNS' $env:COMPUTERNAME 'OK' "ExitCode $($erg.ExitCode)"
            if ("$($erg.RestartNeeded)" -eq 'Yes') { Write-Warnung 'Windows meldet: Neustart des Servers nötig.' }
            break
        }
        catch {
            $meldung = $_.Exception.Message
            if (-not (Test-QuelleFehlt $meldung)) { Add-Ergebnis 'DNS-Rolle' 'DNS' $env:COMPUTERNAME 'FEHLER' $meldung; return }
            Write-Warnung 'Die Installationsdateien wurden nicht gefunden (Server offline oder Feature-Dateien entfernt).'
            Write-Info 'Lösung: Windows-Server-ISO einbinden und den Ordner \sources\sxs angeben, z.B. D:\sources\sxs'
            Write-Info '(entspricht Install-WindowsFeature DNS -IncludeManagementTools -Source D:\sources\sxs)'
            $quelle = (Read-Text 'Pfad zu \sources\sxs (Enter = abbrechen)').Trim('"')
            if (-not $quelle) { Add-Ergebnis 'DNS-Rolle' 'DNS' $env:COMPUTERNAME 'FEHLER' 'Installationsdateien fehlen - mit -Source erneut versuchen'; return }
            if (-not (Test-Path -LiteralPath $quelle -PathType Container)) { Write-Warnung "Ordner '$quelle' nicht gefunden."; $quelle = ''; continue }
        }
    }

    # Fähigkeiten neu prüfen, damit das DNS-Menü sofort alle Punkte zeigt
    $script:Faehig = Get-Faehigkeiten
    if ($script:Faehig.DnsRolle -and -not $script:Faehig.DnsDienst -and (Read-JaNein 'DNS-Dienst läuft nicht. Jetzt starten?' $true)) {
        try { Start-Service -Name DNS -ErrorAction Stop } catch { Write-Warnung "Dienst nicht gestartet: $($_.Exception.Message)" }
        $script:Faehig = Get-Faehigkeiten
    }
    if ($script:Faehig.DNS) { Write-Ok 'DNS ist jetzt verfügbar - alle Punkte unter [D] stehen bereit.' }
    else { Write-Warnung "DNS noch nicht nutzbar: $($script:Faehig.Grund.DNS)" }
}

# [D][3]
function Start-DnsForwardZonen {
    Write-Titel 'Forward-Zone(n) erstellen'
    $namen   = @(Read-Namensliste 'Zonenname(n), z.B. firma.local')
    $gueltig = @()
    foreach ($n in $namen) {
        $fehler = Get-DnsHostnameFehler $n
        if ($fehler) { Write-Warnung "'$n': $fehler - übersprungen." } else { $gueltig += $n.TrimEnd('.').ToLower() }
    }
    if ($gueltig.Count -eq 0) { Stop-Aktion }
    $optionen = Read-DnsZonenOptionen
    if ($Funktionen.Vorschau) {
        $art = if ($optionen.AdIntegriert) { "AD-integriert ($DnsReplikation)" } else { 'Datei' }
        Write-Info "Wird erstellt ($art, dynamische Updates: $($optionen.DynamicUpdate)):"
        foreach ($n in $gueltig) { Write-Host "    $n" -ForegroundColor White }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    foreach ($n in $gueltig) { [void](New-DnsZone -Zone $n -Optionen $optionen) }
}

# [D][4]
function Start-DnsReverseZonen {
    Write-Titel 'Reverse-Zone(n) erstellen'
    Write-Info 'Netz eingeben, z.B. 192.168.10.0/24, 192.168.10 oder 10.0.0.0/8 (nur /8, /16, /24)'
    $eingabe = Read-Text 'Netz(e) - mehrere mit Komma (Enter = abbrechen)'
    if (-not $eingabe) { Stop-Aktion }
    $netze = @()
    foreach ($teil in ($eingabe -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $r = ConvertTo-ReverseZonenName $teil
        if ($r.Fehler) { Write-Warnung "'$teil': $($r.Fehler) - übersprungen."; continue }
        Write-Host ('    {0,-20} ->  {1}' -f $r.NetworkId, $r.Zone) -ForegroundColor White
        $netze += $r
    }
    if ($netze.Count -eq 0) { Stop-Aktion }
    $optionen = Read-DnsZonenOptionen
    if ($Funktionen.Vorschau -and -not (Read-JaNein "$($netze.Count) Reverse-Zone(n) jetzt erstellen?" $true)) { Stop-Aktion }
    foreach ($r in $netze) { [void](New-DnsZone -Zone $r.Zone -NetworkId $r.NetworkId -Optionen $optionen) }
}

# [D][5]
function Start-DnsEintraege {
    Write-Titel 'DNS-Einträge erstellen'
    $zone = Select-DnsZone 'Forward-Zone für die Einträge wählen' (Get-DnsZonen -Forward)
    Write-Info 'Schnelleingabe, mehrere mit , oder ; getrennt:'
    Write-Info '  srv01=192.168.10.5     A (IPv6-Adresse = AAAA)'
    Write-Info "  www=srv01               CNAME auf srv01.$zone (mit Punkt = vollständiger Name)"
    Write-Info '  @=MX:mail:10            MX am Zonenstamm (@), Ziel mail, Priorität 10'
    $teile   = @(ConvertFrom-DnsSchnelleingabe (Read-Text 'Einträge (Enter = abbrechen)') $zone)
    foreach ($t in @($teile | Where-Object { $_.Fehler })) { Write-Warnung "'$($t.Eingabe)': $($t.Fehler) - übersprungen." }
    foreach ($t in @($teile | Where-Object { $_.Hinweis })) { Write-Info "'$($t.Eingabe)': $($t.Hinweis)" }
    $gueltig = @($teile | Where-Object { -not $_.Fehler })
    if ($gueltig.Count -eq 0) { Stop-Aktion }
    $ttl = Read-DnsTtl

    # Pläne inkl. Konfliktprüfung
    $plaene = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $gueltig) { $plaene.Add((New-DnsEintragPlan $zone $t.Typ $t.Name $t.Daten $t.Prioritaet)) }

    # Automatischer PTR für A/AAAA
    $neueZonen = [System.Collections.Generic.List[object]]::new()
    if ($DnsAutoPTR) {
        $reverse = @(Get-DnsZonen -Reverse | ForEach-Object { $_.ZoneName })
        $ohne    = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @($plaene.ToArray() | Where-Object { $_.Typ -in 'A', 'AAAA' -and $_.Art -in 'Neu', 'Vorhanden' })) {
            $ziel = Get-PtrZielFuerIp $p.Daten ($reverse + @($neueZonen | ForEach-Object { $_.Zone }))
            if (-not $ziel.Zone -and $ziel.VorschlagNetz) {
                $vorschlag = $ziel.VorschlagNetz
                while ($true) {
                    $antwort = Read-Text "Keine Reverse-Zone für $($p.Daten). Netz für neue Reverse-Zone ('-' = ohne PTR)" $vorschlag
                    if ($antwort -eq '-') { break }
                    $r = ConvertTo-ReverseZonenName $antwort
                    if ($r.Fehler) { Write-Warnung $r.Fehler; continue }
                    if (-not (Get-PtrZielFuerIp $p.Daten @($r.Zone)).Zone) { Write-Warnung "$($p.Daten) liegt nicht in $($r.NetworkId)."; continue }
                    $neueZonen.Add($r)
                    break
                }
                $ziel = Get-PtrZielFuerIp $p.Daten ($reverse + @($neueZonen | ForEach-Object { $_.Zone }))
            }
            if (-not $ziel.Zone) { $ohne.Add($p.Daten); continue }
            $fqdn = Get-DnsFqdn $p.Name $zone
            if ($neueZonen | Where-Object { $_.Zone -eq $ziel.Zone }) {
                $plaene.Add([pscustomobject]@{ Zone = $ziel.Zone; Typ = 'PTR'; Name = $ziel.Name; Daten = $fqdn; Prioritaet = ''; Art = 'Neu'; Grund = '' })
            }
            else { $plaene.Add((New-DnsEintragPlan $ziel.Zone 'PTR' $ziel.Name $fqdn)) }
        }
        if ($ohne.Count) { Write-Info "Ohne PTR (keine Reverse-Zone): $($ohne -join ', ')" }
    }
    $zonenOptionen = $null
    if ($neueZonen.Count) { Write-Info 'Einstellungen für die neue(n) Reverse-Zone(n):'; $zonenOptionen = Read-DnsZonenOptionen }

    if ($Funktionen.Vorschau) {
        Write-Titel "Vorschau: $($plaene.Count) Eintrag/Einträge, TTL $ttl"
        foreach ($r in $neueZonen) { Write-Host ('    Zone   {0}   (neu, Netz {1})' -f $r.Zone, $r.NetworkId) -ForegroundColor White }
        foreach ($p in $plaene) { Write-DnsPlanZeile $p }
        if (-not @($plaene | Where-Object { $_.Art -eq 'Neu' }).Count) { Write-Info 'Nichts Neues anzulegen.' }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }

    Write-Titel 'Erstelle DNS-Einträge'
    $fehlgeschlagen = @()
    foreach ($r in $neueZonen) {
        if (-not (New-DnsZone -Zone $r.Zone -NetworkId $r.NetworkId -Optionen $zonenOptionen)) { $fehlgeschlagen += $r.Zone }
    }
    foreach ($p in $plaene) {
        if ($p.Typ -eq 'PTR' -and $fehlgeschlagen -contains $p.Zone) { $p.Art = 'Fehler'; $p.Grund = "Reverse-Zone $($p.Zone) konnte nicht angelegt werden" }
        Invoke-DnsEintragPlan $p $ttl
    }
}

# [D][6] Sucht A/AAAA-Einträge der Zonen ohne PTR. Rückgabe: Plaene (fehlende PTR-Einträge),
# OhneZone (keine Reverse-Zone, mit VorschlagNetz/VorschlagZone), NurDienst (nur Dienst-Namen)
function Get-DnsFehlendePtr {
    param([string[]]$Zonen, [string[]]$ReverseZonen = @())
    $dns        = Get-DnsParameter
    $kandidaten = [System.Collections.Generic.List[object]]::new()
    foreach ($zone in $Zonen) {
        foreach ($rr in @('A', 'AAAA' | ForEach-Object { Get-DnsServerResourceRecord -ZoneName $zone -RRType $_ @dns -ErrorAction SilentlyContinue })) {
            $r = ConvertFrom-DnsRecord $rr
            $kandidaten.Add([pscustomobject]@{ Zone = $zone; HostName = $r.Name; Ip = $r.Daten })
        }
    }
    # global sortiert: echte Hostnamen zuerst, @/DomainDnsZones/ForestDnsZones danach, Dienst-Namen nie
    $auswahl = Select-DnsPtrKandidaten $kandidaten.ToArray() $ReverseZonen
    $plaene  = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $auswahl.MitZone) {
        $ptr = @(Get-DnsServerResourceRecord -ZoneName $k.Zone -Name $k.Name -RRType Ptr @dns -ErrorAction SilentlyContinue |
                 Where-Object { "$($_.HostName)" -eq $k.Name })
        if ($ptr.Count) { continue }
        $plaene.Add([pscustomobject]@{ Zone = $k.Zone; Typ = 'PTR'; Name = $k.Name; Daten = $k.Fqdn; Prioritaet = ''; Art = 'Neu'; Grund = '' })
    }
    return [pscustomobject]@{ Plaene = $plaene.ToArray(); OhneZone = $auswahl.OhneZone; NurDienst = $auswahl.NurDienst }
}

# [D][6] Reverse-Zonen für Adressen ohne Zone anlegen (Auswahl je /24-Netz, anpassbar).
# $true = mindestens eine Zone ist jetzt da (neu oder schon vorhanden)
function Invoke-DnsReverseZonenFuerPtr([object[]]$OhneZone) {
    foreach ($o in @($OhneZone | Where-Object { -not $_.VorschlagNetz })) {
        Write-Info "Reverse-Zone für IPv6 bitte von Hand anlegen: $($o.Ip) ($($o.Fqdn))"
    }
    $netze = @(Group-DnsOhneZoneNachNetz $OhneZone)
    if ($netze.Count -eq 0) { return $false }
    $eintraege = @([pscustomobject]@{ Anzeige = '(alle)'; Netz = '*'; Zone = ''; Adressen = @() }) + $netze
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel 'Für welche Netze Reverse-Zonen erstellen?' -Mehrfach -Optional)
    if ($wahl.Count -eq 0) { Write-Info 'Kein Netz gewählt - es werden keine Zonen angelegt.'; return $false }
    if (@($wahl | Where-Object { $_.Netz -eq '*' }).Count) { $wahl = $netze }

    $anpassen = Read-JaNein 'Netze anpassen (z. B. /16 statt /24)?' $false
    $neu = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $wahl) {
        $r = ConvertTo-ReverseZonenName $n.Netz
        if ($anpassen) {
            $ips = @($n.Adressen | ForEach-Object { $_.Ip })
            while ($true) {
                $antwort = Read-Text "Netz für $($ips -join ', ') ('-' = weglassen)" $n.Netz
                if ($antwort -eq '-') { $r = $null; break }
                $r = ConvertTo-ReverseZonenName $antwort
                if ($r.Fehler) { Write-Warnung $r.Fehler; continue }
                $draussen = @($ips | Where-Object { -not (Get-PtrZielFuerIp $_ @($r.Zone)).Zone })
                if ($draussen.Count) { Write-Warnung "$($draussen -join ', ') liegt nicht in $($r.NetworkId)."; continue }
                break
            }
        }
        if ($r -and -not @($neu | Where-Object { $_.Zone -eq $r.Zone }).Count) { $neu.Add($r) }
    }
    if ($neu.Count -eq 0) { Write-Info 'Kein Netz übrig - es werden keine Zonen angelegt.'; return $false }

    $optionen = Read-DnsZonenOptionen
    if ($Funktionen.Vorschau) {
        $art = if ($optionen.AdIntegriert) { "AD-integriert ($DnsReplikation)" } else { 'Datei' }
        Write-Info "Wird erstellt ($art, dynamische Updates: $($optionen.DynamicUpdate)):"
        foreach ($r in $neu) { Write-Host ('    {0,-20} ->  {1}' -f $r.NetworkId, $r.Zone) -ForegroundColor White }
        if (-not (Read-JaNein "$($neu.Count) Reverse-Zone(n) jetzt erstellen?" $true)) { Write-Info 'Es werden keine Zonen angelegt.'; return $false }
    }
    $fehlgeschlagen = @()
    foreach ($r in $neu) {
        if (-not (New-DnsZone -Zone $r.Zone -NetworkId $r.NetworkId -Optionen $optionen)) { $fehlgeschlagen += $r.Zone }
    }
    if ($fehlgeschlagen.Count) { Write-Warnung "Nicht angelegt: $($fehlgeschlagen -join ', ') - dort gibt es keine PTR-Einträge." }
    return ($fehlgeschlagen.Count -lt $neu.Count)
}

# [D][6]
function Start-DnsPtrAuffuellen {
    Write-Titel 'Fehlende PTR-Einträge auffüllen'
    $forward = @(Get-DnsZonen -Forward)
    if ($forward.Count -eq 0) { Write-Warnung 'Keine Forward-Zone vorhanden.'; return }
    $eintraege = @([pscustomobject]@{ Anzeige = '(alle Forward-Zonen)'; Zone = '*' }) +
                 @($forward | ForEach-Object { [pscustomobject]@{ Anzeige = $_.ZoneName; Zone = $_.ZoneName } })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel 'Welche Forward-Zone(n) durchsuchen?')
    if ($wahl.Count -eq 0) { Stop-Aktion }
    $zonen = if ($wahl[0].Zone -eq '*') { @($forward | ForEach-Object { $_.ZoneName }) } else { @($wahl[0].Zone) }

    $reverse = @(Get-DnsZonen -Reverse | ForEach-Object { $_.ZoneName })
    $suche   = Get-DnsFehlendePtr -Zonen $zonen -ReverseZonen $reverse
    if ($suche.NurDienst.Count) {
        Write-Info "Nur Dienst-Namen - kein PTR ($($suche.NurDienst.Count) Adresse(n)):"
        foreach ($o in $suche.NurDienst) { Write-Info "  $($o.Ip) ($($o.Fqdn))" }
    }
    if ($suche.OhneZone.Count) {
        $hinweis = if ($Funktionen.DnsZonen) { '' } else { ' - unter [4] anlegen' }
        Write-Warnung "Keine passende Reverse-Zone für $($suche.OhneZone.Count) Adresse(n)${hinweis}:"
        foreach ($o in $suche.OhneZone) { Write-Info "  $($o.Ip) ($($o.Fqdn))" }
        if ($Funktionen.DnsZonen -and (Read-JaNein 'Passende Reverse-Zone(n) jetzt erstellen?' $true)) {
            if (Invoke-DnsReverseZonenFuerPtr $suche.OhneZone) {
                # neu suchen: die PTR-Einträge für die neuen Zonen sind damit automatisch geplant
                $reverse = @(Get-DnsZonen -Reverse | ForEach-Object { $_.ZoneName })
                $suche   = Get-DnsFehlendePtr -Zonen $zonen -ReverseZonen $reverse
                if ($suche.OhneZone.Count) { Write-Info "Weiterhin ohne Reverse-Zone: $($suche.OhneZone.Count) Adresse(n)." }
            }
        }
    }
    $plaene = @($suche.Plaene)
    if ($plaene.Count -eq 0) {
        if ($suche.OhneZone.Count) { Write-Info 'Keine PTR-Einträge zu erstellen: Adressen mit Reverse-Zone haben schon einen PTR, die übrigen haben keine Reverse-Zone.' }
        else { Write-Ok 'Alle Adressen mit Reverse-Zone haben schon einen PTR-Eintrag.' }
        return
    }
    Write-Info "Fehlende PTR-Einträge: $($plaene.Count)"
    foreach ($p in $plaene) { Write-DnsPlanZeile $p }
    if (-not (Read-JaNein 'Diese PTR-Einträge jetzt erstellen?' $true)) { Stop-Aktion }
    $ttl = ConvertTo-DnsTtl $DnsStandardTTL
    foreach ($p in $plaene) { Invoke-DnsEintragPlan $p $ttl }
}

# [D][7]
function Start-DnsWeiterleitungen {
    Write-Titel 'Weiterleitungen (Forwarder)'
    $dns = Get-DnsParameter
    $aktuell = @((Get-DnsServerForwarder @dns -ErrorAction Stop).IPAddress | Where-Object { $_ } | ForEach-Object { "$_" })
    Write-Info ('Aktuell: ' + $(if ($aktuell.Count) { $aktuell -join ', ' } else { 'keine' }))
    Write-Host '  [1] Ergänzen (vorhandene bleiben)'
    Write-Host '  [2] Ersetzen (nur die neuen gelten)'
    Write-Host '  [0] Zurück'
    $modus = Read-Zahl 'Auswahl' 0 2
    if ($modus -eq 0) { return }
    $vorschlag = (@($DnsWeiterleitungen) -join ', ')
    $liste = ConvertFrom-IpListe (Read-Text 'IP-Adresse(n) der Weiterleitungen, mit Komma' $vorschlag -Pflicht)
    foreach ($u in $liste.Ungueltig) { Write-Warnung "'$u' ist keine gültige IP-Adresse - übersprungen." }
    if ($liste.Gueltig.Count -eq 0) { Stop-Aktion }
    if ($Funktionen.Vorschau) {
        $neu = if ($modus -eq 1) { @($aktuell) + @($liste.Gueltig | Where-Object { $aktuell -notcontains $_ }) } else { $liste.Gueltig }
        Write-Info "Danach: $($neu -join ', ')"
        if (-not (Read-JaNein 'Jetzt übernehmen?' $true)) { Stop-Aktion }
    }
    $server = Get-DnsServerAnzeige
    if ($modus -eq 1) {
        foreach ($ip in $liste.Gueltig) {
            if ($aktuell -contains $ip) { Add-Ergebnis 'DNS-Forwarder' $ip $server 'VORHANDEN'; continue }
            try   { Add-DnsServerForwarder -IPAddress $ip @dns -ErrorAction Stop; Add-Ergebnis 'DNS-Forwarder' $ip $server 'OK' 'ergänzt' }
            catch { Add-Ergebnis 'DNS-Forwarder' $ip $server 'FEHLER' $_.Exception.Message }
        }
    }
    else {
        $text = $liste.Gueltig -join ', '
        try   { Set-DnsServerForwarder -IPAddress $liste.Gueltig @dns -ErrorAction Stop; Add-Ergebnis 'DNS-Forwarder' $text $server 'OK' "ersetzt, vorher: $(if ($aktuell.Count) { $aktuell -join ', ' } else { 'keine' })" }
        catch { Add-Ergebnis 'DNS-Forwarder' $text $server 'FEHLER' $_.Exception.Message }
    }
}

# [D][8]
function Start-DnsTest {
    Write-Titel 'Namensauflösung testen'
    $server = if ($DnsServerName) { $DnsServerName } else { '127.0.0.1' }
    Write-Info "Fragt nur den DNS-Server $server (Resolve-DnsName -DnsOnly). IP-Adresse = Rückwärtssuche (PTR)."
    while ($true) {
        $name = Read-Text 'Name oder IP-Adresse (Enter = zurück)'
        if (-not $name) { return }
        try {
            $antwort = @(Resolve-DnsName -Name $name -Server $server -DnsOnly -ErrorAction Stop)
            $antwort | ForEach-Object {
                $daten = if ($_.IPAddress) { $_.IPAddress } elseif ($_.NameHost) { $_.NameHost } elseif ($_.NameExchange) { "$($_.Preference) $($_.NameExchange)" } elseif ($_.PrimaryServer) { "SOA $($_.PrimaryServer)" } else { '' }
                [pscustomobject]@{ Name = $_.Name; Typ = "$($_.Type)"; TTL = $_.TTL; Bereich = "$($_.Section)"; Daten = $daten }
            } | Format-Table -AutoSize | Out-Host
        }
        catch { Write-Warnung "Keine Antwort für '$name': $($_.Exception.Message)" }
    }
}
#endregion

#region ======================= MODUL [S] SUBNETZRECHNER ============
# Reiner IPv4-Rechner: braucht weder AD noch DNS und ändert nichts am Server.

# "192.168.8.0" -> Zahl (ungültig -> $null)
function ConvertTo-IpZahl([string]$Text) {
    if ((Get-IpArt $Text) -ne 'IPv4') { return $null }
    [int64]$zahl = 0
    foreach ($oktett in "$Text".Trim().Split('.')) { $zahl = $zahl * 256 + [int64]$oktett }
    return $zahl
}

# Zahl -> die 4 Oktette
function Get-IpOktette([int64]$Zahl) {
    return @((($Zahl -shr 24) -band 255), (($Zahl -shr 16) -band 255), (($Zahl -shr 8) -band 255), ($Zahl -band 255))
}

# Zahl -> "192.168.8.0"
function ConvertTo-IpText([int64]$Zahl) {
    return (Get-IpOktette $Zahl) -join '.'
}

# Zahl -> "11111111.11111111.11111100.00000000"
function ConvertTo-IpBinaer([int64]$Zahl) {
    return (@(Get-IpOktette $Zahl | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join '.')
}

# Präfix (z.B. 22) -> Maske als Zahl
function Get-MaskeAusPraefix([int]$Praefix) {
    return ([int64]4294967296 - ([int64]1 -shl (32 - $Praefix)))
}

# Maske "255.255.252.0", "255.255.252" (Rest wird mit 0 aufgefüllt), "/22" oder "22" -> Präfix (ungültig -> $null)
function Get-PraefixAusEingabe([string]$Eingabe) {
    $e = "$Eingabe".Trim()
    if ($e -match '^/?\d{1,2}$') {
        $p = [int]$e.TrimStart('/')
        if ($p -le 32) { return $p }
        return $null
    }
    $teile = @($e.Split('.') | Where-Object { $_ -ne '' })
    if ($teile.Count -lt 1 -or $teile.Count -gt 4) { return $null }
    while ($teile.Count -lt 4) { $teile += '0' }
    $zahl = ConvertTo-IpZahl ($teile -join '.')
    if ($null -eq $zahl) { return $null }
    # welches Präfix ergibt genau diese Maske? (255.255.253.0 ist keine gültige Maske)
    for ($p = 0; $p -le 32; $p++) { if ((Get-MaskeAusPraefix $p) -eq $zahl) { return $p } }
    return $null
}

# Eingabe "/22", "255.255.252.0", "192.168.10.37/26" oder "192.168.10.37 255.255.255.192"
# -> Ip (Zahl, $null = nicht angegeben) und Praefix ($null = ungültig)
function ConvertFrom-SubnetzEingabe([string]$Text) {
    $e = [pscustomobject]@{ Ip = $null; Praefix = $null }
    $teile = @(("$Text".Trim() -replace '\s*/\s*', ' /') -split '\s+' | Where-Object { $_ })
    if ($teile.Count -eq 1) { $e.Praefix = Get-PraefixAusEingabe $teile[0] }
    elseif ($teile.Count -eq 2 -and (Get-IpArt $teile[0]) -eq 'IPv4') {
        $e.Praefix = Get-PraefixAusEingabe $teile[1]
        if ($null -ne $e.Praefix) { $e.Ip = ConvertTo-IpZahl $teile[0] }
    }
    return $e
}

# Alles zu IP + Präfix berechnen (ohne Ausgabe)
function Get-SubnetzInfo([int64]$Ip, [int]$Praefix) {
    $maske     = Get-MaskeAusPraefix $Praefix
    $hostBits  = 32 - $Praefix
    $adressen  = [int64]1 -shl $hostBits
    $netz      = $Ip - ($Ip % $adressen)
    $broadcast = $netz + $adressen - 1
    if ($Praefix -le 30) {
        $hosts = $adressen - 2; $erster = $netz + 1; $letzter = $broadcast - 1
        $formel = "(2^$hostBits - 2)"; $hinweis = ''
    }
    elseif ($Praefix -eq 31) {
        $hosts = 2; $erster = $netz; $letzter = $broadcast
        $formel = ''; $hinweis = 'Sonderfall /31: Punkt-zu-Punkt-Verbindung (RFC 3021), nichts reserviert.'
    }
    else {
        $hosts = 1; $erster = $netz; $letzter = $netz
        $formel = ''; $hinweis = 'Sonderfall /32: genau eine einzelne Adresse, nichts reserviert.'
    }
    return [pscustomobject]@{
        Ip          = ConvertTo-IpText $Ip
        Praefix     = $Praefix
        Maske       = ConvertTo-IpText $maske
        Wildcard    = ConvertTo-IpText ($adressen - 1)
        MaskeBinaer = ConvertTo-IpBinaer $maske
        HostBits    = $hostBits
        Netz        = ConvertTo-IpText $netz
        Broadcast   = ConvertTo-IpText $broadcast
        ErsterHost  = ConvertTo-IpText $erster
        LetzterHost = ConvertTo-IpText $letzter
        Hosts       = [int64]$hosts
        Adressen    = $adressen
        Formel      = $formel
        Reserviert  = ($Praefix -le 30)    # Netz- und Broadcast-Adresse sind reserviert
        Hinweis     = $hinweis
    }
}

function Show-SubnetzInfo($Info) {
    Write-Host ''
    Write-Host '  Ergebnis' -ForegroundColor Cyan
    Write-Info ('Eingegebene IP     : {0}' -f $Info.Ip)
    Write-Info ('Subnetzmaske       : {0}' -f $Info.Maske)
    Write-Host ('  CIDR-Schreibweise  : /{0}' -f $Info.Praefix) -ForegroundColor Yellow
    Write-Info ('Wildcard-Maske     : {0}' -f $Info.Wildcard)
    Write-Info ('Maske binär        : {0}' -f $Info.MaskeBinaer)
    Write-Info ('Netz-/Host-Bits    : {0} / {1}' -f $Info.Praefix, $Info.HostBits)
    Write-Host ''
    Write-Host '  Reservierte Adressen' -ForegroundColor Cyan
    if ($Info.Reserviert) {
        Write-Info ('Netzadresse        : {0}' -f $Info.Netz)
        Write-Info ('Broadcast-Adresse  : {0}' -f $Info.Broadcast)
    }
    else { Write-Info $Info.Hinweis }
    Write-Host ''
    Write-Host '  Hosts' -ForegroundColor Cyan
    Write-Info ('Erster Host        : {0}' -f $Info.ErsterHost)
    Write-Info ('Letzter Host       : {0}' -f $Info.LetzterHost)
    Write-Ok   ('Nutzbare Hosts     : {0:N0}  {1}' -f $Info.Hosts, $Info.Formel)
    Write-Info ('Adressen gesamt    : {0:N0}  (2^{1})' -f $Info.Adressen, $Info.HostBits)
    Write-Host ''
    Write-Host ('  Bereich            : {0}  bis  {1}' -f $Info.Netz, $Info.Broadcast) -ForegroundColor Yellow
}

# [S]
function Start-Subnetzrechner {
    Write-Titel 'Subnetzrechner'
    Write-Info 'Maske als 255.255.252.0, 255.255.252 (Rest = 0) oder /22 - oder gleich mit IP: 192.168.10.37/26'
    while ($true) {
        $eingabe = Read-Text 'Subnetzmaske oder IP/Präfix (Enter = zurück)'
        if (-not $eingabe) { return }
        $e = ConvertFrom-SubnetzEingabe $eingabe
        if ($null -eq $e.Praefix) {
            Write-Warnung 'Ungültige Eingabe! Die Einsen der Maske müssen am Stück von links kommen (z.B. 255.255.252.0 oder /22), mit IP z.B. 192.168.10.37/26.'
            continue
        }
        $ip = $e.Ip
        while ($null -eq $ip) {
            $ip = ConvertTo-IpZahl (Read-Text 'IP-Adresse im Netz' '192.168.0.0')
            if ($null -eq $ip) { Write-Warnung 'Ungültige IP-Adresse! Beispiel: 192.168.8.0' }
        }
        Show-SubnetzInfo (Get-SubnetzInfo -Ip $ip -Praefix $e.Praefix)
    }
}
#endregion

#region ======================= EINSTELLUNGEN [E] ====================

# Alle Werte, die unter [E] änderbar sind. Schluessel = Variablenname bzw. 'Tabelle.Schlüssel'
function Get-EinstellungsDefinitionen {
    $d = [System.Collections.Generic.List[object]]::new()
    $neu = {
        param($Gruppe, $Schluessel, $Text, $Art, $Hinweis = '', $Min = 0, $Max = 0, $Werte = @())
        $d.Add([pscustomobject]@{ Gruppe = $Gruppe; Schluessel = $Schluessel; Text = $Text; Art = $Art; Hinweis = $Hinweis; Min = $Min; Max = $Max; Werte = $Werte })
    }
    $g = 'Namensregeln'
    & $neu $g 'PrefixGG'            'Präfix globale Gruppen'            'Praefix'
    & $neu $g 'PrefixDL'            'Präfix domänenlokale Gruppen'      'Praefix'
    & $neu $g 'TrennerRechte'       'Trenner Name / Rechte'             'Praefix'
    & $neu $g 'VerbinderRechte'     'Verbinder zwischen Rechten'        'Praefix'
    & $neu $g 'BenutzernameMuster'  'Muster Anmeldename'                'Muster'      'Platzhalter: {vorname} {nachname} {v} {n}'
    & $neu $g 'EmailMuster'         'Muster E-Mail'                     'EmailMuster' 'Platzhalter: {anmeldename} {domain} {vorname} {nachname} {v} {n}; leer = keine E-Mail'
    & $neu $g 'MailDomain'          'Mail-Domain'                       'Domain'      'leer = DNS-Name der Domäne'
    & $neu $g 'UPNSuffix'           'UPN-Suffix'                        'Domain'      'leer = DNS-Name der Domäne'
    & $neu $g 'NamenKleinschreiben' 'Anmeldename / E-Mail klein'        'Bool'
    $g = 'Benutzer-Standards'
    & $neu $g 'EinstellungenFragen'     'Kontoeinstellungen jedes Mal fragen' 'Bool'
    & $neu $g 'StandardKonto.Aktiviert' 'Konto sofort aktiv'                  'Bool'
    & $neu $g 'StandardKonto.PwAendern' 'Passwort bei 1. Anmeldung ändern'    'Bool'
    & $neu $g 'StandardKonto.PwNieAb'   'Passwort läuft nie ab'               'Bool'
    & $neu $g 'PasswortLaenge'          'Länge der Zufallspasswörter'         'Zahl'     '8 bis 128 Zeichen' 8 128
    & $neu $g 'HomeBasisPfad'           'Basis-Pfad Home-Ordner'              'Pfad'     'z.B. \\SRV01\Home$ oder D:\Home, leer = wird gefragt'
    & $neu $g 'HomeLaufwerk'            'Laufwerk Home-Ordner'                'Laufwerk' 'z.B. H:'
    & $neu $g 'HomeRecht'               'NTFS-Recht auf Home-Ordner'          'NtfsRecht' 'z.B. Modify, FullControl, ReadAndExecute'
    $g = 'OU / Abteilung'
    & $neu $g 'OUSchutzVorLoeschen' 'OUs vor Löschen schützen'   'Bool'
    & $neu $g 'AbteilungsUnterOUs'  'Unter-OUs einer Abteilung'  'OUListe' "mit Komma, '-' = keine"
    & $neu $g 'AbteilungBenutzerOU' 'Unter-OU für Benutzer'      'OUName'
    & $neu $g 'AbteilungGruppenOU'  'Unter-OU für Gruppen'       'OUName'
    $g = 'DNS'
    & $neu $g 'DnsServerName'      'DNS-Server'                 'Server'  'leer = dieser Server'
    & $neu $g 'DnsReplikation'     'Replikation AD-Zonen'       'Auswahl' 'Domain, Forest oder Legacy' 0 0 @('Domain', 'Forest', 'Legacy')
    & $neu $g 'DnsStandardTTL'     'Standard-TTL'               'TTL'     'Format hh:mm:ss'
    & $neu $g 'DnsAutoPTR'         'PTR automatisch anlegen'    'Bool'
    & $neu $g 'DnsWeiterleitungen' 'Vorschlag Weiterleitungen'  'IPListe' "IP-Adressen mit Komma, '-' = keine"
    $texte = @{
        OU = '[1] OUs erstellen'; Benutzer = '[2] Benutzer erstellen'
        GlobaleGruppen = '[3] Globale Gruppen'; DLGruppen = '[4] Domänenlokale Gruppen'; AGDLP = '[5] AGDLP-Paket'
        Abteilung = '[6] Abteilung komplett'; Mitgliedschaften = '[7] Mitgliedschaften'; Rueckgaengig = '[8] Rückgängig'
        DNS = '[D] DNS-Menü'; GPO = '[G] Gruppenrichtlinien'; DHCP = '[H] DHCP'; Subnetzrechner = '[S] Subnetzrechner'; Schnelleingabe = 'Benutzer: Schnelleingabe'; ZufallsPasswort = 'Benutzer: Zufallspasswörter'
        VorlageBenutzer = 'Benutzer: Vorlage kopieren'; GruppenZuweisen = 'Gruppen direkt zuweisen'
        AbteilungAusfuellen = 'Benutzer: Feld Abteilung'; EmailAusfuellen = 'Benutzer: E-Mail ausfüllen'
        HomeOrdner = 'Benutzer: Home-Ordner'; NTFSRechte = 'DL-Gruppen: NTFS-Rechte'; Freigabe = 'DL-Gruppen: SMB-Freigabe'
        FensterAuswahl = 'Auswahlfenster (Out-GridView)'; Vorschau = 'Vorschau vor dem Erstellen'; Protokoll = 'CSV-Protokoll'
        DnsRolle = '[D][2] DNS-Rolle installieren'; DnsZonen = '[D][3]+[4] Zonen'; DnsEintraege = '[D][5] Einträge'
        DnsPTRAuffuellen = '[D][6] PTR auffüllen'; DnsWeiterleitung = '[D][7] Weiterleitungen'; DnsTest = '[D][8] Namensauflösung'
    }
    foreach ($k in @($Funktionen.Keys)) {
        $text = if ($texte.ContainsKey($k)) { $texte[$k] } else { $k }
        & $neu 'Module ein/aus' "Funktionen.$k" $text 'Bool'
    }
    return $d.ToArray()
}

function Get-EinstellungsWert([string]$Schluessel) {
    if ($Schluessel -match '^(StandardKonto|Funktionen)\.(.+)$') {
        $tabelle = Get-Variable -Name $Matches[1] -ValueOnly
        return , $tabelle[$Matches[2]]
    }
    return , (Get-Variable -Name $Schluessel -ValueOnly)
}

function Set-EinstellungsWert([string]$Schluessel, $Wert) {
    if ($Schluessel -match '^(StandardKonto|Funktionen)\.(.+)$') {
        $tabelle = Get-Variable -Name $Matches[1] -ValueOnly
        $tabelle[$Matches[2]] = $Wert
        return
    }
    Set-Variable -Name $Schluessel -Value $Wert -Scope Script
}

function Test-EinstellungGleich($A, $B) {
    return ((ConvertTo-Json -InputObject $A -Compress) -ceq (ConvertTo-Json -InputObject $B -Compress))
}

# Wert prüfen und umwandeln -> Ok, Wert, Fehler. $Wert kommt aus der Eingabe (Text) oder aus der JSON-Datei
function Test-EinstellungsWert($Definition, $Wert) {
    $e = [pscustomobject]@{ Ok = $false; Wert = $null; Fehler = '' }
    $art = $Definition.Art

    if ($art -eq 'Bool') {
        if ($Wert -is [bool]) { $e.Wert = $Wert }
        elseif ("$Wert" -in 'true', 'false') { $e.Wert = ("$Wert" -eq 'true') }
        else { $e.Fehler = 'erwartet true oder false'; return $e }
        $e.Ok = $true
        return $e
    }
    if ($art -eq 'Zahl') {
        $zahl = 0
        if ($Wert -is [bool] -or -not [int]::TryParse("$Wert", [ref]$zahl)) { $e.Fehler = "erwartet eine ganze Zahl ($($Definition.Min) bis $($Definition.Max))"; return $e }
        if ($zahl -lt $Definition.Min -or $zahl -gt $Definition.Max) { $e.Fehler = "muss zwischen $($Definition.Min) und $($Definition.Max) liegen"; return $e }
        $e.Wert = $zahl
        $e.Ok = $true
        return $e
    }
    if ($art -in 'OUListe', 'IPListe') {
        if ($null -eq $Wert) { $teile = @() }
        elseif ($Wert -is [array]) { $teile = @($Wert | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
        elseif ("$Wert".Trim() -in '', '-', 'leer') { $teile = @() }
        else { $teile = @("$Wert" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        foreach ($t in $teile) {
            if ($art -eq 'IPListe' -and -not (Get-IpArt $t)) { $e.Fehler = "'$t' ist keine gültige IP-Adresse"; return $e }
            if ($art -eq 'OUListe' -and $t -match '[,=+<>#;\\"/]') { $e.Fehler = "'$t': ungültige Zeichen für einen OU-Namen"; return $e }
        }
        $e.Wert = [string[]]@($teile | Select-Object -Unique)
        $e.Ok = $true
        return $e
    }

    # alle übrigen Arten sind Text
    if ($null -eq $Wert) { $Wert = '' }
    if ($Wert -isnot [string]) { $e.Fehler = 'erwartet einen Text'; return $e }
    $text = $Wert.Trim()
    if ($text -eq 'leer') { $text = '' }
    switch ($art) {
        'Praefix' {
            if ($text -match '["/\\\[\]:;|=,+*?<>@\s]') { $e.Fehler = 'enthält Zeichen, die in AD-Gruppennamen nicht erlaubt sind (" / \ [ ] : ; | = , + * ? < > @ Leerzeichen)'; return $e }
            if ($text.Length -gt 20) { $e.Fehler = 'höchstens 20 Zeichen'; return $e }
        }
        'Muster' {
            if ($text -cnotmatch '\{vorname\}|\{nachname\}') { $e.Fehler = 'muss {vorname} oder {nachname} enthalten'; return $e }
        }
        'EmailMuster' {
            if ($text -and ($text -notmatch '@' -or $text -cnotmatch '\{(vorname|nachname|anmeldename|v|n)\}')) {
                $e.Fehler = 'braucht ein @ und {anmeldename}, {vorname} oder {nachname} (leer = keine E-Mail)'; return $e
            }
        }
        { $_ -in 'Domain', 'Server' } {
            if ($text -and -not (Test-DnsHostname $text)) { $e.Fehler = "kein gültiger Name: $(Get-DnsHostnameFehler $text)"; return $e }
            $text = $text.TrimEnd('.')
        }
        'Laufwerk' {
            if ($text -notmatch '^[A-Za-z]:$') { $e.Fehler = 'Format: Buchstabe und Doppelpunkt, z.B. H:'; return $e }
            $text = $text.ToUpper()
        }
        'NtfsRecht' {
            $ok = $false
            if ($text -match '^[A-Za-z, ]+$') { try { $null = [System.Security.AccessControl.FileSystemRights]$text; $ok = $true } catch { } }
            if (-not $ok) { $e.Fehler = 'kein NTFS-Recht (z.B. Modify, FullControl, ReadAndExecute)'; return $e }
        }
        'OUName' {
            if (-not $text) { $e.Fehler = 'darf nicht leer sein'; return $e }
            if ($text -match '[,=+<>#;\\"/]') { $e.Fehler = 'ungültige Zeichen für einen OU-Namen'; return $e }
        }
        'TTL' {
            if (-not (ConvertTo-DnsTtl $text)) { $e.Fehler = 'Format hh:mm:ss, z.B. 01:00:00'; return $e }
        }
        'Auswahl' {
            $treffer = @($Definition.Werte | Where-Object { $_ -eq $text }) | Select-Object -First 1
            if (-not $treffer) { $e.Fehler = "erlaubt: $($Definition.Werte -join ', ')"; return $e }
            $text = $treffer
        }
        'Pfad' { $text = $text.Trim('"') }
    }
    $e.Wert = $text
    $e.Ok = $true
    return $e
}

function Format-EinstellungsWert($Definition, $Wert) {
    if ($Definition.Art -eq 'Bool') { if ($Wert) { return 'ja' } else { return 'nein' } }
    if ($Definition.Art -in 'OUListe', 'IPListe') { $liste = @($Wert | Where-Object { $_ }); if ($liste.Count) { return ($liste -join ', ') } else { return '(keine)' } }
    if ("$Wert" -eq '') { return '(leer)' }
    return "$Wert"
}

# Beispieltext für die Vorschau. Der neue Wert überdeckt den Script-Wert nur hier (lokale Variable)
function Get-EinstellungsBeispiel([string]$Schluessel, $Wert) {
    if ($Schluessel -notmatch '\.') { Set-Variable -Name $Schluessel -Value $Wert }
    if (-not $MailDomain) { $MailDomain = if ($Domain) { $Domain.DNSRoot } else { 'firma.local' } }
    if (-not $UPNSuffix)  { $UPNSuffix  = if ($Domain) { $Domain.DNSRoot } else { 'firma.local' } }
    $sam = Format-NamensMuster $BenutzernameMuster 'Max' 'Müller'
    switch ($Schluessel) {
        'PrefixGG'            { return "Globale Gruppe heißt dann: $($PrefixGG)Vertrieb" }
        'PrefixDL'            { return "Domänenlokale Gruppe heißt dann: $(Get-DLName 'Vertrieb' @('R', 'W'))" }
        'TrennerRechte'       { return "Domänenlokale Gruppe heißt dann: $(Get-DLName 'Vertrieb' @('R', 'W'))" }
        'VerbinderRechte'     { return "Domänenlokale Gruppe heißt dann: $(Get-DLName 'Vertrieb' @('R', 'W'))" }
        'BenutzernameMuster'  { return "Anmeldename für Max Müller: $sam" }
        'NamenKleinschreiben' { return "Anmeldename für Max Müller: $sam" }
        'EmailMuster'         { if (-not $EmailMuster) { return 'E-Mail wird nicht ausgefüllt' }; return "E-Mail für Max Müller: $(Format-NamensMuster $EmailMuster 'Max' 'Müller' $sam)" }
        'MailDomain'          { if (-not $EmailMuster) { return '' }; return "E-Mail für Max Müller: $(Format-NamensMuster $EmailMuster 'Max' 'Müller' $sam)" }
        'UPNSuffix'           { return "Anmeldung (UPN) für Max Müller: $sam@$UPNSuffix" }
        'PasswortLaenge'      { return "Zufallspasswörter haben $Wert Zeichen (oder mehr, wenn die Domänen-Richtlinie das verlangt)" }
        'AbteilungsUnterOUs'  { $u = @($Wert | Where-Object { $_ }); if (-not $u.Count) { return 'Abteilung Vertrieb bekommt keine Unter-OUs' }; return "Abteilung Vertrieb bekommt: $((@($u) | ForEach-Object { "Vertrieb/$_" }) -join ', ')" }
        'DnsServerName'       { if (-not $Wert) { return 'DNS-Befehle laufen auf diesem Server' }; return "DNS-Befehle laufen mit -ComputerName $Wert" }
        'DnsStandardTTL'      { return "Neue DNS-Einträge bekommen die TTL $(ConvertTo-DnsTtl $Wert)" }
    }
    return ''
}

# Beim Start: Standardwerte merken, dann Einstellungen.json darüberlegen
function Initialize-Einstellungen {
    $stand = [ordered]@{}
    foreach ($d in Get-EinstellungsDefinitionen) {
        $w = Get-EinstellungsWert $d.Schluessel
        if ($w -is [array]) { $w = $w.Clone() }
        $stand[$d.Schluessel] = $w
    }
    $script:EinstellungenStandard = $stand
    $script:EinstellungenGesetzt  = [ordered]@{}
    Import-Einstellungen
}

# JSON-Text prüfen -> Werte (nur gültige, bekannte Einträge) + Warnungen. Ändert nichts.
function ConvertFrom-EinstellungenJson([string]$Json, [object[]]$Definitionen) {
    $werte     = [ordered]@{}
    $warnungen = [System.Collections.Generic.List[string]]::new()
    $ergebnis  = [pscustomobject]@{ Werte = $werte; Warnungen = $warnungen }
    $objekt = $null
    try { $objekt = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { $warnungen.Add("Einstellungen.json ist fehlerhaft ($($_.Exception.Message)) - es gelten die Standardwerte."); return $ergebnis }
    if ($objekt -isnot [System.Management.Automation.PSCustomObject]) {
        $warnungen.Add('Einstellungen.json enthält kein JSON-Objekt { ... } - es gelten die Standardwerte.')
        return $ergebnis
    }
    # Schlüssel aus älteren Versionen still ignorieren (fallen beim nächsten Speichern weg)
    $veraltet = @('Funktionen.CsvImport')
    foreach ($p in $objekt.PSObject.Properties) {
        if ($p.Name.StartsWith('_')) { continue }   # Kommentare wie "_Hinweis"
        if ($veraltet -contains $p.Name) { continue }
        $def = @($Definitionen | Where-Object { $_.Schluessel -eq $p.Name }) | Select-Object -First 1
        if (-not $def) { $warnungen.Add("Einstellungen.json: unbekannter Eintrag '$($p.Name)' - wird ignoriert."); continue }
        $pruefung = Test-EinstellungsWert $def $p.Value
        if (-not $pruefung.Ok) { $warnungen.Add("Einstellungen.json: '$($p.Name)' $($pruefung.Fehler) - Standardwert gilt."); continue }
        $werte[$def.Schluessel] = $pruefung.Wert
    }
    return $ergebnis
}

function Import-Einstellungen {
    $pfad = $script:EinstellungenDatei
    if (-not $pfad -or -not (Test-Path -LiteralPath $pfad -PathType Leaf)) { return }
    try   { $text = [System.IO.File]::ReadAllText($pfad) }
    catch { Write-Warnung "Einstellungen.json nicht lesbar ($($_.Exception.Message)) - es gelten die Standardwerte."; return }
    $ergebnis = ConvertFrom-EinstellungenJson $text (Get-EinstellungsDefinitionen)
    foreach ($w in $ergebnis.Warnungen) { Write-Warnung $w }
    foreach ($k in @($ergebnis.Werte.Keys)) {
        Set-EinstellungsWert $k $ergebnis.Werte[$k]
        $script:EinstellungenGesetzt[$k] = $ergebnis.Werte[$k]
    }
    if ($ergebnis.Werte.Count) { Write-Info "$($ergebnis.Werte.Count) Einstellung(en) aus Einstellungen.json übernommen." }
}

# Folgen einer Änderung sofort anwenden ('*' = alles)
function Update-NachEinstellung([string]$Schluessel) {
    if ($Schluessel -in '*', 'MailDomain' -and -not $MailDomain -and $Domain) { $script:MailDomain = $Domain.DNSRoot }
    if ($Schluessel -in '*', 'UPNSuffix'  -and -not $UPNSuffix  -and $Domain) { $script:UPNSuffix  = $Domain.DNSRoot }
    if ($Schluessel -in '*', 'DnsServerName' -and $script:Faehig) { $script:Faehig = Get-Faehigkeiten }
    if ($Schluessel -in '*', 'Funktionen.FensterAuswahl' -and $script:Faehig) { $script:GuiVerfuegbar = $Funktionen.FensterAuswahl -and $script:Faehig.Gui }
}

# Wert setzen, für "Speichern" merken und sofort wirksam machen
function Set-Einstellung([string]$Schluessel, $Wert) {
    Set-EinstellungsWert $Schluessel $Wert
    $script:EinstellungenGesetzt[$Schluessel] = $Wert
    Update-NachEinstellung $Schluessel
}

# Gesetzte Werte, die vom Standard im Script abweichen
function Get-EinstellungsAenderungen {
    $aenderungen = [ordered]@{}
    foreach ($k in @($script:EinstellungenGesetzt.Keys)) {
        if (-not (Test-EinstellungGleich $script:EinstellungenGesetzt[$k] $script:EinstellungenStandard[$k])) {
            $aenderungen[$k] = $script:EinstellungenGesetzt[$k]
        }
    }
    return $aenderungen
}

# Schreibt nur die geänderten Werte (UTF-8). Keine Abweichung -> vorhandene Datei wird gelöscht
function Save-EinstellungsDatei {
    $aenderungen = Get-EinstellungsAenderungen
    $pfad = $script:EinstellungenDatei
    if ($aenderungen.Count -eq 0) {
        if (Test-Path -LiteralPath $pfad -PathType Leaf) { Remove-Item -LiteralPath $pfad -Force -ErrorAction Stop }
        return 0
    }
    $daten = [ordered]@{ '_Hinweis' = "Gespeichert von AD-Schnellanlage $ScriptVersion am $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Nur geänderte Werte - alles andere kommt aus dem Script." }
    foreach ($k in @($aenderungen.Keys)) { $daten[$k] = $aenderungen[$k] }
    $json = ConvertTo-Json -InputObject $daten -Depth 4
    [System.IO.File]::WriteAllText($pfad, $json, [System.Text.UTF8Encoding]::new($false))
    return $aenderungen.Count
}

# Alle Werte auf die Standards im Script zurück, Einstellungen.json löschen
function Reset-Einstellungen {
    if (Test-Path -LiteralPath $script:EinstellungenDatei -PathType Leaf) { Remove-Item -LiteralPath $script:EinstellungenDatei -Force -ErrorAction Stop }
    foreach ($k in @($script:EinstellungenStandard.Keys)) {
        $w = $script:EinstellungenStandard[$k]
        if ($w -is [array]) { $w = $w.Clone() }
        Set-EinstellungsWert $k $w
    }
    $script:EinstellungenGesetzt = [ordered]@{}
    Update-NachEinstellung '*'
}

function Edit-Einstellung($Definition) {
    $aktuell = Get-EinstellungsWert $Definition.Schluessel
    if ($Definition.Art -eq 'Bool') {
        $neu = -not [bool]$aktuell
    }
    else {
        if ($Definition.Hinweis) { Write-Info $Definition.Hinweis }
        $vorschlag = if ($Definition.Art -in 'OUListe', 'IPListe') { (@($aktuell | Where-Object { $_ }) -join ', ') } else { "$aktuell" }
        while ($true) {
            $eingabe = Read-Text "Neuer Wert für '$($Definition.Text)' (Enter = behalten, 'leer' = leeren)" $vorschlag
            if ($eingabe -ceq $vorschlag) { return }
            $pruefung = Test-EinstellungsWert $Definition $eingabe
            if ($pruefung.Ok) { $neu = $pruefung.Wert; break }
            Write-Warnung $pruefung.Fehler
        }
        if (Test-EinstellungGleich $neu $aktuell) { return }
        $beispiel = Get-EinstellungsBeispiel $Definition.Schluessel $neu
        if ($beispiel) { Write-Ok "Vorschau: $beispiel" }
        if ($Funktionen.Vorschau -and -not (Read-JaNein 'Übernehmen?' $true)) { return }
    }
    Set-Einstellung $Definition.Schluessel $neu
    Write-Ok "$($Definition.Text): $(Format-EinstellungsWert $Definition $neu)   (gilt sofort; [S] = dauerhaft speichern)"
    if ($Definition.Art -eq 'Bool') {
        $beispiel = Get-EinstellungsBeispiel $Definition.Schluessel $neu
        if ($beispiel) { Write-Info "Vorschau: $beispiel" }
    }
}

function Show-EinstellungsGruppe([string]$Gruppe) {
    while ($true) {
        $defs = @(Get-EinstellungsDefinitionen | Where-Object { $_.Gruppe -eq $Gruppe })
        Write-Titel "Einstellungen: $Gruppe"
        for ($i = 0; $i -lt $defs.Count; $i++) {
            $d      = $defs[$i]
            $wert   = Get-EinstellungsWert $d.Schluessel
            $zusatz = ''
            if ($script:EinstellungenStandard.Contains($d.Schluessel) -and -not (Test-EinstellungGleich $wert $script:EinstellungenStandard[$d.Schluessel])) {
                $zusatz = "   (Standard: $(Format-EinstellungsWert $d $script:EinstellungenStandard[$d.Schluessel]))"
            }
            Write-Host ('  [{0,2}] {1,-36} {2}{3}' -f ($i + 1), $d.Text, (Format-EinstellungsWert $d $wert), $zusatz)
        }
        $eingabe = Read-Text 'Nummer zum Ändern (Ja/Nein wird umgeschaltet, Enter = zurück)'
        if (-not $eingabe) { return }
        $nr = ConvertFrom-NummernAuswahl $eingabe $defs.Count
        if ($null -eq $nr -or $nr.Count -ne 1) { Write-Warnung 'Bitte eine Nummer eingeben.'; continue }
        try { Edit-Einstellung $defs[$nr[0] - 1] }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen.' }
    }
}

function Start-Einstellungen {
    $gruppen = @('Namensregeln', 'Benutzer-Standards', 'OU / Abteilung', 'DNS', 'Module ein/aus')
    while ($true) {
        $offen = Get-EinstellungsAenderungen
        $datei = Test-Path -LiteralPath $script:EinstellungenDatei -PathType Leaf
        Write-Titel 'Einstellungen'
        for ($i = 0; $i -lt $gruppen.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $gruppen[$i]) }
        Write-Host "  [S] Speichern in Einstellungen.json ($($offen.Count) vom Standard abweichende Werte)"
        Write-Host '  [R] Auf Standard zurücksetzen'
        Write-Host '  [0] Zurück zum Hauptmenü'
        Write-Info "Datei: $script:EinstellungenDatei  ($(if ($datei) { 'vorhanden' } else { 'noch nicht gespeichert' }))"
        $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
        if (-not $wahl -or $wahl -eq '0') {
            if ($offen.Count -and -not $datei) { Write-Info 'Hinweis: Änderungen gelten nur bis zum Beenden - mit [S] dauerhaft speichern.' }
            return
        }
        $zahl = 0
        if ([int]::TryParse($wahl, [ref]$zahl) -and $zahl -ge 1 -and $zahl -le $gruppen.Count) { Show-EinstellungsGruppe $gruppen[$zahl - 1]; continue }
        try {
            switch ($wahl) {
                'S' {
                    if ($offen.Count) {
                        Write-Info 'Wird gespeichert:'
                        $defs = @(Get-EinstellungsDefinitionen)
                        foreach ($k in @($offen.Keys)) {
                            $d = @($defs | Where-Object { $_.Schluessel -eq $k }) | Select-Object -First 1
                            Write-Host ('    {0,-36} {1}  ->  {2}' -f $d.Text, (Format-EinstellungsWert $d $script:EinstellungenStandard[$k]), (Format-EinstellungsWert $d $offen[$k])) -ForegroundColor White
                        }
                    }
                    elseif ($datei) { Write-Info 'Alle Werte entsprechen den Standards - Einstellungen.json wird gelöscht.' }
                    else { Write-Info 'Nichts zu speichern - alle Werte entsprechen den Standards.'; continue }
                    if (-not (Read-JaNein 'Jetzt speichern?' $true)) { Stop-Aktion }
                    $anzahl = Save-EinstellungsDatei
                    if ($anzahl) { Write-Ok "$anzahl Wert(e) gespeichert: $script:EinstellungenDatei" } else { Write-Ok 'Einstellungen.json gelöscht - es gelten die Standards.' }
                }
                'R' {
                    Write-Warnung 'Alle Werte gehen auf die Standards im Script zurück, Einstellungen.json wird gelöscht.'
                    if (-not (Read-JaNein 'Wirklich zurücksetzen?' $false)) { Stop-Aktion }
                    Reset-Einstellungen
                    Write-Ok 'Standardwerte wiederhergestellt.'
                }
                default { Write-Warnung 'Ungültige Auswahl.' }
            }
        }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen.' }
        catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    }
}
#endregion

#region ======================= [P] PROTOKOLL ========================

function Show-Protokoll {
    Write-Titel 'Protokoll dieser Sitzung'
    if ($script:Ergebnisse.Count -eq 0) { Write-Info 'Noch keine Einträge.' }
    else { $script:Ergebnisse | Format-Table Zeit, Typ, Status, Name, Info -AutoSize | Out-Host }
    if ($Funktionen.Protokoll) { Write-Info "Protokolldatei: $script:LogDatei" }
}
#endregion

#region ======================= FÄHIGKEITEN =========================

# Lädt ein Modul ohne Meldungen; $true = verfügbar
function Import-ModulStill([string]$Name) {
    if (Get-Module -Name $Name) { return $true }
    if (-not (Get-Module -ListAvailable -Name $Name)) { return $false }
    try {
        Import-Module -Name $Name -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false | Out-Null
        return $true
    }
    catch { return $false }
}

function Test-Befehl([string]$Name) {
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Test-Adminrechte {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return ([System.Security.Principal.WindowsPrincipal]::new($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# Was kann dieser Server? Ändert nichts und bricht nie ab.
# Rückgabe: AD, DNS, DnsRolle, DnsDienst, Smb, Gui, Admin, ServerManager, GpoDatei,
#           GroupPolicy, GPO, DhcpDatei, DhcpRolle, DhcpDienst, DhcpModul, DHCP ($true/$false),
#           Domain (Ergebnis von Get-ADDomain) und Grund (Text je fehlender Fähigkeit)
function Get-Faehigkeiten {
    $f = @{
        AD            = $false
        Domain        = $null
        DNS           = $false
        DnsRolle      = $false
        DnsDienst     = $false
        Smb           = Test-Befehl 'New-SmbShare'
        Gui           = Test-Befehl 'Out-GridView'
        DnsClient     = Test-Befehl 'Resolve-DnsName'
        DnsEntfernt   = $false
        Admin         = Test-Adminrechte
        ServerManager = Import-ModulStill 'ServerManager'
        Grund         = @{}
    }

    # Active Directory: Modul + erreichbare Domäne
    if (-not (Import-ModulStill 'ActiveDirectory')) {
        $f.Grund.AD = 'AD - Modul ActiveDirectory fehlt (Feature RSAT-AD-PowerShell)'
    }
    else {
        try {
            $f.Domain = Get-ADDomain -ErrorAction Stop
            $f.AD     = $true
        }
        catch { $f.Grund.AD = "AD - Domäne nicht erreichbar ($($_.Exception.Message))" }
    }

    # DNS: Rolle (Windows-Feature), Dienst, Modul - lokal
    if ($f.ServerManager) {
        try   { $f.DnsRolle = [bool](Get-WindowsFeature -Name DNS -ErrorAction Stop).Installed }
        catch { $f.DnsRolle = $false }
    }
    $dienst = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($dienst -and -not $f.ServerManager) { $f.DnsRolle = $true }   # ohne ServerManager: Dienst vorhanden = Rolle da
    $f.DnsDienst = [bool]($dienst -and "$($dienst.Status)" -eq 'Running')

    # Anderer DNS-Server ($DnsServerName): nur Modul + Erreichbarkeit zählen
    $f.DnsEntfernt = [bool]($DnsServerName -and $DnsServerName -ne $env:COMPUTERNAME -and $DnsServerName -notlike "$env:COMPUTERNAME.*")
    if ($f.DnsEntfernt) {
        if (-not (Import-ModulStill 'DnsServer')) { $f.Grund.DNS = 'DNS - Modul DnsServer fehlt (Feature RSAT-DNS-Server)' }
        else {
            try   { $null = Get-DnsServerSetting -ComputerName $DnsServerName -ErrorAction Stop; $f.DNS = $true }
            catch { $f.Grund.DNS = "DNS - Server $DnsServerName nicht erreichbar" }
        }
    }
    elseif (-not $f.DnsRolle)                     { $f.Grund.DNS = 'DNS - Rolle nicht installiert' }
    elseif (-not $f.DnsDienst)                    { $f.Grund.DNS = 'DNS - Dienst läuft nicht' }
    elseif (-not (Import-ModulStill 'DnsServer')) { $f.Grund.DNS = 'DNS - Modul DnsServer fehlt' }
    else                                          { $f.DNS = $true }
    if (-not $f.DnsClient) { $f.Grund.DnsClient = 'DNS - Resolve-DnsName fehlt (Modul DnsClient)' }

    # Gruppenrichtlinien: Teilmodul-Datei, AD und Modul GroupPolicy (Feature GPMC)
    $f.GpoDatei    = [bool]($script:Teilmodule -and $script:Teilmodule['GPO'])
    $f.GroupPolicy = Import-ModulStill 'GroupPolicy'
    $f.GPO         = $f.AD -and $f.GroupPolicy
    if (-not $f.GpoDatei)    { $f.Grund.GpoDatei = 'GPO - Datei Module\GPO.psm1 fehlt neben dem Script' }
    if (-not $f.GroupPolicy) { $f.Grund.GroupPolicy = 'GPO - Modul GroupPolicy fehlt (Feature GPMC, im Menü [G] installierbar)' }
    if (-not $f.GPO)         { $f.Grund.GPO = if (-not $f.AD) { $f.Grund.AD } else { $f.Grund.GroupPolicy } }
    if (-not $f.ServerManager) { $f.Grund.ServerManager = 'Modul ServerManager fehlt - Rollen hier nicht installierbar' }

    # DHCP: Teilmodul-Datei, Rolle (Windows-Feature), Dienst, Modul DhcpServer - lokal
    $f.DhcpDatei = [bool]($script:Teilmodule -and $script:Teilmodule['DHCP'])
    $f.DhcpRolle = $false
    if ($f.ServerManager) {
        try   { $f.DhcpRolle = [bool](Get-WindowsFeature -Name DHCP -ErrorAction Stop).Installed }
        catch { $f.DhcpRolle = $false }
    }
    $dhcpDienst = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($dhcpDienst -and -not $f.ServerManager) { $f.DhcpRolle = $true }   # ohne ServerManager: Dienst vorhanden = Rolle da
    $f.DhcpDienst = [bool]($dhcpDienst -and "$($dhcpDienst.Status)" -eq 'Running')
    $f.DhcpModul  = Import-ModulStill 'DhcpServer'
    $f.DHCP       = $false
    if (-not $f.DhcpDatei)      { $f.Grund.DhcpDatei = 'DHCP - Datei Module\DHCP.psm1 fehlt neben dem Script' }
    if (-not $f.DhcpRolle)      { $f.Grund.DHCP = 'DHCP - Rolle nicht installiert' }
    elseif (-not $f.DhcpDienst) { $f.Grund.DHCP = 'DHCP - Dienst läuft nicht' }
    elseif (-not $f.DhcpModul)  { $f.Grund.DHCP = 'DHCP - Modul DhcpServer fehlt (Feature RSAT-DHCP)' }
    else                        { $f.DHCP = $true }

    if (-not $f.Smb) { $f.Grund.Smb = 'SMB - Modul SmbShare fehlt' }
    if (-not $f.Gui) { $f.Grund.Gui = 'Auswahlfenster (Out-GridView) nicht vorhanden' }
    return $f
}

# Bedingungen eines Menüpunkts prüfen: '' = verfügbar, sonst der Grund.
# Jeder Eintrag in $Braucht muss erfüllt sein; 'AD|DNS' = eines von beiden reicht.
function Get-FehlendeFaehigkeit([string[]]$Braucht, [hashtable]$Faehig) {
    foreach ($bedingung in @($Braucht | Where-Object { $_ })) {
        $alternativen = @($bedingung -split '\|' | Where-Object { $_ })
        if (@($alternativen | Where-Object { $Faehig[$_] }).Count) { continue }
        $gruende = @($alternativen | ForEach-Object {
            if ($Faehig.Grund -and $Faehig.Grund[$_]) { $Faehig.Grund[$_] } else { "$_ nicht verfügbar" }
        })
        return ($gruende -join ' / ')
    }
    return ''
}

# Werte, die vom AD abhängen (nur aufrufen, wenn AD verfügbar ist)
function Initialize-AdUmgebung {
    $script:Domain = $script:Faehig.Domain
    $PSDefaultParameterValues['*-AD*:Server'] = $Domain.PDCEmulator
    if (-not $MailDomain) { $script:MailDomain = $Domain.DNSRoot }
    if (-not $UPNSuffix)  { $script:UPNSuffix  = $Domain.DNSRoot }
    $richtlinie = Get-ADDefaultDomainPasswordPolicy -ErrorAction SilentlyContinue
    if ($richtlinie) { $script:PwRichtlinie = $richtlinie }
}

# Windows-Feature installieren (für Teilmodule, z.B. GPMC). Fehlen die Installationsdateien
# (Server offline), wird nach dem Ordner \sources\sxs gefragt (-Source).
# $true = Feature ist danach installiert; die Fähigkeiten sind neu geprüft.
function Install-WindowsRolle {
    param([string]$Feature, [string]$Typ, [string]$Text)
    if (-not $script:Faehig.ServerManager) { Write-Warnung 'Modul ServerManager fehlt - Installation hier nicht möglich.'; return $false }
    $installiert = $false
    try { $installiert = [bool](Get-WindowsFeature -Name $Feature -ErrorAction Stop).Installed } catch { $installiert = $false }
    if ($installiert) { Add-Ergebnis $Typ $Feature $env:COMPUTERNAME 'VORHANDEN'; $script:Faehig = Get-Faehigkeiten; return $true }
    if (-not $script:Faehig.Admin) { Write-Warnung 'Ohne Administratorrechte schlägt die Installation fehl.' }
    Write-Info "Wird installiert: $Text (Install-WindowsFeature $Feature -IncludeManagementTools)"
    if ($Funktionen.Vorschau -and -not (Read-JaNein 'Jetzt installieren?' $true)) { Stop-Aktion }
    $quelle = ''
    while ($true) {
        $param = @{ Name = $Feature; IncludeManagementTools = $true; ErrorAction = 'Stop' }
        if ($quelle) { $param.Source = $quelle }
        try {
            Write-Info 'Installation läuft, das kann einige Minuten dauern ...'
            $erg = Install-WindowsFeature @param
            if (-not $erg.Success) { throw "Installation nicht erfolgreich (ExitCode $($erg.ExitCode))" }
            Add-Ergebnis $Typ $Feature $env:COMPUTERNAME 'OK' "ExitCode $($erg.ExitCode)"
            if ("$($erg.RestartNeeded)" -eq 'Yes') { Write-Warnung 'Windows meldet: Neustart des Servers nötig.' }
            break
        }
        catch {
            $meldung = $_.Exception.Message
            if (-not (Test-QuelleFehlt $meldung)) { Add-Ergebnis $Typ $Feature $env:COMPUTERNAME 'FEHLER' $meldung; return $false }
            Write-Warnung 'Die Installationsdateien wurden nicht gefunden (Server offline oder Feature-Dateien entfernt).'
            Write-Info 'Lösung: Windows-Server-ISO einbinden und den Ordner \sources\sxs angeben, z.B. D:\sources\sxs'
            Write-Info "(entspricht Install-WindowsFeature $Feature -IncludeManagementTools -Source D:\sources\sxs)"
            $quelle = (Read-Text 'Pfad zu \sources\sxs (Enter = abbrechen)').Trim('"')
            if (-not $quelle) { Add-Ergebnis $Typ $Feature $env:COMPUTERNAME 'FEHLER' 'Installationsdateien fehlen - mit -Source erneut versuchen'; return $false }
            if (-not (Test-Path -LiteralPath $quelle -PathType Container)) { Write-Warnung "Ordner '$quelle' nicht gefunden."; $quelle = '' }
        }
    }
    $script:Faehig = Get-Faehigkeiten
    return $true
}
#endregion

#region ======================= HAUPTMENÜ ===========================

# Wird in jedem Durchlauf neu gebaut, damit Präfixe und Fähigkeiten aktuell sind.
# An = Schalter aus $Funktionen (aus = ausgeblendet), Braucht = nötige Fähigkeiten
function Get-Hauptmenue {
    return @(
        [pscustomobject]@{ Taste = '1'; Text = 'OUs erstellen (auch verschachtelt: Firma/Buchhaltung)';      An = $Funktionen.OU;               Braucht = @('AD'); Aktion = { Start-OUs } }
        [pscustomobject]@{ Taste = '2'; Text = 'Benutzer erstellen (einzeln oder Schnelleingabe)';           An = $Funktionen.Benutzer;         Braucht = @('AD'); Aktion = { Start-BenutzerAnlage } }
        [pscustomobject]@{ Taste = '3'; Text = "Globale Gruppen ($PrefixGG<Name>)";                          An = $Funktionen.GlobaleGruppen;   Braucht = @('AD'); Aktion = { Start-GlobaleGruppen } }
        [pscustomobject]@{ Taste = '4'; Text = "Domänenlokale Gruppen + Rechte ($PrefixDL<Name>$TrennerRechte<Rechte>)"; An = $Funktionen.DLGruppen; Braucht = @('AD'); Aktion = { Start-DLGruppen } }
        [pscustomobject]@{ Taste = '5'; Text = 'AGDLP-Paket: GG + DL + Verschachtelung + Ordnerrechte';      An = $Funktionen.AGDLP;            Braucht = @('AD'); Aktion = { Start-AGDLP } }
        [pscustomobject]@{ Taste = '6'; Text = 'Abteilung komplett: OU + Unter-OUs + Gruppen + Benutzer';    An = $Funktionen.Abteilung;        Braucht = @('AD'); Aktion = { Start-Abteilung } }
        [pscustomobject]@{ Taste = '7'; Text = 'Mitglieder zu Gruppen hinzufügen';                           An = $Funktionen.Mitgliedschaften; Braucht = @('AD'); Aktion = { Start-Mitgliedschaften } }
        [pscustomobject]@{ Taste = '8'; Text = 'Rückgängig machen anhand des Protokolls (AD und DNS)';       An = ($Funktionen.Rueckgaengig -and $Funktionen.Protokoll); Braucht = @('AD|DNS'); Aktion = { Start-Rueckgaengig } }
        [pscustomobject]@{ Taste = 'D'; Text = 'DNS: Zonen, Einträge, PTR, Weiterleitungen';                  An = $Funktionen.DNS;              Braucht = @();     Aktion = { Start-DnsMenue } }
        [pscustomobject]@{ Taste = 'G'; Text = 'Gruppenrichtlinien: GPOs, Netzlaufwerke, Standard-Richtlinien'; An = $Funktionen.GPO;              Braucht = @('AD', 'GpoDatei'); Aktion = { Start-GpoMenue } }
        [pscustomobject]@{ Taste = 'H'; Text = 'DHCP: Einrichtungs-Assistent, Bereiche, Reservierungen';       An = $Funktionen.DHCP;             Braucht = @('DhcpDatei'); Aktion = { Start-DhcpMenue } }
        [pscustomobject]@{ Taste = 'S'; Text = 'Subnetzrechner (IPv4: Netz, Broadcast, Hosts)';              An = $Funktionen.Subnetzrechner;   Braucht = @();     Aktion = { Start-Subnetzrechner } }
        [pscustomobject]@{ Taste = 'E'; Text = 'Einstellungen ansehen und ändern';                            An = $true;                        Braucht = @();     Aktion = { Start-Einstellungen } }
        [pscustomobject]@{ Taste = 'P'; Text = 'Protokoll der Sitzung anzeigen';                             An = $true;                        Braucht = @();     Aktion = { Show-Protokoll } }
    )
}

function Show-Startanzeige {
    $f = $script:Faehig
    Write-Titel "AD-Schnellanlage $ScriptVersion"
    if ($f.AD)  { Write-Ok "Active Directory: ja ($($Domain.DNSRoot))" } else { Write-Info "Active Directory: nein  ($($f.Grund.AD))" }
    if ($f.DNS) { Write-Ok "DNS-Server:       ja ($(Get-DnsServerAnzeige))" } else { Write-Info "DNS-Server:       nein  ($($f.Grund.DNS))" }
    $modus = if ($script:GuiVerfuegbar) { 'Auswahlfenster (Out-GridView)' }
             elseif (-not $f.Gui)       { 'Konsole (Out-GridView nicht vorhanden)' }
             else                       { 'Konsole (Auswahlfenster abgeschaltet)' }
    Write-Info "Auswahlmodus:     $modus"
    if (-not $f.Admin) { Write-Warnung 'Keine Administratorrechte - Änderungen am Server schlagen wahrscheinlich fehl. Script "Als Administrator" starten.' }
}
#endregion

#region ======================= TEILMODULE ==========================
# Größere Bereiche liegen als eigene Dateien in Module\<Name>.psm1 neben dem Script. Sie werden
# hier in den Script-Bereich geladen (nicht per Import-Module), damit sie Eingabe, Protokoll,
# Einstellungen und Fähigkeiten des Hauptscripts mitbenutzen. Fehlt eine Datei, fehlen nur
# ihre Menüpunkte (Grund steht im Menü). Pester lädt die Teilmodule beim Dot-Sourcing mit.
$script:Teilmodule = @{}
foreach ($teilmodul in @('GPO', 'DHCP')) {
    $teilmodulPfad = Join-Path (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }) 'Module') "$teilmodul.psm1"
    if (-not (Test-Path -LiteralPath $teilmodulPfad -PathType Leaf)) { continue }
    try {
        . ([scriptblock]::Create([System.IO.File]::ReadAllText($teilmodulPfad)))
        $script:Teilmodule[$teilmodul] = $teilmodulPfad
    }
    catch { Write-Warnung "Teilmodul $teilmodul.psm1 nicht geladen: $($_.Exception.Message)" }
}
#endregion

#region ======================= START ===============================

function Start-Hauptprogramm {
    $script:ScriptOrdner       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
    $script:EinstellungenDatei = Join-Path $script:ScriptOrdner 'Einstellungen.json'
    Initialize-Einstellungen

    $script:Faehig       = Get-Faehigkeiten
    $script:Domain       = $null
    $script:PwRichtlinie = [pscustomobject]@{ MinPasswordLength = 8; ComplexityEnabled = $true }
    if ($script:Faehig.AD) { Initialize-AdUmgebung }

    if (-not $LogOrdner) { $script:LogOrdner = Join-Path $script:ScriptOrdner 'AD-Schnellanlage-Protokolle' }
    if (-not (Test-Path -LiteralPath $LogOrdner)) {
        try   { New-Item -ItemType Directory -Path $LogOrdner -Force -ErrorAction Stop | Out-Null }
        catch { Write-Warnung "Protokollordner nicht anlegbar: $($_.Exception.Message)" }
    }
    $script:LogDatei          = Join-Path $LogOrdner ('AD-Anlage_{0:yyyy-MM-dd_HH-mm-ss}.csv' -f (Get-Date))
    $script:Ergebnisse        = [System.Collections.Generic.List[object]]::new()
    $script:LogFehlerGemeldet = $false
    $script:GuiVerfuegbar     = $Funktionen.FensterAuswahl -and $script:Faehig.Gui

    Show-Startanzeige

    while ($true) {
        $punkte = @(Get-Hauptmenue | Where-Object { $_.An })
        $titel  = if ($Domain) { "AD-Schnellanlage $ScriptVersion   Domäne: $($Domain.DNSRoot)" } else { "AD-Schnellanlage $ScriptVersion   Server: $env:COMPUTERNAME" }
        Write-Titel $titel
        $gesperrt = [ordered]@{}
        foreach ($m in $punkte) {
            $grund = Get-FehlendeFaehigkeit $m.Braucht $script:Faehig
            if ($grund) { $gesperrt[$grund] = @($gesperrt[$grund]) + "[$($m.Taste)]"; continue }
            Write-Host ('  [{0}] {1}' -f $m.Taste, $m.Text)
        }
        Write-Host '  [0] Beenden'
        foreach ($grund in @($gesperrt.Keys)) {
            Write-Host ('  Nicht verfügbar: {0}  ->  {1}' -f (@($gesperrt[$grund] | Where-Object { $_ }) -join ' '), $grund) -ForegroundColor DarkGray
        }

        $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
        if ($wahl -in '0', 'Q', 'X') { break }
        $punkt = @($punkte | Where-Object { $_.Taste -eq $wahl }) | Select-Object -First 1
        if (-not $punkt) { Write-Warnung 'Ungültige Auswahl.'; continue }
        $grund = Get-FehlendeFaehigkeit $punkt.Braucht $script:Faehig
        if ($grund) { Write-Warnung "[$($punkt.Taste)] ist auf diesem Server nicht verfügbar: $grund"; continue }
        try { & $punkt.Aktion }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen - zurück zum Menü.' }
        catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    }

    if ($script:Ergebnisse.Count -and $Funktionen.Protokoll) { Write-Info "Protokoll gespeichert: $script:LogDatei" }
    Write-Info 'Auf Wiedersehen.'
}
#endregion

# Nur bei direktem Aufruf starten, nicht beim Dot-Sourcing (Pester lädt so die Funktionen)
if ($MyInvocation.InvocationName -ne '.') { Start-Hauptprogramm }
