# Teilmodul DHCP: reine Hilfsfunktionen, Prüfungen, Konfigurationsdatei und Abläufe
# (DHCP-, Netzwerk- und Dienst-Befehle gemockt). Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

# Platzhalter für Befehle, die es auf dem Testrechner nicht gibt (Pester kann nur Vorhandenes mocken)
$platzhalter = @{
    'Get-DhcpServerv4Scope'          = { [CmdletBinding()] param($ScopeId) }
    'Add-DhcpServerv4Scope'          = { [CmdletBinding()] param([string]$Name, $StartRange, $EndRange, $SubnetMask, $LeaseDuration, $State, [string]$Description) }
    'Set-DhcpServerv4Scope'          = { [CmdletBinding()] param($ScopeId, $State) }
    'Remove-DhcpServerv4Scope'       = { [CmdletBinding()] param($ScopeId, [switch]$Force) }
    'Get-DhcpServerv4ExclusionRange' = { [CmdletBinding()] param($ScopeId) }
    'Add-DhcpServerv4ExclusionRange' = { [CmdletBinding()] param($ScopeId, $StartRange, $EndRange) }
    'Get-DhcpServerv4OptionValue'    = { [CmdletBinding()] param($ScopeId, $OptionId) }
    'Set-DhcpServerv4OptionValue'    = { [CmdletBinding()] param($ScopeId, $Router, $DnsServer, $DnsDomain, [switch]$Force) }
    'Get-DhcpServerv4Reservation'    = { [CmdletBinding()] param($ScopeId) }
    'Add-DhcpServerv4Reservation'    = { [CmdletBinding()] param($ScopeId, $IPAddress, $ClientId, [string]$Name, [string]$Description) }
    'Get-DhcpServerv4Lease'          = { [CmdletBinding()] param($ScopeId) }
    'Get-DhcpServerInDC'             = { [CmdletBinding()] param() }
    'Add-DhcpServerInDC'             = { [CmdletBinding()] param([string]$DnsName, $IPAddress) }
    'Add-DhcpServerSecurityGroup'    = { [CmdletBinding()] param() }
    'Get-NetIPAddress'               = { [CmdletBinding()] param($AddressFamily) }
    'Get-NetRoute'                   = { [CmdletBinding()] param([string]$DestinationPrefix) }
    'Get-WindowsFeature'             = { [CmdletBinding()] param([string[]]$Name) }
    'Get-ADDomain'                   = { [CmdletBinding()] param() }
}
foreach ($befehl in @($platzhalter.Keys)) {
    if (-not (Get-Command $befehl -ErrorAction SilentlyContinue)) { Set-Item -Path "function:global:$befehl" -Value $platzhalter[$befehl] }
}

$Domain = [pscustomobject]@{ DNSRoot = 'firma.local'; NetBIOSName = 'FIRMA'; PDCEmulator = 'dc01.firma.local'; DistinguishedName = 'DC=firma,DC=local' }

function New-TestPlan {
    $p = Get-DhcpVorschlag '192.168.10.10' 24 'firma.local'
    $p.Start = '192.168.10.100'
    $p.Ende  = '192.168.10.200'
    return $p
}

Describe 'Teilmodul DHCP - Laden' {
    It 'ist beim Dot-Sourcing geladen' {
        $script:Teilmodule['DHCP'] | Should Match 'DHCP\.psm1$'
        [bool](Get-Command Start-DhcpMenue -ErrorAction SilentlyContinue) | Should Be $true
    }
}

Describe 'ConvertTo-MacAdresse' {
    It 'nimmt jede übliche Schreibweise' {
        ConvertTo-MacAdresse '00:11:22:AA:BB:CC' | Should BeExactly '00-11-22-aa-bb-cc'
        ConvertTo-MacAdresse '00-11-22-aa-bb-cc' | Should BeExactly '00-11-22-aa-bb-cc'
        ConvertTo-MacAdresse '0011.22aa.bbcc' | Should BeExactly '00-11-22-aa-bb-cc'
        ConvertTo-MacAdresse '001122AABBCC' | Should BeExactly '00-11-22-aa-bb-cc'
        ConvertTo-MacAdresse ' 00 11 22 aa bb cc ' | Should BeExactly '00-11-22-aa-bb-cc'
    }
    It 'lehnt falsche Länge und Nicht-Hex ab' {
        ConvertTo-MacAdresse '00:11:22:AA:BB' | Should BeExactly ''
        ConvertTo-MacAdresse '00:11:22:AA:BB:CC:DD' | Should BeExactly ''
        ConvertTo-MacAdresse '00:11:22:AA:BB:GG' | Should BeExactly ''
        ConvertTo-MacAdresse '' | Should BeExactly ''
    }
}

