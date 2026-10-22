# R.E.A.L. Mod Manager - Quellcode auf GitHub hochladen und Release vorbereiten (Windows PowerShell 5.1)
# Braucht Git fuer Windows (https://git-scm.com/download/win). Die Anmeldung bei GitHub uebernimmt
# der Git Credential Manager (Browserfenster) - dieses Skript speichert keine Zugangsdaten.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$repoDir = Join-Path $dist 'repo'

function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function RunGit { $ErrorActionPreference = 'Continue'; & git @args 2>&1 | ForEach-Object { Write-Host "  $_" }; return $LASTEXITCODE }

$ver = Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$ver.Version
if ($ver.Repository -notmatch '^https://github\.com/([^/]+)/([^/]+?)/?$') { throw 'version.json: Repository fehlt.' }
$owner = $Matches[1]; $name = $Matches[2]
$remote = "https://github.com/$owner/$name.git"
Write-Host "R.E.A.L. Mod Manager $version -> $remote" -ForegroundColor White

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Git ist nicht installiert: https://git-scm.com/download/win (Standardeinstellungen genuegen), danach erneut starten.' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- Dateien fuer das Repository
Step 'Dateien zusammenstellen (ohne Data, dist, Testdaten)'
[void](New-Item -ItemType Directory -Path $repoDir -Force)
Get-ChildItem -LiteralPath $repoDir -Force | Where-Object { $_.Name -ne '.git' } | Remove-Item -Recurse -Force
foreach ($f in @('RealVRManager.ps1', 'Start-RealVRManager.cmd', 'Start-RealVRManager-Debug.cmd', 'version.json', 'README.md', 'CHANGELOG.md', 'LICENSE', '.gitignore')) {
    Copy-Item -LiteralPath (Join-Path $root $f) -Destination $repoDir
}
foreach ($d in @('lib', 'ui', 'lang', 'assets', 'build')) { Copy-Item -LiteralPath (Join-Path $root $d) -Destination $repoDir -Recurse }
[void](New-Item -ItemType Directory -Path (Join-Path $repoDir 'tests') -Force)
foreach ($f in @('Run-Tests.ps1', 'Run-Selftest.cmd')) { Copy-Item -LiteralPath (Join-Path $root "tests\$f") -Destination (Join-Path $repoDir 'tests') }
# Repository-Fassung von version.json: portable, ohne Datenpfad
$vj = Join-Path $repoDir 'version.json'
$j = Get-Content -LiteralPath $vj -Raw -Encoding UTF8 | ConvertFrom-Json
$j.InstallType = 'portable'; $j.DataDir = ''
[IO.File]::WriteAllText($vj, ($j | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- Commit + Push
Step 'Git'
Push-Location $repoDir
try {
    if (-not (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
        [void](RunGit init -b main)
        [void](RunGit remote add origin $remote)
    }
    $ErrorActionPreference = 'Continue'
    if (-not (& git config user.name)) { [void](RunGit config user.name $owner) }
    if (-not (& git config user.email)) { [void](RunGit config user.email "$owner@users.noreply.github.com") }
    $ErrorActionPreference = 'Stop'
    [void](RunGit add -A)
    $ErrorActionPreference = 'Continue'
    $pending = & git status --porcelain
    $ErrorActionPreference = 'Stop'
    if ($pending) {
        $msg = Join-Path $dist 'commit-msg.txt'
        @"
R.E.A.L. Mod Manager $version

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015ahBcMkeqzWnmzQzCEinP5
"@ | ForEach-Object { [IO.File]::WriteAllText($msg, $_, (New-Object Text.UTF8Encoding($false))) }   # ohne BOM, sonst steht ein unsichtbares Zeichen im Commit-Titel
        if ((RunGit commit -F $msg) -ne 0) { throw 'git commit fehlgeschlagen.' }
        Remove-Item -LiteralPath $msg -Force
    } else { Write-Host '  Keine Aenderungen seit dem letzten Hochladen.' }
    Write-Host '  Hochladen - beim ersten Mal oeffnet sich ein GitHub-Anmeldefenster ...' -ForegroundColor Yellow
    if ((RunGit push -u origin main) -ne 0) {
        Write-Host ''
        Write-Host 'Hochladen fehlgeschlagen. Ist das Repository wirklich leer? Falls GitHub beim Anlegen eine README erzeugt hat:' -ForegroundColor Red
        Write-Host '  diese auf GitHub loeschen oder mich fragen - nicht einfach mit --force ueberschreiben.' -ForegroundColor Red
        exit 1
    }
} finally { Pop-Location }

# ---------------------------------------------------------------- Release vorbereiten
Step 'Release vorbereiten'
$assets = @(Get-ChildItem -LiteralPath $dist -File | Where-Object { $_.Name -like "R.E.A.L.-Mod-Manager-$version-*" })
if (-not $assets.Count) { Write-Host "  Keine Release-Dateien fuer $version in dist\ - zuerst build\Build-Release.cmd ausfuehren." -ForegroundColor Yellow }
foreach ($a in $assets) { Write-Host "  Anhang: $($a.Name)" }
# Notizen aus CHANGELOG.md (Abschnitt der aktuellen Version) in die Zwischenablage
$cl = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8
$m = [regex]::Match($cl, "(?ms)^## $([regex]::Escape($version))[^\n]*\n(.*?)(?=^## |\z)")
$notes = if ($m.Success) { $m.Groups[1].Value.Trim() } else { "R.E.A.L. Mod Manager $version" }
$notesFile = Join-Path $dist "release-notes-$version.md"
[IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))
try { Set-Clipboard -Value $notes; Write-Host '  Release-Notizen sind in der Zwischenablage.' } catch { Write-Host "  Release-Notizen: $notesFile" }
$title = [Uri]::EscapeDataString("R.E.A.L. Mod Manager $version")
Start-Process "https://github.com/$owner/$name/releases/new?tag=v$version&title=$title"
Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dist)
Write-Host ''
Write-Host 'Im Browser: Notizen einfuegen (Strg+V), die beiden Dateien aus dem geoeffneten dist-Ordner ins Feld' -ForegroundColor Green
Write-Host '"Attach binaries" ziehen, "Set as a pre-release" NICHT anhaken, dann "Publish release".' -ForegroundColor Green
