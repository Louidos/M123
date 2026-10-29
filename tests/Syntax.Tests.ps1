# Prüft die Script-Datei selbst: vorhanden, fehlerfrei parsbar (Windows PowerShell 5.1), UTF-8 mit BOM.
# Kompatibel mit Pester 3.4 und 4.x.

$wurzel     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPfad = Join-Path (Join-Path $wurzel 'src') 'AD-Schnellanlage.ps1'

Describe 'AD-Schnellanlage.ps1 - Datei' {

    It 'existiert unter src/' {
        Test-Path -LiteralPath $scriptPfad | Should Be $true
    }

    It 'hat keine Syntaxfehler' {
        $tokens = $null
        $parseFehler = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPfad, [ref]$tokens, [ref]$parseFehler)
        (@($parseFehler) | ForEach-Object { "Zeile $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' | Should Be ''
    }

    It 'ist als UTF-8 mit BOM gespeichert (sonst falsche Umlaute in PS 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes($scriptPfad)
        ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should Be 'EFBBBF'
    }
}

Describe 'src/ - ein einziges Script' {
    It 'enthält nur AD-Schnellanlage.ps1 (kein Teilmodul, keine Zusatzdatei)' {
        (@(Get-ChildItem -Path (Join-Path $wurzel 'src') -Recurse -File | ForEach-Object { $_.Name }) -join ',') | Should Be 'AD-Schnellanlage.ps1'
    }
}

Describe 'Module unter src/ - Dateien' {
    $module = @(Get-ChildItem -Path (Join-Path $wurzel 'src') -Include '*.psm1', '*.psd1' -Recurse -File)

    foreach ($m in $module) {
        It "$($m.Name) hat keine Syntaxfehler" {
            $tokens = $null
            $parseFehler = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($m.FullName, [ref]$tokens, [ref]$parseFehler)
            (@($parseFehler) | ForEach-Object { "Zeile $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' | Should Be ''
        }
        It "$($m.Name) ist als UTF-8 mit BOM gespeichert" {
            $bytes = [System.IO.File]::ReadAllBytes($m.FullName)
            ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should Be 'EFBBBF'
        }
    }
}
