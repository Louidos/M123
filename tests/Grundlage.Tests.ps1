# Modulare Grundlage: Fähigkeiten-Prüfung und Menü. Server-Befehle werden gemockt.
# Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

# Platzhalter für Befehle, die es auf dem Testrechner nicht gibt (Pester kann nur Vorhandenes mocken)
if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue))       { function global:Get-ADDomain { [CmdletBinding()] param() } }
if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) { function global:Get-WindowsFeature { [CmdletBinding()] param([string[]]$Name) } }

Describe 'Get-FehlendeFaehigkeit' {
    $f = @{ AD = $false; DNS = $true; Grund = @{ AD = 'AD - Modul fehlt' } }

    It 'ist leer, wenn nichts gebraucht wird' {
        Get-FehlendeFaehigkeit @() $f | Should BeExactly ''
    }
    It 'nennt den Grund einer fehlenden Fähigkeit' {
        Get-FehlendeFaehigkeit @('AD') $f | Should BeExactly 'AD - Modul fehlt'
    }
    It 'ist leer, wenn alles vorhanden ist' {
        Get-FehlendeFaehigkeit @('DNS') $f | Should BeExactly ''
    }
    It 'reicht bei "AD|DNS" eine der beiden' {
        Get-FehlendeFaehigkeit @('AD|DNS') $f | Should BeExactly ''
    }
    It 'verlangt alle Einträge' {
        Get-FehlendeFaehigkeit @('DNS', 'AD') $f | Should BeExactly 'AD - Modul fehlt'
    }
    It 'hat einen Standardtext ohne hinterlegten Grund' {
        Get-FehlendeFaehigkeit @('Smb') $f | Should BeExactly 'Smb nicht verfügbar'
    }
}

Describe 'Get-Faehigkeiten' {

    Context 'Mitgliedsserver ohne AD-Modul und ohne DNS' {
        Mock Import-ModulStill { $false }
        Mock Test-Befehl { $false }
        Mock Test-Adminrechte { $false }
        Mock Get-Service { $null }
        Mock Get-ADDomain { throw 'darf nicht aufgerufen werden' }

        $f = Get-Faehigkeiten

        It 'meldet kein AD mit Grund' {
            $f.AD | Should Be $false
            $f.Grund.AD | Should Match 'Modul ActiveDirectory fehlt'
        }
        It 'fragt die Domäne gar nicht erst ab' {
            Assert-MockCalled Get-ADDomain -Times 0 -Exactly
        }
        It 'meldet keine DNS-Rolle mit Grund' {
            $f.DnsRolle | Should Be $false
            $f.DNS | Should Be $false
            $f.Grund.DNS | Should Match 'Rolle nicht installiert'
        }
        It 'meldet fehlende Adminrechte, SMB und Auswahlfenster' {
            $f.Admin | Should Be $false
            $f.Smb | Should Be $false
            $f.Gui | Should Be $false
        }
    }

    Context 'AD-Modul vorhanden, aber Domäne nicht erreichbar' {
        Mock Import-ModulStill { $false }
        Mock Import-ModulStill { $true } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-Service { $null }
        Mock Get-ADDomain { throw 'Server nicht erreichbar' }

        $f = Get-Faehigkeiten

        It 'meldet kein AD und nennt den Fehler' {
            $f.AD | Should Be $false
            $f.Grund.AD | Should Match 'nicht erreichbar'
        }
    }

    Context 'Domänencontroller mit DNS-Rolle' {
        Mock Import-ModulStill { $true }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local'; PDCEmulator = 'dc01.firma.local' } }
        Mock Get-WindowsFeature { [pscustomobject]@{ Name = 'DNS'; Installed = $true } }
        Mock Get-Service { [pscustomobject]@{ Name = 'DNS'; Status = 'Running' } }

        $f = Get-Faehigkeiten

        It 'erkennt AD und merkt sich die Domäne' {
            $f.AD | Should Be $true
            $f.Domain.DNSRoot | Should Be 'firma.local'
        }
        It 'erkennt DNS-Rolle, Dienst und Modul' {
            $f.DnsRolle | Should Be $true
            $f.DnsDienst | Should Be $true
            $f.DNS | Should Be $true
        }
    }

    Context 'DNS-Rolle installiert, Dienst gestoppt' {
        Mock Import-ModulStill { $true }
        Mock Test-Befehl { $true }
        Mock Test-Adminrechte { $true }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'firma.local' } }
        Mock Get-WindowsFeature { [pscustomobject]@{ Name = 'DNS'; Installed = $true } }
        Mock Get-Service { [pscustomobject]@{ Name = 'DNS'; Status = 'Stopped' } }

        $f = Get-Faehigkeiten

        It 'meldet DNS als nicht nutzbar, weil der Dienst nicht läuft' {
            $f.DnsRolle | Should Be $true
            $f.DNS | Should Be $false
            $f.Grund.DNS | Should Match 'Dienst'
        }
    }
}

Describe 'Get-Hauptmenue' {
    $menue = @(Get-Hauptmenue)

    It 'enthält alle bisherigen Menüpunkte' {
        (@($menue | ForEach-Object { $_.Taste }) -join ',') | Should Be '1,2,3,4,5,6,7,8,D,E,P'
    }
    It 'hat keinen CSV-Import und keine CSV-Vorlage mehr' {
        @($menue | Where-Object { $_.Taste -eq 'V' -or $_.Text -match 'CSV' }).Count | Should Be 0
    }
    It 'hat keine doppelten Tasten' {
        @($menue | Group-Object Taste | Where-Object { $_.Count -gt 1 }).Count | Should Be 0
    }
    It 'verlangt AD für alle AD-Punkte, nicht für P' {
        @($menue | Where-Object { $_.Taste -match '^[1-7]$' -and @($_.Braucht) -notcontains 'AD' }).Count | Should Be 0
        (@(($menue | Where-Object { $_.Taste -eq '8' }).Braucht) -join ',') | Should Be 'AD|DNS'
        @(($menue | Where-Object { $_.Taste -eq 'P' }).Braucht).Count | Should Be 0
    }
    It 'zeigt das aktuelle Präfix im Text' {
        $PrefixGG = 'GG-'
        (@(Get-Hauptmenue) | Where-Object { $_.Taste -eq '3' }).Text | Should Match 'GG-<Name>'
    }
    It 'blendet abgeschaltete Punkte über An aus' {
        $Funktionen = [ordered]@{ OU = $false }
        (@(Get-Hauptmenue) | Where-Object { $_.Taste -eq '1' }).An | Should Be $false
    }
}
