# Gruppenrichtlinien [G]: reine Hilfsfunktionen, Drives.xml, Versionen, Vorlagen und Abläufe
# (GroupPolicy- und AD-Befehle gemockt). Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

# Platzhalter für Befehle, die es auf dem Testrechner nicht gibt (Pester kann nur Vorhandenes mocken)
$platzhalter = @{
    'Get-GPO'             = { [CmdletBinding()] param([string]$Name, $Guid, [switch]$All) }
    'New-GPO'             = { [CmdletBinding()] param([string]$Name, [string]$Comment) }
    'Remove-GPO'          = { [CmdletBinding()] param($Guid) }
    'New-GPLink'          = { [CmdletBinding()] param($Guid, [string]$Target, $LinkEnabled) }
    'Set-GPLink'          = { [CmdletBinding()] param($Guid, [string]$Target, $LinkEnabled) }
    'Get-GPInheritance'   = { [CmdletBinding()] param([string]$Target) }
    'Get-GPOReport'       = { [CmdletBinding()] param($Guid, [string]$ReportType) }
    'Set-GPRegistryValue' = { [CmdletBinding()] param($Guid, [string]$Key, [string]$ValueName, [string]$Type, $Value) }
    'Get-GPRegistryValue' = { [CmdletBinding()] param($Guid, [string]$Key, [string]$ValueName) }
    'Invoke-GPUpdate'     = { [CmdletBinding()] param([string]$Computer, [switch]$Force, [int]$RandomDelayInMinutes) }
    'Get-ADObject'        = { [CmdletBinding()] param($Identity, [string]$LDAPFilter, [string[]]$Properties, [string]$Filter, [string]$SearchBase, [string]$SearchScope, [string]$Server) }
    'Set-ADObject'        = { [CmdletBinding()] param($Identity, [hashtable]$Replace, [string]$Server) }
    'Get-ADGroup'         = { [CmdletBinding()] param($Identity, [string]$LDAPFilter, [string]$Server) }
}
foreach ($befehl in @($platzhalter.Keys)) {
    if (-not (Get-Command $befehl -ErrorAction SilentlyContinue)) { Set-Item -Path "function:global:$befehl" -Value $platzhalter[$befehl] }
}

$guid    = [guid]'6ac1786c-016f-11d2-945f-00c04fb984f9'
$testGpo = [pscustomobject]@{ Id = $guid; DisplayName = 'Netzlaufwerke'; Path = 'cn={6AC1786C-016F-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=firma,DC=local' }
$Domain  = [pscustomobject]@{ DNSRoot = 'firma.local'; NetBIOSName = 'FIRMA'; PDCEmulator = 'dc01.firma.local'; DistinguishedName = 'DC=firma,DC=local' }

Describe 'Gruppenrichtlinien im Script' {
    It 'sind beim Dot-Sourcing des einen Scripts da' {
        [bool](Get-Command Start-GpoMenue -ErrorAction SilentlyContinue) | Should Be $true
        [bool](Get-Command Set-GppLaufwerk -ErrorAction SilentlyContinue) | Should Be $true
    }
}

Describe 'ConvertTo-GpoLaufwerk' {
    It 'akzeptiert H, h: und Leerzeichen' {
        ConvertTo-GpoLaufwerk 'H' | Should BeExactly 'H'
        ConvertTo-GpoLaufwerk ' h: ' | Should BeExactly 'H'
        ConvertTo-GpoLaufwerk 'Z:' | Should BeExactly 'Z'
    }
    It 'lehnt A bis C, Zahlen und mehrere Buchstaben ab' {
        ConvertTo-GpoLaufwerk 'C:' | Should BeExactly ''
        ConvertTo-GpoLaufwerk 'A' | Should BeExactly ''
        ConvertTo-GpoLaufwerk '1' | Should BeExactly ''
        ConvertTo-GpoLaufwerk 'HH' | Should BeExactly ''
        ConvertTo-GpoLaufwerk '' | Should BeExactly ''
    }
}