Describe 'ConvertTo-LeaseDauer / Format-LeaseDauer' {
    It 'versteht Tage, Stunden, Minuten und d.hh:mm:ss' {
        (ConvertTo-LeaseDauer '8').TotalDays | Should Be 8
        (ConvertTo-LeaseDauer '8 Tage').TotalDays | Should Be 8
        (ConvertTo-LeaseDauer '12h').TotalHours | Should Be 12
        (ConvertTo-LeaseDauer '30m').TotalMinutes | Should Be 30
        (ConvertTo-LeaseDauer '1.12:00:00').TotalHours | Should Be 36
    }
    It 'lehnt 0, Unsinn und mehr als 999 Tage ab' {
        ConvertTo-LeaseDauer '0' | Should BeNullOrEmpty
        ConvertTo-LeaseDauer 'acht' | Should BeNullOrEmpty
        ConvertTo-LeaseDauer '1000' | Should BeNullOrEmpty
        ConvertTo-LeaseDauer '' | Should BeNullOrEmpty
    }
    It 'zeigt die Dauer lesbar' {
        Format-LeaseDauer ([TimeSpan]::FromDays(8)) | Should Be '8 Tage'
        Format-LeaseDauer ([TimeSpan]::FromHours(36)) | Should Be '1 Tag 12 Stunden'
        Format-LeaseDauer ([TimeSpan]::FromMinutes(1)) | Should Be '1 Minute'
    }
}

Describe 'ConvertFrom-DhcpAusschlussText' {
    It 'liest Bereiche und einzelne Adressen' {
        $r = ConvertFrom-DhcpAusschlussText '192.168.10.150-192.168.10.155, 192.168.10.180'
        $r.Fehler | Should BeExactly ''
        $r.Bereiche.Count | Should Be 2
        $r.Bereiche[1].Start | Should Be '192.168.10.180'
        $r.Bereiche[1].Ende | Should Be '192.168.10.180'
        Format-DhcpAusschluesse $r.Bereiche | Should Be '192.168.10.150-192.168.10.155, 192.168.10.180'
    }
    It "nimmt '-' als keine" { (ConvertFrom-DhcpAusschlussText '-').Bereiche.Count | Should Be 0 }
    It 'meldet Fehler verständlich' {
        (ConvertFrom-DhcpAusschlussText '192.168.10.155-192.168.10.150').Fehler | Should Match 'hinter dem Ende'
        (ConvertFrom-DhcpAusschlussText '192.168.10.300').Fehler | Should Match 'keine gültige'
    }
}

Describe 'Get-DhcpVorschlag' {
    It 'leitet aus 192.168.10.10/24 alles ab' {
        $v = Get-DhcpVorschlag '192.168.10.10' 24 'firma.local'
        $v.Netz | Should Be '192.168.10.0'
        $v.Maske | Should Be '255.255.255.0'
        $v.Start | Should Be '192.168.10.100'
        $v.Ende | Should Be '192.168.10.200'
        $v.Router | Should Be '192.168.10.1'
        $v.DnsServer | Should Be '192.168.10.10'
        $v.Domaene | Should Be 'firma.local'
        $v.LeaseDauer.TotalDays | Should Be 8
    }
    It 'nimmt bei kleinen Netzen die obere Hälfte' {
        $v = Get-DhcpVorschlag '192.168.10.70' 26
        $v.Netz | Should Be '192.168.10.64'
        $v.Start | Should Be '192.168.10.96'
        $v.Ende | Should Be '192.168.10.126'
    }
}

