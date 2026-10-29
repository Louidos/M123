# DNS-Modul: reine Hilfsfunktionen, Menü-Sichtbarkeit und Rückgängig (DNS-Befehle gemockt).
# Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

# Platzhalter für DNS-Befehle (überdecken auch ein vorhandenes DnsServer-Modul, damit die Mocks
# keine echten CIM-Objekte verlangen)
function global:Get-DnsServerResourceRecord { [CmdletBinding()] param([string]$ZoneName, [string]$Name, [string]$RRType, [string]$ComputerName) }
function global:Remove-DnsServerResourceRecord { [CmdletBinding()] param([string]$ZoneName, $InputObject, [switch]$Force, [string]$ComputerName) }
function global:Get-DnsServerZone { [CmdletBinding()] param([string]$Name, [string]$ComputerName) }
function global:Remove-DnsServerZone { [CmdletBinding()] param([string]$Name, [switch]$Force, [string]$ComputerName) }
function global:Get-DnsServerSetting { [CmdletBinding()] param([string]$ComputerName) }
function global:Add-DnsServerPrimaryZone { [CmdletBinding()] param([string]$Name, [string]$NetworkId, [string]$DynamicUpdate, [string]$ReplicationScope, [string]$ZoneFile, [string]$ComputerName) }
function global:Add-DnsServerResourceRecordPtr { [CmdletBinding()] param([string]$ZoneName, [string]$Name, [string]$PtrDomainName, $TimeToLive, [string]$ComputerName) }
if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue))       { function global:Get-ADDomain { [CmdletBinding()] param() } }
if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) { function global:Get-WindowsFeature { [CmdletBinding()] param([string[]]$Name) } }

function New-TestRecord([string]$HostName, [string]$Typ, $Daten) {
    return [pscustomobject]@{ HostName = $HostName; RecordType = $Typ; RecordData = [pscustomobject]$Daten }
}

Describe 'Get-DnsHostnameFehler / Test-DnsHostname' {
    It 'akzeptiert normale Hostnamen' {
        Test-DnsHostname 'srv01' | Should Be $true
        Test-DnsHostname 'srv-01.sub' | Should Be $true
        Test-DnsHostname 'srv01.firma.local.' | Should Be $true
    }
    It 'lehnt Umlaute mit Vorschlag ab' {
        Get-DnsHostnameFehler 'müller' | Should Match 'Umlaute.*mueller'
    }
    It 'erlaubt 63 Zeichen pro Namensteil, aber nicht 64' {
        Test-DnsHostname ('a' * 63) | Should Be $true
        Get-DnsHostnameFehler ('a' * 64) | Should Match '63'
    }
    It 'lehnt Bindestrich am Anfang oder Ende ab' {
        Test-DnsHostname '-srv' | Should Be $false
        Test-DnsHostname 'srv-' | Should Be $false
    }
    It 'lehnt Unterstrich, Leerzeichen, doppelte Punkte und leere Namen ab' {
        Test-DnsHostname 'srv_01' | Should Be $false
        Test-DnsHostname 'srv 01' | Should Be $false
        Test-DnsHostname 'a..b' | Should Be $false
        Test-DnsHostname '' | Should Be $false
    }
}

Describe 'Get-IpArt' {
    It 'erkennt IPv4' { Get-IpArt '192.168.10.5' | Should Be 'IPv4' }
    It 'erkennt IPv6' {
        Get-IpArt 'fd00::5' | Should Be 'IPv6'
        Get-IpArt '2001:db8::1' | Should Be 'IPv6'
    }
    It 'lehnt unvollständige und falsche IPv4 ab' {
        Get-IpArt '192.168.10' | Should Be ''
        Get-IpArt '256.1.1.1' | Should Be ''
        Get-IpArt '192.168.010.5' | Should Be ''
    }
    It 'lehnt Hostnamen ab' { Get-IpArt 'srv01' | Should Be '' }
}

Describe 'ConvertFrom-IpListe' {
    It 'trennt gültige und ungültige Adressen' {
        $r = ConvertFrom-IpListe '192.168.10.1, 1.2.3, 192.168.10.1; fd00::1'
        ($r.Gueltig -join ',') | Should Be '192.168.10.1,fd00::1'
        ($r.Ungueltig -join ',') | Should Be '1.2.3'
    }
}