Describe 'Get-UncPfadFehler / Get-UncTeile' {
    It 'akzeptiert gültige UNC-Pfade' {
        Get-UncPfadFehler '\\server\freigabe' | Should BeExactly ''
        Get-UncPfadFehler '\\srv01.firma.local\Daten$\Abteilung' | Should BeExactly ''
        Get-UncPfadFehler '\\server\freigabe\' | Should BeExactly ''
    }
    It 'erklärt, was falsch ist' {
        Get-UncPfadFehler 'C:\Daten' | Should Match 'muss mit'
        Get-UncPfadFehler '\\server' | Should Match 'Server und Freigabe'
        Get-UncPfadFehler '\\server\\freigabe' | Should Match 'mitten'
        Get-UncPfadFehler '\\server\frei*gabe' | Should Match 'ungültige Zeichen'
        Get-UncPfadFehler '\\ser ver\freigabe' | Should Match 'Servername'
        Get-UncPfadFehler '' | Should Match 'leer'
    }
    It 'zerlegt Server, Freigabe und Rest' {
        $t = Get-UncTeile '\\srv01\Daten$\Abt\Team'
        $t.Server | Should Be 'srv01'
        $t.Freigabe | Should Be 'Daten$'
        $t.Rest | Should Be 'Abt\Team'
    }
    It 'erkennt den eigenen Server' {
        Test-UncAufDiesemServer $env:COMPUTERNAME | Should Be $true
        Test-UncAufDiesemServer "$env:COMPUTERNAME.firma.local" | Should Be $true
        Test-UncAufDiesemServer 'localhost' | Should Be $true
        Test-UncAufDiesemServer 'anderer-server-xyz' | Should Be $false
    }
}

Describe 'Get-GpoPfadFehler' {
    It 'akzeptiert UNC, lokale Pfade und Umgebungsvariablen' {
        Get-GpoPfadFehler '\\srv\netlogon\bild.jpg' | Should BeExactly ''
        Get-GpoPfadFehler 'C:\Bilder\bild.jpg' | Should BeExactly ''
        Get-GpoPfadFehler '%SystemRoot%\Web\Wallpaper\Windows\img0.jpg' | Should BeExactly ''
    }
    It 'lehnt Unsinn ab' {
        Get-GpoPfadFehler 'bild.jpg' | Should Not BeExactly ''
        Get-GpoPfadFehler 'C:\Bild?.jpg' | Should Not BeExactly ''
    }
}

Describe 'Add-GpoErweiterung' {
    $laufwerk = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
    $registry = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F73-3407-48AE-BA88-E8213C6761F1}]'

    It 'trägt die Laufwerkszuordnung in eine leere GPO ein' {
        Add-GpoErweiterung '' $script:GppLaufwerkErweiterung | Should BeExactly $laufwerk
    }
    It 'behält vorhandene Einträge und sortiert nach GUID' {
        Add-GpoErweiterung $registry $script:GppLaufwerkErweiterung |
            Should BeExactly ('[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' + $registry + '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]')
    }
    It 'ändert nichts, wenn schon alles drin ist (idempotent)' {
        Add-GpoErweiterung $laufwerk $script:GppLaufwerkErweiterung | Should BeExactly $laufwerk
    }
    It 'ergänzt fehlende Tool-GUIDs im Sammeleintrag sortiert' {
        $andere = '[{00000000-0000-0000-0000-000000000000}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}][{B087BE9D-ED37-454F-AF9C-04291E351182}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]'
        Add-GpoErweiterung $andere $script:GppLaufwerkErweiterung |
            Should BeExactly ('[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]' +
                              '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' +
                              '[{B087BE9D-ED37-454F-AF9C-04291E351182}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]')
    }
}