Describe 'Test-DhcpBereichPlan' {
    It 'akzeptiert einen sauberen Bereich' {
        $t = Test-DhcpBereichPlan (New-TestPlan) @() @('192.168.10.10')
        $t.Fehler.Count | Should Be 0
        $t.Vorschlaege.Count | Should Be 0
        $t.Vorhanden | Should BeNullOrEmpty
    }
    It 'schlägt Server-IP und Router im Verteilbereich als Ausschluss vor' {
        $p = New-TestPlan
        $p.Start = '192.168.10.1'
        $t = Test-DhcpBereichPlan $p @() @('192.168.10.10')
        $t.Fehler.Count | Should Be 0
        (@($t.Vorschlaege | ForEach-Object { "$($_.Start) $($_.Grund)" }) -join '; ') | Should Be '192.168.10.1 Router; 192.168.10.10 IP dieses Servers'
    }
    It 'schlägt nichts vor, was schon ausgeschlossen ist' {
        $p = New-TestPlan
        $p.Start = '192.168.10.2'
        $p.Ausschluesse = @([pscustomobject]@{ Start = '192.168.10.5'; Ende = '192.168.10.15' })
        (Test-DhcpBereichPlan $p @() @('192.168.10.10')).Vorschlaege.Count | Should Be 0
    }
    It 'meldet Start/Ende außerhalb des Netzes und vertauschte Grenzen' {
        $p = New-TestPlan
        $p.Start = '192.168.11.5'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'Start.*nicht im Netz 192\.168\.10\.0/24'
        $p = New-TestPlan
        $p.Start = '192.168.10.200'; $p.Ende = '192.168.10.100'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'hinter dem Ende'
        $p = New-TestPlan
        $p.Ende = '192.168.10.255'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'Ende.*nicht im Netz'
    }
    It 'erklärt eine falsche Netzadresse' {
        $p = New-TestPlan
        $p.Netz = '192.168.10.10'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'gemeint ist wohl 192\.168\.10\.0'
    }
    It 'lehnt ungültige Masken und Router außerhalb ab' {
        $p = New-TestPlan
        $p.Maske = '255.255.253.0'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'Maske'
        $p = New-TestPlan
        $p.Router = '10.0.0.1'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'Router.*nicht im Netz'
    }
    It 'meldet Ausschlüsse außerhalb des Verteilbereichs' {
        $p = New-TestPlan
        $p.Ausschluesse = @([pscustomobject]@{ Start = '192.168.10.50'; Ende = '192.168.10.60' })
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'nicht im Verteilbereich'
    }
    It 'erkennt überlappende und gleiche Bereiche' {
        $gross = [pscustomobject]@{ ScopeId = '192.168.0.0'; SubnetMask = '255.255.0.0'; Name = 'Alles' }
        (Test-DhcpBereichPlan (New-TestPlan) @($gross)).Fehler[0] | Should Match 'Überschneidet sich.*192\.168\.0\.0/16'
        $gleich = [pscustomobject]@{ ScopeId = '192.168.10.0'; SubnetMask = '255.255.255.0'; Name = 'LAN' }
        $t = Test-DhcpBereichPlan (New-TestPlan) @($gleich)
        $t.Fehler.Count | Should Be 0
        $t.Vorhanden.Name | Should Be 'LAN'
        $nachbar = [pscustomobject]@{ ScopeId = '192.168.11.0'; SubnetMask = '255.255.255.0'; Name = 'Nachbar' }
        (Test-DhcpBereichPlan (New-TestPlan) @($nachbar)).Fehler.Count | Should Be 0
    }
    It 'weist auf ein nötiges DHCP-Relay hin, wenn der Server nicht im Netz ist' {
        (Test-DhcpBereichPlan (New-TestPlan) @() @('10.0.0.5')).Hinweise -join ' ' | Should Match 'Relay'
    }
    It 'prüft DNS-Server und Domänenname' {
        $p = New-TestPlan
        $p.DnsServer = @('192.168.10.300')
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'DNS-Server'
        $p = New-TestPlan
        $p.Domaene = 'firma_local'
        (Test-DhcpBereichPlan $p).Fehler[0] | Should Match 'Domänenname'
    }
}

