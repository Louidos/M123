<#
    Teilmodul DHCP - DHCP-Server einrichten für AD-Schnellanlage (Menü [H]).

    Wird vom Hauptscript in dessen Bereich geladen (nicht per Import-Module) und benutzt
    dessen Eingabe (Read-Text, Read-JaNein, Select-AusListe ...), Protokoll (Add-Ergebnis),
    Subnetzrechner (ConvertTo-IpZahl, Get-SubnetzInfo ...), $Domain, $Funktionen und
    $script:Faehig.

    Bordmittel: Module DhcpServer (Feature DHCP), ServerManager, NetTCPIP, ActiveDirectory.
    Annahme: DHCP läuft auf diesem Server (Domänencontroller mit DNS), nur IPv4.
    Ablauf und Prüfungen: docs/DHCP.md
#>

# Registry-Schlüssel des Server-Managers für die DHCP-Rolle ("Konfiguration abschließen")
$script:DhcpServerManagerSchluessel = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'

#region ======================= DHCP-HILFSFUNKTIONEN (ohne Server) ===

# MAC-Adresse in beliebiger Schreibweise -> "00-11-22-aa-bb-cc" (ungültig -> '')
# Erlaubt: 00:11:22:AA:BB:CC, 00-11-22-aa-bb-cc, 0011.22aa.bbcc, 001122AABBCC, mit Leerzeichen
function ConvertTo-MacAdresse([string]$Text) {
    $roh = ("$Text".Trim() -replace '[\s:\-\.]', '').ToLower()
    if ($roh -notmatch '^[0-9a-f]{12}$') { return '' }
    return (($roh -split '(..)' | Where-Object { $_ }) -join '-')
}

# Lease-Dauer: "8" = 8 Tage, "8d", "12h", "30m", "1.12:00:00" oder "12:00:00" -> TimeSpan ($null = ungültig)
function ConvertTo-LeaseDauer([string]$Text) {
    $t = "$Text".Trim().ToLower()
    $dauer = $null
    if ($t -match '^(\d{1,3})\s*(d|t|tag|tage)?$')  { $dauer = [TimeSpan]::FromDays([int]$Matches[1]) }
    elseif ($t -match '^(\d{1,5})\s*(h|std)$')     { $dauer = [TimeSpan]::FromHours([int]$Matches[1]) }
    elseif ($t -match '^(\d{1,6})\s*(m|min)$')     { $dauer = [TimeSpan]::FromMinutes([int]$Matches[1]) }
    elseif ($t -match '^(\d+\.)?\d{1,2}:\d{2}:\d{2}$') {
        $z = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($t, [ref]$z)) { $dauer = $z }
    }
    if ($null -eq $dauer) { return $null }
    if ($dauer.TotalMinutes -lt 1 -or $dauer.TotalDays -gt 999) { return $null }
    return $dauer
}

# TimeSpan -> "8 Tage", "12 Stunden", "1 Tag 12 Stunden"
function Format-LeaseDauer([TimeSpan]$Dauer) {
    $teile = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @(@($Dauer.Days, 'Tag', 'Tage'), @($Dauer.Hours, 'Stunde', 'Stunden'), @($Dauer.Minutes, 'Minute', 'Minuten'))) {
        if ($t[0] -eq 1) { $teile.Add("1 $($t[1])") }
        elseif ($t[0]) { $teile.Add("$($t[0]) $($t[2])") }
    }
    if ($teile.Count -eq 0) { return '0 Minuten' }
    return ($teile -join ' ')
}

