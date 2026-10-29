<#
    Teilmodul GPO - Gruppenrichtlinien für AD-Schnellanlage (Menü [G]).

    Wird vom Hauptscript in dessen Bereich geladen (nicht per Import-Module) und benutzt
    dessen Eingabe (Read-Text, Read-JaNein, Select-AusListe ...), Protokoll (Add-Ergebnis),
    $Domain, $Funktionen und $script:Faehig.

    Bordmittel: Module GroupPolicy (Feature GPMC), ActiveDirectory, SmbShare.
    Laufwerkszuordnungen (Group Policy Preferences) kann das Modul GroupPolicy nicht -
    dafür wird Drives.xml im SYSVOL selbst geschrieben, die Erweiterung in
    gPCUserExtensionNames eingetragen und die Benutzerversion in AD und GPT.ini erhöht.
    Aufbau und GUIDs: docs/GPO.md
#>

# GUIDs der Laufwerkszuordnungen (Group Policy Preferences, Benutzerkonfiguration)
$script:GppSammelCse    = '{00000000-0000-0000-0000-000000000000}'
$script:GppLaufwerkCse  = '{5794DAFD-BE60-433F-88A2-1A31939AC01F}'
$script:GppLaufwerkTool = '{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}'
$script:GppDrivesClsid  = '{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}'
$script:GppDriveClsid   = '{935D1B74-9CB8-4e3c-9914-7DD559B7A417}'
$script:GppLaufwerkErweiterung = "[$script:GppSammelCse$script:GppLaufwerkTool][$script:GppLaufwerkCse$script:GppLaufwerkTool]"

#region ======================= GPO-HILFSFUNKTIONEN (ohne Server) ====

# "h", "H:", " h: " -> "H". Nur D bis Z (A/B Diskette, C System). Ungültig -> ''
function ConvertTo-GpoLaufwerk([string]$Text) {
    $t = "$Text".Trim().TrimEnd(':').ToUpper()
    if ($t -match '^[D-Z]$') { return $t }
    return ''
}