Describe 'ConvertFrom-DhcpKonfigJson' {
    It 'liest config/DHCP.example.json ohne Fehler und füllt Vorschläge auf' {
        $json = [System.IO.File]::ReadAllText((Join-Path (Join-Path $wurzel 'config') 'DHCP.example.json'))
        $k = ConvertFrom-DhcpKonfigJson $json '' 'firma.local'
        ($k.Fehler -join '; ') | Should Be ''
        $k.ServerIp | Should Be '192.168.10.10'
        $k.DnsIntegration | Should Be $true
        $k.Plaene.Count | Should Be 2
        $k.Plaene[0].Reservierungen[0].Mac | Should Be '00-11-22-aa-bb-cc'
        $k.Plaene[0].Ausschluesse[0].Ende | Should Be '192.168.10.155'
        $gast = $k.Plaene[1]
        $gast.Netz | Should Be '192.168.20.0'
        $gast.Praefix | Should Be 24
        $gast.Start | Should Be '192.168.20.100'
        $gast.Router | Should Be '192.168.20.1'
        $gast.DnsServer | Should Be '192.168.10.10'
        $gast.Domaene | Should Be 'firma.local'
        $gast.LeaseDauer.TotalDays | Should Be 1
    }
    It 'meldet ungültige MAC, Netz und Lease mit Bereich' {
        $k = ConvertFrom-DhcpKonfigJson '{"Bereiche":[{"Netz":"192.168.10.0","Reservierungen":[{"Name":"x","Ip":"192.168.10.120","Mac":"00:11"}]},{"Netz":"abc"},{"Netz":"10.0.0.0","LeaseTage":0}]}' '192.168.10.10'
        $k.Fehler.Count | Should Be 3
        $k.Fehler[0] | Should Match 'Bereich 1.*MAC'
        $k.Fehler[1] | Should Match 'Bereich 2.*Netz'
        $k.Fehler[2] | Should Match 'Bereich 3.*LeaseTage'
    }
    It 'meldet kaputtes JSON und fehlende Bereiche' {
        (ConvertFrom-DhcpKonfigJson '{kaputt').Fehler[0] | Should Match 'JSON'
        (ConvertFrom-DhcpKonfigJson '{"x":1}').Fehler[0] | Should Match 'Bereiche'
    }
}

Describe 'Test-DhcpReservierung' {
    $bereich = [pscustomobject]@{ ScopeId = '192.168.10.0'; StartRange = '192.168.10.100'; EndRange = '192.168.10.200' }
    $vorhanden = @([pscustomobject]@{ IPAddress = '192.168.10.120'; ClientId = '00-11-22-aa-bb-cc'; Name = 'Drucker01' })

    It 'erlaubt eine neue Reservierung im Verteilbereich' {
        Test-DhcpReservierung '192.168.10.121' '00-11-22-aa-bb-dd' $bereich $vorhanden | Should BeExactly ''
    }
    It 'erkennt eine schon vorhandene Reservierung' {
        Test-DhcpReservierung '192.168.10.120' '00-11-22-aa-bb-cc' $bereich $vorhanden | Should BeExactly 'VORHANDEN'
    }
    It 'verhindert doppelte IP oder MAC' {
        Test-DhcpReservierung '192.168.10.120' '00-11-22-aa-bb-dd' $bereich $vorhanden | Should Match 'schon für'
        Test-DhcpReservierung '192.168.10.130' '00-11-22-aa-bb-cc' $bereich $vorhanden | Should Match 'hat schon'
    }
    It 'verlangt eine IP im Verteilbereich' {
        Test-DhcpReservierung '192.168.10.50' '00-11-22-aa-bb-dd' $bereich $vorhanden | Should Match 'nicht im Verteilbereich'
    }
}

Describe 'Get-AktiveNetzwerkkarte' {
    Mock Get-NetIPAddress {
        @([pscustomobject]@{ IPAddress = '127.0.0.1'; PrefixLength = 8; InterfaceIndex = 1; InterfaceAlias = 'Loopback' }
          [pscustomobject]@{ IPAddress = '10.99.0.5'; PrefixLength = 16; InterfaceIndex = 7; InterfaceAlias = 'Intern' }
          [pscustomobject]@{ IPAddress = '192.168.10.10'; PrefixLength = 24; InterfaceIndex = 4; InterfaceAlias = 'Ethernet' })
    }
    Mock Get-NetRoute { @([pscustomobject]@{ InterfaceIndex = 4; NextHop = '192.168.10.1' }) }

    It 'nimmt die Karte mit Standardgateway' {
        $k = Get-AktiveNetzwerkkarte
        $k.Ip | Should Be '192.168.10.10'
        $k.Praefix | Should Be 24
        $k.Gateway | Should Be '192.168.10.1'
        $k.Alias | Should Be 'Ethernet'
    }
}