Describe 'ConvertTo-ReverseZonenName' {
    It 'macht aus 192.168.10.0/24 die Zone 10.168.192.in-addr.arpa' {
        $r = ConvertTo-ReverseZonenName '192.168.10.0/24'
        $r.Zone | Should Be '10.168.192.in-addr.arpa'
        $r.NetworkId | Should Be '192.168.10.0/24'
        $r.Fehler | Should Be ''
    }
    It 'versteht 192.168.10 ohne Präfix als /24' {
        $r = ConvertTo-ReverseZonenName '192.168.10'
        $r.Zone | Should Be '10.168.192.in-addr.arpa'
        $r.NetworkId | Should Be '192.168.10.0/24'
    }
    It 'kann /16' {
        $r = ConvertTo-ReverseZonenName '172.16.0.0/16'
        $r.Zone | Should Be '16.172.in-addr.arpa'
        $r.NetworkId | Should Be '172.16.0.0/16'
    }
    It 'kann /8' {
        $r = ConvertTo-ReverseZonenName '10.0.0.0/8'
        $r.Zone | Should Be '10.in-addr.arpa'
        $r.NetworkId | Should Be '10.0.0.0/8'
    }
    It 'lehnt andere Präfixe ab' {
        (ConvertTo-ReverseZonenName '192.168.10.0/25').Fehler | Should Match '/8, /16 oder /24'
        (ConvertTo-ReverseZonenName '10.0.0.0/12').Fehler | Should Match '/8, /16 oder /24'
    }
    It 'lehnt Zahlen über 255, IPv6 und Text ab' {
        (ConvertTo-ReverseZonenName '300.1.1.0/24').Fehler | Should Match '255'
        (ConvertTo-ReverseZonenName 'fd00::/64').Fehler | Should Match 'IPv4'
        (ConvertTo-ReverseZonenName 'abc').Fehler | Should Match 'Format'
        (ConvertTo-ReverseZonenName '10/16').Fehler | Should Match 'mindestens 2'
    }
}

Describe 'Get-PtrZielFuerIp' {
    It 'nimmt die genaueste Reverse-Zone' {
        $r = Get-PtrZielFuerIp '192.168.10.5' @('168.192.in-addr.arpa', '10.168.192.in-addr.arpa')
        $r.Zone | Should Be '10.168.192.in-addr.arpa'
        $r.Name | Should Be '5'
    }
    It 'bildet den Namen in einer /16-Zone' {
        $r = Get-PtrZielFuerIp '192.168.10.5' @('168.192.in-addr.arpa')
        $r.Zone | Should Be '168.192.in-addr.arpa'
        $r.Name | Should Be '5.10'
    }
    It 'schlägt ohne passende Zone ein /24-Netz vor' {
        $r = Get-PtrZielFuerIp '192.168.10.5' @('20.168.192.in-addr.arpa')
        $r.Zone | Should Be ''
        $r.VorschlagNetz | Should Be '192.168.10.0/24'
        $r.VorschlagZone | Should Be '10.168.192.in-addr.arpa'
    }
    It 'kann IPv6 (ip6.arpa)' {
        $r = Get-PtrZielFuerIp 'fd00::5' @('0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa')
        $r.Zone | Should Be '0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa'
        $r.Name | Should Be '5.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0'
    }
    It 'meldet ungültige IP' {
        (Get-PtrZielFuerIp '192.168.10' @()).Fehler | Should Match 'keine gültige'
    }
}

Describe 'Get-DnsFqdn' {
    It 'macht aus @ den Zonennamen' {
        Get-DnsFqdn '@' 'lutefisk.local' | Should BeExactly 'lutefisk.local.'
    }
    It 'hängt die Zone an einfache Namen an, klein geschrieben' {
        Get-DnsFqdn 'DC01' 'Lutefisk.Local' | Should BeExactly 'dc01.lutefisk.local.'
    }
    It 'behandelt einen Punkt im HostName als relativ zur Zone' {
        Get-DnsFqdn 'gc._msdcs' 'lutefisk.local' | Should BeExactly 'gc._msdcs.lutefisk.local.'
        Get-DnsFqdn 'srv01.sub' 'lutefisk.local' | Should BeExactly 'srv01.sub.lutefisk.local.'
    }
    It 'gibt mit und ohne Punkt am Zonenende dasselbe' {
        Get-DnsFqdn 'dc01' 'lutefisk.local.' | Should BeExactly 'dc01.lutefisk.local.'
        Get-DnsFqdn '@' 'lutefisk.local.' | Should BeExactly 'lutefisk.local.'
    }
}

Describe 'Test-DnsDienstName / Get-DnsPtrRang' {
    It 'erkennt Namen mit einem Teil, der mit _ beginnt' {
        Test-DnsDienstName 'gc._msdcs' | Should Be $true
        Test-DnsDienstName '_ldap._tcp' | Should Be $true
        Test-DnsDienstName 'dc01' | Should Be $false
        Test-DnsDienstName 'srv_01' | Should Be $false
    }
    It 'sortiert echte Hostnamen vor @/DomainDnsZones und Dienst-Namen' {
        Get-DnsPtrRang 'dc01' | Should Be 0
        Get-DnsPtrRang '@' | Should Be 1
        Get-DnsPtrRang 'DomainDnsZones' | Should Be 1
        Get-DnsPtrRang 'ForestDnsZones' | Should Be 1
        Get-DnsPtrRang 'gc._msdcs' | Should Be 2
    }
}