Describe 'Get-GpoVersionNeu / Set-GptIniVersion' {
    It 'erhöht nur die Benutzerversion (obere 16 Bit)' {
        Get-GpoVersionNeu 0 | Should Be 65536
        Get-GpoVersionNeu (2 * 65536 + 5) | Should Be (3 * 65536 + 5)
        (Get-GpoVersionTeile (Get-GpoVersionNeu (2 * 65536 + 5))).Computer | Should Be 5
    }
    It 'läuft nach 65535 mit 1 weiter' {
        (Get-GpoVersionTeile (Get-GpoVersionNeu (Get-GpoVersionNeu ([int](32767 * 65536))))).Benutzer | Should Be 32769
        (Get-GpoVersionTeile (Get-GpoVersionNeu (-65536))).Benutzer | Should Be 1
    }
    It 'setzt Version= in GPT.ini' {
        Set-GptIniVersion "[General]`r`nVersion=65536`r`ndisplayName=Neues GPO`r`n" 131072 | Should BeExactly "[General]`r`nVersion=131072`r`ndisplayName=Neues GPO`r`n"
    }
    It 'ergänzt eine fehlende Version-Zeile' {
        Set-GptIniVersion "[General]`r`ndisplayName=X`r`n" 65536 | Should BeExactly "[General]`r`nVersion=65536`r`ndisplayName=X`r`n"
        Set-GptIniVersion '' 65536 | Should BeExactly "[General]`r`nVersion=65536`r`n"
    }
}

Describe 'ConvertFrom-GpLink' {
    It 'liest GUID, aktiviert und erzwungen' {
        $l = @(ConvertFrom-GpLink '[LDAP://cn={6AC1786C-016F-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=firma,DC=local;0][LDAP://cn={31b2f340-016d-11d2-945f-00c04fb984f9},cn=policies,cn=system,DC=firma,DC=local;3]')
        $l.Count | Should Be 2
        $l[0].Guid | Should Be '{6AC1786C-016F-11D2-945F-00C04FB984F9}'
        $l[0].Aktiviert | Should Be $true
        $l[0].Erzwungen | Should Be $false
        $l[1].Guid | Should BeExactly '{31B2F340-016D-11D2-945F-00C04FB984F9}'
        $l[1].Aktiviert | Should Be $false
        $l[1].Erzwungen | Should Be $true
    }
    It 'gibt bei leerem gPLink nichts zurück' { @(ConvertFrom-GpLink '').Count | Should Be 0 }
}