Describe 'Initialize-DhcpServer' {
    Mock Write-Host { }
    Mock Add-Ergebnis { }
    Mock Get-Faehigkeiten { @{ AD = $true; DhcpRolle = $true; DhcpDienst = $true; DhcpModul = $true; DHCP = $true; Grund = @{} } }
    Mock Add-DhcpServerSecurityGroup { }
    Mock Add-DhcpServerInDC { }
    Mock Set-Service { }
    Mock Restart-Service { }
    Mock Set-DhcpNachkonfigFertig { }

    It 'autorisiert, startet neu und entfernt den Server-Manager-Hinweis' {
        $script:Faehig = @{ AD = $true; DhcpRolle = $true; DhcpDienst = $true; DhcpModul = $true; DHCP = $true; Grund = @{} }
        Mock Get-DhcpServerInDC { @() }
        Mock Test-DhcpNachkonfigFertig { $false }
        Initialize-DhcpServer '192.168.10.10' -Bestaetigt | Should Be $true
        Assert-MockCalled Add-DhcpServerSecurityGroup -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-DhcpServerInDC -Times 1 -Exactly -Scope It -ParameterFilter { $DnsName -eq "$($env:COMPUTERNAME.ToLower()).firma.local" -and "$IPAddress" -eq '192.168.10.10' }
        Assert-MockCalled Restart-Service -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'DHCPServer' }
        Assert-MockCalled Set-DhcpNachkonfigFertig -Times 1 -Exactly -Scope It
    }
    It 'autorisiert nicht doppelt und lässt den erledigten Hinweis in Ruhe' {
        $script:Faehig = @{ AD = $true; DhcpRolle = $true; DhcpDienst = $true; DhcpModul = $true; DHCP = $true; Grund = @{} }
        Mock Get-DhcpServerInDC { @([pscustomobject]@{ DnsName = "$($env:COMPUTERNAME).firma.local"; IPAddress = '192.168.10.10' }) }
        Mock Test-DhcpNachkonfigFertig { $true }
        Initialize-DhcpServer '192.168.10.10' -Bestaetigt | Should Be $true
        Assert-MockCalled Add-DhcpServerInDC -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-DhcpNachkonfigFertig -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-Ergebnis -Scope It -ParameterFilter { $Typ -eq 'DHCP-Autorisierung' -and $Status -eq 'VORHANDEN' }
    }
    It 'installiert die fehlende Rolle über Install-WindowsRolle' {
        $script:Faehig = @{ AD = $true; DhcpRolle = $false; DhcpDienst = $false; DhcpModul = $false; DHCP = $false; Grund = @{} }
        Mock Get-DhcpServerInDC { @() }
        Mock Test-DhcpNachkonfigFertig { $false }
        Mock Install-WindowsRolle { $true }
        Initialize-DhcpServer '192.168.10.10' -Bestaetigt | Should Be $true
        Assert-MockCalled Install-WindowsRolle -Times 1 -Exactly -Scope It -ParameterFilter { $Feature -eq 'DHCP' }
    }
}

