# Regeln für Invoke-ScriptAnalyzer (CI und scripts/Run-Tests.ps1).
# Fehler (Severity Error) machen die CI rot, Warnungen werden nur angezeigt.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Konsolenmenü: farbige Ausgabe ist gewollt
        'PSAvoidUsingWriteHost',
        # Deutsche Verbnamen-Kombinationen wie Start-/Show-/Read-* ohne ShouldProcess sind Menüaktionen,
        # bestätigt wird über die eigene Vorschau (Read-JaNein)
        'PSUseShouldProcessForStateChangingFunctions',
        # Pluralnamen (Get-DnsZonen, Get-Faehigkeiten) sind deutsche Wörter
        'PSUseSingularNouns',
        # Das Script ist UTF-8 mit BOM (Test in tests/Syntax.Tests.ps1)
        'PSUseBOMForUnicodeEncodedFile'
    )
}
