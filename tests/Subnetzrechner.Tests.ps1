# Subnetzrechner [S]: reine Rechenfunktionen ohne Server. Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

function Get-TestSubnetz([string]$Ip, [int]$Praefix) { return (Get-SubnetzInfo -Ip (ConvertTo-IpZahl $Ip) -Praefix $Praefix) }

Describe 'ConvertTo-IpZahl / ConvertTo-IpText / ConvertTo-IpBinaer' {
    It 'rechnet IP-Adressen in Zahlen um und zurück' {
        ConvertTo-IpZahl '192.168.8.0' | Should Be 3232237568
        ConvertTo-IpZahl '0.0.0.0' | Should Be 0
        ConvertTo-IpZahl '255.255.255.255' | Should Be 4294967295
        ConvertTo-IpText 3232237568 | Should BeExactly '192.168.8.0'
    }
    It 'lehnt ungültige Adressen ab' {
        ConvertTo-IpZahl '192.168.8' | Should BeNullOrEmpty
        ConvertTo-IpZahl '256.1.1.1' | Should BeNullOrEmpty
        ConvertTo-IpZahl 'abc' | Should BeNullOrEmpty
        ConvertTo-IpZahl '' | Should BeNullOrEmpty
    }
    It 'zeigt die Maske binär' {
        ConvertTo-IpBinaer (Get-MaskeAusPraefix 22) | Should BeExactly '11111111.11111111.11111100.00000000'
    }
}

Describe 'Get-MaskeAusPraefix / Get-PraefixAusEingabe' {
    It 'bildet Masken aus Präfixen' {
        ConvertTo-IpText (Get-MaskeAusPraefix 0) | Should BeExactly '0.0.0.0'
        ConvertTo-IpText (Get-MaskeAusPraefix 8) | Should BeExactly '255.0.0.0'
        ConvertTo-IpText (Get-MaskeAusPraefix 22) | Should BeExactly '255.255.252.0'
        ConvertTo-IpText (Get-MaskeAusPraefix 32) | Should BeExactly '255.255.255.255'
    }
    It 'versteht komplette, gekürzte und CIDR-Eingaben' {
        Get-PraefixAusEingabe '255.255.252.0' | Should Be 22
        Get-PraefixAusEingabe '255.255.252' | Should Be 22
        Get-PraefixAusEingabe '255' | Should Be 8
        Get-PraefixAusEingabe '/22' | Should Be 22
        Get-PraefixAusEingabe '22' | Should Be 22
        Get-PraefixAusEingabe '/0' | Should Be 0
        Get-PraefixAusEingabe ' 255.255.255.192 ' | Should Be 26
    }
    It 'lehnt ungültige Masken ab' {
        Get-PraefixAusEingabe '255.255.253.0' | Should BeNullOrEmpty
        Get-PraefixAusEingabe '/33' | Should BeNullOrEmpty
        Get-PraefixAusEingabe '255.255.255.255.0' | Should BeNullOrEmpty
        Get-PraefixAusEingabe 'abc' | Should BeNullOrEmpty
        Get-PraefixAusEingabe '' | Should BeNullOrEmpty
    }
}

Describe 'ConvertFrom-SubnetzEingabe' {
    It 'nimmt nur eine Maske' {
        $e = ConvertFrom-SubnetzEingabe '255.255.252'
        $e.Praefix | Should Be 22
        $e.Ip | Should BeNullOrEmpty
    }
    It 'nimmt IP mit Präfix oder Maske' {
        $e = ConvertFrom-SubnetzEingabe '192.168.10.37/26'
        $e.Praefix | Should Be 26
        ConvertTo-IpText $e.Ip | Should BeExactly '192.168.10.37'
        (ConvertFrom-SubnetzEingabe '192.168.10.37 / 26').Praefix | Should Be 26
        (ConvertFrom-SubnetzEingabe '192.168.10.37 255.255.255.192').Praefix | Should Be 26
    }
    It 'meldet ungültige Eingaben mit leerem Präfix' {
        (ConvertFrom-SubnetzEingabe '192.168.10.37/40').Praefix | Should BeNullOrEmpty
        (ConvertFrom-SubnetzEingabe '192.168.10/26').Praefix | Should BeNullOrEmpty
        (ConvertFrom-SubnetzEingabe 'a b c').Praefix | Should BeNullOrEmpty
    }
}

