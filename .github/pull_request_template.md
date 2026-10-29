## Was ändert sich?

<!-- Kurz, für Nutzer verständlich. -->

Closes #

## Checkliste

- [ ] Eigener Branch vom aktuellen `main`
- [ ] Conventional Commit (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`)
- [ ] CHANGELOG unter `## Unveröffentlicht` ergänzt
- [ ] README / docs angepasst (falls Bedienung oder Verhalten sich ändert)
- [ ] Tests ergänzt, `scripts/Run-Tests.ps1` grün (oder: lokal nicht getestet, CI entscheidet)
- [ ] Hauptscript + Teilmodule (`src/Module/*.psm1`), UTF-8 mit BOM, Windows PowerShell 5.1, offline

## Nur auf einem echten Server prüfbar

<!-- Was die CI nicht testen kann (AD, DNS, Rollen, Rechte). -->