Describe 'Drives.xml (Set-GppLaufwerk)' {
    It 'legt H: wie die GPMC an' {
        $xml = New-GppLaufwerkXml
        Set-GppLaufwerk -Xml $xml -Buchstabe 'H' -Pfad '\\server\freigabe' -Bezeichnung 'Daten' -Zeit '2026-10-29 12:00:00' | Should Be 'Neu'
        $xml.DocumentElement.GetAttribute('clsid') | Should BeExactly '{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}'
        $d = $xml.DocumentElement.SelectSingleNode('Drive')
        $d.GetAttribute('clsid') | Should BeExactly '{935D1B74-9CB8-4e3c-9914-7DD559B7A417}'
        $d.GetAttribute('name') | Should BeExactly 'H:'
        $d.GetAttribute('image') | Should BeExactly '2'
        $d.GetAttribute('uid') | Should Match '^\{[0-9A-F\-]{36}\}$'
        $p = $d.SelectSingleNode('Properties')
        $p.GetAttribute('action') | Should BeExactly 'U'
        $p.GetAttribute('path') | Should BeExactly '\\server\freigabe'
        $p.GetAttribute('label') | Should BeExactly 'Daten'
        $p.GetAttribute('letter') | Should BeExactly 'H'
        $p.GetAttribute('useLetter') | Should BeExactly '1'
        $d.SelectSingleNode('Filters') | Should BeNullOrEmpty
    }
    It 'schreibt die Zielgruppe als FilterGroup' {
        $xml = New-GppLaufwerkXml
        [void](Set-GppLaufwerk -Xml $xml -Buchstabe 'S' -Pfad '\\srv\vertrieb' -Aktion 'R' -GruppeName 'FIRMA\GG_Vertrieb' -GruppeSid 'S-1-5-21-1-2-3-1105')
        $f = $xml.DocumentElement.SelectSingleNode('Drive/Filters/FilterGroup')
        $f.GetAttribute('name') | Should BeExactly 'FIRMA\GG_Vertrieb'
        $f.GetAttribute('sid') | Should BeExactly 'S-1-5-21-1-2-3-1105'
        $f.GetAttribute('userContext') | Should BeExactly '1'
        $xml.DocumentElement.SelectSingleNode('Drive').GetAttribute('image') | Should BeExactly '1'
    }
    It 'erweitert eine bestehende Datei, statt sie zu überschreiben' {
        $xml = New-GppLaufwerkXml
        [void](Set-GppLaufwerk -Xml $xml -Buchstabe 'H' -Pfad '\\server\home')
        [void](Set-GppLaufwerk -Xml $xml -Buchstabe 'S' -Pfad '\\server\daten')
        $wieder = [xml](ConvertTo-GppText $xml)
        (@(Get-GppLaufwerke $wieder | ForEach-Object { $_.Buchstabe }) -join ',') | Should Be 'H,S'
    }
    It 'legt beim zweiten Lauf nichts doppelt an' {
        $xml = New-GppLaufwerkXml
        [void](Set-GppLaufwerk -Xml $xml -Buchstabe 'H' -Pfad '\\server\freigabe' -Bezeichnung 'Daten')
        Set-GppLaufwerk -Xml $xml -Buchstabe 'h:' -Pfad '\\server\freigabe' -Bezeichnung 'Daten' | Should Be 'Vorhanden'
        @(Get-GppLaufwerke $xml).Count | Should Be 1
    }
    It 'ersetzt einen geänderten Eintrag mit gleicher uid' {
        $xml = New-GppLaufwerkXml
        [void](Set-GppLaufwerk -Xml $xml -Buchstabe 'H' -Pfad '\\server\alt')
        $uid = (Get-GppLaufwerke $xml)[0].Uid
        Set-GppLaufwerk -Xml $xml -Buchstabe 'H' -Pfad '\\server\neu' | Should Be 'Geaendert'
        $l = @(Get-GppLaufwerke $xml)
        $l.Count | Should Be 1
        $l[0].Pfad | Should Be '\\server\neu'
        $l[0].Uid | Should Be $uid
    }
    It 'schreibt die XML-Deklaration wie die GPMC' {
        $xml = New-GppLaufwerkXml
        (ConvertTo-GppText $xml) | Should Match '^<\?xml version="1\.0" encoding="utf-8"\?>\r\n<Drives clsid='
    }
}