Describe 'Select-DnsPtrKandidaten' {
    $k = { param($Zone, $HostName, $Ip) [pscustomobject]@{ Zone = $Zone; HostName = $HostName; Ip = $Ip } }
    $kandidaten = @(
        (& $k 'lutefisk.local' '@'              '192.168.10.10')
        (& $k 'lutefisk.local' 'gc._msdcs'      '192.168.10.10')
        (& $k 'lutefisk.local' 'DomainDnsZones' '192.168.10.10')
        (& $k 'b.local'        'dc01'           '192.168.10.10')
        (& $k 'lutefisk.local' 'gc._msdcs'      '192.168.8.10')
        (& $k 'lutefisk.local' '@'              '192.168.9.10')
        (& $k 'lutefisk.local' 'srv02'          '192.168.9.10')
    )
    $r = Select-DnsPtrKandidaten $kandidaten @('10.168.192.in-addr.arpa')

    It 'nimmt zonenübergreifend den echten Hostnamen' {
        @($r.MitZone).Count | Should Be 1
        $r.MitZone[0].Fqdn | Should BeExactly 'dc01.b.local.'
        $r.MitZone[0].Zone | Should Be '10.168.192.in-addr.arpa'
        $r.MitZone[0].Name | Should Be '10'
    }
    It 'zeigt Adressen ohne Reverse-Zone mit vollständigem Namen und Vorschlag' {
        @($r.OhneZone).Count | Should Be 1
        $r.OhneZone[0].Ip | Should Be '192.168.9.10'
        $r.OhneZone[0].Fqdn | Should BeExactly 'srv02.lutefisk.local.'
        $r.OhneZone[0].VorschlagNetz | Should Be '192.168.9.0/24'
        $r.OhneZone[0].VorschlagZone | Should Be '9.168.192.in-addr.arpa'
    }
    It 'plant für Dienst-Namen keinen PTR und meldet IPs mit nur Dienst-Namen separat' {
        @($r.MitZone + $r.OhneZone | Where-Object { $_.Fqdn -like '*_msdcs*' }).Count | Should Be 0
        @($r.NurDienst).Count | Should Be 1
        $r.NurDienst[0].Ip | Should Be '192.168.8.10'
        $r.NurDienst[0].Fqdn | Should BeExactly 'gc._msdcs.lutefisk.local.'
    }
    It 'nimmt @ nur, wenn es keinen echten Hostnamen gibt' {
        $r2 = Select-DnsPtrKandidaten @((& $k 'lutefisk.local' 'gc._msdcs' '192.168.10.10'), (& $k 'lutefisk.local' '@' '192.168.10.10')) @('10.168.192.in-addr.arpa')
        $r2.MitZone[0].Fqdn | Should BeExactly 'lutefisk.local.'
        @($r2.NurDienst).Count | Should Be 0
    }
}

Describe 'Group-DnsOhneZoneNachNetz' {
    $o = {
        param($Ip, $Fqdn)
        $z = Get-PtrZielFuerIp $Ip @()
        [pscustomobject]@{ Ip = $Ip; Fqdn = $Fqdn; VorschlagNetz = $z.VorschlagNetz; VorschlagZone = $z.VorschlagZone }
    }
    $ohne = @(
        (& $o '192.168.122.243' 'kvm.lutefisk.local.')
        (& $o '192.168.8.10'    'dc01.lutefisk.local.')
        (& $o '192.168.8.11'    'dc02.lutefisk.local.')
        (& $o '192.168.9.10'    'srv01.lutefisk.local.')
        (& $o '192.168.11.200'  'drucker.lutefisk.local.')
        (& $o 'fd00::5'         'srv6.lutefisk.local.')
    )
    $netze = @(Group-DnsOhneZoneNachNetz $ohne)

    It 'bildet je /24-Netz eine Zeile, sortiert nach Netz, ohne IPv6' {
        (@($netze | ForEach-Object { $_.Netz }) -join ',') | Should Be '192.168.8.0/24,192.168.9.0/24,192.168.11.0/24,192.168.122.0/24'
    }
    It 'nennt Zone, Anzahl und Namen in der Anzeige' {
        $netze[0].Zone | Should Be '8.168.192.in-addr.arpa'
        @($netze[0].Adressen).Count | Should Be 2
        $netze[0].Anzeige | Should Match '^192\.168\.8\.0/24\s+->\s+8\.168\.192\.in-addr\.arpa\s+\(2 Adressen: dc01\.lutefisk\.local\., dc02\.lutefisk\.local\.\)$'
        $netze[1].Anzeige | Should Match '\(1 Adresse: srv01\.lutefisk\.local\.\)$'
    }
    It 'ist leer, wenn nur IPv6 oder nichts übrig ist' {
        @(Group-DnsOhneZoneNachNetz @($ohne[5])).Count | Should Be 0
        @(Group-DnsOhneZoneNachNetz @()).Count | Should Be 0
    }
}

