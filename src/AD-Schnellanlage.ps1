#Requires -Version 5.1
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    AD-Schnellanlage - OUs, Benutzer und Gruppen in Sekunden anlegen.

.DESCRIPTION
    Interaktives Menue fuer Windows Server mit Active Directory.
    Nutzt ausschliesslich Bordmittel: ActiveDirectory-Modul, SmbShare-Modul,
    .NET und - wenn vorhanden - Out-GridView. Keine externen Programme.

    Menue (jeder Punkt einzeln ein-/ausschaltbar unter KONFIGURATION -> $Funktionen):
      [1] OUs erstellen (auch verschachtelt: Firma/Buchhaltung)
      [2] Benutzer erstellen (einzeln oder Schnelleingabe in einer Zeile)
      [3] Benutzer aus CSV importieren          [V] CSV-Vorlage erstellen
      [4] Globale Gruppen               -> GG_Name
      [5] Domaenenlokale Gruppen + Rechte -> DL_Name_M
      [6] AGDLP-Paket: GG + DL + Verschachtelung + Ordnerrechte
      [7] Abteilung komplett: OU + Unter-OUs + Gruppen + Ordner + Benutzer
      [8] Mitglieder zu Gruppen hinzufuegen
      [9] Rueckgaengig machen anhand des Protokolls
      [P] Protokoll der Sitzung anzeigen

.NOTES
    Start:   powershell.exe -ExecutionPolicy Bypass -File .\AD-Schnellanlage.ps1
    Laeuft auf einem Domaenencontroller oder einem Server mit dem Windows-Feature
    "RSAT-AD-PowerShell". Enter uebernimmt immer den Vorschlag in [eckigen Klammern].
#>

#region ======================= KONFIGURATION =======================
# Alles in diesem Block darf angepasst werden.

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

# --- Protokoll -------------------------------------------------------
$LogOrdner           = ''         # leer = Ordner "AD-Schnellanlage-Protokolle" neben dem Script