Describe 'Standard-Richtlinien (Vorlagen)' {
    $basis = @(Get-GpoStandardVorlagen | ForEach-Object { ConvertTo-GpoVorlage $_ })

    It 'hat fünf gültige eingebaute Vorlagen' {
        $basis.Count | Should Be 5
        @($basis | Where-Object { $_.Fehler }).Count | Should Be 0
        (@($basis | ForEach-Object { $_.Vorlage.Name }) -join ',') | Should Be 'Systemsteuerung,Desktophintergrund,Eingabeaufforderung,USB-Speicher,Bildschirmsperre'
    }
    It 'rechnet die Bildschirmsperre von Minuten in Sekunden um' {
        $v = ($basis | Where-Object { $_.Vorlage.Name -eq 'Bildschirmsperre' }).Vorlage
        Test-GpoVorlageEingabe $v.Eingabe '0' | Should Match '1 bis 999'
        Test-GpoVorlageEingabe $v.Eingabe 'zehn' | Should Not BeExactly ''
        Test-GpoVorlageEingabe $v.Eingabe '10' | Should BeExactly ''
        $r = Get-GpoVorlageWerte $v '10'
        $r.Fehler | Should BeExactly ''
        ($r.Werte | Where-Object { $_.Name -eq 'ScreenSaveTimeOut' }).Wert | Should Be '600'
        ($r.Werte | Where-Object { $_.Name -eq 'ScreenSaverIsSecure' }).Wert | Should Be '1'
    }
    It 'setzt DWord-Werte als Zahl' {
        $v = ($basis | Where-Object { $_.Vorlage.Name -eq 'Systemsteuerung' }).Vorlage
        $w = (Get-GpoVorlageWerte $v).Werte[0]
        $w.Typ | Should Be 'DWord'
        $w.Wert -is [int] | Should Be $true
        $w.Wert | Should Be 1
        $v.Bereich | Should Be 'Benutzer'
    }
    It 'prüft den Pfad für den Desktophintergrund' {
        $v = ($basis | Where-Object { $_.Vorlage.Name -eq 'Desktophintergrund' }).Vorlage
        Test-GpoVorlageEingabe $v.Eingabe 'bild.jpg' | Should Match 'Ungültiger Pfad'
        (Get-GpoVorlageWerte $v '\\srv\netlogon\bild.jpg').Werte[0].Wert | Should Be '\\srv\netlogon\bild.jpg'
    }
    It 'meldet fehlerhafte Vorlagen' {
        (ConvertTo-GpoVorlage @{ Name = 'X'; Werte = @(@{ Schluessel = 'HKCR\x'; Name = 'a'; Typ = 'DWord'; Wert = '1' }) }).Fehler | Should Match 'HKCU'
        (ConvertTo-GpoVorlage @{ Name = 'X'; Werte = @(@{ Schluessel = 'HKCU\x'; Name = 'a'; Typ = 'Binary'; Wert = '1' }) }).Fehler | Should Match 'Typ'
        (ConvertTo-GpoVorlage @{ Name = 'X'; Werte = @(@{ Schluessel = 'HKCU\x'; Name = 'a'; Typ = 'String'; Wert = '{eingabe}' }) }).Fehler | Should Match 'ohne Eingabe'
        (ConvertTo-GpoVorlage @{ Name = ''; Werte = @() }).Fehler | Should Match 'ohne Name'
        (ConvertTo-GpoVorlage @{ Name = 'X' }).Fehler | Should Match 'keine Werte'
    }
    It 'meldet ungültige Zahlen aus der Konfiguration' {
        $v = (ConvertTo-GpoVorlage @{ Name = 'X'; Werte = @(@{ Schluessel = 'HKCU\x'; Name = 'a'; Typ = 'DWord'; Wert = 'abc' }) }).Vorlage
        (Get-GpoVorlageWerte $v).Fehler | Should Match 'keine Zahl'
    }
    It 'erkennt Computerkonfiguration' {
        $v = (ConvertTo-GpoVorlage @{ Name = 'X'; Werte = @(@{ Schluessel = 'HKLM\Software\Policies\X'; Name = 'a'; Typ = 'DWord'; Wert = '1' }) }).Vorlage
        $v.Bereich | Should Be 'Computer'
    }
}