Describe 'Get-SubnetzInfo' {
    It '/26: 192.168.10.37 -> Netz .0, Broadcast .63, Hosts .1 bis .62' {
        $r = Get-TestSubnetz '192.168.10.37' 26
        $r.Netz | Should BeExactly '192.168.10.0'
        $r.Broadcast | Should BeExactly '192.168.10.63'
        $r.ErsterHost | Should BeExactly '192.168.10.1'
        $r.LetzterHost | Should BeExactly '192.168.10.62'
        $r.Hosts | Should Be 62
        $r.Adressen | Should Be 64
        $r.Maske | Should BeExactly '255.255.255.192'
        $r.Wildcard | Should BeExactly '0.0.0.63'
        $r.HostBits | Should Be 6
        $r.Formel | Should BeExactly '(2^6 - 2)'
        $r.Reserviert | Should Be $true
    }
    It '/24' {
        $r = Get-TestSubnetz '192.168.8.77' 24
        $r.Netz | Should BeExactly '192.168.8.0'
        $r.Broadcast | Should BeExactly '192.168.8.255'
        $r.ErsterHost | Should BeExactly '192.168.8.1'
        $r.LetzterHost | Should BeExactly '192.168.8.254'
        $r.Hosts | Should Be 254
        $r.MaskeBinaer | Should BeExactly '11111111.11111111.11111111.00000000'
    }
    It '/30' {
        $r = Get-TestSubnetz '10.0.0.6' 30
        $r.Netz | Should BeExactly '10.0.0.4'
        $r.Broadcast | Should BeExactly '10.0.0.7'
        $r.ErsterHost | Should BeExactly '10.0.0.5'
        $r.LetzterHost | Should BeExactly '10.0.0.6'
        $r.Hosts | Should Be 2
    }
    It '/31 ist Punkt-zu-Punkt ohne reservierte Adressen' {
        $r = Get-TestSubnetz '10.0.0.7' 31
        $r.Netz | Should BeExactly '10.0.0.6'
        $r.ErsterHost | Should BeExactly '10.0.0.6'
        $r.LetzterHost | Should BeExactly '10.0.0.7'
        $r.Hosts | Should Be 2
        $r.Reserviert | Should Be $false
        $r.Hinweis | Should Match '/31'
    }
    It '/32 ist genau eine Adresse' {
        $r = Get-TestSubnetz '192.168.10.37' 32
        $r.Netz | Should BeExactly '192.168.10.37'
        $r.ErsterHost | Should BeExactly '192.168.10.37'
        $r.LetzterHost | Should BeExactly '192.168.10.37'
        $r.Hosts | Should Be 1
        $r.Adressen | Should Be 1
        $r.Wildcard | Should BeExactly '0.0.0.0'
        $r.Hinweis | Should Match '/32'
    }
    It '/8' {
        $r = Get-TestSubnetz '10.20.30.40' 8
        $r.Netz | Should BeExactly '10.0.0.0'
        $r.Broadcast | Should BeExactly '10.255.255.255'
        $r.ErsterHost | Should BeExactly '10.0.0.1'
        $r.LetzterHost | Should BeExactly '10.255.255.254'
        $r.Hosts | Should Be 16777214
        $r.Maske | Should BeExactly '255.0.0.0'
    }
    It '/22 mit 255.255.252' {
        $r = Get-SubnetzInfo -Ip (ConvertTo-IpZahl '192.168.10.5') -Praefix (Get-PraefixAusEingabe '255.255.252')
        $r.Netz | Should BeExactly '192.168.8.0'
        $r.Broadcast | Should BeExactly '192.168.11.255'
        $r.Hosts | Should Be 1022
    }
    It '/0 umfasst alle Adressen' {
        $r = Get-TestSubnetz '1.2.3.4' 0
        $r.Netz | Should BeExactly '0.0.0.0'
        $r.Broadcast | Should BeExactly '255.255.255.255'
        $r.Hosts | Should Be 4294967294
    }
}

Describe 'Start-Subnetzrechner' {
    Mock Show-SubnetzInfo { }
    Mock Write-Warnung { }
    $global:SubnetzAntworten = [System.Collections.Generic.Queue[string]]::new([string[]]@('255.255.253.0', '/26', 'kaputt', '192.168.10.37', '192.168.10.37/26', ''))
    Mock Read-Host { $global:SubnetzAntworten.Dequeue() }

    It 'fragt bei falschen Eingaben neu und geht mit Enter zurück' {
        { Start-Subnetzrechner } | Should Not Throw
        Assert-MockCalled Write-Warnung -Times 2 -Exactly -Scope Describe
        Assert-MockCalled Show-SubnetzInfo -Times 2 -Exactly -Scope Describe -ParameterFilter { $Info.Netz -eq '192.168.10.0' -and $Info.Broadcast -eq '192.168.10.63' }
        $global:SubnetzAntworten.Count | Should Be 0
    }
}
