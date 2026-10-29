# Reine Hilfsfunktionen (ohne Server-Aufrufe). Kompatibel mit Pester 3.4 und 4.x.

$wurzel = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1')

Describe 'ConvertTo-AdName' {
    It 'ersetzt Umlaute und ß' {
        ConvertTo-AdName 'Jürgen Müßig' | Should BeExactly 'JuergenMuessig'
    }
    It 'ersetzt große Umlaute mit großem Anfang' {
        ConvertTo-AdName 'Österreich Ärger Übel' | Should BeExactly 'OesterreichAergerUebel'
    }
    It 'entfernt Akzente' {
        ConvertTo-AdName 'José François' | Should BeExactly 'JoseFrancois'
    }
    It 'behält Bindestrich, entfernt Apostroph und Leerzeichen' {
        ConvertTo-AdName "Anne-Marie O'Neil" | Should BeExactly 'Anne-MarieONeil'
    }
    It 'gibt bei leerer Eingabe leer zurück' {
        ConvertTo-AdName '' | Should BeExactly ''
    }
}

Describe 'Format-NamensMuster' {
    $MailDomain          = 'firma.local'
    $NamenKleinschreiben = $true

    It 'bildet vorname.nachname in Kleinbuchstaben' {
        Format-NamensMuster '{vorname}.{nachname}' 'Max' 'Müller' | Should BeExactly 'max.mueller'
    }
    It 'kennt die Kurzformen {v} und {n}' {
        Format-NamensMuster '{v}{nachname}' 'Max' 'Muster' | Should BeExactly 'mmuster'
        Format-NamensMuster '{vorname}{n}' 'Max' 'Muster' | Should BeExactly 'maxm'
    }
    It 'setzt Anmeldename und Domain für die E-Mail ein' {
        Format-NamensMuster '{anmeldename}@{domain}' 'Max' 'Muster' 'max.muster' | Should BeExactly 'max.muster@firma.local'
    }
    It 'lässt die Schreibweise, wenn Kleinschreibung aus ist' {
        $NamenKleinschreiben = $false
        Format-NamensMuster '{vorname}.{nachname}' 'Max' 'Müller' | Should BeExactly 'Max.Mueller'
    }
    It 'kommt mit leerem Vornamen zurecht' {
        Format-NamensMuster '{v}{nachname}' '' 'Muster' | Should BeExactly 'muster'
    }
}

Describe 'ConvertFrom-NummernAuswahl' {
    It 'liest Einzelwerte und Bereiche' {
        (ConvertFrom-NummernAuswahl '1,3,5-7' 10) -join ',' | Should Be '1,3,5,6,7'
    }
    It 'akzeptiert ; und Leerzeichen und entfernt Doppelte' {
        (ConvertFrom-NummernAuswahl '2; 2 3' 5) -join ',' | Should Be '2,3'
    }
    It 'lehnt 0 ab' {
        ConvertFrom-NummernAuswahl '0' 5 | Should BeNullOrEmpty
    }
    It 'lehnt Werte über dem Maximum ab' {
        ConvertFrom-NummernAuswahl '11' 10 | Should BeNullOrEmpty
        ConvertFrom-NummernAuswahl '8-12' 10 | Should BeNullOrEmpty
    }
    It 'lehnt umgekehrte Bereiche ab' {
        ConvertFrom-NummernAuswahl '5-3' 10 | Should BeNullOrEmpty
    }
    It 'lehnt Text und leere Eingabe ab' {
        ConvertFrom-NummernAuswahl 'abc' 10 | Should BeNullOrEmpty
        ConvertFrom-NummernAuswahl '' 10 | Should BeNullOrEmpty
    }
    It 'gibt bei genau einer Nummer ein Array mit einem Element zurück' {
        $r = ConvertFrom-NummernAuswahl '4' 10
        $r.Count | Should Be 1
        $r[0] | Should Be 4
    }
}

Describe 'Get-RdnWert' {
    It 'liefert den ersten Teil ohne Präfix' {
        Get-RdnWert 'OU=Buchhaltung,OU=Firma,DC=firma,DC=local' | Should BeExactly 'Buchhaltung'
    }
    It 'beachtet maskierte Kommas' {
        Get-RdnWert 'CN=Muster\, Max,OU=Firma,DC=firma,DC=local' | Should BeExactly 'Muster, Max'
    }
}

Describe 'Get-Kurzpfad' {
    $Domain = [pscustomobject]@{ DNSRoot = 'firma.local' }

    It 'baut den Pfad von oben nach unten' {
        Get-Kurzpfad 'OU=Buchhaltung,OU=Firma,DC=firma,DC=local' | Should BeExactly 'firma.local/Firma/Buchhaltung'
    }
    It 'gibt beim Domänenstamm nur den Domänennamen zurück' {
        Get-Kurzpfad 'DC=firma,DC=local' | Should BeExactly 'firma.local'
    }
    It 'nimmt auch CN-Container mit' {
        Get-Kurzpfad 'CN=Users,DC=firma,DC=local' | Should BeExactly 'firma.local/Users'
    }
}