Describe 'Merge-GpoVorlagenJson / config-Beispiel' {
    $basis = @(Get-GpoStandardVorlagen | ForEach-Object { (ConvertTo-GpoVorlage $_).Vorlage })

    It 'liest config/GPO-Richtlinien.example.json ohne Warnung' {
        $json = [System.IO.File]::ReadAllText((Join-Path (Join-Path $wurzel 'config') 'GPO-Richtlinien.example.json'))
        $r = Merge-GpoVorlagenJson $json $basis
        @($r.Warnungen).Count | Should Be 0
        $r.Vorlagen.Count | Should BeGreaterThan 5
    }
    It 'ersetzt Vorlagen mit gleichem Namen und ergänzt neue' {
        $json = '{"Richtlinien":[{"Name":"USB-Speicher","Text":"USB nur lesen","Werte":[{"Schluessel":"HKCU\\Software\\Policies\\Microsoft\\Windows\\RemovableStorageDevices","Name":"Deny_Write","Typ":"DWord","Wert":"1"}]},{"Name":"Neu","Werte":[{"Schluessel":"HKCU\\Software\\X","Name":"Y","Typ":"String","Wert":"Z"}]}]}'
        $r = Merge-GpoVorlagenJson $json $basis
        $r.Vorlagen.Count | Should Be 6
        ($r.Vorlagen | Where-Object { $_.Name -eq 'USB-Speicher' }).Text | Should Be 'USB nur lesen'
    }
    It 'warnt bei kaputtem JSON und nimmt die eingebauten' {
        $r = Merge-GpoVorlagenJson '{kaputt' $basis
        @($r.Warnungen).Count | Should Be 1
        $r.Vorlagen.Count | Should Be 5
    }
    It 'überspringt ungültige Einträge mit Warnung' {
        $r = Merge-GpoVorlagenJson '{"Richtlinien":[{"Name":"Falsch","Werte":[{"Schluessel":"X","Name":"a","Typ":"DWord","Wert":"1"}]}]}' $basis
        @($r.Warnungen).Count | Should Be 1
        $r.Vorlagen.Count | Should Be 5
    }
}

Describe 'Get-GpoBerichtInfo' {
    $bericht = [xml]@'
<?xml version="1.0" encoding="utf-16"?>
<GPO xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <Name>Netzlaufwerke</Name>
  <Computer><VersionDirectory>0</VersionDirectory><VersionSysvol>0</VersionSysvol><Enabled>true</Enabled></Computer>
  <User><VersionDirectory>2</VersionDirectory><VersionSysvol>2</VersionSysvol><Enabled>true</Enabled>
    <ExtensionData>
      <Extension xmlns:q1="http://www.microsoft.com/GroupPolicy/Settings/DriveMaps" xsi:type="q1:DriveMapSettings">
        <q1:DriveMapSettings clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
          <q1:Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="H:" status="H:" image="2"><q1:Properties action="U" path="\\server\freigabe" letter="H"/></q1:Drive>
        </q1:DriveMapSettings>
      </Extension>
      <Name>Drive Maps</Name>
    </ExtensionData>
  </User>
  <LinksTo><SOMName>Benutzer</SOMName><SOMPath>firma.local/Benutzer</SOMPath><Enabled>true</Enabled><NoOverride>false</NoOverride></LinksTo>
</GPO>
'@
    $info = Get-GpoBerichtInfo $bericht

    It 'liest Name und Versionen' {
        $info.Name | Should Be 'Netzlaufwerke'
        $info.BenutzerAd | Should Be '2'
        $info.BenutzerSysvol | Should Be '2'
    }
    It 'findet die Laufwerkszuordnung und die Verknüpfung' {
        $info.Laufwerke | Should Be 'H: \\server\freigabe'
        $info.Links | Should Be 'firma.local/Benutzer'
    }
}

Describe 'Update-GpoBenutzerVersion' {
    Mock Get-ADObject { [pscustomobject]@{ versionNumber = (2 * 65536 + 3); gPCUserExtensionNames = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F73-3407-48AE-BA88-E8213C6761F1}]' } }
    Mock Set-ADObject { }
    Mock Get-GpoSysvolPfad { $TestDrive }
    [System.IO.File]::WriteAllText((Join-Path $TestDrive 'GPT.ini'), "[General]`r`nVersion=131075`r`ndisplayName=Neues Gruppenrichtlinienobjekt`r`n")

    $version = Update-GpoBenutzerVersion $testGpo $script:GppLaufwerkErweiterung

    It 'erhöht die Benutzerversion' { $version | Should Be (3 * 65536 + 3) }
    It 'schreibt Version und Erweiterung ins AD-Objekt' {
        Assert-MockCalled Set-ADObject -Times 1 -Exactly -ParameterFilter {
            $Replace.versionNumber -eq (3 * 65536 + 3) -and $Replace.gPCUserExtensionNames -match '^\[\{00000000.*\{35378EAC.*\{5794DAFD'
        }
    }
    It 'setzt dieselbe Version in GPT.ini' {
        [System.IO.File]::ReadAllText((Join-Path $TestDrive 'GPT.ini')) | Should Match 'Version=196611\r\n'
    }
}

