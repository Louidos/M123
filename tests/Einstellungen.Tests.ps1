# Einstellungen [E]: Prüfung, JSON lesen, Speichern/Laden/Zurücksetzen. Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

$definitionen = @(Get-EinstellungsDefinitionen)
function Get-TestDefinition([string]$Schluessel) {
    return (@($definitionen | Where-Object { $_.Schluessel -eq $Schluessel }) | Select-Object -First 1)
}
function Test-Wert([string]$Schluessel, $Wert) { return (Test-EinstellungsWert (Get-TestDefinition $Schluessel) $Wert) }

Describe 'Get-EinstellungsDefinitionen' {
    It 'enthält alle Gruppen' {
        (@($definitionen | ForEach-Object { $_.Gruppe } | Select-Object -Unique) -join ',') | Should Be 'Namensregeln,Benutzer-Standards,OU / Abteilung,DNS,Module ein/aus'
    }
    It 'enthält jeden Schalter aus $Funktionen' {
        @($definitionen | Where-Object { $_.Gruppe -eq 'Module ein/aus' }).Count | Should Be $Funktionen.Count
    }
    It 'hat keine doppelten Schlüssel' {
        @($definitionen | Group-Object Schluessel | Where-Object { $_.Count -gt 1 }).Count | Should Be 0
    }
}

Describe 'Test-EinstellungsWert' {
    It 'prüft Präfixe auf ungültige AD-Zeichen' {
        (Test-Wert 'PrefixGG' 'GG-').Wert | Should BeExactly 'GG-'
        (Test-Wert 'PrefixGG' 'GG,').Ok | Should Be $false
        (Test-Wert 'PrefixGG' 'G*').Ok | Should Be $false
        (Test-Wert 'PrefixGG' 'G G').Ok | Should Be $false
        (Test-Wert 'PrefixGG' 'leer').Wert | Should BeExactly ''
    }
    It 'verlangt {vorname} oder {nachname} im Benutzernamen-Muster' {
        (Test-Wert 'BenutzernameMuster' '{v}{nachname}').Ok | Should Be $true
        (Test-Wert 'BenutzernameMuster' 'abc').Fehler | Should Match 'vorname'
        (Test-Wert 'BenutzernameMuster' '{Vorname}').Ok | Should Be $false
    }
    It 'prüft das E-Mail-Muster' {
        (Test-Wert 'EmailMuster' '{anmeldename}@firma.de').Ok | Should Be $true
        (Test-Wert 'EmailMuster' '').Ok | Should Be $true
        (Test-Wert 'EmailMuster' '{anmeldename}').Ok | Should Be $false
    }
    It 'prüft die TTL im Format hh:mm:ss' {
        (Test-Wert 'DnsStandardTTL' '00:30:00').Ok | Should Be $true
        (Test-Wert 'DnsStandardTTL' '1h').Ok | Should Be $false
    }
    It 'erlaubt Passwortlängen von 8 bis 128' {
        (Test-Wert 'PasswortLaenge' '8').Wert | Should Be 8
        (Test-Wert 'PasswortLaenge' 128).Ok | Should Be $true
        (Test-Wert 'PasswortLaenge' '7').Ok | Should Be $false
        (Test-Wert 'PasswortLaenge' '129').Ok | Should Be $false
        (Test-Wert 'PasswortLaenge' 'abc').Ok | Should Be $false
        (Test-Wert 'PasswortLaenge' $true).Ok | Should Be $false
    }
    It 'nimmt bei Ja/Nein nur echte Wahrheitswerte' {
        (Test-Wert 'NamenKleinschreiben' $false).Ok | Should Be $true
        (Test-Wert 'NamenKleinschreiben' 'ja').Ok | Should Be $false
    }
    It 'prüft Laufwerk, NTFS-Recht und Auswahl' {
        (Test-Wert 'HomeLaufwerk' 'h:').Wert | Should BeExactly 'H:'
        (Test-Wert 'HomeLaufwerk' 'HH').Ok | Should Be $false
        (Test-Wert 'HomeRecht' 'Modify').Ok | Should Be $true
        (Test-Wert 'HomeRecht' 'Quatsch').Ok | Should Be $false
        (Test-Wert 'DnsReplikation' 'forest').Wert | Should BeExactly 'Forest'
        (Test-Wert 'DnsReplikation' 'Welt').Ok | Should Be $false
    }
    It 'liest Listen aus Text und aus JSON-Arrays' {
        @((Test-Wert 'DnsWeiterleitungen' '192.168.10.1, 192.168.10.2').Wert).Count | Should Be 2
        (Test-Wert 'DnsWeiterleitungen' '192.168.10.1, x').Ok | Should Be $false
        @((Test-Wert 'DnsWeiterleitungen' '-').Wert).Count | Should Be 0
        @((Test-Wert 'AbteilungsUnterOUs' @('Benutzer', 'Gruppen')).Wert).Count | Should Be 2
        (Test-Wert 'AbteilungsUnterOUs' 'Benutzer, A/B').Ok | Should Be $false
    }
}