# UNC-Pfad prüfen: '' = in Ordnung, sonst der Fehler
function Get-UncPfadFehler([string]$Pfad) {
    $p = "$Pfad".Trim()
    if (-not $p) { return 'darf nicht leer sein' }
    if ($p -notmatch '^\\\\[^\\]') { return 'muss mit \\ beginnen, z.B. \\server\freigabe' }
    $teile = @($p.Substring(2).TrimEnd('\') -split '\\')
    if ($teile.Count -lt 2) { return 'braucht Server und Freigabe, z.B. \\server\freigabe' }
    foreach ($t in $teile) {
        if (-not $t) { return 'enthält \\ mitten im Pfad' }
        if ($t -match '[/:*?"<>|]') { return "ungültige Zeichen in '$t' (/ : * ? `" < > |)" }
    }
    if ($teile[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*$') { return "ungültiger Servername '$($teile[0])'" }
    return ''
}

# "\\srv01\Daten$\Abt" -> Server srv01, Freigabe Daten$, Rest Abt
function Get-UncTeile([string]$Pfad) {
    $teile = @("$Pfad".Trim().Substring(2).TrimEnd('\') -split '\\')
    return [pscustomobject]@{
        Server   = $teile[0]
        Freigabe = $teile[1]
        Rest     = (@($teile | Select-Object -Skip 2) -join '\')
    }
}

# Liegt der Server aus dem UNC-Pfad auf diesem Rechner?
function Test-UncAufDiesemServer([string]$Server) {
    $s = "$Server".Trim().ToLower()
    $ich = "$env:COMPUTERNAME".ToLower()
    return ($s -eq $ich -or $s.StartsWith("$ich.") -or $s -in 'localhost', '127.0.0.1')
}

# Pfad für Dateien (z.B. Hintergrundbild): UNC, lokal (C:\...) oder mit Umgebungsvariable
function Get-GpoPfadFehler([string]$Pfad) {
    $p = "$Pfad".Trim()
    if ($p.StartsWith('\\')) { return (Get-UncPfadFehler $p) }
    if ($p -match '^[A-Za-z]:\\.+' -or $p -match '^%[A-Za-z_]+%\\.+') {
        if ($p -match '[*?"<>|]') { return 'ungültige Zeichen (* ? " < > |)' }
        return ''
    }
    return 'Pfad als \\server\freigabe\datei.jpg, C:\Ordner\datei.jpg oder %SystemRoot%\...'
}

# GUID der GPO in der Schreibweise von AD und SYSVOL: {6AC1786C-016F-11D2-945F-00C04FB984F9}
function Get-GpoGuidText($Id) {
    return '{' + "$Id".Trim('{', '}').ToUpper() + '}'
}

# gPCUserExtensionNames "[{CSE}{Tool}...][...]" -> geordnete Tabelle CSE -> Tool-GUIDs
function ConvertFrom-GpoErweiterungen([string]$Text) {
    $tabelle = [ordered]@{}
    foreach ($m in [regex]::Matches("$Text", '\[([^\]]*)\]')) {
        $guids = @([regex]::Matches($m.Groups[1].Value, '\{[0-9A-Fa-f\-]{36}\}') | ForEach-Object { $_.Value.ToUpper() })
        if ($guids.Count -eq 0) { continue }
        $cse = $guids[0]
        if (-not $tabelle.Contains($cse)) { $tabelle[$cse] = [System.Collections.Generic.List[string]]::new() }
        foreach ($g in @($guids | Select-Object -Skip 1)) {
            if (-not $tabelle[$cse].Contains($g)) { $tabelle[$cse].Add($g) }
        }
    }
    return $tabelle
}

# Erweiterungen zusammenführen: vorhandene bleiben, neue kommen dazu, alles nach GUID sortiert
function Add-GpoErweiterung([string]$Vorhanden, [string]$Neu) {
    $tabelle = ConvertFrom-GpoErweiterungen $Vorhanden
    $dazu    = ConvertFrom-GpoErweiterungen $Neu
    foreach ($cse in @($dazu.Keys)) {
        if (-not $tabelle.Contains($cse)) { $tabelle[$cse] = [System.Collections.Generic.List[string]]::new() }
        foreach ($g in $dazu[$cse]) { if (-not $tabelle[$cse].Contains($g)) { $tabelle[$cse].Add($g) } }
    }
    $teile = foreach ($cse in @($tabelle.Keys | Sort-Object)) {
        '[' + $cse + (@($tabelle[$cse] | Sort-Object) -join '') + ']'
    }
    return (-join @($teile))
}

# versionNumber der GPO: obere 16 Bit = Benutzer, untere 16 Bit = Computer
function Get-GpoVersionTeile([int]$Version) {
    return [pscustomobject]@{ Benutzer = (($Version -shr 16) -band 0xFFFF); Computer = ($Version -band 0xFFFF) }
}

# Benutzerversion um 1 erhöhen, Computerversion bleibt (nach 65535 geht es mit 1 weiter)
function Get-GpoVersionNeu([int]$Version) {
    $t = Get-GpoVersionTeile $Version
    $benutzer = ($t.Benutzer + 1) % 65536
    if ($benutzer -eq 0) { $benutzer = 1 }
    $wert = [int64]$benutzer * 65536 + $t.Computer
    if ($wert -gt [int]::MaxValue) { $wert -= 4294967296 }
    return [int]$wert
}

# Zeile "Version=" in GPT.ini setzen (fehlt sie, wird sie unter [General] ergänzt)
function Set-GptIniVersion([string]$Text, [int]$Version) {
    if ($Text -match '(?im)^Version=') { return ($Text -replace '(?im)^Version=-?\d*', "Version=$Version") }
    if ($Text -match '(?im)^\[General\]\r?\n') { return ($Text -replace '(?im)^(\[General\]\r?\n)', "`${1}Version=$Version`r`n") }
    return "[General]`r`nVersion=$Version`r`n$Text"
}

# gPLink eines AD-Objekts "[LDAP://cn={GUID},cn=policies,...;0][...]" -> GUID, Aktiviert, Erzwungen
function ConvertFrom-GpLink([string]$Text) {
    $liste = foreach ($m in [regex]::Matches("$Text", '\[LDAP://[^\]]*?(\{[0-9A-Fa-f\-]{36}\})[^\]]*;(\d+)\]')) {
        $optionen = [int]$m.Groups[2].Value
        [pscustomobject]@{
            Guid      = $m.Groups[1].Value.ToUpper()
            Aktiviert = -not ($optionen -band 1)
            Erzwungen = [bool]($optionen -band 2)
        }
    }
    return @($liste)
}

# ---- Drives.xml (Group Policy Preferences) ---------------------------

function New-GppLaufwerkXml {
    $xml = New-Object System.Xml.XmlDocument
    $wurzel = $xml.CreateElement('Drives')
    $wurzel.SetAttribute('clsid', $script:GppDrivesClsid)
    [void]$xml.AppendChild($wurzel)
    return , $xml
}

# Ein <Drive>-Element als Objekt
function ConvertFrom-GppLaufwerk($Element) {
    $p = $Element.SelectSingleNode('Properties')
    $f = $Element.SelectSingleNode('Filters/FilterGroup')
    $buchstabe = if ($p -and $p.GetAttribute('letter')) { $p.GetAttribute('letter') } else { "$($Element.GetAttribute('name'))".TrimEnd(':') }
    return [pscustomobject]@{
        Buchstabe   = $buchstabe.ToUpper()
        Pfad        = if ($p) { $p.GetAttribute('path') } else { '' }
        Bezeichnung = if ($p) { $p.GetAttribute('label') } else { '' }
        Aktion      = if ($p) { $p.GetAttribute('action') } else { '' }
        GruppeName  = if ($f) { $f.GetAttribute('name') } else { '' }
        GruppeSid   = if ($f) { $f.GetAttribute('sid') } else { '' }
        Uid         = $Element.GetAttribute('uid')
    }
}

function Get-GppLaufwerkElemente([xml]$Xml) {
    if (-not $Xml -or -not $Xml.DocumentElement) { return @() }
    return @($Xml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Drive' })
}

# Alle Laufwerke einer Drives.xml
function Get-GppLaufwerke([xml]$Xml) {
    return @(Get-GppLaufwerkElemente $Xml | ForEach-Object { ConvertFrom-GppLaufwerk $_ })
}

# Laufwerk eintragen. Gleicher Buchstabe wird ersetzt (uid bleibt), nie doppelt.
# Rückgabe: 'Neu', 'Vorhanden' (genau so schon da) oder 'Geaendert'
function Set-GppLaufwerk {
    param(
        [xml]$Xml,
        [string]$Buchstabe,
        [string]$Pfad,
        [string]$Bezeichnung = '',
        [ValidateSet('C', 'R', 'U')][string]$Aktion = 'U',
        [string]$GruppeName = '',
        [string]$GruppeSid = '',
        [string]$Zeit = ''
    )
    if (-not $Zeit) { $Zeit = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $Buchstabe = $Buchstabe.TrimEnd(':').ToUpper()
    $alt = @(Get-GppLaufwerkElemente $Xml | Where-Object { (ConvertFrom-GppLaufwerk $_).Buchstabe -eq $Buchstabe }) | Select-Object -First 1
    $uid = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
    if ($alt) {
        $v = ConvertFrom-GppLaufwerk $alt
        if ($v.Pfad -eq $Pfad -and $v.Bezeichnung -ceq $Bezeichnung -and $v.Aktion -eq $Aktion -and $v.GruppeSid -eq $GruppeSid) { return 'Vorhanden' }
        if ($v.Uid) { $uid = $v.Uid }
    }
    $bild = @{ C = '0'; R = '1'; U = '2' }[$Aktion]

    $drive = $Xml.CreateElement('Drive')
    $drive.SetAttribute('clsid', $script:GppDriveClsid)
    $drive.SetAttribute('name', "${Buchstabe}:")
    $drive.SetAttribute('status', "${Buchstabe}:")
    $drive.SetAttribute('image', $bild)
    $drive.SetAttribute('changed', $Zeit)
    $drive.SetAttribute('uid', $uid)
    $p = $Xml.CreateElement('Properties')
    $p.SetAttribute('action', $Aktion)
    $p.SetAttribute('thisDrive', 'NOCHANGE')
    $p.SetAttribute('allDrives', 'NOCHANGE')
    $p.SetAttribute('userName', '')
    $p.SetAttribute('path', $Pfad)
    $p.SetAttribute('label', $Bezeichnung)
    $p.SetAttribute('persistent', '0')
    $p.SetAttribute('useLetter', '1')
    $p.SetAttribute('letter', $Buchstabe)
    [void]$drive.AppendChild($p)
    if ($GruppeSid) {
        $filter = $Xml.CreateElement('Filters')
        $g = $Xml.CreateElement('FilterGroup')
        $g.SetAttribute('bool', 'AND')
        $g.SetAttribute('not', '0')
        $g.SetAttribute('name', $GruppeName)
        $g.SetAttribute('sid', $GruppeSid)
        $g.SetAttribute('userContext', '1')
        $g.SetAttribute('primaryGroup', '0')
        $g.SetAttribute('localGroup', '0')
        [void]$filter.AppendChild($g)
        [void]$drive.AppendChild($filter)
    }
    if ($alt) {
        [void]$Xml.DocumentElement.ReplaceChild($drive, $alt)
        return 'Geaendert'
    }
    [void]$Xml.DocumentElement.AppendChild($drive)
    return 'Neu'
}

# Text der Datei, wie ihn die GPMC schreibt (Deklaration + eine Zeile)
function ConvertTo-GppText([xml]$Xml) {
    return '<?xml version="1.0" encoding="utf-8"?>' + "`r`n" + $Xml.DocumentElement.OuterXml
}

function Get-GpoAktionText([string]$Aktion) {
    switch ($Aktion) {
        'C' { return 'Erstellen' }
        'R' { return 'Ersetzen' }
        'U' { return 'Aktualisieren' }
        'D' { return 'Löschen' }
    }
    return $Aktion
}

# ---- Standard-Richtlinien (Vorlagen) --------------------------------

# Eingebaute Vorlagen. Erweiterbar über GPO-Richtlinien.json neben dem Script
# (Beispiel: config/GPO-Richtlinien.example.json). {eingabe} wird durch die Antwort ersetzt.
function Get-GpoStandardVorlagen {
    return @(
        @{
            Name  = 'Systemsteuerung'
            Text  = 'Systemsteuerung und PC-Einstellungen sperren'
            Werte = @(@{ Schluessel = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoControlPanel'; Typ = 'DWord'; Wert = '1' })
        }
        @{
            Name    = 'Desktophintergrund'
            Text    = 'Desktophintergrund festlegen'
            Hinweis = 'Das Bild muss für alle Benutzer lesbar sein, z.B. auf einer Freigabe oder in NETLOGON.'
            Eingabe = @{ Frage = 'Pfad zum Bild, z.B. \\server\freigabe\hintergrund.jpg'; Art = 'Pfad' }
            Werte   = @(
                @{ Schluessel = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'Wallpaper'; Typ = 'String'; Wert = '{eingabe}' }
                @{ Schluessel = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'WallpaperStyle'; Typ = 'String'; Wert = '4' }
            )
        }
        @{
            Name    = 'Eingabeaufforderung'
            Text    = 'Eingabeaufforderung (cmd) sperren'
            Hinweis = 'Anmeldescripts laufen weiterhin (DisableCMD = 2).'
            Werte   = @(@{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\System'; Name = 'DisableCMD'; Typ = 'DWord'; Wert = '2' })
        }
        @{
            Name  = 'USB-Speicher'
            Text  = 'USB-Speicher und alle Wechselmedien sperren'
            Werte = @(@{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\RemovableStorageDevices'; Name = 'Deny_All'; Typ = 'DWord'; Wert = '1' })
        }
        @{
            Name    = 'Bildschirmsperre'
            Text    = 'Bildschirmsperre nach X Minuten'
            Eingabe = @{ Frage = 'Minuten bis zur Sperre'; Art = 'Zahl'; Standard = '10'; Min = 1; Max = 999; Faktor = 60 }
            Werte   = @(
                @{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveActive'; Typ = 'String'; Wert = '1' }
                @{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaverIsSecure'; Typ = 'String'; Wert = '1' }
                @{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveTimeOut'; Typ = 'String'; Wert = '{eingabe}' }
                @{ Schluessel = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'SCRNSAVE.EXE'; Typ = 'String'; Wert = 'scrnsave.scr' }
            )
        }
    )
}

# Vorlage (Hashtable oder Objekt aus JSON) prüfen -> Vorlage oder Fehler
function ConvertTo-GpoVorlage($Objekt) {
    $e = [pscustomobject]@{ Vorlage = $null; Fehler = '' }
    $name = "$($Objekt.Name)".Trim()
    if (-not $name) { $e.Fehler = 'Eintrag ohne Name'; return $e }
    $typen = 'String', 'ExpandString', 'DWord', 'QWord', 'MultiString'
    $werte = [System.Collections.Generic.List[object]]::new()
    foreach ($w in @($Objekt.Werte)) {
        if ($null -eq $w) { continue }
        $schluessel = "$($w.Schluessel)".Trim().TrimEnd('\')
        if ($schluessel -notmatch '^(HKCU|HKLM)\\.+') { $e.Fehler = "'$name': Schlüssel muss mit HKCU\ oder HKLM\ beginnen ('$schluessel')"; return $e }
        $typ = @($typen | Where-Object { $_ -eq "$($w.Typ)" }) | Select-Object -First 1
        if (-not $typ) { $e.Fehler = "'$name': Typ '$($w.Typ)' unbekannt (erlaubt: $($typen -join ', '))"; return $e }
        $wertName = "$($w.Name)".Trim()
        if (-not $wertName) { $e.Fehler = "'$name': Wert ohne Name"; return $e }
        $werte.Add([pscustomobject]@{ Schluessel = $schluessel; Name = $wertName; Typ = $typ; Wert = "$($w.Wert)" })
    }
    if ($werte.Count -eq 0) { $e.Fehler = "'$name': keine Werte"; return $e }

    $mitPlatzhalter = @($werte | Where-Object { $_.Wert -match '\{eingabe\}' }).Count
    $eingabe = $null
    if ($Objekt.Eingabe) {
        $art = @('Zahl', 'Pfad', 'Text' | Where-Object { $_ -eq "$($Objekt.Eingabe.Art)" }) | Select-Object -First 1
        if (-not $art) { $e.Fehler = "'$name': Eingabe-Art '$($Objekt.Eingabe.Art)' unbekannt (Zahl, Pfad oder Text)"; return $e }
        if (-not $mitPlatzhalter) { $e.Fehler = "'$name': Eingabe wird in keinem Wert als {eingabe} verwendet"; return $e }
        $zahl = { param($Wert, [int]$Standard) $z = 0; if ([int]::TryParse("$Wert", [ref]$z)) { $z } else { $Standard } }
        $eingabe = [pscustomobject]@{
            Frage    = if ("$($Objekt.Eingabe.Frage)") { "$($Objekt.Eingabe.Frage)" } else { 'Wert' }
            Art      = $art
            Standard = "$($Objekt.Eingabe.Standard)"
            Min      = & $zahl $Objekt.Eingabe.Min 0
            Max      = & $zahl $Objekt.Eingabe.Max ([int]::MaxValue)
            Faktor   = & $zahl $Objekt.Eingabe.Faktor 1
        }
    }
    elseif ($mitPlatzhalter) { $e.Fehler = "'$name': {eingabe} ohne Eingabe-Angabe"; return $e }

    $hklm = @($werte | Where-Object { $_.Schluessel -like 'HKLM\*' }).Count
    $bereich = if ($hklm -eq $werte.Count) { 'Computer' } elseif ($hklm) { 'Benutzer + Computer' } else { 'Benutzer' }
    $e.Vorlage = [pscustomobject]@{
        Name    = $name
        Text    = if ("$($Objekt.Text)".Trim()) { "$($Objekt.Text)".Trim() } else { $name }
        Hinweis = "$($Objekt.Hinweis)"
        Eingabe = $eingabe
        Werte   = $werte.ToArray()
        Bereich = $bereich
    }
    return $e
}

# JSON-Text {"Richtlinien": [...]} mit den Basis-Vorlagen zusammenführen (gleicher Name = ersetzt)
function Merge-GpoVorlagenJson([string]$Json, [object[]]$Basis) {
    $liste     = [System.Collections.Generic.List[object]]::new()
    $warnungen = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $Basis) { $liste.Add($b) }
    $ergebnis = [pscustomobject]@{ Vorlagen = $liste; Warnungen = $warnungen }
    try { $objekt = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { $warnungen.Add("GPO-Richtlinien.json ist fehlerhaft ($($_.Exception.Message)) - nur eingebaute Vorlagen."); return $ergebnis }
    if (-not $objekt -or -not ($objekt.PSObject.Properties.Name -contains 'Richtlinien')) {
        $warnungen.Add('GPO-Richtlinien.json: Eintrag "Richtlinien" fehlt - nur eingebaute Vorlagen.')
        return $ergebnis
    }
    foreach ($o in @($objekt.Richtlinien)) {
        $r = ConvertTo-GpoVorlage $o
        if ($r.Fehler) { $warnungen.Add("GPO-Richtlinien.json: $($r.Fehler) - übersprungen."); continue }
        $alt = @($liste | Where-Object { $_.Name -eq $r.Vorlage.Name }) | Select-Object -First 1
        if ($alt) { $liste[$liste.IndexOf($alt)] = $r.Vorlage } else { $liste.Add($r.Vorlage) }
    }
    return $ergebnis
}

# Alle Vorlagen: eingebaute + GPO-Richtlinien.json ($Datei leer = neben dem Script)
function Get-GpoVorlagen([string]$Datei = '') {
    $basis = @(Get-GpoStandardVorlagen | ForEach-Object { (ConvertTo-GpoVorlage $_).Vorlage })
    if (-not $Datei) {
        if (-not $script:ScriptOrdner) { return $basis }
        $Datei = Join-Path $script:ScriptOrdner 'GPO-Richtlinien.json'
    }
    if (-not (Test-Path -LiteralPath $Datei -PathType Leaf)) { return $basis }
    $r = Merge-GpoVorlagenJson ([System.IO.File]::ReadAllText($Datei)) $basis
    foreach ($w in $r.Warnungen) { Write-Warnung $w }
    return @($r.Vorlagen)
}

# Antwort auf die Eingabe einer Vorlage prüfen ('' = in Ordnung)
function Test-GpoVorlageEingabe($Eingabe, [string]$Text) {
    $t = "$Text".Trim()
    switch ($Eingabe.Art) {
        'Zahl' {
            $z = 0
            if (-not [int]::TryParse($t, [ref]$z) -or $z -lt $Eingabe.Min -or $z -gt $Eingabe.Max) { return "Bitte eine ganze Zahl von $($Eingabe.Min) bis $($Eingabe.Max) eingeben." }
        }
        'Pfad' {
            $f = Get-GpoPfadFehler $t
            if ($f) { return "Ungültiger Pfad: $f" }
        }
        default { if (-not $t) { return 'Eingabe darf nicht leer sein.' } }
    }
    return ''
}

# Werte einer Vorlage mit eingesetzter Antwort und passendem Typ -> Werte + Fehler
function Get-GpoVorlageWerte($Vorlage, [string]$Eingabe = '') {
    $ergebnis = [pscustomobject]@{ Werte = @(); Fehler = '' }
    $einsetzen = "$Eingabe".Trim()
    if ($Vorlage.Eingabe -and $Vorlage.Eingabe.Art -eq 'Zahl') { $einsetzen = [string]([int64]$einsetzen * $Vorlage.Eingabe.Faktor) }
    $liste = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $Vorlage.Werte) {
        $text = $w.Wert.Replace('{eingabe}', $einsetzen)
        $wert = $text
        if ($w.Typ -eq 'DWord') {
            $z = 0
            if (-not [int]::TryParse($text, [ref]$z)) { $ergebnis.Fehler = "$($w.Name): '$text' ist keine Zahl (DWord)"; break }
            $wert = $z
        }
        elseif ($w.Typ -eq 'QWord') {
            $z = [int64]0
            if (-not [int64]::TryParse($text, [ref]$z)) { $ergebnis.Fehler = "$($w.Name): '$text' ist keine Zahl (QWord)"; break }
            $wert = $z
        }
        elseif ($w.Typ -eq 'MultiString') { $wert = [string[]]@($text -split '\|') }
        $liste.Add([pscustomobject]@{ Schluessel = $w.Schluessel; Name = $w.Name; Typ = $w.Typ; Wert = $wert; Anzeige = $text })
    }
    if (-not $ergebnis.Fehler) { $ergebnis.Werte = $liste.ToArray() }
    return $ergebnis
}

# ---- Bericht --------------------------------------------------------

# Get-GPOReport -ReportType Xml -> kurze Zusammenfassung
function Get-GpoBerichtInfo([xml]$Bericht) {
    $lokal = { param([string]$Pfad) @(Select-Xml -Xml $Bericht -XPath $Pfad | ForEach-Object { $_.Node }) }
    $text  = { param([string]$Pfad) $k = @(& $lokal $Pfad) | Select-Object -First 1; if ($k) { $k.InnerText } else { '' } }
    $laufwerke = foreach ($d in @(& $lokal "//*[local-name()='User']//*[local-name()='Drive']")) {
        $p = @($d.ChildNodes | Where-Object { $_.LocalName -eq 'Properties' }) | Select-Object -First 1
        $pfad = if ($p) { $p.GetAttribute('path') } else { '' }
        '{0} {1}' -f $d.GetAttribute('name'), $pfad
    }
    $einstellungen = @(& $lokal "//*[local-name()='Extension']//*[local-name()='Policy' or local-name()='RegistrySetting']").Count
    $links = foreach ($l in @(& $lokal "//*[local-name()='LinksTo']")) {
        $somPfad = @($l.ChildNodes | Where-Object { $_.LocalName -eq 'SOMPath' }) | Select-Object -First 1
        $an      = @($l.ChildNodes | Where-Object { $_.LocalName -eq 'Enabled' }) | Select-Object -First 1
        $zusatz  = if ($an -and $an.InnerText -eq 'false') { ' (deaktiviert)' } else { '' }
        if ($somPfad) { "$($somPfad.InnerText)$zusatz" }
    }
    return [pscustomobject]@{
        Name           = & $text "/*[local-name()='GPO']/*[local-name()='Name']"
        BenutzerAd     = & $text "/*[local-name()='GPO']/*[local-name()='User']/*[local-name()='VersionDirectory']"
        BenutzerSysvol = & $text "/*[local-name()='GPO']/*[local-name()='User']/*[local-name()='VersionSysvol']"
        Laufwerke      = @($laufwerke)
        Einstellungen  = $einstellungen
        Links          = @($links)
    }
}
#endregion

#region ======================= GPO-SERVER ===========================

# SYSVOL-Ordner der GPO auf dem PDC-Emulator - dort schreiben auch New-GPO und Set-GPRegistryValue
function Get-GpoSysvolPfad($Gpo) {
    $server = if ($Domain.PDCEmulator) { $Domain.PDCEmulator } else { $Domain.DNSRoot }
    return "\\$server\SYSVOL\$($Domain.DNSRoot)\Policies\$(Get-GpoGuidText $Gpo.Id)"
}

function Get-GpoDrivesPfad($Gpo) {
    return (Join-Path (Get-GpoSysvolPfad $Gpo) 'User\Preferences\Drives\Drives.xml')
}

# Vorhandene Drives.xml lesen (fehlt sie: neues, leeres Dokument)
function Read-GppLaufwerkDatei($Gpo) {
    $pfad = Get-GpoDrivesPfad $Gpo
    if (-not (Test-Path -LiteralPath $pfad -PathType Leaf)) { return , (New-GppLaufwerkXml) }
    $xml = [xml][System.IO.File]::ReadAllText($pfad)
    return , $xml
}

function Save-GppLaufwerkDatei($Gpo, [xml]$Xml) {
    $pfad   = Get-GpoDrivesPfad $Gpo
    $ordner = Split-Path -Parent $pfad
    if (-not (Test-Path -LiteralPath $ordner)) { New-Item -ItemType Directory -Path $ordner -Force -ErrorAction Stop | Out-Null }
    [System.IO.File]::WriteAllText($pfad, (ConvertTo-GppText $Xml), [System.Text.UTF8Encoding]::new($false))
}

# Benutzerversion in AD (versionNumber) und GPT.ini gleich erhöhen, Erweiterung eintragen
function Update-GpoBenutzerVersion($Gpo, [string]$Erweiterung = '') {
    $ad = Get-ADObject -Identity $Gpo.Path -Properties versionNumber, gPCUserExtensionNames -ErrorAction Stop
    $version  = Get-GpoVersionNeu ([int]$ad.versionNumber)
    $ersetzen = @{ versionNumber = $version }
    if ($Erweiterung) {
        $neu = Add-GpoErweiterung "$($ad.gPCUserExtensionNames)" $Erweiterung
        if ($neu -cne "$($ad.gPCUserExtensionNames)") { $ersetzen.gPCUserExtensionNames = $neu }
    }
    Set-ADObject -Identity $Gpo.Path -Replace $ersetzen -ErrorAction Stop
    $ini  = Join-Path (Get-GpoSysvolPfad $Gpo) 'GPT.ini'
    $kodierung = [System.Text.Encoding]::Default
    $text = if (Test-Path -LiteralPath $ini -PathType Leaf) { [System.IO.File]::ReadAllText($ini, $kodierung) } else { "[General]`r`n" }
    [System.IO.File]::WriteAllText($ini, (Set-GptIniVersion $text $version), $kodierung)
    return $version
}

# Wo ist die GPO verknüpft? -> DN, Kurzpfad, Aktiviert
function Get-GpoVerknuepfungen($Gpo) {
    $guid = Get-GpoGuidText $Gpo.Id
    $liste = foreach ($o in @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" -Properties gPLink -ErrorAction SilentlyContinue)) {
        foreach ($l in @(ConvertFrom-GpLink $o.gPLink | Where-Object { $_.Guid -eq $guid })) {
            [pscustomobject]@{ DN = $o.DistinguishedName; Pfad = (Get-Kurzpfad $o.DistinguishedName); Aktiviert = $l.Aktiviert }
        }
    }
    return @($liste)
}

# GPO auswählen. $NeuVorschlag gesetzt = "(neue GPO anlegen)" anbieten.
# Rückgabe: Gpo (vorhanden) oder Name (neu, wird erst nach der Bestätigung angelegt)
function Select-Gpo([string]$Titel, [string]$NeuVorschlag = '') {
    $gpos = @(Get-GPO -All -ErrorAction Stop | Sort-Object DisplayName)
    if (-not $NeuVorschlag -and $gpos.Count -eq 0) { Write-Warnung 'Noch keine GPO vorhanden - zuerst unter [1] erstellen.'; Stop-Aktion }
    $eintraege = @()
    if ($NeuVorschlag) { $eintraege += [pscustomobject]@{ Anzeige = '(neue GPO anlegen)'; Gpo = $null } }
    $eintraege += @($gpos | ForEach-Object {
        [pscustomobject]@{ Anzeige = '{0,-40} geändert {1:dd.MM.yyyy HH:mm}' -f $_.DisplayName, $_.ModificationTime; Gpo = $_ }
    })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel $Titel)
    if ($wahl.Count -eq 0) { Stop-Aktion }
    if ($wahl[0].Gpo) {
        Write-Ok "GPO: $($wahl[0].Gpo.DisplayName)"
        return [pscustomobject]@{ Gpo = $wahl[0].Gpo; Name = $wahl[0].Gpo.DisplayName }
    }
    return (Read-GpoName $NeuVorschlag)
}

# Name für eine neue GPO; gibt es sie schon, wird die vorhandene verwendet
function Read-GpoName([string]$Vorschlag) {
    while ($true) {
        $name = Read-Text 'Name der GPO' $Vorschlag -Pflicht
        if ($name.Length -gt 200) { Write-Warnung 'Höchstens 200 Zeichen.'; continue }
        $vorhanden = Get-GPO -Name $name -ErrorAction SilentlyContinue
        if ($vorhanden) {
            Write-Info "Die GPO '$name' gibt es schon - sie wird verwendet, nichts wird doppelt angelegt."
            return [pscustomobject]@{ Gpo = $vorhanden; Name = $name }
        }
        return [pscustomobject]@{ Gpo = $null; Name = $name }
    }
}

# GPO anlegen (vorhanden -> VORHANDEN). Rückgabe: GPO oder $null
function New-GpoObjekt([string]$Name, [string]$Kommentar = '') {
    $vorhanden = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($vorhanden) { Add-Ergebnis 'GPO' $Name $vorhanden.Path 'VORHANDEN'; return $vorhanden }
    $param = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($Kommentar) { $param.Comment = $Kommentar }
    try {
        $gpo = New-GPO @param
        Add-Ergebnis 'GPO' $Name $gpo.Path 'OK' -Bezug (Get-GpoGuidText $gpo.Id)
        return $gpo
    }
    catch { Add-Ergebnis 'GPO' $Name '' 'FEHLER' $_.Exception.Message; return $null }
}

# Auswahl aus Select-Gpo auflösen: neue GPO jetzt anlegen
function Resolve-GpoAuswahl($Auswahl) {
    if ($Auswahl.Gpo) { return $Auswahl.Gpo }
    return (New-GpoObjekt $Auswahl.Name 'Angelegt mit AD-Schnellanlage')
}

# GPO mit OU (oder Domänenstamm) verknüpfen und den Link aktivieren
function Add-GpoLink($Gpo, [string]$ZielDN) {
    $text = "$($Gpo.DisplayName) -> $(Get-Kurzpfad $ZielDN)"
    try {
        $link = @((Get-GPInheritance -Target $ZielDN -ErrorAction Stop).GpoLinks | Where-Object { "$($_.GpoId)" -eq "$($Gpo.Id)" }) | Select-Object -First 1
        if ($link -and $link.Enabled) { Add-Ergebnis 'GPO-Link' $text $ZielDN 'VORHANDEN'; return }
        if ($link) {
            Set-GPLink -Guid $Gpo.Id -Target $ZielDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
            Add-Ergebnis 'GPO-Link' $text $ZielDN 'OK' 'war deaktiviert - jetzt aktiviert' -Bezug (Get-GpoGuidText $Gpo.Id)
            return
        }
        New-GPLink -Guid $Gpo.Id -Target $ZielDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
        Add-Ergebnis 'GPO-Link' $text $ZielDN 'OK' -Bezug (Get-GpoGuidText $Gpo.Id)
    }
    catch { Add-Ergebnis 'GPO-Link' $text $ZielDN 'FEHLER' $_.Exception.Message }
}

# Nach einer Änderung: ist die GPO nirgends verknüpft, Verknüpfung anbieten
function Invoke-GpoVerknuepfungAnbieten($Gpo) {
    $links = @(Get-GpoVerknuepfungen $Gpo)
    if ($links.Count) {
        Write-Info "Verknüpft mit: $(($links | ForEach-Object { if ($_.Aktiviert) { $_.Pfad } else { "$($_.Pfad) (deaktiviert)" } }) -join ', ')"
        return
    }
    Write-Warnung "Die GPO '$($Gpo.DisplayName)' ist noch nirgends verknüpft und wirkt deshalb nicht."
    if (-not (Read-JaNein 'Jetzt mit einer OU verknüpfen?' $true)) { return }
    $ziel = Select-AdZiel 'die Verknüpfung' -OhneContainer
    if ($Funktionen.Vorschau -and -not (Read-JaNein "GPO '$($Gpo.DisplayName)' mit $(Get-Kurzpfad $ziel) verknüpfen?" $true)) { return }
    Add-GpoLink $Gpo $ziel
}

function Show-GpoBericht($Info) {
    Write-Host ''
    Write-Host "  Bericht (Get-GPOReport): $($Info.Name)" -ForegroundColor Cyan
    Write-Info "Benutzerversion AD / SYSVOL: $($Info.BenutzerAd) / $($Info.BenutzerSysvol)"
    if ($Info.BenutzerAd -ne $Info.BenutzerSysvol) { Write-Warnung 'Versionen in AD und SYSVOL sind (noch) verschieden - nach der Replikation erneut prüfen.' }
    if ($Info.Laufwerke.Count) { Write-Info "Laufwerkszuordnungen: $($Info.Laufwerke -join ', ')" }
    Write-Info "Registry-Einstellungen: $($Info.Einstellungen)"
    Write-Info ('Verknüpft mit: ' + $(if ($Info.Links.Count) { $Info.Links -join ', ' } else { 'nichts' }))
}

# Abschluss: Bericht zur Kontrolle, gpupdate anbieten
function Invoke-GpoAbschluss($Gpo) {
    try {
        $bericht = [xml](Get-GPOReport -Guid $Gpo.Id -ReportType Xml -ErrorAction Stop)
        Show-GpoBericht (Get-GpoBerichtInfo $bericht)
    }
    catch { Write-Warnung "Bericht nicht abrufbar: $($_.Exception.Message)" }
    Write-Info 'Am Client: gpupdate /force, danach ab- und wieder anmelden (Laufwerke werden bei der Anmeldung verbunden).'
    $pc = Read-Text 'Einen Client jetzt per Invoke-GPUpdate aktualisieren? Computername (Enter = nein)'
    if (-not $pc) { return }
    try {
        Invoke-GPUpdate -Computer $pc -Force -RandomDelayInMinutes 0 -ErrorAction Stop
        Write-Ok "gpupdate auf $pc angestoßen."
    }
    catch { Write-Warnung "Invoke-GPUpdate auf $pc fehlgeschlagen ($($_.Exception.Message)) - dort von Hand 'gpupdate /force' ausführen." }
}

# Freigabe auf diesem Server anlegen: Ordner + SMB-Freigabe + NTFS-Recht Ändern für die Gruppe
function New-GpoFreigabe([string]$Unc, $Gruppe) {
    $teile = Get-UncTeile $Unc
    if ($teile.Rest) { Write-Warnung "Unterordner '$($teile.Rest)' bitte nach dem Anlegen der Freigabe von Hand erstellen." }
    if (-not $script:Faehig.Smb) { Write-Warnung 'Modul SmbShare fehlt - Freigabe bitte von Hand anlegen.'; return $false }
    if (Get-SmbShare -Name $teile.Freigabe -ErrorAction SilentlyContinue) { Add-Ergebnis 'Freigabe' $teile.Freigabe $Unc 'VORHANDEN'; return $true }
    $vorschlag = "C:\Freigaben\$($teile.Freigabe.TrimEnd('$'))"
    while ($true) {
        $ordner = (Read-Text 'Lokaler Ordner für die Freigabe' $vorschlag -Pflicht).Trim('"')
        if ($ordner -match '^[A-Za-z]:\\[^*?"<>|]*$') { break }
        Write-Warnung 'Bitte einen lokalen Pfad angeben, z.B. D:\Freigaben\Daten'
    }
    $admins = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value
    $wer    = if ($Gruppe) { $Gruppe.Name } else { Get-AuthentifizierteBenutzer }
    $sid    = if ($Gruppe) { $Gruppe.Sid } else { [System.Security.Principal.SecurityIdentifier]'S-1-5-11' }
    Write-Info 'Wird angelegt:'
    Write-Host "    Ordner     $ordner" -ForegroundColor White
    Write-Host "    Freigabe   \\$env:COMPUTERNAME\$($teile.Freigabe)   (Freigaberecht: $wer = Ändern, $admins = Vollzugriff)" -ForegroundColor White
    Write-Host "    NTFS       $wer = Ändern" -ForegroundColor White
    if (-not (Read-JaNein 'Ordner und Freigabe jetzt anlegen?' $true)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $ordner -PathType Container)) {
            New-Item -ItemType Directory -Path $ordner -Force -ErrorAction Stop | Out-Null
            Add-Ergebnis 'Ordner' $ordner $ordner 'OK'
        }
        Add-NtfsRegel -Pfad $ordner -Identitaet $sid -Recht 'Modify'
        Add-Ergebnis 'NTFS' "$wer = Ändern" $ordner 'OK' 'M'
        New-SmbShare -Name $teile.Freigabe -Path $ordner -ChangeAccess $wer -FullAccess $admins -FolderEnumerationMode AccessBased -ErrorAction Stop | Out-Null
        Add-Ergebnis 'Freigabe' $teile.Freigabe $ordner 'OK'
        return $true
    }
    catch { Add-Ergebnis 'Freigabe' $teile.Freigabe $ordner 'FEHLER' $_.Exception.Message; return $false }
}

# Gruppe für Item-Level-Targeting wählen (optional) -> Name (DOMÄNE\sam), Sid oder $null
function Select-GpoZielgruppe {
    if (-not (Read-JaNein 'Nur für Mitglieder einer bestimmten Gruppe (Zielgruppenadressierung)?' $false)) { return $null }
    $dns = @(Select-AdObjekte -Art Gruppe -Titel 'Gruppe für die Zielgruppenadressierung wählen')
    if ($dns.Count -eq 0) { return $null }
    if ($dns.Count -gt 1) { Write-Warnung 'Es zählt nur die erste gewählte Gruppe.' }
    $g = Get-ADGroup -Identity $dns[0] -ErrorAction Stop
    $name = "$($Domain.NetBIOSName)\$($g.SamAccountName)"
    Write-Ok "Zielgruppe: $name"
    return [pscustomobject]@{ Name = $name; Sid = $g.SID; SidText = "$($g.SID)" }
}
#endregion

#region ======================= MODUL [G] GRUPPENRICHTLINIEN ==========

function Get-GpoMenue {
    $f = $script:Faehig
    return @(
        [pscustomobject]@{ Taste = '1'; Text = 'GPO erstellen (optional gleich verknüpfen)';              An = $true; Braucht = @('GPO'); Aktion = { Start-GpoErstellen } }
        [pscustomobject]@{ Taste = '2'; Text = 'Netzlaufwerk zuordnen (Einstellungen > Laufwerkszuordnungen)'; An = $true; Braucht = @('GPO'); Aktion = { Start-GpoNetzlaufwerk } }
        [pscustomobject]@{ Taste = '3'; Text = 'Standard-Richtlinie anwenden (Systemsteuerung, USB, ...)'; An = $true; Braucht = @('GPO'); Aktion = { Start-GpoStandardRichtlinie } }
        [pscustomobject]@{ Taste = '4'; Text = 'GPO mit OU verknüpfen';                                   An = $true; Braucht = @('GPO'); Aktion = { Start-GpoVerknuepfen } }
        [pscustomobject]@{ Taste = '5'; Text = 'Vorhandene GPOs anzeigen';                                An = $true; Braucht = @('GPO'); Aktion = { Show-GpoListe } }
        [pscustomobject]@{ Taste = '6'; Text = 'GPO entfernen';                                           An = $true; Braucht = @('GPO'); Aktion = { Start-GpoEntfernen } }
        [pscustomobject]@{ Taste = '7'; Text = 'Gruppenrichtlinienverwaltung (GPMC) installieren';        An = (-not $f.GroupPolicy); Braucht = @('ServerManager'); Aktion = { Install-GpoVerwaltung } }
    )
}

function Start-GpoMenue {
    while ($true) {
        $sichtbar = @()
        $gruende  = @()
        foreach ($m in @(Get-GpoMenue | Where-Object { $_.An })) {
            $grund = Get-FehlendeFaehigkeit $m.Braucht $script:Faehig
            if (-not $grund) { $sichtbar += $m }
            elseif ($gruende -notcontains $grund) { $gruende += $grund }
        }
        Write-Titel "Gruppenrichtlinien   Domäne: $($Domain.DNSRoot)"
        foreach ($m in $sichtbar) { Write-Host ('  [{0}] {1}' -f $m.Taste, $m.Text) }
        Write-Host '  [0] Zurück zum Hauptmenü'
        if ($gruende.Count) { Write-Host "  Weitere Punkte ausgeblendet: $($gruende -join ' / ')" -ForegroundColor DarkGray }
        $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
        if (-not $wahl -or $wahl -eq '0') { return }
        $punkt = @($sichtbar | Where-Object { $_.Taste -eq $wahl }) | Select-Object -First 1
        if (-not $punkt) { Write-Warnung 'Ungültige Auswahl.'; continue }
        try { & $punkt.Aktion }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen - zurück zum GPO-Menü.' }
        catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# [G][1]
function Start-GpoErstellen {
    Write-Titel 'GPO erstellen'
    $auswahl = Read-GpoName 'Neue Richtlinie'
    $gpo = $auswahl.Gpo
    $kommentar = ''
    if (-not $auswahl.Gpo) { $kommentar = Read-Text 'Kommentar (optional)' 'Angelegt mit AD-Schnellanlage' }
    $ziel = ''
    if (Read-JaNein 'Gleich mit einer OU verknüpfen?' $true) { $ziel = Select-AdZiel 'die Verknüpfung' -OhneContainer }
    if ($Funktionen.Vorschau) {
        Write-Info 'Wird erstellt:'
        if ($auswahl.Gpo) { Write-Host "    GPO   $($auswahl.Name)   (vorhanden)" -ForegroundColor Yellow }
        else { Write-Host "    GPO   $($auswahl.Name)" -ForegroundColor White }
        if ($ziel) { Write-Host "    Link  -> $(Get-Kurzpfad $ziel)   (aktiviert)" -ForegroundColor White }
        if (-not (Read-JaNein 'Jetzt erstellen?' $true)) { Stop-Aktion }
    }
    if (-not $auswahl.Gpo) { $gpo = New-GpoObjekt $auswahl.Name $kommentar }
    if (-not $gpo) { return }
    if ($ziel) { Add-GpoLink $gpo $ziel }
}

# [G][2] Abfrage eines Laufwerks -> Plan
function Read-GpoLaufwerkPlan([object[]]$Vorhandene, [string[]]$Geplant) {
    $belegt = @(@($Vorhandene | ForEach-Object { $_.Buchstabe }) + @($Geplant))
    $vorschlag = @('H', 'S', 'P', 'T', 'G', 'K', 'L', 'M', 'N', 'O', 'Q', 'R', 'U', 'V', 'W', 'X', 'Y', 'Z' | Where-Object { $belegt -notcontains $_ }) | Select-Object -First 1
    while ($true) {
        $buchstabe = ConvertTo-GpoLaufwerk (Read-Text 'Laufwerksbuchstabe (D bis Z)' $vorschlag -Pflicht)
        if (-not $buchstabe) { Write-Warnung 'Ungültiger Laufwerksbuchstabe - bitte D bis Z, z.B. H oder H:'; continue }
        if ($Geplant -contains $buchstabe) { Write-Warnung "${buchstabe}: ist in diesem Durchlauf schon geplant."; continue }
        break
    }
    $alt = @($Vorhandene | Where-Object { $_.Buchstabe -eq $buchstabe }) | Select-Object -First 1
    if ($alt) { Write-Info "${buchstabe}: ist in dieser GPO schon zugeordnet: $($alt.Pfad) ($(Get-GpoAktionText $alt.Aktion))" }

    $pfadVorschlag = if ($alt) { $alt.Pfad } else { '' }
    while ($true) {
        $pfad = (Read-Text 'UNC-Pfad, z.B. \\server\freigabe' $pfadVorschlag -Pflicht).Trim('"').TrimEnd('\')
        $fehler = Get-UncPfadFehler $pfad
        if ($fehler) { Write-Warnung "Ungültiger UNC-Pfad: $fehler"; continue }
        break
    }
    $teile = Get-UncTeile $pfad
    $bezVorschlag = if ($alt -and $alt.Bezeichnung) { $alt.Bezeichnung } else { $teile.Freigabe.TrimEnd('$') }
    $bezeichnung = Read-Text 'Bezeichnung im Explorer' $bezVorschlag

    Write-Host '  Aktion: [1] Erstellen  [2] Aktualisieren  [3] Ersetzen' -ForegroundColor Cyan
    while ($true) {
        $a = Read-Text 'Aktion' '2'
        $aktion = @{ '1' = 'C'; '2' = 'U'; '3' = 'R'; 'e' = 'C'; 'erstellen' = 'C'; 'a' = 'U'; 'aktualisieren' = 'U'; 'ersetzen' = 'R' }[$a.ToLower()]
        if ($aktion) { break }
        Write-Warnung 'Bitte 1, 2 oder 3 eingeben.'
    }
    $gruppe = Select-GpoZielgruppe

    # Erreichbarkeit der Freigabe
    $erreichbar = Test-Path -LiteralPath $pfad
    $freigabeNeu = $false
    if (-not $erreichbar) {
        Write-Warnung "$pfad ist von hier aus nicht erreichbar."
        if ((Test-UncAufDiesemServer $teile.Server) -and (Read-JaNein 'Die Freigabe liegt auf diesem Server. Ordner und Freigabe jetzt anlegen?' $true)) {
            $freigabeNeu = New-GpoFreigabe $pfad $gruppe
        }
        elseif (-not (Read-JaNein 'Trotzdem zuordnen (Freigabe wird später angelegt)?' $false)) { Stop-Aktion }
    }
    return [pscustomobject]@{
        Buchstabe   = $buchstabe
        Pfad        = $pfad
        Bezeichnung = $bezeichnung
        Aktion      = $aktion
        Gruppe      = $gruppe
        Alt         = $alt
        Erreichbar  = ($erreichbar -or $freigabeNeu)
    }
}

# [G][2]
function Start-GpoNetzlaufwerk {
    Write-Titel 'Netzlaufwerk per GPO zuordnen (Benutzerkonfiguration)'
    $auswahl = Select-Gpo 'GPO für die Laufwerke wählen' 'Netzlaufwerke'
    $vorhandene = @()
    if ($auswahl.Gpo) {
        $vorhandene = @(Get-GppLaufwerke (Read-GppLaufwerkDatei $auswahl.Gpo))
        if ($vorhandene.Count) {
            Write-Info 'Schon in dieser GPO:'
            foreach ($v in $vorhandene) { Write-Host ('    {0}:  {1,-36} {2,-14} {3}' -f $v.Buchstabe, $v.Pfad, (Get-GpoAktionText $v.Aktion), $v.GruppeName) -ForegroundColor Gray }
        }
    }
    $plaene = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        Write-Host ''
        Write-Host "  -- Laufwerk $($plaene.Count + 1) --" -ForegroundColor Cyan
        $plaene.Add((Read-GpoLaufwerkPlan $vorhandene @($plaene | ForEach-Object { $_.Buchstabe })))
        if (-not (Read-JaNein 'Weiteres Laufwerk in dieselbe GPO?' $false)) { break }
    }

    Write-Titel "Vorschau: GPO '$($auswahl.Name)'$(if (-not $auswahl.Gpo) { ' (neu)' })"
    $arbeit = [System.Collections.Generic.List[object]]::new()
    $ohne   = [System.Collections.Generic.List[object]]::new()   # vorhanden oder übersprungen: Status, Info
    foreach ($p in $plaene) {
        $ziel = if ($p.Gruppe) { "nur $($p.Gruppe.Name)" } else { 'alle Benutzer' }
        $text = '    {0}:  {1,-36} "{2}"  {3}, {4}' -f $p.Buchstabe, $p.Pfad, $p.Bezeichnung, (Get-GpoAktionText $p.Aktion), $ziel
        $gleich = $p.Alt -and $p.Alt.Pfad -eq $p.Pfad -and $p.Alt.Bezeichnung -ceq $p.Bezeichnung -and $p.Alt.Aktion -eq $p.Aktion -and $p.Alt.GruppeSid -eq $(if ($p.Gruppe) { $p.Gruppe.SidText } else { '' })
        if ($gleich) {
            Write-Host "$text   (vorhanden)" -ForegroundColor Yellow
            $ohne.Add([pscustomobject]@{ Plan = $p; Status = 'VORHANDEN'; Info = '' })
            continue
        }
        if ($p.Alt) {
            Write-Host "$text   (ersetzt bisher $($p.Alt.Pfad))" -ForegroundColor White
            if (-not (Read-JaNein "Vorhandene Zuordnung $($p.Buchstabe): ersetzen?" $true)) {
                $ohne.Add([pscustomobject]@{ Plan = $p; Status = 'UEBERSPRUNGEN'; Info = 'vorhandene Zuordnung behalten' })
                continue
            }
        }
        else { Write-Host $text -ForegroundColor White }
        if (-not $p.Erreichbar) { Write-Host '          (Pfad zurzeit nicht erreichbar)' -ForegroundColor DarkYellow }
        $arbeit.Add($p)
    }
    if ($arbeit.Count -and $Funktionen.Vorschau -and -not (Read-JaNein 'Jetzt in die GPO schreiben?' $true)) { Stop-Aktion }
    foreach ($o in $ohne) { Add-Ergebnis 'GPO-Laufwerk' "$($o.Plan.Buchstabe): -> $($o.Plan.Pfad)" $auswahl.Name $o.Status $o.Info }
    if ($arbeit.Count -eq 0) {
        Write-Info 'Nichts zu ändern - nichts wird doppelt angelegt.'
        if ($auswahl.Gpo) { Invoke-GpoVerknuepfungAnbieten $auswahl.Gpo }
        return
    }

    $gpo = Resolve-GpoAuswahl $auswahl
    if (-not $gpo) { return }
    try {
        $xml = Read-GppLaufwerkDatei $gpo
        $status = @{}
        foreach ($p in $arbeit) {
            $gName = if ($p.Gruppe) { $p.Gruppe.Name } else { '' }
            $gSid  = if ($p.Gruppe) { $p.Gruppe.SidText } else { '' }
            $status[$p.Buchstabe] = Set-GppLaufwerk -Xml $xml -Buchstabe $p.Buchstabe -Pfad $p.Pfad -Bezeichnung $p.Bezeichnung -Aktion $p.Aktion -GruppeName $gName -GruppeSid $gSid
        }
        Save-GppLaufwerkDatei $gpo $xml
        $version = Update-GpoBenutzerVersion $gpo $script:GppLaufwerkErweiterung
        foreach ($p in $arbeit) {
            $info = switch ($status[$p.Buchstabe]) { 'Geaendert' { 'ersetzt' } 'Vorhanden' { 'unverändert' } default { Get-GpoAktionText $p.Aktion } }
            Add-Ergebnis 'GPO-Laufwerk' "$($p.Buchstabe): -> $($p.Pfad)" $gpo.DisplayName 'OK' $info -Bezug (Get-GpoGuidText $gpo.Id)
        }
        Write-Info "Benutzerversion der GPO jetzt $((Get-GpoVersionTeile $version).Benutzer) (AD und GPT.ini)."
    }
    catch {
        Add-Ergebnis 'GPO-Laufwerk' (($arbeit | ForEach-Object { "$($_.Buchstabe):" }) -join ' ') $gpo.DisplayName 'FEHLER' $_.Exception.Message
        return
    }
    Invoke-GpoVerknuepfungAnbieten $gpo
    Invoke-GpoAbschluss $gpo
}

# [G][3]
function Start-GpoStandardRichtlinie {
    Write-Titel 'Standard-Richtlinie anwenden'
    $vorlagen = @(Get-GpoVorlagen)
    $eintraege = @($vorlagen | ForEach-Object { [pscustomobject]@{ Anzeige = '{0,-46} ({1})' -f $_.Text, $_.Bereich; Vorlage = $_ } })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel 'Welche Richtlinie(n)?' -Mehrfach)
    if ($wahl.Count -eq 0) { Stop-Aktion }
    $auswahl = Select-Gpo 'GPO für die Richtlinie(n) wählen' 'Standard-Richtlinien'

    $plaene = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $wahl) {
        $v = $w.Vorlage
        Write-Host ''
        Write-Host "  -- $($v.Text) --" -ForegroundColor Cyan
        if ($v.Hinweis) { Write-Info $v.Hinweis }
        if ($v.Bereich -ne 'Benutzer') { Write-Info 'Computerkonfiguration: wirkt nur, wenn die Computerkonten in der verknüpften OU liegen.' }
        $antwort = ''
        if ($v.Eingabe) {
            while ($true) {
                $antwort = Read-Text $v.Eingabe.Frage $v.Eingabe.Standard -Pflicht
                $fehler = Test-GpoVorlageEingabe $v.Eingabe $antwort
                if (-not $fehler) { break }
                Write-Warnung $fehler
            }
        }
        $r = Get-GpoVorlageWerte $v $antwort
        if ($r.Fehler) { Write-Warnung "$($v.Name): $($r.Fehler) - übersprungen."; continue }
        foreach ($wert in $r.Werte) {
            $aktuell = $null
            if ($auswahl.Gpo) {
                # fehlt der Wert, meldet Get-GPRegistryValue einen Fehler -> gilt als "neu"
                try { $aktuell = Get-GPRegistryValue -Guid $auswahl.Gpo.Id -Key $wert.Schluessel -ValueName $wert.Name -ErrorAction Stop } catch { $aktuell = $null }
            }
            $art = 'Neu'
            if ($aktuell -and "$(@($aktuell.Value) -join '|')" -eq $wert.Anzeige) { $art = 'Vorhanden' }
            elseif ($aktuell) { $art = 'Aendern' }
            $plaene.Add([pscustomobject]@{ Vorlage = $v.Name; Wert = $wert; Art = $art; Vorher = $(if ($aktuell) { "$(@($aktuell.Value) -join '|')" } else { '' }) })
        }
    }
    if ($plaene.Count -eq 0) { Stop-Aktion }

    Write-Titel "Vorschau: GPO '$($auswahl.Name)'$(if (-not $auswahl.Gpo) { ' (neu)' })"
    foreach ($p in $plaene) {
        $text = '    {0,-20} {1}\{2} = {3} ({4})' -f $p.Vorlage, $p.Wert.Schluessel, $p.Wert.Name, $p.Wert.Anzeige, $p.Wert.Typ
        switch ($p.Art) {
            'Vorhanden' { Write-Host "$text   (vorhanden)" -ForegroundColor Yellow }
            'Aendern'   { Write-Host "$text   (bisher: $($p.Vorher))" -ForegroundColor White }
            default     { Write-Host $text -ForegroundColor White }
        }
    }
    $neu = @($plaene | Where-Object { $_.Art -ne 'Vorhanden' })
    if ($neu.Count -eq 0) {
        foreach ($p in $plaene) { Add-Ergebnis 'GPO-Wert' "$($p.Vorlage): $($p.Wert.Name)" $auswahl.Name 'VORHANDEN' $p.Wert.Anzeige }
        Write-Info 'Alles ist schon so eingestellt.'
        if ($auswahl.Gpo) { Invoke-GpoVerknuepfungAnbieten $auswahl.Gpo }
        return
    }
    if ($Funktionen.Vorschau -and -not (Read-JaNein 'Jetzt in die GPO schreiben?' $true)) { Stop-Aktion }

    $gpo = Resolve-GpoAuswahl $auswahl
    if (-not $gpo) { return }
    foreach ($p in $plaene) {
        $name = "$($p.Vorlage): $($p.Wert.Name)"
        if ($p.Art -eq 'Vorhanden') { Add-Ergebnis 'GPO-Wert' $name $gpo.DisplayName 'VORHANDEN' $p.Wert.Anzeige; continue }
        try {
            Set-GPRegistryValue -Guid $gpo.Id -Key $p.Wert.Schluessel -ValueName $p.Wert.Name -Type $p.Wert.Typ -Value $p.Wert.Wert -ErrorAction Stop | Out-Null
            $info = if ($p.Art -eq 'Aendern') { "$($p.Wert.Anzeige) (vorher $($p.Vorher))" } else { $p.Wert.Anzeige }
            Add-Ergebnis 'GPO-Wert' $name $gpo.DisplayName 'OK' $info -Bezug "$($p.Wert.Schluessel)|$($p.Wert.Name)"
        }
        catch { Add-Ergebnis 'GPO-Wert' $name $gpo.DisplayName 'FEHLER' $_.Exception.Message }
    }
    Invoke-GpoVerknuepfungAnbieten $gpo
    Invoke-GpoAbschluss $gpo
}

# [G][4]
function Start-GpoVerknuepfen {
    Write-Titel 'GPO mit OU verknüpfen'
    $gpo = (Select-Gpo 'Welche GPO verknüpfen?').Gpo
    $links = @(Get-GpoVerknuepfungen $gpo)
    if ($links.Count) { Write-Info "Bisher verknüpft mit: $(($links | ForEach-Object { $_.Pfad }) -join ', ')" }
    $ziel = Select-AdZiel 'die Verknüpfung' -OhneContainer
    if ($Funktionen.Vorschau -and -not (Read-JaNein "GPO '$($gpo.DisplayName)' mit $(Get-Kurzpfad $ziel) verknüpfen (aktiviert)?" $true)) { Stop-Aktion }
    Add-GpoLink $gpo $ziel
}

# [G][5]
function Show-GpoListe {
    Write-Titel 'Vorhandene GPOs'
    $gpos = @(Get-GPO -All -ErrorAction Stop | Sort-Object DisplayName)
    if ($gpos.Count -eq 0) { Write-Info 'Keine GPOs vorhanden.'; return }
    # Verknüpfungen einmal für alle lesen
    $links = @{}
    foreach ($o in @(Get-ADObject -LDAPFilter '(gPLink=*)' -Properties gPLink -ErrorAction SilentlyContinue)) {
        foreach ($l in @(ConvertFrom-GpLink $o.gPLink)) {
            $text = Get-Kurzpfad $o.DistinguishedName
            if (-not $l.Aktiviert) { $text += ' (aus)' }
            $links[$l.Guid] = @($links[$l.Guid]) + $text
        }
    }
    $gpos | ForEach-Object {
        $verkn = @($links[(Get-GpoGuidText $_.Id)] | Where-Object { $_ })
        [pscustomobject]@{
            Name            = $_.DisplayName
            Status          = "$($_.GpoStatus)"
            Geaendert       = '{0:dd.MM.yyyy HH:mm}' -f $_.ModificationTime
            'Verknüpft mit' = if ($verkn.Count) { $verkn -join ', ' } else { '-' }
        }
    } | Format-Table -AutoSize -Wrap | Out-Host
}

# [G][6]
function Start-GpoEntfernen {
    Write-Titel 'GPO entfernen'
    $gpo = (Select-Gpo 'Welche GPO entfernen?').Gpo
    $links = @(Get-GpoVerknuepfungen $gpo)
    Write-Info "GPO: $($gpo.DisplayName)  $(Get-GpoGuidText $gpo.Id)"
    Write-Info ('Verknüpft mit: ' + $(if ($links.Count) { ($links | ForEach-Object { $_.Pfad }) -join ', ' } else { 'nichts' }))
    Write-Warnung 'Die GPO wird mit allen Einstellungen und Verknüpfungen GELÖSCHT (Remove-GPO).'
    if ("$(Read-Host "  Zum Bestätigen 'JA' eingeben")".Trim() -cne 'JA') { Stop-Aktion }
    try {
        Remove-GPO -Guid $gpo.Id -ErrorAction Stop
        Add-Ergebnis 'GPO' $gpo.DisplayName $gpo.Path 'ENTFERNT' -Bezug (Get-GpoGuidText $gpo.Id)
    }
    catch { Add-Ergebnis 'GPO' $gpo.DisplayName $gpo.Path 'FEHLER' $_.Exception.Message }
}

# [G][7]
function Install-GpoVerwaltung {
    Write-Titel 'Gruppenrichtlinienverwaltung installieren'
    if (Install-WindowsRolle -Feature 'GPMC' -Typ 'GPO-Rolle' -Text 'Gruppenrichtlinienverwaltung (GPMC) mit Modul GroupPolicy') {
        if ($script:Faehig.GPO) { Write-Ok 'Modul GroupPolicy ist jetzt verfügbar - alle Punkte unter [G] stehen bereit.' }
        else { Write-Warnung "GPO noch nicht nutzbar: $($script:Faehig.Grund.GPO)" }
    }
}
#endregion