Describe 'Add-GpoLink' {
    Mock Add-Ergebnis { }
    Mock New-GPLink { }
    Mock Set-GPLink { }

    It 'verknüpft nicht doppelt' {
        Mock Get-GPInheritance { [pscustomobject]@{ GpoLinks = @([pscustomobject]@{ GpoId = $guid; Enabled = $true }) } }
        Add-GpoLink $testGpo 'OU=Benutzer,DC=firma,DC=local'
        Assert-MockCalled New-GPLink -Times 0 -Exactly
        Assert-MockCalled Add-Ergebnis -ParameterFilter { $Status -eq 'VORHANDEN' }
    }
    It 'aktiviert einen deaktivierten Link' {
        Mock Get-GPInheritance { [pscustomobject]@{ GpoLinks = @([pscustomobject]@{ GpoId = $guid; Enabled = $false }) } }
        Add-GpoLink $testGpo 'OU=Benutzer,DC=firma,DC=local'
        Assert-MockCalled Set-GPLink -Times 1 -Exactly
    }
    It 'legt einen neuen aktivierten Link an' {
        Mock Get-GPInheritance { [pscustomobject]@{ GpoLinks = @() } }
        Add-GpoLink $testGpo 'OU=Benutzer,DC=firma,DC=local'
        Assert-MockCalled New-GPLink -Times 1 -Exactly -ParameterFilter { "$LinkEnabled" -eq 'Yes' -and $Target -eq 'OU=Benutzer,DC=firma,DC=local' }
    }
}

Describe 'Start-GpoNetzlaufwerk' {
    Mock Write-Host { }
    Mock Add-Ergebnis { }
    Mock Read-JaNein { $true }
    Mock Read-JaNein { $false } -ParameterFilter { $Frage -like 'Weiteres Laufwerk*' }
    Mock Select-Gpo { [pscustomobject]@{ Gpo = $testGpo; Name = 'Netzlaufwerke' } }
    Mock Save-GppLaufwerkDatei { }
    Mock Update-GpoBenutzerVersion { 3 * 65536 }
    Mock Invoke-GpoVerknuepfungAnbieten { }
    Mock Invoke-GpoAbschluss { }
    Mock Read-GpoLaufwerkPlan {
        [pscustomobject]@{ Buchstabe = 'H'; Pfad = '\\server\freigabe'; Bezeichnung = 'freigabe'; Aktion = 'U'; Gruppe = $null; Alt = $null; Erreichbar = $true }
    }

    It 'schreibt beim ersten Lauf Drives.xml und erhöht die Version' {
        Mock Read-GppLaufwerkDatei { , (New-GppLaufwerkXml) }
        Start-GpoNetzlaufwerk
        Assert-MockCalled Save-GppLaufwerkDatei -Times 1 -Exactly -ParameterFilter { @(Get-GppLaufwerke $Xml).Count -eq 1 }
        Assert-MockCalled Update-GpoBenutzerVersion -Times 1 -Exactly -ParameterFilter { $Erweiterung -eq $script:GppLaufwerkErweiterung }
        Assert-MockCalled Add-Ergebnis -ParameterFilter { $Typ -eq 'GPO-Laufwerk' -and $Status -eq 'OK' }
    }
    It 'legt beim zweiten Lauf nichts doppelt an' {
        Mock Read-GppLaufwerkDatei {
            $x = New-GppLaufwerkXml
            [void](Set-GppLaufwerk -Xml $x -Buchstabe 'H' -Pfad '\\server\freigabe' -Bezeichnung 'freigabe')
            , $x
        }
        Mock Read-GpoLaufwerkPlan {
            $alt = [pscustomobject]@{ Buchstabe = 'H'; Pfad = '\\server\freigabe'; Bezeichnung = 'freigabe'; Aktion = 'U'; GruppeName = ''; GruppeSid = ''; Uid = '' }
            [pscustomobject]@{ Buchstabe = 'H'; Pfad = '\\server\freigabe'; Bezeichnung = 'freigabe'; Aktion = 'U'; Gruppe = $null; Alt = $alt; Erreichbar = $true }
        }
        Start-GpoNetzlaufwerk
        Assert-MockCalled Save-GppLaufwerkDatei -Times 0 -Exactly -Scope It
        Assert-MockCalled Update-GpoBenutzerVersion -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-Ergebnis -Scope It -ParameterFilter { $Typ -eq 'GPO-Laufwerk' -and $Status -eq 'VORHANDEN' }
    }
}