# --- Module ein/aus ($false = ausgeblendet bzw. Schritt wird übersprungen)
$Funktionen = [ordered]@{
    # Menüpunkte
    OU                  = $true   # [1]
    Benutzer            = $true   # [2]
    CsvImport           = $true   # [3] + [V]
    GlobaleGruppen      = $true   # [4]
    DLGruppen           = $true   # [5]
    AGDLP               = $true   # [6]
    Abteilung           = $true   # [7]
    Mitgliedschaften    = $true   # [8]
    Rueckgaengig        = $true   # [9] (braucht Protokoll)
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

# Gemeinsamer Abschluss für manuell, Schnelleingabe und CSV:
# Passwörter -> Einstellungen -> Extras -> Vorschau -> Erstellen
function Complete-BenutzerAnlage {
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

#region ======================= MODUL [3] CSV-IMPORT =================

# Liest UTF-8 (mit/ohne BOM) und ANSI (Excel), Trennzeichen ; oder ,
function Import-CsvAuto([string]$Pfad) {
    $voll  = (Resolve-Path -LiteralPath $Pfad).ProviderPath
    $bytes = [System.IO.File]::ReadAllBytes($voll)
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch {
        $ansi = if ($PSVersionTable.PSVersion.Major -lt 6) { [System.Text.Encoding]::Default } else { [System.Text.Encoding]::GetEncoding(28591) }
        $text = $ansi.GetString($bytes)
    }
    $zeilen = @($text.TrimStart([char]0xFEFF) -split '\r?\n' | Where-Object { $_.Trim() })
    if ($zeilen.Count -lt 2) { return }
    $trenner = if ($zeilen[0].Contains(';')) { ';' } else { ',' }
    return ($zeilen | ConvertFrom-Csv -Delimiter $trenner)
}

# OU-Angabe aus der CSV: DN, "Firma/Buchhaltung", "firma.local/Firma/Buchhaltung" oder nur "Buchhaltung"
function Resolve-OuWert([string]$Wert, [object[]]$Ziele) {
    if ($Wert -match '=') {
        $treffer = @($Ziele | Where-Object { $_.DN -eq $Wert })
    }
    else {
        $w = $Wert.Replace('\', '/').Trim('/')
        $treffer = @($Ziele | Where-Object { $_.Pfad -eq "$($Domain.DNSRoot)/$w" -or $_.Pfad -eq $w })
        if ($treffer.Count -eq 0) { $treffer = @($Ziele | Where-Object { $_.Pfad.EndsWith("/$w", [System.StringComparison]::OrdinalIgnoreCase) }) }
    }
    if ($treffer.Count -eq 1) { return $treffer[0].DN }
    return $null
}

function Resolve-GruppeName([string]$Name, [hashtable]$Cache) {
    if ($Cache.ContainsKey($Name)) { return $Cache[$Name] }
    $esc = ConvertTo-LdapWert $Name
    $treffer = @(Get-ADGroup -LDAPFilter "(|(sAMAccountName=$esc)(name=$esc))" -ErrorAction SilentlyContinue)
    $dn = if ($treffer.Count -eq 1) { $treffer[0].DistinguishedName } else { '' }
    $Cache[$Name] = $dn
    return $dn
}

function Import-BenutzerCsv {
    Write-Titel 'Benutzer aus CSV importieren'
    Write-Info 'Spalten: Vorname;Nachname;Anmeldename;Passwort;OU;Abteilung;Gruppen'
    Write-Info 'Pflicht: Vorname + Nachname. Mehrere Gruppen mit | trennen. Vorlage: Menüpunkt [V].'
    $pfad = (Read-Text 'Pfad zur CSV-Datei (Enter = abbrechen)').Trim('"')
    if (-not $pfad) { Stop-Aktion }
    if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) { Write-Warnung 'Datei nicht gefunden.'; return }

    $zeilen = @(Import-CsvAuto $pfad)
    if ($zeilen.Count -eq 0) { Write-Warnung 'Keine Datenzeilen gefunden.'; return }
    $spalten = @($zeilen[0].PSObject.Properties.Name)
    if ($spalten -notcontains 'Vorname' -or $spalten -notcontains 'Nachname') {
        Write-Warnung "Spalten 'Vorname' und 'Nachname' fehlen (Trennzeichen ; oder ,)."
        return
    }

    $ziele        = @(Get-ZielListe)
    $gruppenCache = @{}
    $standardZiel = $null
    $vergeben     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $plaene       = [System.Collections.Generic.List[object]]::new()
    $nr           = 1

    foreach ($z in $zeilen) {
        $nr++
        $v = "$($z.Vorname)".Trim()
        $n = "$($z.Nachname)".Trim()
        if (-not $v -or -not $n) { Write-Warnung "Zeile ${nr}: Vor- oder Nachname fehlt - übersprungen."; continue }

        $ouWert = "$($z.OU)".Trim()
        if ($ouWert) {
            $ziel = Resolve-OuWert $ouWert $ziele
            if (-not $ziel) { Write-Warnung "Zeile ${nr}: OU '$ouWert' nicht gefunden oder nicht eindeutig - übersprungen."; continue }
        }
        else {
            if (-not $standardZiel) {
                Write-Info 'Mindestens eine Zeile hat keine OU angegeben.'
                $standardZiel = Select-AdZiel 'Benutzer ohne OU-Angabe'
            }
            $ziel = $standardZiel
        }

        $sam = "$($z.Anmeldename)".Trim()
        if ($sam) {
            if ($sam.Length -gt 20 -or $sam -match '["/\\\[\]:;|=,+*?<>\s]' -or $vergeben.Contains($sam) -or (Test-SamVorhanden $sam)) {
                Write-Warnung "Zeile ${nr}: Anmeldename '$sam' ungültig oder vergeben - übersprungen."
                continue
            }
        }
        else { $sam = Get-FreierAnmeldename $v $n $vergeben }

        $pw = "$($z.Passwort)"
        if ($pw) {
            $problem = Test-PasswortRichtlinie $pw
            if ($problem) { Write-Warnung "Zeile ${nr} ($sam): $problem - übersprungen."; continue }
        }

        $p = New-BenutzerPlan $v $n $ziel
        Set-PlanAnmeldename $p $sam $vergeben
        if ($pw) { $p.Passwort = ConvertTo-SecureString $pw -AsPlainText -Force; $p.PasswortArt = 'aus CSV' }
        if ("$($z.Abteilung)".Trim()) { $p.Abteilung = "$($z.Abteilung)".Trim() }
        foreach ($g in ("$($z.Gruppen)" -split '[|,]')) {
            $g = $g.Trim()
            if (-not $g) { continue }
            $dn = Resolve-GruppeName $g $gruppenCache
            if ($dn) { $p.Gruppen.Add($dn) } else { Write-Warnung "Zeile ${nr}: Gruppe '$g' nicht gefunden - wird ignoriert." }
        }
        $plaene.Add($p)
    }

    if ($plaene.Count -eq 0) { Write-Warnung 'Keine gültigen Zeilen.'; return }
    Write-Ok "$($plaene.Count) Benutzer aus der CSV vorbereitet."

    $ohnePw     = @($plaene | Where-Object { -not $_.Passwort })
    $modus      = ''
    $gleichesPw = $null
    if ($ohnePw.Count) {
        Write-Info "$($ohnePw.Count) Benutzer haben kein Passwort in der CSV."
        $modus = Select-PasswortModus $ohnePw.Count
        if ($modus -eq 'Gleich') { $gleichesPw = Read-Passwort 'alle ohne CSV-Passwort' }
    }
    Complete-BenutzerAnlage -Plaene $plaene.ToArray() -PwModus $modus -GleichesPw $gleichesPw
}

function New-CsvVorlage {
    Write-Titel 'CSV-Vorlage erstellen'
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = [Environment]::GetFolderPath('MyDocuments') }
    if (-not $desktop) { $desktop = (Get-Location).ProviderPath }
    $pfad = (Read-Text 'Speichern unter' (Join-Path $desktop 'Benutzer-Import.csv')).Trim('"')
    if ((Test-Path -LiteralPath $pfad) -and -not (Read-JaNein 'Datei existiert schon. Überschreiben?' $false)) { Stop-Aktion }
    $beispiel = @(
        [pscustomobject]@{ Vorname = 'Max';  Nachname = 'Muster';   Anmeldename = '';           Passwort = ''; OU = 'Firma/Buchhaltung'; Abteilung = 'Buchhaltung'; Gruppen = "$($PrefixGG)Buchhaltung" }
        [pscustomobject]@{ Vorname = 'Anna'; Nachname = 'Beispiel'; Anmeldename = 'a.beispiel'; Passwort = ''; OU = '';                  Abteilung = '';            Gruppen = "$($PrefixGG)Alle|$($PrefixGG)Vertrieb" }
    )
    try {
        $beispiel | Export-Csv -LiteralPath $pfad -NoTypeInformation -Delimiter ';' -Encoding UTF8 -ErrorAction Stop
        Write-Ok "Vorlage gespeichert: $pfad"
        Write-Info 'Leere Felder = automatisch: Anmeldename nach Muster, OU wird gefragt, Passwort-Art wird gefragt.'
    }
    catch { Write-Warnung "Speichern fehlgeschlagen: $($_.Exception.Message)" }
}
#endregion

#region ======================= MODUL [4] + [5] GRUPPEN ==============

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

#region ======================= MODUL [6] AGDLP ======================

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

#region ======================= MODUL [7] ABTEILUNG ==================

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

#region ======================= MODUL [8] MITGLIEDSCHAFTEN ===========

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

#region ======================= MODUL [9] RÜCKGÄNGIG =================

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
    $typen   = 'Mitglied', 'Freigabe', 'Benutzer', 'Gruppe', 'OU'
    $rueck   = @($daten | Where-Object { $typen -contains $_.Typ })
    $manuell = @($daten | Where-Object { $_.Typ -in 'Ordner', 'NTFS', 'Home' } | Select-Object -ExpandProperty DN -Unique)
    if ($rueck.Count -eq 0) { Write-Warnung 'In diesem Protokoll gibt es nichts zum Rückgängigmachen.'; return }

    Write-Info 'Wird entfernt:'
    foreach ($gruppe in ($rueck | Group-Object Typ)) { Write-Host ('    {0,-10} {1}' -f $gruppe.Name, $gruppe.Count) -ForegroundColor White }
    Write-Warnung 'Achtung: Diese Objekte werden aus dem AD GELÖSCHT (nicht leere OUs bleiben stehen).'
    if ("$(Read-Host "  Zum Bestätigen 'JA' eingeben")".Trim() -cne 'JA') { Stop-Aktion }

    foreach ($typ in $typen) {
        $liste = @($rueck | Where-Object { $_.Typ -eq $typ })
        if ($typ -eq 'OU') { $liste = @($liste | Sort-Object { ($_.DN -split '(?<!\\),').Count } -Descending) }
        foreach ($e in $liste) {
            try {
                switch ($typ) {
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
                Add-Ergebnis $typ $e.Name $e.DN 'ENTFERNT'
            }
            catch [System.Management.Automation.ItemNotFoundException] { Add-Ergebnis $typ $e.Name $e.DN 'FEHLT' 'existiert nicht mehr' }
            catch { Add-Ergebnis $typ $e.Name $e.DN 'FEHLER' $_.Exception.Message }
        }
    }
    if ($manuell.Count) {
        Write-Warnung 'Nicht automatisch entfernt (Ordner, NTFS-Rechte, Home-Ordner) - bei Bedarf von Hand löschen:'
        foreach ($m in $manuell) { Write-Info $m }
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

#region ======================= START ===============================

try { $Domain = Get-ADDomain -ErrorAction Stop }
catch {
    Write-Host "  Domäne nicht erreichbar: $($_.Exception.Message)" -ForegroundColor Red
    return
}
$PSDefaultParameterValues['*-AD*:Server'] = $Domain.PDCEmulator
if (-not $MailDomain) { $MailDomain = $Domain.DNSRoot }
if (-not $UPNSuffix)  { $UPNSuffix  = $Domain.DNSRoot }
$script:PwRichtlinie = Get-ADDefaultDomainPasswordPolicy -ErrorAction SilentlyContinue
if (-not $script:PwRichtlinie) { $script:PwRichtlinie = [pscustomobject]@{ MinPasswordLength = 8; ComplexityEnabled = $true } }
if (-not $LogOrdner) { $LogOrdner = Join-Path $PSScriptRoot 'AD-Schnellanlage-Protokolle' }
if (-not (Test-Path -LiteralPath $LogOrdner)) { New-Item -ItemType Directory -Path $LogOrdner -Force | Out-Null }
$script:LogDatei          = Join-Path $LogOrdner ('AD-Anlage_{0:yyyy-MM-dd_HH-mm-ss}.csv' -f (Get-Date))
$script:Ergebnisse        = [System.Collections.Generic.List[object]]::new()
$script:LogFehlerGemeldet = $false
$script:GuiVerfuegbar     = $Funktionen.FensterAuswahl -and [bool](Get-Command Out-GridView -ErrorAction SilentlyContinue)

$menue = @(
    [pscustomobject]@{ Taste = '1'; Text = 'OUs erstellen (auch verschachtelt: Firma/Buchhaltung)';      An = $Funktionen.OU;               Aktion = { Start-OUs } }
    [pscustomobject]@{ Taste = '2'; Text = 'Benutzer erstellen (einzeln oder Schnelleingabe)';           An = $Funktionen.Benutzer;         Aktion = { Start-BenutzerAnlage } }
    [pscustomobject]@{ Taste = '3'; Text = 'Benutzer aus CSV importieren';                               An = $Funktionen.CsvImport;        Aktion = { Import-BenutzerCsv } }
    [pscustomobject]@{ Taste = 'V'; Text = 'CSV-Vorlage erstellen';                                      An = $Funktionen.CsvImport;        Aktion = { New-CsvVorlage } }
    [pscustomobject]@{ Taste = '4'; Text = "Globale Gruppen ($PrefixGG<Name>)";                          An = $Funktionen.GlobaleGruppen;   Aktion = { Start-GlobaleGruppen } }
    [pscustomobject]@{ Taste = '5'; Text = "Domänenlokale Gruppen + Rechte ($PrefixDL<Name>$TrennerRechte<Rechte>)"; An = $Funktionen.DLGruppen; Aktion = { Start-DLGruppen } }
    [pscustomobject]@{ Taste = '6'; Text = 'AGDLP-Paket: GG + DL + Verschachtelung + Ordnerrechte';      An = $Funktionen.AGDLP;            Aktion = { Start-AGDLP } }
    [pscustomobject]@{ Taste = '7'; Text = 'Abteilung komplett: OU + Unter-OUs + Gruppen + Benutzer';    An = $Funktionen.Abteilung;        Aktion = { Start-Abteilung } }
    [pscustomobject]@{ Taste = '8'; Text = 'Mitglieder zu Gruppen hinzufügen';                           An = $Funktionen.Mitgliedschaften; Aktion = { Start-Mitgliedschaften } }
    [pscustomobject]@{ Taste = '9'; Text = 'Rückgängig machen anhand des Protokolls';                    An = ($Funktionen.Rueckgaengig -and $Funktionen.Protokoll); Aktion = { Start-Rueckgaengig } }
    [pscustomobject]@{ Taste = 'P'; Text = 'Protokoll der Sitzung anzeigen';                             An = $true;                        Aktion = { Show-Protokoll } }
)

while ($true) {
    Write-Titel "AD-Schnellanlage   Domäne: $($Domain.DNSRoot)"
    foreach ($m in @($menue | Where-Object { $_.An })) { Write-Host ('  [{0}] {1}' -f $m.Taste, $m.Text) }
    Write-Host '  [0] Beenden'
    $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
    if ($wahl -in '0', 'Q', 'X') { break }
    $punkt = @($menue | Where-Object { $_.An -and $_.Taste -eq $wahl }) | Select-Object -First 1
    if (-not $punkt) { Write-Warnung 'Ungültige Auswahl.'; continue }
    try { & $punkt.Aktion }
    catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen - zurück zum Menü.' }
    catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
}

if ($script:Ergebnisse.Count -and $Funktionen.Protokoll) { Write-Info "Protokoll gespeichert: $script:LogDatei" }
Write-Info 'Auf Wiedersehen.'
#endregion