Describe 'ConvertFrom-EinstellungenJson' {
    It 'übernimmt gültige Werte und überspringt Kommentare' {
        $r = ConvertFrom-EinstellungenJson '{"_Hinweis":"x","PrefixGG":"GG-","Funktionen.DNS":false,"AbteilungsUnterOUs":["Benutzer"]}' $definitionen
        @($r.Warnungen).Count | Should Be 0
        $r.Werte.Count | Should Be 3
        $r.Werte['PrefixGG'] | Should BeExactly 'GG-'
        $r.Werte['Funktionen.DNS'] | Should Be $false
        @($r.Werte['AbteilungsUnterOUs']).Count | Should Be 1
    }
    It 'meldet kaputtes JSON und übernimmt nichts' {
        $r = ConvertFrom-EinstellungenJson '{kaputt' $definitionen
        @($r.Warnungen).Count | Should Be 1
        @($r.Warnungen)[0] | Should Match 'fehlerhaft'
        $r.Werte.Count | Should Be 0
    }
    It 'warnt bei unbekannten Einträgen und nimmt den Rest' {
        $r = ConvertFrom-EinstellungenJson '{"Unbekannt":1,"PrefixGG":"GG-"}' $definitionen
        @($r.Warnungen)[0] | Should Match 'unbekannt'
        $r.Werte['PrefixGG'] | Should BeExactly 'GG-'
    }
    It 'ignoriert veraltete Schlüssel ohne Warnung' {
        $r = ConvertFrom-EinstellungenJson '{"Funktionen.CsvImport":false,"PrefixGG":"GG-"}' $definitionen
        @($r.Warnungen).Count | Should Be 0
        $r.Werte.Count | Should Be 1
        $r.Werte.Contains('Funktionen.CsvImport') | Should Be $false
    }
    It 'nimmt ungültige Werte nicht an' {
        $r = ConvertFrom-EinstellungenJson '{"PasswortLaenge":3}' $definitionen
        @($r.Warnungen).Count | Should Be 1
        $r.Werte.Count | Should Be 0
    }
    It 'liest config/Einstellungen.example.json ohne Warnung' {
        $text = [System.IO.File]::ReadAllText((Join-Path (Join-Path $wurzel 'config') 'Einstellungen.example.json'))
        $r = ConvertFrom-EinstellungenJson $text $definitionen
        (@($r.Warnungen) -join ' | ') | Should Be ''
        $r.Werte.Count | Should BeGreaterThan 5
    }
    It 'verlangt ein JSON-Objekt' {
        (@((ConvertFrom-EinstellungenJson '[1,2]' $definitionen).Warnungen))[0] | Should Match 'JSON-Objekt'
        (@((ConvertFrom-EinstellungenJson '' $definitionen).Warnungen)).Count | Should Be 1
    }
}

Describe 'Einstellungen ändern, speichern, laden, zurücksetzen' {
    $script:EinstellungenDatei = Join-Path $TestDrive 'Einstellungen.json'
    $script:Faehig = $null
    Initialize-Einstellungen

    It 'Präfix GG- wirkt sofort auf Menü und Beispiel' {
        Set-Einstellung 'PrefixGG' 'GG-'
        $PrefixGG | Should BeExactly 'GG-'
        (@(Get-Hauptmenue) | Where-Object { $_.Taste -eq '3' }).Text | Should Match 'GG-<Name>'
        Get-EinstellungsBeispiel 'PrefixGG' 'GG-' | Should BeExactly 'Globale Gruppe heißt dann: GG-Vertrieb'
    }
    It 'zeigt Beispiele für DL-Namen und Anmeldenamen' {
        Get-EinstellungsBeispiel 'VerbinderRechte' '+' | Should Match 'DL_Vertrieb_R\+W'
        Get-EinstellungsBeispiel 'BenutzernameMuster' '{v}{nachname}' | Should Match 'mmueller'
    }
    It 'speichert nur die geänderten Werte' {
        Save-EinstellungsDatei | Should Be 1
        Test-Path -LiteralPath $script:EinstellungenDatei | Should Be $true
        $json = [System.IO.File]::ReadAllText($script:EinstellungenDatei) | ConvertFrom-Json
        $json.PrefixGG | Should BeExactly 'GG-'
        @($json.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('_') }).Count | Should Be 1
    }
    It 'lädt den Wert beim nächsten Start wieder' {
        Set-EinstellungsWert 'PrefixGG' 'GG_'        # frisch gestartetes Script
        Initialize-Einstellungen
        $PrefixGG | Should BeExactly 'GG-'
    }
    It 'setzt beim Zurücksetzen alles auf Standard und löscht die Datei' {
        Set-Einstellung 'Funktionen.OU' $false
        (@(Get-Hauptmenue) | Where-Object { $_.Taste -eq '1' }).An | Should Be $false
        Reset-Einstellungen
        Test-Path -LiteralPath $script:EinstellungenDatei | Should Be $false
        $PrefixGG | Should BeExactly 'GG_'
        $Funktionen.OU | Should Be $true
    }
    It 'löscht die Datei, wenn beim Speichern nichts mehr abweicht' {
        Set-Einstellung 'PrefixGG' 'GG-'
        Save-EinstellungsDatei | Should Be 1
        Set-Einstellung 'PrefixGG' 'GG_'
        Save-EinstellungsDatei | Should Be 0
        Test-Path -LiteralPath $script:EinstellungenDatei | Should Be $false
    }
    It 'läuft bei kaputter Einstellungen.json mit Standards weiter' {
        [System.IO.File]::WriteAllText($script:EinstellungenDatei, '{ kaputt', [System.Text.UTF8Encoding]::new($false))
        Mock Write-Warnung { }
        { Initialize-Einstellungen } | Should Not Throw
        $PrefixGG | Should BeExactly 'GG_'
        Assert-MockCalled Write-Warnung -Times 1 -Exactly -Scope It
        Remove-Item -LiteralPath $script:EinstellungenDatei -Force
    }
}
