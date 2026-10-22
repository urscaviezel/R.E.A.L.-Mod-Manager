# Lädt alle Module des R.E.A.L. Mod Managers (per Dot-Sourcing).
$libDir = $PSScriptRoot
foreach ($f in @('Common.ps1', 'I18n.ps1', 'BatParser.ps1', 'ModLibrary.ps1', 'GameScanner.ps1', 'Compat.ps1', 'Snapshot.ps1', 'Engine.ps1', 'RegistryTools.ps1', 'Covers.ps1', 'Updater.ps1')) {
    . ([IO.Path]::Combine($libDir, $f))
}