Describe 'Get-DnsFehlendePtr' {
    Mock Get-DnsServerResourceRecord {
        @((New-TestRecord 'dc01' 'A' @{ IPv4Address = '192.168.10.10' }), (New-TestRecord 'gc._msdcs' 'A' @{ IPv4Address = '192.168.10.10' }),
          (New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.10.20' }), (New-TestRecord 'srv02' 'A' @{ IPv4Address = '192.168.8.10' }))
    } -ParameterFilter { $ZoneName -eq 'lutefisk.local' -and $RRType -eq 'A' }
    Mock Get-DnsServerResourceRecord { } -ParameterFilter { $ZoneName -eq 'lutefisk.local' -and $RRType -eq 'AAAA' }
    Mock Get-DnsServerResourceRecord { New-TestRecord '20' 'PTR' @{ PtrDomainName = 'srv01.lutefisk.local.' } } -ParameterFilter { $ZoneName -eq '10.168.192.in-addr.arpa' -and $Name -eq '20' }
    Mock Get-DnsServerResourceRecord { } -ParameterFilter { $ZoneName -eq '10.168.192.in-addr.arpa' -and $Name -eq '10' }
    Mock Get-DnsServerResourceRecord { } -ParameterFilter { $ZoneName -eq '8.168.192.in-addr.arpa' }

    It 'plant nur fehlende PTR-Einträge und meldet Adressen ohne Zone' {
        $r = Get-DnsFehlendePtr -Zonen @('lutefisk.local') -ReverseZonen @('10.168.192.in-addr.arpa')
        @($r.Plaene).Count | Should Be 1
        $r.Plaene[0].Zone | Should Be '10.168.192.in-addr.arpa'
        $r.Plaene[0].Name | Should Be '10'
        $r.Plaene[0].Daten | Should BeExactly 'dc01.lutefisk.local.'
        @($r.OhneZone).Count | Should Be 1
        $r.OhneZone[0].Fqdn | Should BeExactly 'srv02.lutefisk.local.'
    }
    It 'plant nach dem Anlegen der Zone den PTR für die neue Zone mit' {
        $r = Get-DnsFehlendePtr -Zonen @('lutefisk.local') -ReverseZonen @('10.168.192.in-addr.arpa', '8.168.192.in-addr.arpa')
        (@($r.Plaene | ForEach-Object { "$($_.Zone)|$($_.Name)|$($_.Daten)" }) -join ',') | Should Be '10.168.192.in-addr.arpa|10|dc01.lutefisk.local.,8.168.192.in-addr.arpa|10|srv02.lutefisk.local.'
        @($r.OhneZone).Count | Should Be 0
    }
}

Describe 'ConvertFrom-DnsSchnelleingabe' {
    $zone = 'firma.local'

    It 'erkennt A und CNAME aus "srv01=192.168.10.5, www=srv01"' {
        $r = @(ConvertFrom-DnsSchnelleingabe 'srv01=192.168.10.5, www=srv01' $zone)
        $r.Count | Should Be 2
        $r[0].Typ | Should Be 'A';     $r[0].Name | Should Be 'srv01'; $r[0].Daten | Should Be '192.168.10.5'
        $r[1].Typ | Should Be 'CNAME'; $r[1].Name | Should Be 'www';   $r[1].Daten | Should Be 'srv01.firma.local.'
    }
    It 'nimmt einen Namen mit Punkt als vollständigen Namen' {
        (@(ConvertFrom-DnsSchnelleingabe 'www=srv01.firma.local' $zone))[0].Daten | Should Be 'srv01.firma.local.'
    }
    It 'erkennt IPv6 als AAAA' {
        $r = (@(ConvertFrom-DnsSchnelleingabe 'srv02=FD00:0:0::5' $zone))[0]
        $r.Typ | Should Be 'AAAA'
        $r.Daten | Should Be 'fd00::5'
    }
    It 'erkennt MX mit Priorität am Zonenstamm' {
        $r = (@(ConvertFrom-DnsSchnelleingabe '@=MX:mail:10' $zone))[0]
        $r.Typ | Should Be 'MX'; $r.Name | Should Be '@'; $r.Daten | Should Be 'mail.firma.local.'; $r.Prioritaet | Should Be '10'
        $r.Fehler | Should Be ''
    }
    It 'nimmt bei MX ohne Priorität 10 und gibt einen Hinweis' {
        $r = (@(ConvertFrom-DnsSchnelleingabe '@=MX:mail' $zone))[0]
        $r.Prioritaet | Should Be '10'
        $r.Hinweis | Should Match 'Priorität'
        $r.Fehler | Should Be ''
    }
    It 'lehnt eine ungültige MX-Priorität ab' {
        (@(ConvertFrom-DnsSchnelleingabe '@=MX:mail:abc' $zone))[0].Fehler | Should Match 'Priorität'
    }
    It 'kürzt vollständige Namen der Zone und erkennt den Zonenstamm' {
        (@(ConvertFrom-DnsSchnelleingabe 'srv04.firma.local=10.0.0.4' $zone))[0].Name | Should Be 'srv04'
        (@(ConvertFrom-DnsSchnelleingabe '@=10.0.0.1' $zone))[0].Name | Should Be '@'
    }
    It 'lehnt Umlaute, zu lange Namen und falsche IPs mit Grund ab' {
        (@(ConvertFrom-DnsSchnelleingabe 'müller=192.168.10.6' $zone))[0].Fehler | Should Match 'Umlaute'
        (@(ConvertFrom-DnsSchnelleingabe "$('a' * 64)=10.0.0.1" $zone))[0].Fehler | Should Match '63'
        (@(ConvertFrom-DnsSchnelleingabe 'srv03=192.168.10' $zone))[0].Fehler | Should Match 'IPv4'
    }
    It 'verbietet CNAME am Zonenstamm und Teile ohne =' {
        (@(ConvertFrom-DnsSchnelleingabe '@=srv01' $zone))[0].Fehler | Should Match 'Zonenstamm'
        (@(ConvertFrom-DnsSchnelleingabe 'kaputt' $zone))[0].Fehler | Should Match 'Format'
    }
    It 'prüft jeden Teil einzeln, ungültige stoppen den Rest nicht' {
        $r = @(ConvertFrom-DnsSchnelleingabe 'srv01=1.2.3.4; x_y=1.2.3.5 ;; srv02=1.2.3.6' $zone)
        $r.Count | Should Be 3
        $r[0].Fehler | Should Be ''
        $r[1].Fehler | Should Not Be ''
        $r[2].Fehler | Should Be ''
        $r[2].Daten | Should Be '1.2.3.6'
    }
}

Describe 'Get-DnsBezug / ConvertFrom-DnsBezug / ConvertFrom-DnsRecord' {
    It 'normalisiert Werte für Protokoll und Vergleich' {
        Get-DnsBezug 'A' '192.168.10.5' | Should Be 'A|192.168.10.5'
        Get-DnsBezug 'cname' 'SRV01.Firma.local' | Should Be 'CNAME|srv01.firma.local.'
        Get-DnsBezug 'AAAA' 'FD00:0:0::5' | Should Be 'AAAA|fd00::5'
        Get-DnsBezug 'MX' 'mail.firma.local.' '10' | Should Be 'MX|mail.firma.local.|10'
    }
    It 'liest den Bezug wieder zurück' {
        $b = ConvertFrom-DnsBezug 'MX|mail.firma.local.|10'
        $b.Typ | Should Be 'MX'; $b.Daten | Should Be 'mail.firma.local.'; $b.Prioritaet | Should Be '10'
        (ConvertFrom-DnsBezug 'A|192.168.10.5').Daten | Should Be '192.168.10.5'
    }
    It 'wandelt Server-Einträge passend um' {
        Get-DnsBezugAusRecord (New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.10.5' }) | Should Be 'A|192.168.10.5'
        Get-DnsBezugAusRecord (New-TestRecord 'www' 'CNAME' @{ HostNameAlias = 'srv01.firma.local.' }) | Should Be 'CNAME|srv01.firma.local.'
        Get-DnsBezugAusRecord (New-TestRecord '@' 'MX' @{ MailExchange = 'mail.firma.local.'; Preference = 10 }) | Should Be 'MX|mail.firma.local.|10'
        Get-DnsBezugAusRecord (New-TestRecord '5' 'PTR' @{ PtrDomainName = 'srv01.firma.local.' }) | Should Be 'PTR|srv01.firma.local.'
    }
}

Describe 'Get-DnsKonflikt' {
    $a5 = [pscustomobject]@{ Typ = 'A'; Daten = '192.168.10.5'; Prioritaet = '' }

    It 'meldet exakt gleiche Einträge als Vorhanden' {
        (Get-DnsKonflikt $a5 @($a5)).Art | Should Be 'Vorhanden'
    }
    It 'meldet gleichen Namen mit anderem Wert als Anders' {
        $neu = [pscustomobject]@{ Typ = 'A'; Daten = '192.168.10.6'; Prioritaet = '' }
        $k = Get-DnsKonflikt $neu @($a5)
        $k.Art | Should Be 'Anders'
        $k.Werte | Should Be '192.168.10.5'
    }
    It 'verbietet CNAME neben anderen Einträgen' {
        $neu = [pscustomobject]@{ Typ = 'CNAME'; Daten = 'srv02.firma.local.'; Prioritaet = '' }
        $k = Get-DnsKonflikt $neu @($a5)
        $k.Art | Should Be 'Fehler'
        $k.Grund | Should Match 'CNAME'
    }
    It 'verbietet weitere Einträge auf einem CNAME' {
        $cname = [pscustomobject]@{ Typ = 'CNAME'; Daten = 'srv01.firma.local.'; Prioritaet = '' }
        (Get-DnsKonflikt $a5 @($cname)).Art | Should Be 'Fehler'
    }
    It 'ist Neu ohne vorhandene Einträge und neben SOA/NS am Zonenstamm' {
        (Get-DnsKonflikt $a5 @()).Art | Should Be 'Neu'
        $soa = [pscustomobject]@{ Typ = 'SOA'; Daten = ''; Prioritaet = '' }
        $mx  = [pscustomobject]@{ Typ = 'MX'; Daten = 'mail.firma.local.'; Prioritaet = '10' }
        (Get-DnsKonflikt $mx @($soa)).Art | Should Be 'Neu'
    }
}

Describe 'ConvertTo-DnsTtl und Test-QuelleFehlt' {
    It 'liest gültige TTL' {
        (ConvertTo-DnsTtl '01:00:00').TotalHours | Should Be 1
        (ConvertTo-DnsTtl '0:05:00').TotalMinutes | Should Be 5
        (ConvertTo-DnsTtl '1.00:00:00').TotalDays | Should Be 1
    }
    It 'lehnt ungültige TTL ab' {
        ConvertTo-DnsTtl '25:00' | Should BeNullOrEmpty
        ConvertTo-DnsTtl 'abc' | Should BeNullOrEmpty
        ConvertTo-DnsTtl '00:00:00' | Should BeNullOrEmpty
        ConvertTo-DnsTtl '01:60:00' | Should BeNullOrEmpty
    }
    It 'erkennt fehlende Installationsdateien' {
        Test-QuelleFehlt 'Installation failed. Error: 0x800f081f' | Should Be $true
        Test-QuelleFehlt 'The source files could not be found.' | Should Be $true
        Test-QuelleFehlt 'Zugriff verweigert' | Should Be $false
    }
}

Describe 'DNS-Menü und Fähigkeiten' {

    Context 'Server ohne DNS-Rolle' {
        $script:Faehig = @{ DNS = $false; DnsRolle = $false; DnsEntfernt = $false; ServerManager = $true; DnsClient = $true; Grund = @{ DNS = 'DNS - Rolle nicht installiert' } }
        It 'zeigt nur Status und Rolle installieren' {
            $sichtbar = @(Get-DnsMenue | Where-Object { $_.An -and -not (Get-FehlendeFaehigkeit $_.Braucht $script:Faehig) })
            (@($sichtbar | ForEach-Object { $_.Taste }) -join ',') | Should Be '1,2'
        }
    }

    Context 'Server mit laufender DNS-Rolle' {
        $script:Faehig = @{ DNS = $true; DnsRolle = $true; DnsEntfernt = $false; ServerManager = $true; DnsClient = $true; Grund = @{} }
        It 'zeigt alle Punkte außer Rolle installieren' {
            $sichtbar = @(Get-DnsMenue | Where-Object { $_.An -and -not (Get-FehlendeFaehigkeit $_.Braucht $script:Faehig) })
            (@($sichtbar | ForEach-Object { $_.Taste }) -join ',') | Should Be '1,3,4,5,6,7,8'
        }
    }

    Context 'Anderer DNS-Server über $DnsServerName' {
        $DnsServerName = 'dns-test-01'
        Mock Import-ModulStill { $true }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local' } }
        Mock Get-WindowsFeature { [pscustomobject]@{ Name = 'DNS'; Installed = $false } }
        Mock Get-Service { $null }
        Mock Get-DnsServerSetting { [pscustomobject]@{ ComputerName = 'dns-test-01' } }

        $f = Get-Faehigkeiten

        It 'nutzt den anderen Server, auch ohne lokale Rolle' {
            $f.DnsEntfernt | Should Be $true
            $f.DnsRolle | Should Be $false
            $f.DNS | Should Be $true
            Assert-MockCalled Get-DnsServerSetting -Times 1 -Exactly -Scope Context -ParameterFilter { $ComputerName -eq 'dns-test-01' }
        }
        It 'gibt allen DNS-Aufrufen -ComputerName mit' {
            (Get-DnsParameter).ComputerName | Should Be 'dns-test-01'
        }
    }
}

Describe 'Start-Rueckgaengig mit DNS-Einträgen' {
    $LogOrdner             = $TestDrive
    $Funktionen            = @{ Protokoll = $false }
    $script:Ergebnisse     = [System.Collections.Generic.List[object]]::new()
    $script:GuiVerfuegbar  = $false
    $script:Faehig         = @{ AD = $false; DNS = $true; Grund = @{} }

    $zeile = { param($Typ, $Name, $Status, $DN, $Bezug) [pscustomobject]@{ Zeit = '2026-10-29 10:00:00'; Typ = $Typ; Name = $Name; Status = $Status; DN = $DN; Bezug = $Bezug; Info = '' } }
    @(
        (& $zeile 'DNS-Zone'      '10.168.192.in-addr.arpa' 'OK' '10.168.192.in-addr.arpa' 'Reverse')
        (& $zeile 'DNS-Zone'      'firma.local' 'OK'        'firma.local' 'Forward')
        (& $zeile 'DNS-Eintrag'   'srv01' 'OK'              'firma.local' 'A|192.168.10.5')
        (& $zeile 'DNS-Eintrag'   'www'   'OK'              'firma.local' 'CNAME|srv01.firma.local.')
        (& $zeile 'DNS-Eintrag'   '5'     'OK'              '10.168.192.in-addr.arpa' 'PTR|srv01.firma.local.')
        (& $zeile 'DNS-Eintrag'   'alt'   'VORHANDEN'       'firma.local' 'A|192.168.10.7')
        (& $zeile 'Benutzer'      'max.muster' 'OK'         'CN=Max Muster,OU=Firma,DC=firma,DC=local' '')
        (& $zeile 'DNS-Forwarder' '192.168.10.1' 'OK'       'SRV01' '')
    ) | Export-Csv -LiteralPath (Join-Path $TestDrive 'AD-Anlage_2026-10-29_10-00-00.csv') -NoTypeInformation -Delimiter ';' -Encoding UTF8

    Mock Read-Host { '1' }
    Mock Read-Host { 'JA' } -ParameterFilter { $Prompt -like '*JA*' }
    Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = $Name } }
    Mock Get-DnsServerResourceRecord {
        @((New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.10.5' }), (New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.10.99' }))
    } -ParameterFilter { $ZoneName -eq 'firma.local' -and $Name -eq 'srv01' }
    Mock Get-DnsServerResourceRecord { New-TestRecord 'www' 'CNAME' @{ HostNameAlias = 'srv01.firma.local.' } } -ParameterFilter { $ZoneName -eq 'firma.local' -and $Name -eq 'www' }
    Mock Get-DnsServerResourceRecord { New-TestRecord '5' 'PTR' @{ PtrDomainName = 'srv01.firma.local.' } } -ParameterFilter { $ZoneName -eq '10.168.192.in-addr.arpa' -and $Name -eq '5' }
    Mock Get-DnsServerResourceRecord {
        @((New-TestRecord '@' 'SOA' @{}), (New-TestRecord '@' 'NS' @{ NameServer = 'srv01.firma.local.' }))
    } -ParameterFilter { $ZoneName -eq '10.168.192.in-addr.arpa' -and -not $Name }
    Mock Get-DnsServerResourceRecord {
        @((New-TestRecord '@' 'SOA' @{}), (New-TestRecord '@' 'NS' @{ NameServer = 'srv01.firma.local.' }), (New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.10.99' }))
    } -ParameterFilter { $ZoneName -eq 'firma.local' -and -not $Name }
    Mock Remove-DnsServerResourceRecord { }
    Mock Remove-DnsServerZone { }

    Start-Rueckgaengig

    It 'entfernt genau die drei protokollierten Einträge' {
        Assert-MockCalled Remove-DnsServerResourceRecord -Times 3 -Exactly -Scope Describe
        Assert-MockCalled Remove-DnsServerResourceRecord -Times 1 -Exactly -Scope Describe -ParameterFilter { "$($InputObject.RecordData.IPv4Address)" -eq '192.168.10.5' }
        Assert-MockCalled Remove-DnsServerResourceRecord -Times 0 -Exactly -Scope Describe -ParameterFilter { "$($InputObject.RecordData.IPv4Address)" -eq '192.168.10.99' }
    }
    It 'fasst VORHANDEN-Einträge nicht an' {
        Assert-MockCalled Get-DnsServerResourceRecord -Times 0 -Exactly -Scope Describe -ParameterFilter { $Name -eq 'alt' }
    }
    It 'entfernt die leere Reverse-Zone, die nicht leere Forward-Zone bleibt' {
        Assert-MockCalled Remove-DnsServerZone -Times 1 -Exactly -Scope Describe -ParameterFilter { $Name -eq '10.168.192.in-addr.arpa' }
        Assert-MockCalled Remove-DnsServerZone -Times 0 -Exactly -Scope Describe -ParameterFilter { $Name -eq 'firma.local' }
        @($script:Ergebnisse | Where-Object { $_.Typ -eq 'DNS-Zone' -and $_.Name -eq 'firma.local' -and $_.Status -eq 'FEHLER' -and $_.Info -match 'nicht leer' }).Count | Should Be 1
    }
    It 'überspringt AD-Einträge ohne AD mit Grund' {
        $b = @($script:Ergebnisse | Where-Object { $_.Typ -eq 'Benutzer' })
        $b.Count | Should Be 1
        $b[0].Status | Should Be 'FEHLER'
        $b[0].Info | Should Match 'Active Directory'
    }
    It 'meldet die DNS-Einträge als ENTFERNT' {
        @($script:Ergebnisse | Where-Object { $_.Typ -eq 'DNS-Eintrag' -and $_.Status -eq 'ENTFERNT' }).Count | Should Be 3
    }
}

Describe 'Start-DnsPtrAuffuellen legt fehlende Reverse-Zonen an' {
    $Funktionen           = @{ Protokoll = $false; DnsZonen = $true; Vorschau = $true }
    $script:Ergebnisse    = [System.Collections.Generic.List[object]]::new()
    $script:GuiVerfuegbar = $false
    $script:Faehig        = @{ AD = $false; DNS = $true; DnsEntfernt = $false; Grund = @{} }
    $global:TestReverseZonen = [System.Collections.Generic.List[string]]::new()

    Mock Get-DnsZonen { [pscustomobject]@{ ZoneName = 'lutefisk.local' } } -ParameterFilter { $Forward }
    Mock Get-DnsZonen { @($global:TestReverseZonen | ForEach-Object { [pscustomobject]@{ ZoneName = $_ } }) } -ParameterFilter { $Reverse }
    Mock Get-DnsServerResourceRecord {
        @((New-TestRecord 'dc01' 'A' @{ IPv4Address = '192.168.8.10' }), (New-TestRecord 'gc._msdcs' 'A' @{ IPv4Address = '192.168.8.10' }),
          (New-TestRecord 'srv01' 'A' @{ IPv4Address = '192.168.9.10' }), (New-TestRecord 'srv02' 'A' @{ IPv4Address = '192.168.11.200' }),
          (New-TestRecord 'kvm' 'A' @{ IPv4Address = '192.168.122.243' }))
    } -ParameterFilter { $ZoneName -eq 'lutefisk.local' -and $RRType -eq 'A' }
    Mock Get-DnsServerZone { }
    Mock Add-DnsServerPrimaryZone { $global:TestReverseZonen.Add(((ConvertTo-ReverseZonenName $NetworkId).Zone)) }
    Mock Add-DnsServerResourceRecordPtr { }
    Mock Read-Host { '' }
    Mock Read-Host { '1' } -ParameterFilter { $Prompt -like '*Nummer*' }    # (alle Forward-Zonen) und (alle) Netze

    Start-DnsPtrAuffuellen

    It 'legt für alle vier Netze eine Reverse-Zone an' {
        Assert-MockCalled Add-DnsServerPrimaryZone -Times 4 -Exactly -Scope Describe
        ($global:TestReverseZonen -join ',') | Should Be '8.168.192.in-addr.arpa,9.168.192.in-addr.arpa,11.168.192.in-addr.arpa,122.168.192.in-addr.arpa'
    }
    It 'plant danach ohne weiteren Aufruf die PTR-Einträge mit vollständigem Namen und legt sie an' {
        Assert-MockCalled Add-DnsServerResourceRecordPtr -Times 4 -Exactly -Scope Describe
        Assert-MockCalled Add-DnsServerResourceRecordPtr -Times 1 -Exactly -Scope Describe -ParameterFilter { $ZoneName -eq '8.168.192.in-addr.arpa' -and $Name -eq '10' -and $PtrDomainName -eq 'dc01.lutefisk.local.' }
        Assert-MockCalled Add-DnsServerResourceRecordPtr -Times 0 -Exactly -Scope Describe -ParameterFilter { $PtrDomainName -like '*_msdcs*' }
    }
    It 'protokolliert Zonen und Einträge für Rückgängig' {
        @($script:Ergebnisse | Where-Object { $_.Typ -eq 'DNS-Zone' -and $_.Status -eq 'OK' -and $_.Bezug -eq 'Reverse' }).Count | Should Be 4
        @($script:Ergebnisse | Where-Object { $_.Typ -eq 'DNS-Eintrag' -and $_.Status -eq 'OK' -and $_.Bezug -like 'PTR|*' }).Count | Should Be 4
    }
}

Describe 'Start-DnsPtrAuffuellen ohne neue Reverse-Zonen' {
    $Funktionen           = @{ Protokoll = $false; DnsZonen = $true; Vorschau = $true }
    $script:Ergebnisse    = [System.Collections.Generic.List[object]]::new()
    $script:GuiVerfuegbar = $false
    $script:Faehig        = @{ AD = $false; DNS = $true; DnsEntfernt = $false; Grund = @{} }

    Mock Get-DnsZonen { [pscustomobject]@{ ZoneName = 'lutefisk.local' } } -ParameterFilter { $Forward }
    Mock Get-DnsZonen { } -ParameterFilter { $Reverse }
    Mock Get-DnsServerResourceRecord { New-TestRecord 'dc01' 'A' @{ IPv4Address = '192.168.8.10' } } -ParameterFilter { $ZoneName -eq 'lutefisk.local' -and $RRType -eq 'A' }
    Mock Add-DnsServerPrimaryZone { }
    Mock Add-DnsServerResourceRecordPtr { }
    Mock Read-Host { '' }
    Mock Read-Host { '1' } -ParameterFilter { $Prompt -like '*Nummer*' }
    Mock Read-Host { 'n' } -ParameterFilter { $Prompt -like '*Reverse-Zone(n) jetzt erstellen*' }

    It 'kehrt bei Nein ohne Fehler zurück und legt nichts an' {
        { Start-DnsPtrAuffuellen } | Should Not Throw
        Assert-MockCalled Add-DnsServerPrimaryZone -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-DnsServerResourceRecordPtr -Times 0 -Exactly -Scope It
    }
}