# "192.168.10.150-192.168.10.155, 192.168.10.180" -> Liste Start/Ende ('-' oder leer = keine)
function ConvertFrom-DhcpAusschlussText([string]$Text) {
    $e = [pscustomobject]@{ Bereiche = @(); Fehler = '' }
    $t = "$Text".Trim()
    if ($t -in '', '-', 'keine') { return $e }
    $liste = [System.Collections.Generic.List[object]]::new()
    foreach ($teil in @($t -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $ab = @($teil -split '\s*-\s*')
        if ($ab.Count -gt 2) { $e.Fehler = "'$teil': Format 192.168.10.150-192.168.10.155 oder eine einzelne Adresse"; return $e }
        $von = $ab[0]
        $bis = if ($ab.Count -eq 2) { $ab[1] } else { $ab[0] }
        if ($null -eq (ConvertTo-IpZahl $von) -or $null -eq (ConvertTo-IpZahl $bis)) { $e.Fehler = "'$teil': keine gültige IPv4-Adresse"; return $e }
        if ((ConvertTo-IpZahl $von) -gt (ConvertTo-IpZahl $bis)) { $e.Fehler = "'$teil': Anfang liegt hinter dem Ende"; return $e }
        $liste.Add([pscustomobject]@{ Start = $von; Ende = $bis })
    }
    $e.Bereiche = $liste.ToArray()
    return $e
}

function Format-DhcpAusschluesse([object[]]$Bereiche) {
    $liste = @($Bereiche | Where-Object { $_ } | ForEach-Object { if ($_.Start -eq $_.Ende) { $_.Start } else { "$($_.Start)-$($_.Ende)" } })
    if ($liste.Count -eq 0) { return '-' }
    return ($liste -join ', ')
}

# Vorschlag für einen Bereich aus der IP des Servers: Netz, /24 -> .100 bis .200, Router = erste
# Adresse im Netz, DNS = eigene IP, Domäne aus AD, Lease 8 Tage
function Get-DhcpVorschlag([string]$Ip, [int]$Praefix, [string]$Domaene = '') {
    if ($Praefix -lt 8 -or $Praefix -gt 30) { $Praefix = 24 }
    $info  = Get-SubnetzInfo -Ip (ConvertTo-IpZahl $Ip) -Praefix $Praefix
    $netz  = ConvertTo-IpZahl $info.Netz
    if ($info.Hosts -ge 254) { $start = $netz + 100; $ende = $netz + 200 }
    else {
        $start = (ConvertTo-IpZahl $info.ErsterHost) + [int64][Math]::Floor($info.Hosts / 2)
        $ende  = ConvertTo-IpZahl $info.LetzterHost
    }
    return [pscustomobject]@{
        Name          = "LAN $($info.Netz)"
        Netz          = $info.Netz
        Praefix       = $Praefix
        Maske         = $info.Maske
        Start         = ConvertTo-IpText $start
        Ende          = ConvertTo-IpText $ende
        Ausschluesse  = @()
        LeaseDauer    = [TimeSpan]::FromDays(8)
        Router        = $info.ErsterHost
        DnsServer     = @($Ip)
        Domaene       = $Domaene
        Reservierungen = @()
        Vorhanden     = $null
    }
}

# Liegt $Zahl in einem der Bereiche (Start/Ende als Text)?
function Test-IpInBereichen([int64]$Zahl, [object[]]$Bereiche) {
    foreach ($b in @($Bereiche | Where-Object { $_ })) {
        if ($Zahl -ge (ConvertTo-IpZahl $b.Start) -and $Zahl -le (ConvertTo-IpZahl $b.Ende)) { return $true }
    }
    return $false
}

# Bereich prüfen. Rückgabe: Fehler (Liste), Hinweise (Liste), Vorschlaege (Ausschlüsse mit Grund),
# Vorhanden (vorhandener Bereich mit genau diesem Netz oder $null)
function Test-DhcpBereichPlan($Plan, [object[]]$Vorhandene = @(), [string[]]$ServerIps = @()) {
    $e = [pscustomobject]@{
        Fehler      = [System.Collections.Generic.List[string]]::new()
        Hinweise    = [System.Collections.Generic.List[string]]::new()
        Vorschlaege = [System.Collections.Generic.List[object]]::new()
        Vorhanden   = $null
    }
    $netz    = ConvertTo-IpZahl $Plan.Netz
    $praefix = Get-PraefixAusEingabe "$($Plan.Maske)"
    if ($null -eq $netz) { $e.Fehler.Add("Netz: '$($Plan.Netz)' ist keine gültige IPv4-Adresse."); return $e }
    if ($null -eq $praefix) { $e.Fehler.Add("Maske: '$($Plan.Maske)' ist keine gültige Subnetzmaske (z.B. 255.255.255.0 oder /24)."); return $e }
    if ($praefix -lt 8 -or $praefix -gt 30) { $e.Fehler.Add("Maske: /$praefix geht nicht - für DHCP /8 bis /30."); return $e }
    $info = Get-SubnetzInfo -Ip $netz -Praefix $praefix
    if ($info.Netz -ne $Plan.Netz) { $e.Fehler.Add("Netz: $($Plan.Netz) ist keine Netzadresse für /$praefix - gemeint ist wohl $($info.Netz)."); return $e }
    $nA = $netz
    $bA = ConvertTo-IpZahl $info.Broadcast
    $erlaubt = "erlaubt $($info.ErsterHost) bis $($info.LetzterHost)"

    $start = ConvertTo-IpZahl $Plan.Start
    $ende  = ConvertTo-IpZahl $Plan.Ende
    if ($null -eq $start) { $e.Fehler.Add("Start: '$($Plan.Start)' ist keine gültige IPv4-Adresse.") }
    elseif ($start -le $nA -or $start -ge $bA) { $e.Fehler.Add("Start: $($Plan.Start) liegt nicht im Netz $($info.Netz)/$praefix ($erlaubt).") }
    if ($null -eq $ende) { $e.Fehler.Add("Ende: '$($Plan.Ende)' ist keine gültige IPv4-Adresse.") }
    elseif ($ende -le $nA -or $ende -ge $bA) { $e.Fehler.Add("Ende: $($Plan.Ende) liegt nicht im Netz $($info.Netz)/$praefix ($erlaubt).") }
    if ($e.Fehler.Count -eq 0 -and $start -gt $ende) { $e.Fehler.Add("Start $($Plan.Start) liegt hinter dem Ende $($Plan.Ende).") }

    $router = $null
    if ($Plan.Router) {
        $router = ConvertTo-IpZahl $Plan.Router
        if ($null -eq $router) { $e.Fehler.Add("Router: '$($Plan.Router)' ist keine gültige IPv4-Adresse.") }
        elseif ($router -le $nA -or $router -ge $bA) { $e.Fehler.Add("Router: $($Plan.Router) liegt nicht im Netz $($info.Netz)/$praefix - Clients könnten ihn nicht erreichen.") }
    }
    else { $e.Hinweise.Add('Kein Router (Option 003) - Clients kommen dann nicht aus dem eigenen Netz hinaus.') }
    foreach ($d in @($Plan.DnsServer | Where-Object { $_ })) {
        if ($null -eq (ConvertTo-IpZahl $d)) { $e.Fehler.Add("DNS-Server: '$d' ist keine gültige IPv4-Adresse.") }
    }
    if (-not @($Plan.DnsServer | Where-Object { $_ }).Count) { $e.Hinweise.Add('Kein DNS-Server (Option 006) - Clients finden dann die Domäne nicht.') }
    if ($Plan.Domaene -and -not (Test-DnsHostname $Plan.Domaene)) { $e.Fehler.Add("Domänenname: $(Get-DnsHostnameFehler $Plan.Domaene)") }
    if ($null -eq $Plan.LeaseDauer -or $Plan.LeaseDauer -isnot [TimeSpan]) { $e.Fehler.Add('Lease-Dauer fehlt oder ist ungültig.') }

    if ($e.Fehler.Count -eq 0) {
        foreach ($a in @($Plan.Ausschluesse | Where-Object { $_ })) {
            $as = ConvertTo-IpZahl $a.Start
            $ae = ConvertTo-IpZahl $a.Ende
            if ($null -eq $as -or $null -eq $ae -or $as -gt $ae) { $e.Fehler.Add("Ausschluss $(Format-DhcpAusschluesse @($a)): ungültig."); continue }
            if ($as -lt $start -or $ae -gt $ende) { $e.Fehler.Add("Ausschluss $(Format-DhcpAusschluesse @($a)) liegt nicht im Verteilbereich $($Plan.Start) bis $($Plan.Ende).") }
        }
    }
    if ($e.Fehler.Count) { return $e }

    # Router und Server-IP dürfen nicht verteilt werden -> als Ausschluss vorschlagen
    if ($null -ne $router -and $router -ge $start -and $router -le $ende -and -not (Test-IpInBereichen $router $Plan.Ausschluesse)) {
        $e.Vorschlaege.Add([pscustomobject]@{ Start = $Plan.Router; Ende = $Plan.Router; Grund = 'Router' })
    }
    $imNetz = $false
    foreach ($ip in @($ServerIps | Where-Object { $_ })) {
        $z = ConvertTo-IpZahl $ip
        if ($null -eq $z) { continue }
        if ($z -gt $nA -and $z -lt $bA) { $imNetz = $true }
        if ($z -ge $start -and $z -le $ende -and -not (Test-IpInBereichen $z $Plan.Ausschluesse) -and
            -not @($e.Vorschlaege | Where-Object { $_.Start -eq $ip }).Count) {
            $e.Vorschlaege.Add([pscustomobject]@{ Start = $ip; Ende = $ip; Grund = 'IP dieses Servers' })
        }
    }
    if (@($ServerIps | Where-Object { $_ }).Count -and -not $imNetz) {
        $e.Hinweise.Add("Dieser Server hat keine Adresse im Netz $($info.Netz)/$praefix - Clients erreichen ihn nur über ein DHCP-Relay (IP-Helper) am Router.")
    }

    # Überschneidung mit vorhandenen Bereichen
    foreach ($v in @($Vorhandene | Where-Object { $_ })) {
        $vNetz = ConvertTo-IpZahl "$($v.ScopeId)"
        $vPraefix = Get-PraefixAusEingabe "$($v.SubnetMask)"
        if ($null -eq $vNetz -or $null -eq $vPraefix) { continue }
        $vBc = $vNetz + ([int64]1 -shl (32 - $vPraefix)) - 1
        if ($vNetz -eq $nA -and $vPraefix -eq $praefix) { $e.Vorhanden = $v; continue }
        if ($vNetz -le $bA -and $vBc -ge $nA) {
            $e.Fehler.Add("Überschneidet sich mit dem vorhandenen Bereich $($v.ScopeId)/$vPraefix ($($v.Name)) - ein Netz darf nur einmal vorkommen.")
        }
    }
    return $e
}

# Bereiche aus JSON {"Bereiche":[...], "ServerIp": "", "DnsIntegration": true} -> Pläne + Fehler.
# Fehlende Angaben kommen aus dem Vorschlag (Router = erste Adresse, DNS = Server-IP, Domäne aus AD).
function ConvertFrom-DhcpKonfigJson([string]$Json, [string]$ServerIp = '', [string]$Domaene = '') {
    $e = [pscustomobject]@{ Plaene = @(); Fehler = [System.Collections.Generic.List[string]]::new(); ServerIp = $ServerIp; DnsIntegration = $false }
    try { $objekt = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { $e.Fehler.Add("Datei ist kein gültiges JSON ($($_.Exception.Message))."); return $e }
    if (-not $objekt -or -not ($objekt.PSObject.Properties.Name -contains 'Bereiche')) { $e.Fehler.Add('Eintrag "Bereiche" fehlt.'); return $e }
    if ("$($objekt.ServerIp)".Trim()) {
        if ($null -eq (ConvertTo-IpZahl "$($objekt.ServerIp)".Trim())) { $e.Fehler.Add("ServerIp: '$($objekt.ServerIp)' ist keine gültige IPv4-Adresse.") }
        else { $e.ServerIp = "$($objekt.ServerIp)".Trim() }
    }
    $ServerIp = $e.ServerIp
    $e.DnsIntegration = [bool]$objekt.DnsIntegration
    if (-not $Domaene -and "$($objekt.Domaene)") { $Domaene = "$($objekt.Domaene)" }

    $plaene = [System.Collections.Generic.List[object]]::new()
    $nr = 0
    foreach ($b in @($objekt.Bereiche)) {
        $nr++
        $wo = "Bereich $nr"
        $netzText = "$($b.Netz)".Trim()
        $praefix = $null
        if ($netzText -match '^(.+)/(\d{1,2})$') { $netzText = $Matches[1]; $praefix = [int]$Matches[2] }
        elseif ("$($b.Maske)".Trim()) { $praefix = Get-PraefixAusEingabe "$($b.Maske)" }
        else { $praefix = 24 }
        if ($null -eq (ConvertTo-IpZahl $netzText)) { $e.Fehler.Add("${wo}: Netz '$($b.Netz)' fehlt oder ist ungültig."); continue }
        if ($null -eq $praefix -or $praefix -lt 8 -or $praefix -gt 30) { $e.Fehler.Add("${wo}: Maske '$($b.Maske)' ist ungültig (/8 bis /30)."); continue }
        $basisIp = if ($ServerIp -and (Get-SubnetzInfo -Ip (ConvertTo-IpZahl $ServerIp) -Praefix $praefix).Netz -eq (Get-SubnetzInfo -Ip (ConvertTo-IpZahl $netzText) -Praefix $praefix).Netz) { $ServerIp } else { $netzText }
        $p = Get-DhcpVorschlag $basisIp $praefix $Domaene
        if ($basisIp -ne $ServerIp) { $p.DnsServer = @(if ($ServerIp) { $ServerIp }) }
        $p.Netz = $netzText
        if ("$($b.Name)".Trim())  { $p.Name = "$($b.Name)".Trim() }
        if ("$($b.Start)".Trim()) { $p.Start = "$($b.Start)".Trim() }
        if ("$($b.Ende)".Trim())  { $p.Ende = "$($b.Ende)".Trim() }
        if ($b.PSObject.Properties.Name -contains 'Router') { $p.Router = "$($b.Router)".Trim() }
        if ($b.PSObject.Properties.Name -contains 'DnsServer') { $p.DnsServer = @($b.DnsServer | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
        if ("$($b.Domaene)".Trim()) { $p.Domaene = "$($b.Domaene)".Trim() }
        if ($b.PSObject.Properties.Name -contains 'LeaseTage') {
            $p.LeaseDauer = ConvertTo-LeaseDauer "$($b.LeaseTage)"
            if (-not $p.LeaseDauer) { $e.Fehler.Add("${wo}: LeaseTage '$($b.LeaseTage)' ist ungültig (1 bis 999)."); continue }
        }
        if ($b.Ausschluesse) {
            $a = ConvertFrom-DhcpAusschlussText (@($b.Ausschluesse) -join ',')
            if ($a.Fehler) { $e.Fehler.Add("${wo}: Ausschluss $($a.Fehler)"); continue }
            $p.Ausschluesse = $a.Bereiche
        }
        $res = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @($b.Reservierungen | Where-Object { $_ })) {
            $mac = ConvertTo-MacAdresse "$($r.Mac)"
            if (-not $mac) { $e.Fehler.Add("${wo}: Reservierung '$($r.Name)': MAC '$($r.Mac)' ist ungültig (12 Hex-Zeichen, z.B. 00:11:22:AA:BB:CC)."); continue }
            if ($null -eq (ConvertTo-IpZahl "$($r.Ip)")) { $e.Fehler.Add("${wo}: Reservierung '$($r.Name)': IP '$($r.Ip)' ist ungültig."); continue }
            $name = if ("$($r.Name)".Trim()) { "$($r.Name)".Trim() } else { "Reservierung-$("$($r.Ip)".Split('.')[3])" }
            $res.Add([pscustomobject]@{ Ip = "$($r.Ip)".Trim(); Mac = $mac; Name = $name; Beschreibung = "$($r.Beschreibung)" })
        }
        $p.Reservierungen = $res.ToArray()
        $plaene.Add($p)
    }
    if ($plaene.Count -eq 0 -and $e.Fehler.Count -eq 0) { $e.Fehler.Add('Keine Bereiche in der Datei.') }
    $e.Plaene = $plaene.ToArray()
    return $e
}

# Reservierung prüfen: IP im Verteilbereich, MAC gültig, nicht doppelt -> '' oder Fehler.
# 'VORHANDEN' = genau diese Reservierung gibt es schon
function Test-DhcpReservierung([string]$Ip, [string]$Mac, $Bereich, [object[]]$Vorhandene = @()) {
    $z = ConvertTo-IpZahl $Ip
    if ($null -eq $z) { return "'$Ip' ist keine gültige IPv4-Adresse." }
    if (-not $Mac) { return 'MAC-Adresse ungültig (12 Hex-Zeichen, z.B. 00:11:22:AA:BB:CC).' }
    if ($z -lt (ConvertTo-IpZahl "$($Bereich.StartRange)") -or $z -gt (ConvertTo-IpZahl "$($Bereich.EndRange)")) {
        return "$Ip liegt nicht im Verteilbereich $($Bereich.StartRange) bis $($Bereich.EndRange) - Windows lässt Reservierungen nur dort zu."
    }
    $gleicheIp  = @($Vorhandene | Where-Object { "$($_.IPAddress)" -eq $Ip }) | Select-Object -First 1
    $gleicheMac = @($Vorhandene | Where-Object { (ConvertTo-MacAdresse "$($_.ClientId)") -eq $Mac }) | Select-Object -First 1
    if ($gleicheIp -and (ConvertTo-MacAdresse "$($gleicheIp.ClientId)") -eq $Mac) { return 'VORHANDEN' }
    if ($gleicheIp)  { return "$Ip ist schon für $($gleicheIp.ClientId) reserviert ($($gleicheIp.Name))." }
    if ($gleicheMac) { return "$Mac hat schon die Reservierung $($gleicheMac.IPAddress) ($($gleicheMac.Name))." }
    return ''
}
#endregion

#region ======================= DHCP-SERVER ==========================

# Aktive Netzwerkkarte (mit Standardgateway, sonst die erste mit fester IPv4) -> Ip, Praefix, Gateway, Alias
function Get-AktiveNetzwerkkarte {
    $adressen = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
    if ($adressen.Count -eq 0) { return $null }
    $routen = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $wahl = @($adressen | Where-Object { $routen.InterfaceIndex -contains $_.InterfaceIndex }) | Select-Object -First 1
    if (-not $wahl) { $wahl = $adressen[0] }
    $gateway = @($routen | Where-Object { $_.InterfaceIndex -eq $wahl.InterfaceIndex } | ForEach-Object { "$($_.NextHop)" }) | Select-Object -First 1
    return [pscustomobject]@{ Ip = "$($wahl.IPAddress)"; Praefix = [int]$wahl.PrefixLength; Gateway = "$gateway"; Alias = "$($wahl.InterfaceAlias)" }
}

function Get-ServerIpListe {
    return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { "$($_.IPAddress)" })
}

function Get-DhcpFqdn {
    if ($Domain) { return "$env:COMPUTERNAME.$($Domain.DNSRoot)".ToLower() }
    return "$env:COMPUTERNAME".ToLower()
}

# Ist der Hinweis "Konfiguration abschließen" im Server-Manager erledigt? (ConfigurationState = 2)
function Test-DhcpNachkonfigFertig {
    $wert = Get-ItemProperty -Path $script:DhcpServerManagerSchluessel -Name ConfigurationState -ErrorAction SilentlyContinue
    return ($wert -and [int]$wert.ConfigurationState -eq 2)
}

function Set-DhcpNachkonfigFertig {
    if (-not (Test-Path -Path $script:DhcpServerManagerSchluessel)) { New-Item -Path $script:DhcpServerManagerSchluessel -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $script:DhcpServerManagerSchluessel -Name ConfigurationState -Value 2 -Type DWord -ErrorAction Stop
}

# Ist dieser Server im AD als DHCP-Server autorisiert?
function Test-DhcpAutorisiert([string]$Fqdn, [string]$Ip) {
    $liste = @(Get-DhcpServerInDC -ErrorAction Stop)
    return [bool](@($liste | Where-Object { "$($_.DnsName)" -eq $Fqdn -or "$($_.IPAddress)" -eq $Ip }).Count)
}

# Was ist am Server schon erledigt? Ändert nichts.
function Get-DhcpServerStand([string]$ServerIp) {
    $f = $script:Faehig
    $s = [pscustomobject]@{
        Rolle       = [bool]$f.DhcpRolle
        Dienst      = [bool]$f.DhcpDienst
        Modul       = [bool]$f.DhcpModul
        AD          = [bool]$f.AD
        Fqdn        = Get-DhcpFqdn
        ServerIp    = $ServerIp
        Autorisiert = $null      # $null = unbekannt (Rolle/AD fehlt)
        Nachkonfig  = $false
    }
    if ($s.Modul -and $s.AD) { try { $s.Autorisiert = Test-DhcpAutorisiert $s.Fqdn $ServerIp } catch { $s.Autorisiert = $null } }
    $s.Nachkonfig = Test-DhcpNachkonfigFertig
    return $s
}

function Show-DhcpServerStand($Stand) {
    $jn = { param($Wert) if ($null -eq $Wert) { 'unbekannt' } elseif ($Wert) { 'ja' } else { 'nein' } }
    Write-Info "Rolle installiert:          $(& $jn $Stand.Rolle)"
    Write-Info "Dienst läuft:               $(& $jn $Stand.Dienst)"
    Write-Info "Im AD autorisiert:          $(& $jn $Stand.Autorisiert)   ($($Stand.Fqdn), $($Stand.ServerIp))"
    Write-Info "Server-Manager-Hinweis weg: $(& $jn $Stand.Nachkonfig)"
}

# Rolle, Sicherheitsgruppen, Autorisierung, Dienst-Neustart, Server-Manager-Hinweis.
# Idempotent: erledigte Schritte werden als VORHANDEN gemeldet. $true = Server bereit für Bereiche
function Initialize-DhcpServer([string]$ServerIp, [switch]$Bestaetigt) {
    $stand = Get-DhcpServerStand $ServerIp
    if (-not $Bestaetigt) {
        Write-Info 'Server vorbereiten:'
        Write-Host ("    Rolle DHCP              {0}" -f $(if ($stand.Rolle) { 'vorhanden' } else { 'wird installiert (Install-WindowsFeature DHCP -IncludeManagementTools)' })) -ForegroundColor White
        Write-Host  '    Sicherheitsgruppen      DHCP-Administratoren / DHCP-Benutzer (Add-DhcpServerSecurityGroup)' -ForegroundColor White
        $auth = if (-not $stand.AD) { 'übersprungen (kein AD)' } elseif ($stand.Autorisiert) { 'vorhanden' } else { "wird autorisiert: $($stand.Fqdn) ($ServerIp)" }
        Write-Host  "    Autorisierung im AD     $auth" -ForegroundColor White
        Write-Host  '    Dienst DHCPServer       wird neu gestartet' -ForegroundColor White
        Write-Host ("    Server-Manager-Hinweis  {0}" -f $(if ($stand.Nachkonfig) { 'schon erledigt' } else { 'wird entfernt (ConfigurationState = 2)' })) -ForegroundColor White
        if ($Funktionen.Vorschau -and -not (Read-JaNein 'Server jetzt so vorbereiten?' $true)) { Stop-Aktion }
    }

    # 1) Rolle
    if (-not $stand.Rolle) {
        if (-not (Install-WindowsRolle -Feature 'DHCP' -Typ 'DHCP-Rolle' -Text 'DHCP-Server mit Verwaltungstools')) { return $false }
        $script:Faehig = Get-Faehigkeiten
        if (-not $script:Faehig.DhcpRolle) { Write-Warnung "DHCP-Rolle noch nicht nutzbar: $($script:Faehig.Grund.DHCP)"; return $false }
    }
    else { Add-Ergebnis 'DHCP-Rolle' 'DHCP' $env:COMPUTERNAME 'VORHANDEN' }
    if (-not $script:Faehig.DhcpModul) { Write-Warnung 'Modul DhcpServer fehlt - bitte Feature RSAT-DHCP installieren.'; return $false }

    # 2) Sicherheitsgruppen (legt nur Fehlendes an)
    try {
        Add-DhcpServerSecurityGroup -ErrorAction Stop
        Add-Ergebnis 'DHCP-Gruppen' 'DHCP-Administratoren, DHCP-Benutzer' $env:COMPUTERNAME 'OK' 'angelegt bzw. schon vorhanden'
    }
    catch { Add-Ergebnis 'DHCP-Gruppen' 'DHCP-Administratoren, DHCP-Benutzer' $env:COMPUTERNAME 'FEHLER' $_.Exception.Message }

    # 3) Autorisierung im AD
    if (-not $script:Faehig.AD) {
        Add-Ergebnis 'DHCP-Autorisierung' $stand.Fqdn $ServerIp 'UEBERSPRUNGEN' 'kein Active Directory - Server verteilt nur ohne AD-Prüfung'
    }
    else {
        try {
            if (Test-DhcpAutorisiert $stand.Fqdn $ServerIp) { Add-Ergebnis 'DHCP-Autorisierung' $stand.Fqdn $ServerIp 'VORHANDEN' }
            else {
                Add-DhcpServerInDC -DnsName $stand.Fqdn -IPAddress $ServerIp -ErrorAction Stop
                Add-Ergebnis 'DHCP-Autorisierung' $stand.Fqdn $ServerIp 'OK'
            }
        }
        catch { Add-Ergebnis 'DHCP-Autorisierung' $stand.Fqdn $ServerIp 'FEHLER' $_.Exception.Message }
    }

    # 4) Dienst automatisch starten und neu starten, damit Gruppen und Autorisierung greifen
    try {
        Set-Service -Name DHCPServer -StartupType Automatic -ErrorAction Stop
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        Add-Ergebnis 'DHCP-Dienst' 'DHCPServer' $env:COMPUTERNAME 'OK' 'neu gestartet'
    }
    catch { Add-Ergebnis 'DHCP-Dienst' 'DHCPServer' $env:COMPUTERNAME 'FEHLER' $_.Exception.Message }

    # 5) Server-Manager: "Konfiguration abschließen" entfernen
    if (Test-DhcpNachkonfigFertig) { Add-Ergebnis 'DHCP-Nachkonfig' 'ConfigurationState = 2' $script:DhcpServerManagerSchluessel 'VORHANDEN' }
    else {
        try { Set-DhcpNachkonfigFertig; Add-Ergebnis 'DHCP-Nachkonfig' 'ConfigurationState = 2' $script:DhcpServerManagerSchluessel 'OK' 'Hinweis im Server-Manager entfernt' }
        catch { Add-Ergebnis 'DHCP-Nachkonfig' 'ConfigurationState = 2' $script:DhcpServerManagerSchluessel 'FEHLER' $_.Exception.Message }
    }
    $script:Faehig = Get-Faehigkeiten
    return [bool]$script:Faehig.DHCP
}

function Get-DhcpBereiche {
    return @(Get-DhcpServerv4Scope -ErrorAction Stop | Sort-Object { ConvertTo-IpZahl "$($_.ScopeId)" })
}

function Select-DhcpBereich([string]$Titel) {
    $bereiche = @(Get-DhcpBereiche)
    if ($bereiche.Count -eq 0) { Write-Warnung 'Noch kein Bereich vorhanden - zuerst mit [2] oder [3] anlegen.'; Stop-Aktion }
    $eintraege = @($bereiche | ForEach-Object {
        [pscustomobject]@{ Anzeige = '{0,-16} {1,-24} {2} - {3}   {4}' -f "$($_.ScopeId)", $_.Name, $_.StartRange, $_.EndRange, $_.State; Bereich = $_ }
    })
    $wahl = @(Select-AusListe -Eintraege $eintraege -Titel $Titel)
    if ($wahl.Count -eq 0) { Stop-Aktion }
    Write-Ok "Bereich: $($wahl[0].Bereich.ScopeId) ($($wahl[0].Bereich.Name))"
    return $wahl[0].Bereich
}

# Eine IPv4-Adresse abfragen (Pflicht, gültig)
function Read-DhcpIp([string]$Frage, [string]$Standard) {
    while ($true) {
        $t = Read-Text $Frage $Standard -Pflicht
        if ($null -ne (ConvertTo-IpZahl $t)) { return $t }
        Write-Warnung "'$t' ist keine gültige IPv4-Adresse (z.B. 192.168.10.1)."
    }
}

# Assistent für einen Bereich. $Vorschlag = Startwerte (Enter = übernehmen). Gibt den geprüften Plan zurück
function Read-DhcpBereichPlan($Vorschlag, [object[]]$Vorhandene = @(), [string[]]$ServerIps = @()) {
    $p = $Vorschlag.PSObject.Copy()
    while ($true) {
        Write-Info 'Enter übernimmt den Vorschlag in [Klammern].'
        $p.Name = Read-Text 'Name des Bereichs' $p.Name -Pflicht
        while ($true) {
            $p.Netz = Read-DhcpIp 'Netz (Netzadresse)' $p.Netz
            $maske = Read-Text 'Subnetzmaske (255.255.255.0 oder /24)' $p.Maske -Pflicht
            $praefix = Get-PraefixAusEingabe $maske
            if ($null -eq $praefix -or $praefix -lt 8 -or $praefix -gt 30) { Write-Warnung "Ungültige Maske '$maske' - für DHCP /8 bis /30, z.B. 255.255.255.0."; continue }
            $info = Get-SubnetzInfo -Ip (ConvertTo-IpZahl $p.Netz) -Praefix $praefix
            $p.Praefix = $praefix
            $p.Maske = $info.Maske
            if ($info.Netz -ne $p.Netz) {
                Write-Warnung "$($p.Netz) ist keine Netzadresse für /$praefix - die Netzadresse ist $($info.Netz)."
                $p.Netz = $info.Netz
                continue
            }
            break
        }
        Write-Info "Netz $($p.Netz)/$($p.Praefix): Adressen $($info.ErsterHost) bis $($info.LetzterHost)"
        $p.Start = Read-DhcpIp 'Erste verteilte Adresse' $p.Start
        $p.Ende  = Read-DhcpIp 'Letzte verteilte Adresse' $p.Ende
        while ($true) {
            $a = ConvertFrom-DhcpAusschlussText (Read-Text "Ausschlüsse im Verteilbereich (z.B. 192.168.10.150-192.168.10.155, mehrere mit Komma, '-' = keine)" (Format-DhcpAusschluesse $p.Ausschluesse))
            if (-not $a.Fehler) { $p.Ausschluesse = $a.Bereiche; break }
            Write-Warnung $a.Fehler
        }
        while ($true) {
            $text = Read-Text 'Lease-Dauer (Tage, z.B. 8 - oder 12h, 30m, 1.12:00:00)' $(if ($p.LeaseDauer.TotalHours % 24) { "$($p.LeaseDauer)" } else { "$([int]$p.LeaseDauer.TotalDays)" }) -Pflicht
            $dauer = ConvertTo-LeaseDauer $text
            if ($dauer) { $p.LeaseDauer = $dauer; break }
            Write-Warnung "Ungültige Lease-Dauer '$text' - zwischen 1 Minute und 999 Tagen, z.B. 8 (Tage) oder 12h."
        }
        $p.Router = Read-DhcpIp 'Router / Standardgateway (Option 003)' $p.Router
        while ($true) {
            $liste = ConvertFrom-IpListe (Read-Text 'DNS-Server (Option 006), mehrere mit Komma' ($p.DnsServer -join ', ') -Pflicht)
            $v6 = @($liste.Gueltig | Where-Object { (Get-IpArt $_) -ne 'IPv4' })
            if ($liste.Ungueltig.Count -or $v6.Count) { Write-Warnung "Keine gültige IPv4-Adresse: $((@($liste.Ungueltig) + $v6) -join ', ')"; continue }
            $p.DnsServer = @($liste.Gueltig)
            break
        }
        while ($true) {
            $d = Read-Text 'DNS-Domänenname (Option 015)' $p.Domaene
            if (-not $d -or (Test-DnsHostname $d)) { $p.Domaene = $d.TrimEnd('.'); break }
            Write-Warnung "Ungültiger Domänenname: $(Get-DnsHostnameFehler $d)"
        }

        $test = Test-DhcpBereichPlan $p $Vorhandene $ServerIps
        foreach ($v in $test.Vorschlaege) {
            Write-Warnung "$($v.Start) ($($v.Grund)) liegt im Verteilbereich und würde sonst an einen Client vergeben."
            if (Read-JaNein "$($v.Start) als Ausschluss eintragen?" $true) { $p.Ausschluesse = @($p.Ausschluesse) + $v }
        }
        foreach ($h in $test.Hinweise) { Write-Info "Hinweis: $h" }
        if ($test.Fehler.Count) {
            foreach ($f in $test.Fehler) { Write-Warnung $f }
            if (Read-JaNein 'Angaben korrigieren?' $true) { continue }
            Stop-Aktion
        }
        $p.Vorhanden = $test.Vorhanden
        if ($test.Vorhanden) {
            Write-Warnung "Den Bereich $($p.Netz) gibt es schon ($($test.Vorhanden.Name), $($test.Vorhanden.StartRange) - $($test.Vorhanden.EndRange))."
            if (-not (Read-JaNein 'Vorhandenen Bereich ergänzen (Ausschlüsse, Optionen, aktivieren)? Nein = Angaben ändern' $true)) { continue }
        }
        return $p
    }
}

function Show-DhcpPlan($Plan) {
    $zusatz = if ($Plan.Vorhanden) { '   (vorhanden - wird ergänzt, Verteilbereich bleibt)' } else { '' }
    Write-Host ("    Bereich      {0}/{1}  '{2}'{3}" -f $Plan.Netz, $Plan.Praefix, $Plan.Name, $zusatz) -ForegroundColor White
    Write-Host ("    Verteilt     {0} bis {1}" -f $Plan.Start, $Plan.Ende) -ForegroundColor White
    Write-Host ("    Ausschlüsse  {0}" -f (Format-DhcpAusschluesse $Plan.Ausschluesse)) -ForegroundColor White
    Write-Host ("    Lease        {0}" -f (Format-LeaseDauer $Plan.LeaseDauer)) -ForegroundColor White
    Write-Host ("    003 Router   {0}" -f $(if ($Plan.Router) { $Plan.Router } else { '-' })) -ForegroundColor White
    Write-Host ("    006 DNS      {0}" -f $(if (@($Plan.DnsServer).Count) { $Plan.DnsServer -join ', ' } else { '-' })) -ForegroundColor White
    Write-Host ("    015 Domäne   {0}" -f $(if ($Plan.Domaene) { $Plan.Domaene } else { '-' })) -ForegroundColor White
    foreach ($r in @($Plan.Reservierungen | Where-Object { $_ })) {
        Write-Host ("    Reserviert   {0,-15} {1}  {2}" -f $r.Ip, $r.Mac, $r.Name) -ForegroundColor White
    }
}

# Optionen 003/006/015 setzen, nur wenn sie anders sind
function Set-DhcpBereichOptionen([string]$ScopeId, $Plan) {
    $optionen = @(
        @{ Id = 3;  Text = '003 Router'; Wert = @($Plan.Router | Where-Object { $_ }) }
        @{ Id = 6;  Text = '006 DNS';    Wert = @($Plan.DnsServer | Where-Object { $_ }) }
        @{ Id = 15; Text = '015 Domäne'; Wert = @($Plan.Domaene | Where-Object { $_ }) }
    )
    foreach ($o in $optionen) {
        if ($o.Wert.Count -eq 0) { continue }
        $neu = $o.Wert -join ', '
        $alt = ''
        try { $alt = (@((Get-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId $o.Id -ErrorAction Stop).Value) -join ', ') } catch { $alt = '' }
        if ($alt -eq $neu) { Add-Ergebnis 'DHCP-Option' "$($o.Text) = $neu" $ScopeId 'VORHANDEN'; continue }
        try {
            switch ($o.Id) {
                3  { Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $o.Wert -ErrorAction Stop }
                # -Force: DNS-Server nicht online prüfen (der eigene DNS ist evtl. gerade erst installiert)
                6  { Set-DhcpServerv4OptionValue -ScopeId $ScopeId -DnsServer $o.Wert -Force -ErrorAction Stop }
                15 { Set-DhcpServerv4OptionValue -ScopeId $ScopeId -DnsDomain $o.Wert[0] -ErrorAction Stop }
            }
            $info = if ($alt) { "vorher $alt" } else { '' }
            Add-Ergebnis 'DHCP-Option' "$($o.Text) = $neu" $ScopeId 'OK' $info
        }
        catch { Add-Ergebnis 'DHCP-Option' "$($o.Text) = $neu" $ScopeId 'FEHLER' $_.Exception.Message }
    }
}

# Reservierung anlegen (idempotent). $Bereich = Objekt von Get-DhcpServerv4Scope
function Add-DhcpReservierung($Bereich, [string]$Ip, [string]$Mac, [string]$Name, [string]$Beschreibung = '') {
    $scopeId = "$($Bereich.ScopeId)"
    $text = "$Ip = $Mac ($Name)"
    $vorhandene = @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue)
    $pruefung = Test-DhcpReservierung $Ip $Mac $Bereich $vorhandene
    if ($pruefung -eq 'VORHANDEN') { Add-Ergebnis 'DHCP-Reservierung' $text $scopeId 'VORHANDEN'; return }
    if ($pruefung) { Add-Ergebnis 'DHCP-Reservierung' $text $scopeId 'FEHLER' $pruefung; return }
    $param = @{ ScopeId = $scopeId; IPAddress = $Ip; ClientId = $Mac; Name = $Name; ErrorAction = 'Stop' }
    if ($Beschreibung) { $param.Description = $Beschreibung }
    try {
        Add-DhcpServerv4Reservation @param
        Add-Ergebnis 'DHCP-Reservierung' $text $scopeId 'OK' -Bezug "$Ip|$Mac"
    }
    catch { Add-Ergebnis 'DHCP-Reservierung' $text $scopeId 'FEHLER' $_.Exception.Message }
}

# Bereich nach Plan anlegen bzw. ergänzen: Bereich, Ausschlüsse, Optionen, Reservierungen. $true = Bereich ist da
function New-DhcpBereichAusPlan($Plan) {
    $scopeId = $Plan.Netz
    $text = "$($Plan.Netz)/$($Plan.Praefix) $($Plan.Name)"
    $bereich = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
    if ($bereich) {
        Add-Ergebnis 'DHCP-Bereich' $text $scopeId 'VORHANDEN' "$($bereich.StartRange) - $($bereich.EndRange)"
        if ("$($bereich.State)" -ne 'Active') {
            try { Set-DhcpServerv4Scope -ScopeId $scopeId -State Active -ErrorAction Stop; Add-Ergebnis 'DHCP-Bereich' $text $scopeId 'OK' 'aktiviert' }
            catch { Add-Ergebnis 'DHCP-Bereich' $text $scopeId 'FEHLER' "nicht aktiviert: $($_.Exception.Message)" }
        }
    }
    else {
        $param = @{
            Name          = $Plan.Name
            StartRange    = $Plan.Start
            EndRange      = $Plan.Ende
            SubnetMask    = ConvertTo-IpText (Get-MaskeAusPraefix $Plan.Praefix)
            LeaseDuration = $Plan.LeaseDauer
            State         = 'Active'
            ErrorAction   = 'Stop'
        }
        try {
            Add-DhcpServerv4Scope @param
            Add-Ergebnis 'DHCP-Bereich' $text $scopeId 'OK' "$($Plan.Start) - $($Plan.Ende), Lease $(Format-LeaseDauer $Plan.LeaseDauer)" -Bezug $scopeId
            $bereich = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
        }
        catch { Add-Ergebnis 'DHCP-Bereich' $text $scopeId 'FEHLER' $_.Exception.Message; return $false }
    }

    $vorhanden = @(Get-DhcpServerv4ExclusionRange -ScopeId $scopeId -ErrorAction SilentlyContinue)
    foreach ($a in @($Plan.Ausschluesse | Where-Object { $_ })) {
        $name = Format-DhcpAusschluesse @($a)
        if (@($vorhanden | Where-Object { "$($_.StartRange)" -eq $a.Start -and "$($_.EndRange)" -eq $a.Ende }).Count) { Add-Ergebnis 'DHCP-Ausschluss' $name $scopeId 'VORHANDEN'; continue }
        try {
            Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $a.Start -EndRange $a.Ende -ErrorAction Stop
            Add-Ergebnis 'DHCP-Ausschluss' $name $scopeId 'OK'
        }
        catch { Add-Ergebnis 'DHCP-Ausschluss' $name $scopeId 'FEHLER' $_.Exception.Message }
    }
    Set-DhcpBereichOptionen $scopeId $Plan
    if (-not $bereich) { $bereich = [pscustomobject]@{ ScopeId = $scopeId; StartRange = $Plan.Start; EndRange = $Plan.Ende } }
    foreach ($r in @($Plan.Reservierungen | Where-Object { $_ })) { Add-DhcpReservierung $bereich $r.Ip $r.Mac $r.Name $r.Beschreibung }
    return $true
}

# Server-IP für Autorisierung und Vorschläge: aktive Netzwerkkarte, änderbar
function Read-DhcpServerIp {
    $karte = Get-AktiveNetzwerkkarte
    $vorschlag = if ($karte) { $karte.Ip } else { '' }
    if ($karte) { Write-Info "Aktive Netzwerkkarte: $($karte.Alias)  $($karte.Ip)/$($karte.Praefix)$(if ($karte.Gateway) { "  Gateway $($karte.Gateway)" })" }
    $ip = Read-DhcpIp 'IP-Adresse dieses Servers (für Autorisierung und Vorschläge)' $vorschlag
    $praefix = if ($karte -and $karte.Ip -eq $ip) { $karte.Praefix } else { 24 }
    return [pscustomobject]@{ Ip = $ip; Praefix = $praefix }
}
#endregion

#region ======================= MODUL [H] DHCP =======================

function Get-DhcpMenue {
    return @(
        [pscustomobject]@{ Taste = '1'; Text = 'Status: Rolle, Dienst, Autorisierung, Bereiche';               Braucht = @();                Aktion = { Show-DhcpStatus } }
        [pscustomobject]@{ Taste = '2'; Text = 'Einrichtungs-Assistent (Rolle, Autorisierung, erster Bereich)'; Braucht = @();                Aktion = { Start-DhcpAssistent } }
        [pscustomobject]@{ Taste = '3'; Text = 'Bereich hinzufügen (Assistent mit Prüfungen)';                  Braucht = @('DHCP');          Aktion = { Start-DhcpBereich } }
        [pscustomobject]@{ Taste = '4'; Text = 'Reservierung hinzufügen (MAC in beliebiger Schreibweise)';       Braucht = @('DHCP');          Aktion = { Start-DhcpReservierung } }
        [pscustomobject]@{ Taste = '5'; Text = 'Bereiche, Leases und Reservierungen anzeigen';                  Braucht = @('DHCP');          Aktion = { Show-DhcpUebersicht } }
        [pscustomobject]@{ Taste = '6'; Text = 'Bereich entfernen';                                             Braucht = @('DHCP');          Aktion = { Start-DhcpBereichEntfernen } }
        [pscustomobject]@{ Taste = '7'; Text = 'Ganze Konfiguration aus Datei laden (ohne Fragen)';             Braucht = @();                Aktion = { Start-DhcpAusDatei } }
    )
}

function Start-DhcpMenue {
    while ($true) {
        $sichtbar = @()
        $gruende  = @()
        foreach ($m in @(Get-DhcpMenue)) {
            $grund = Get-FehlendeFaehigkeit $m.Braucht $script:Faehig
            if (-not $grund) { $sichtbar += $m }
            elseif ($gruende -notcontains $grund) { $gruende += $grund }
        }
        Write-Titel "DHCP   Server: $env:COMPUTERNAME"
        foreach ($m in $sichtbar) { Write-Host ('  [{0}] {1}' -f $m.Taste, $m.Text) }
        Write-Host '  [0] Zurück zum Hauptmenü'
        if ($gruende.Count) { Write-Host "  Weitere Punkte ausgeblendet: $($gruende -join ' / ')  ->  [2] Einrichtungs-Assistent" -ForegroundColor DarkGray }
        $wahl = "$(Read-Host '  Auswahl')".Trim().ToUpper()
        if (-not $wahl -or $wahl -eq '0') { return }
        $punkt = @($sichtbar | Where-Object { $_.Taste -eq $wahl }) | Select-Object -First 1
        if (-not $punkt) { Write-Warnung 'Ungültige Auswahl.'; continue }
        try { & $punkt.Aktion }
        catch [System.OperationCanceledException] { Write-Warnung 'Abgebrochen - zurück zum DHCP-Menü.' }
        catch { Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# [H][1]
function Show-DhcpStatus {
    Write-Titel 'DHCP - Status'
    $karte = Get-AktiveNetzwerkkarte
    $ip = if ($karte) { $karte.Ip } else { '' }
    Show-DhcpServerStand (Get-DhcpServerStand $ip)
    if (-not $script:Faehig.DHCP) { Write-Warnung "$($script:Faehig.Grund.DHCP) - Einrichtung mit [2]."; return }
    $bereiche = @(Get-DhcpBereiche)
    if ($bereiche.Count -eq 0) { Write-Info 'Noch keine Bereiche - mit [3] anlegen.'; return }
    $bereiche | ForEach-Object {
        [pscustomobject]@{ Bereich = "$($_.ScopeId)"; Name = $_.Name; Verteilt = "$($_.StartRange) - $($_.EndRange)"; Status = "$($_.State)"; Lease = Format-LeaseDauer $_.LeaseDuration }
    } | Format-Table -AutoSize | Out-Host
}

# [H][2]
function Start-DhcpAssistent {
    Write-Titel 'DHCP einrichten (Assistent)'
    if (-not $script:Faehig.AD) { Write-Warnung "Kein Active Directory ($($script:Faehig.Grund.AD)) - die Autorisierung wird übersprungen." }
    $server = Read-DhcpServerIp
    if (-not (Initialize-DhcpServer $server.Ip)) { Write-Warnung 'Server ist noch nicht bereit - Meldungen oben beachten.'; return }
    Write-Ok 'DHCP-Server ist vorbereitet.'
    if (-not (Read-JaNein 'Jetzt einen Bereich anlegen?' $true)) { return }
    Start-DhcpBereich -ServerIp $server.Ip -Praefix $server.Praefix
}

# [H][3]
function Start-DhcpBereich([string]$ServerIp = '', [int]$Praefix = 0) {
    Write-Titel 'DHCP-Bereich anlegen'
    if (-not $ServerIp) {
        $karte = Get-AktiveNetzwerkkarte
        if ($karte) { $ServerIp = $karte.Ip; $Praefix = $karte.Praefix } else { $ServerIp = '192.168.1.10'; $Praefix = 24 }
    }
    $domaene = if ($Domain) { $Domain.DNSRoot } else { '' }
    $vorhandene = @(Get-DhcpBereiche)
    $serverIps = @(Get-ServerIpListe)
    while ($true) {
        $plan = Read-DhcpBereichPlan (Get-DhcpVorschlag $ServerIp $Praefix $domaene) $vorhandene $serverIps
        Write-Titel 'Vorschau'
        Show-DhcpPlan $plan
        if ($Funktionen.Vorschau -and -not (Read-JaNein 'Bereich jetzt so anlegen?' $true)) { Stop-Aktion }
        if (New-DhcpBereichAusPlan $plan) { Write-Ok "Bereich $($plan.Netz) ist aktiv - Clients bekommen IP, Gateway, DNS und Domäne." }
        if (-not (Read-JaNein 'Noch einen Bereich anlegen?' $false)) { return }
        $vorhandene = @(Get-DhcpBereiche)
    }
}

# [H][4]
function Start-DhcpReservierung {
    Write-Titel 'Reservierung hinzufügen'
    $bereich = Select-DhcpBereich 'Bereich für die Reservierung wählen'
    $scopeId = "$($bereich.ScopeId)"
    while ($true) {
        $vorhandene = @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue)
        $leases = @(Get-DhcpServerv4Lease -ScopeId $scopeId -ErrorAction SilentlyContinue)
        $ipVorschlag = ''; $nameVorschlag = ''
        while ($true) {
            $hinweis = if ($leases.Count) { "; 'L' = aus $($leases.Count) aktuellen Lease(s) wählen" } else { '' }
            $eingabe = Read-Text "MAC-Adresse (beliebige Schreibweise, z.B. 00:11:22:AA:BB:CC$hinweis)" -Pflicht
            if ($eingabe -eq 'L' -and $leases.Count) {
                $eintraege = @($leases | ForEach-Object { [pscustomobject]@{ Anzeige = '{0,-15} {1,-17} {2}' -f "$($_.IPAddress)", $_.ClientId, $_.HostName; Lease = $_ } })
                $wahl = @(Select-AusListe -Eintraege $eintraege -Titel 'Lease wählen' -Optional)
                if ($wahl.Count -eq 0) { continue }
                $eingabe = "$($wahl[0].Lease.ClientId)"
                $ipVorschlag = "$($wahl[0].Lease.IPAddress)"
                $nameVorschlag = "$($wahl[0].Lease.HostName)".Split('.')[0]
            }
            $mac = ConvertTo-MacAdresse $eingabe
            if ($mac) { Write-Ok "MAC: $mac"; break }
            Write-Warnung "'$eingabe' ist keine MAC-Adresse - 12 Hex-Zeichen (0-9, A-F), Trenner : - . oder keiner."
        }
        while ($true) {
            $ip = Read-DhcpIp "IP-Adresse ($($bereich.StartRange) bis $($bereich.EndRange))" $ipVorschlag
            $pruefung = Test-DhcpReservierung $ip $mac $bereich $vorhandene
            if ($pruefung -and $pruefung -ne 'VORHANDEN') { Write-Warnung $pruefung; $ipVorschlag = ''; continue }
            $fremd = @($leases | Where-Object { "$($_.IPAddress)" -eq $ip -and (ConvertTo-MacAdresse "$($_.ClientId)") -ne $mac })
            if ($fremd.Count -and -not (Read-JaNein "$ip ist gerade an $($fremd[0].ClientId) ($($fremd[0].HostName)) vergeben. Trotzdem reservieren?" $false)) { continue }
            break
        }
        if (-not $nameVorschlag) { $nameVorschlag = "Geraet-$($ip.Split('.')[3])" }
        $name = Read-Text 'Name (z.B. Hostname)' $nameVorschlag -Pflicht
        $beschreibung = Read-Text 'Beschreibung (optional)'
        if ($Funktionen.Vorschau -and -not (Read-JaNein "Reservierung $ip = $mac ($name) anlegen?" $true)) { Stop-Aktion }
        Add-DhcpReservierung $bereich $ip $mac $name $beschreibung
        if (-not (Read-JaNein 'Weitere Reservierung in diesem Bereich?' $false)) { return }
    }
}

# [H][5]
function Show-DhcpUebersicht {
    Write-Titel 'DHCP - Bereiche, Leases, Reservierungen'
    $bereiche = @(Get-DhcpBereiche)
    if ($bereiche.Count -eq 0) { Write-Info 'Keine Bereiche vorhanden.'; return }
    $optWert = { param($Id, $OptId) try { (@((Get-DhcpServerv4OptionValue -ScopeId $Id -OptionId $OptId -ErrorAction Stop).Value) -join ', ') } catch { '-' } }
    $bereiche | ForEach-Object {
        $id = "$($_.ScopeId)"
        [pscustomobject]@{
            Bereich  = "$id/$(Get-PraefixAusEingabe "$($_.SubnetMask)")"
            Name     = $_.Name
            Verteilt = "$($_.StartRange) - $($_.EndRange)"
            Status   = "$($_.State)"
            Lease    = Format-LeaseDauer $_.LeaseDuration
            Router   = & $optWert $id 3
            DNS      = & $optWert $id 6
            Domaene  = & $optWert $id 15
        }
    } | Format-Table -AutoSize -Wrap | Out-Host
    foreach ($b in $bereiche) {
        $id = "$($b.ScopeId)"
        Write-Host "  Bereich $id ($($b.Name))" -ForegroundColor Cyan
        $aus = @(Get-DhcpServerv4ExclusionRange -ScopeId $id -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Start = "$($_.StartRange)"; Ende = "$($_.EndRange)" } })
        Write-Info "Ausschlüsse: $(Format-DhcpAusschluesse $aus)"
        $res = @(Get-DhcpServerv4Reservation -ScopeId $id -ErrorAction SilentlyContinue)
        if ($res.Count) {
            Write-Info "Reservierungen ($($res.Count)):"
            $res | Sort-Object { ConvertTo-IpZahl "$($_.IPAddress)" } | ForEach-Object {
                [pscustomobject]@{ IP = "$($_.IPAddress)"; MAC = $_.ClientId; Name = $_.Name; Beschreibung = $_.Description }
            } | Format-Table -AutoSize | Out-Host
        }
        else { Write-Info 'Reservierungen: keine' }
        $leases = @(Get-DhcpServerv4Lease -ScopeId $id -ErrorAction SilentlyContinue)
        if ($leases.Count) {
            Write-Info "Leases ($($leases.Count)):"
            $leases | Sort-Object { ConvertTo-IpZahl "$($_.IPAddress)" } | ForEach-Object {
                [pscustomobject]@{ IP = "$($_.IPAddress)"; MAC = $_.ClientId; Hostname = $_.HostName; Status = "$($_.AddressState)"; 'Läuft ab' = $(if ($_.LeaseExpiryTime) { '{0:dd.MM.yyyy HH:mm}' -f $_.LeaseExpiryTime } else { '-' }) }
            } | Format-Table -AutoSize | Out-Host
        }
        else { Write-Info 'Leases: keine' }
    }
}

# [H][6]
function Start-DhcpBereichEntfernen {
    Write-Titel 'DHCP-Bereich entfernen'
    $bereich = Select-DhcpBereich 'Welchen Bereich entfernen?'
    $id = "$($bereich.ScopeId)"
    $leases = @(Get-DhcpServerv4Lease -ScopeId $id -ErrorAction SilentlyContinue).Count
    $res    = @(Get-DhcpServerv4Reservation -ScopeId $id -ErrorAction SilentlyContinue).Count
    Write-Info "Bereich $id ($($bereich.Name)), $($bereich.StartRange) - $($bereich.EndRange): $leases Lease(s), $res Reservierung(en)"
    Write-Warnung 'Der Bereich wird mit allen Leases, Reservierungen und Optionen GELÖSCHT. Clients bekommen danach hier keine Adresse mehr.'
    if ("$(Read-Host "  Zum Bestätigen 'JA' eingeben")".Trim() -cne 'JA') { Stop-Aktion }
    try {
        Remove-DhcpServerv4Scope -ScopeId $id -Force -ErrorAction Stop
        Add-Ergebnis 'DHCP-Bereich' "$id $($bereich.Name)" $id 'ENTFERNT' "$leases Lease(s), $res Reservierung(en)"
    }
    catch { Add-Ergebnis 'DHCP-Bereich' "$id $($bereich.Name)" $id 'FEHLER' $_.Exception.Message }
}

# [H][7]
function Start-DhcpAusDatei {
    Write-Titel 'DHCP aus Konfigurationsdatei einrichten'
    $ordner = if ($script:ScriptOrdner) { $script:ScriptOrdner } else { (Get-Location).ProviderPath }
    Write-Info 'Beispiel: config/DHCP.example.json (im Repo) - als DHCP-Konfiguration.json neben das Script legen.'
    while ($true) {
        $pfad = (Read-Text 'Konfigurationsdatei (Enter = Vorschlag)' (Join-Path $ordner 'DHCP-Konfiguration.json') -Pflicht).Trim('"')
        if (Test-Path -LiteralPath $pfad -PathType Leaf) { break }
        Write-Warnung "Datei '$pfad' nicht gefunden."
        if (-not (Read-JaNein 'Anderen Pfad eingeben?' $true)) { Stop-Aktion }
    }
    $karte = Get-AktiveNetzwerkkarte
    $domaene = if ($Domain) { $Domain.DNSRoot } else { '' }
    $konfig = ConvertFrom-DhcpKonfigJson ([System.IO.File]::ReadAllText($pfad)) $(if ($karte) { $karte.Ip } else { '' }) $domaene
    if (-not $konfig.ServerIp) { $konfig.ServerIp = (Read-DhcpServerIp).Ip }
    $vorhandene = @()
    if ($script:Faehig.DHCP) { $vorhandene = @(Get-DhcpBereiche) }
    $serverIps = @(Get-ServerIpListe)
    if ($serverIps -notcontains $konfig.ServerIp) { $serverIps += $konfig.ServerIp }
    foreach ($p in $konfig.Plaene) {
        $test = Test-DhcpBereichPlan $p $vorhandene $serverIps
        foreach ($f in $test.Fehler) { $konfig.Fehler.Add("$($p.Netz): $f") }
        foreach ($v in $test.Vorschlaege) {
            Write-Info "$($p.Netz): $($v.Start) ($($v.Grund)) liegt im Verteilbereich - wird automatisch ausgeschlossen."
            $p.Ausschluesse = @($p.Ausschluesse) + $v
        }
        foreach ($h in $test.Hinweise) { Write-Info "$($p.Netz): $h" }
        $p.Vorhanden = $test.Vorhanden
        foreach ($r in @($p.Reservierungen)) {
            $z = ConvertTo-IpZahl $r.Ip
            if ($z -lt (ConvertTo-IpZahl $p.Start) -or $z -gt (ConvertTo-IpZahl $p.Ende)) { $konfig.Fehler.Add("$($p.Netz): Reservierung $($r.Ip) liegt nicht im Verteilbereich $($p.Start) bis $($p.Ende).") }
        }
    }
    if ($konfig.Fehler.Count) {
        Write-Warnung "Die Datei hat $($konfig.Fehler.Count) Fehler - es wird nichts geändert:"
        foreach ($f in $konfig.Fehler) { Write-Info "  $f" }
        return
    }
    Write-Titel "Vorschau: $pfad"
    Write-Info "Server: $(Get-DhcpFqdn) ($($konfig.ServerIp))"
    Show-DhcpServerStand (Get-DhcpServerStand $konfig.ServerIp)
    foreach ($p in $konfig.Plaene) { Write-Host ''; Show-DhcpPlan $p }
    if ($konfig.DnsIntegration) { Write-Info 'DnsIntegration = true: DNS-Integration wird danach eingerichtet (falls verfügbar).' }
    if (-not (Read-JaNein 'Alles jetzt so einrichten?' $true)) { Stop-Aktion }

    if (-not (Initialize-DhcpServer $konfig.ServerIp -Bestaetigt)) { Write-Warnung 'Server ist noch nicht bereit - Bereiche werden nicht angelegt.'; return }
    foreach ($p in $konfig.Plaene) { [void](New-DhcpBereichAusPlan $p) }
    if ($konfig.DnsIntegration -and (Get-Command Start-DhcpDnsIntegration -ErrorAction SilentlyContinue)) {
        Start-DhcpDnsIntegration -Plaene $konfig.Plaene -Automatisch
    }
    Write-Ok 'Fertig - Details stehen im Protokoll ([P]).'
}
#endregion
