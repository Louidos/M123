<#
.SYNOPSIS
    Prüft alle PowerShell-Dateien auf Syntaxfehler und führt die Pester-Tests aus.

.DESCRIPTION
    Läuft mit Windows PowerShell 5.1 und den Bordmitteln von Windows Server.
    Benutzt Pester 3.4 (in Windows enthalten) oder 4.x. Pester 5 wird bewusst nicht
    verwendet, weil die Tests die klassische Schreibweise "Should Be" nutzen.
    Ist das Modul PSScriptAnalyzer vorhanden (CI, Entwicklerrechner), läuft vorher
    Invoke-ScriptAnalyzer über src/ - Fehler machen den Lauf rot. Auf dem Server fehlt
    es meist; dann wird der Schritt nur übersprungen (nichts wird installiert).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Run-Tests.ps1
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Run-Tests.ps1 -NurSyntax
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Run-Tests.ps1 -OhneAnalyse
#>
[CmdletBinding()]
param([switch]$NurSyntax, [switch]$OhneAnalyse)

$ErrorActionPreference = 'Stop'
$wurzel = Split-Path -Parent $PSScriptRoot
$fehler = 0

Write-Host '== Syntax prüfen ==' -ForegroundColor Cyan
$ordner = @('src', 'tests', 'scripts') | ForEach-Object { Join-Path $wurzel $_ } | Where-Object { Test-Path -LiteralPath $_ }
foreach ($datei in @(Get-ChildItem -Path $ordner -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File)) {
    $tokens = $null
    $parseFehler = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($datei.FullName, [ref]$tokens, [ref]$parseFehler)
    if (@($parseFehler).Count) {
        foreach ($f in $parseFehler) {
            Write-Host ('  FEHLER {0}:{1}: {2}' -f $datei.Name, $f.Extent.StartLineNumber, $f.Message) -ForegroundColor Red
        }
        $fehler++
    }
    else { Write-Host "  OK     $($datei.Name)" -ForegroundColor Green }
}
if ($fehler) { Write-Host "$fehler Datei(en) mit Syntaxfehlern." -ForegroundColor Red; exit 1 }
if ($NurSyntax) { exit 0 }

if (-not $OhneAnalyse) {
    Write-Host '== PSScriptAnalyzer ==' -ForegroundColor Cyan
    if (-not (Get-Module PSScriptAnalyzer -ListAvailable)) {
        Write-Host '  Modul PSScriptAnalyzer nicht vorhanden - übersprungen (die CI prüft es).' -ForegroundColor DarkYellow
    }
    else {
        Import-Module PSScriptAnalyzer
        $regeln = Join-Path $wurzel '.github\PSScriptAnalyzerSettings.psd1'
        $funde  = @(Invoke-ScriptAnalyzer -Path (Join-Path $wurzel 'src') -Recurse -Settings $regeln)
        foreach ($f in $funde) {
            $farbe = if ("$($f.Severity)" -eq 'Error') { 'Red' } else { 'DarkYellow' }
            Write-Host ('  {0,-7} {1}:{2}  {3}  {4}' -f $f.Severity, $f.ScriptName, $f.Line, $f.RuleName, $f.Message) -ForegroundColor $farbe
        }
        $schwer = @($funde | Where-Object { "$($_.Severity)" -eq 'Error' })
        if ($schwer.Count) { Write-Host "$($schwer.Count) Analyse-Fehler." -ForegroundColor Red; exit 1 }
        Write-Host "  Keine Fehler ($($funde.Count) Hinweis(e))." -ForegroundColor Green
    }
}

Write-Host '== Pester ==' -ForegroundColor Cyan
$pester = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -lt 5 } |
          Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { Write-Host 'Pester 3.4 oder 4.x nicht gefunden.' -ForegroundColor Red; exit 1 }
Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module Pester -RequiredVersion $pester.Version -Force
Write-Host "  Pester $($pester.Version)"

$ergebnis = Invoke-Pester -Path (Join-Path $wurzel 'tests') -PassThru
if ($ergebnis.FailedCount -gt 0) { Write-Host "$($ergebnis.FailedCount) Test(s) fehlgeschlagen." -ForegroundColor Red; exit 1 }
Write-Host "Alle $($ergebnis.PassedCount) Tests grün." -ForegroundColor Green
exit 0