Describe 'Start-GpoStandardRichtlinie' {
    Mock Write-Host { }
    Mock Add-Ergebnis { }
    Mock Read-JaNein { $true }
    Mock Get-GpoVorlagen { @(Get-GpoStandardVorlagen | ForEach-Object { (ConvertTo-GpoVorlage $_).Vorlage } | Where-Object { $_.Name -in 'Systemsteuerung', 'USB-Speicher' }) }
    Mock Select-AusListe { @($Eintraege) }
    Mock Select-Gpo { [pscustomobject]@{ Gpo = $testGpo; Name = 'Standard-Richtlinien' } }
    Mock Set-GPRegistryValue { }
    Mock Invoke-GpoVerknuepfungAnbieten { }
    Mock Invoke-GpoAbschluss { }

    It 'setzt zwei Standard-Richtlinien' {
        Mock Get-GPRegistryValue { throw 'nicht gefunden' }
        Start-GpoStandardRichtlinie
        Assert-MockCalled Set-GPRegistryValue -Times 2 -Exactly -Scope It
        Assert-MockCalled Set-GPRegistryValue -Scope It -ParameterFilter { $ValueName -eq 'NoControlPanel' -and $Type -eq 'DWord' -and $Value -eq 1 }
        Assert-MockCalled Set-GPRegistryValue -Scope It -ParameterFilter { $ValueName -eq 'Deny_All' }
    }
    It 'setzt nichts doppelt, wenn die Werte schon stimmen' {
        Mock Get-GPRegistryValue { [pscustomobject]@{ Value = 1; Type = 'DWord' } }
        Start-GpoStandardRichtlinie
        Assert-MockCalled Set-GPRegistryValue -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-Ergebnis -Scope It -ParameterFilter { $Status -eq 'VORHANDEN' }
    }
}

Describe 'Get-GpoMenue' {
    It 'hat die Punkte 1 bis 7 ohne doppelte Tasten' {
        $script:Faehig = @{ GroupPolicy = $false }
        (@(Get-GpoMenue | ForEach-Object { $_.Taste }) -join ',') | Should Be '1,2,3,4,5,6,7'
    }
    It 'zeigt GPMC-Installation nur, wenn das Modul fehlt' {
        $script:Faehig = @{ GroupPolicy = $true }
        (@(Get-GpoMenue) | Where-Object { $_.Taste -eq '7' }).An | Should Be $false
    }
    It 'verlangt GPO für alle Punkte außer der Installation' {
        @(Get-GpoMenue | Where-Object { $_.Taste -ne '7' -and @($_.Braucht) -notcontains 'GPO' }).Count | Should Be 0
    }
}