Describe 'New-DhcpBereichAusPlan' {
    Mock Write-Host { }
    Mock Add-Ergebnis { }
    Mock Add-DhcpServerv4Scope { }
    Mock Add-DhcpServerv4ExclusionRange { }
    Mock Set-DhcpServerv4OptionValue { }
    Mock Add-DhcpServerv4Reservation { }
    Mock Get-DhcpServerv4Reservation { @() }

    $plan = New-TestPlan
    $plan.Ausschluesse = @([pscustomobject]@{ Start = '192.168.10.150'; Ende = '192.168.10.155' })
    $plan.Reservierungen = @([pscustomobject]@{ Ip = '192.168.10.120'; Mac = '00-11-22-aa-bb-cc'; Name = 'Drucker01'; Beschreibung = '' })

    It 'legt einen neuen Bereich aktiv mit Ausschluss, Optionen und Reservierung an' {
        Mock Get-DhcpServerv4Scope { }
        Mock Get-DhcpServerv4ExclusionRange { @() }
        Mock Get-DhcpServerv4OptionValue { throw 'nicht gesetzt' }
        New-DhcpBereichAusPlan $plan | Should Be $true
        Assert-MockCalled Add-DhcpServerv4Scope -Times 1 -Exactly -Scope It -ParameterFilter {
            "$StartRange" -eq '192.168.10.100' -and "$EndRange" -eq '192.168.10.200' -and "$SubnetMask" -eq '255.255.255.0' -and "$State" -eq 'Active' -and $LeaseDuration.TotalDays -eq 8
        }
        Assert-MockCalled Add-DhcpServerv4ExclusionRange -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-DhcpServerv4OptionValue -Times 3 -Exactly -Scope It
        Assert-MockCalled Set-DhcpServerv4OptionValue -Times 1 -Exactly -Scope It -ParameterFilter { "$Router" -eq '192.168.10.1' }
        Assert-MockCalled Set-DhcpServerv4OptionValue -Times 1 -Exactly -Scope It -ParameterFilter { "$DnsServer" -eq '192.168.10.10' }
        Assert-MockCalled Set-DhcpServerv4OptionValue -Times 1 -Exactly -Scope It -ParameterFilter { "$DnsDomain" -eq 'firma.local' }
        Assert-MockCalled Add-DhcpServerv4Reservation -Times 1 -Exactly -Scope It -ParameterFilter { "$ClientId" -eq '00-11-22-aa-bb-cc' }
    }
    It 'legt beim zweiten Lauf nichts doppelt an' {
        Mock Get-DhcpServerv4Scope { [pscustomobject]@{ ScopeId = '192.168.10.0'; StartRange = '192.168.10.100'; EndRange = '192.168.10.200'; State = 'Active'; Name = 'LAN' } }
        Mock Get-DhcpServerv4ExclusionRange { @([pscustomobject]@{ StartRange = '192.168.10.150'; EndRange = '192.168.10.155' }) }
        Mock Get-DhcpServerv4OptionValue {
            $werte = @{ 3 = @('192.168.10.1'); 6 = @('192.168.10.10'); 15 = @('firma.local') }
            [pscustomobject]@{ Value = $werte[[int]$OptionId] }
        }
        Mock Get-DhcpServerv4Reservation { @([pscustomobject]@{ IPAddress = '192.168.10.120'; ClientId = '00-11-22-aa-bb-cc'; Name = 'Drucker01' }) }
        New-DhcpBereichAusPlan $plan | Should Be $true
        Assert-MockCalled Add-DhcpServerv4Scope -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-DhcpServerv4ExclusionRange -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-DhcpServerv4OptionValue -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-DhcpServerv4Reservation -Times 0 -Exactly -Scope It
    }
}

Describe 'Get-DhcpMenue / Fähigkeiten' {
    It 'hat die Punkte 1 bis 7, Assistent und Datei ohne Voraussetzung' {
        $m = @(Get-DhcpMenue)
        (@($m | ForEach-Object { $_.Taste }) -join ',') | Should Be '1,2,3,4,5,6,7'
        @(($m | Where-Object { $_.Taste -eq '2' }).Braucht).Count | Should Be 0
        @(($m | Where-Object { $_.Taste -eq '7' }).Braucht).Count | Should Be 0
        @($m | Where-Object { $_.Taste -in '3', '4', '5', '6' -and @($_.Braucht) -notcontains 'DHCP' }).Count | Should Be 0
    }

    Context 'Server mit laufender DHCP-Rolle' {
        Mock Import-ModulStill { $true }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local' } }
        Mock Get-WindowsFeature { [pscustomobject]@{ Name = 'DHCP'; Installed = $true } }
        Mock Get-Service { [pscustomobject]@{ Name = 'DHCPServer'; Status = 'Running' } }
        $f = Get-Faehigkeiten
        It 'erkennt Rolle, Dienst und Modul' {
            $f.DhcpRolle | Should Be $true
            $f.DhcpDienst | Should Be $true
            $f.DHCP | Should Be $true
            $f.DhcpDatei | Should Be $true
        }
    }
    Context 'Server ohne DHCP-Rolle' {
        Mock Import-ModulStill { $true }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local' } }
        Mock Get-WindowsFeature { [pscustomobject]@{ Name = 'DHCP'; Installed = $false } }
        Mock Get-Service { $null }
        $f = Get-Faehigkeiten
        It 'meldet die fehlende Rolle als Grund' {
            $f.DHCP | Should Be $false
            $f.Grund.DHCP | Should Match 'Rolle nicht installiert'
        }
    }
}
