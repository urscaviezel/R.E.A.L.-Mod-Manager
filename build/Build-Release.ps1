# R.E.A.L. Mod Manager - Release bauen (Windows PowerShell 5.1)
# Erzeugt in dist\:
#   R.E.A.L.-Mod-Manager-<Version>-portable.zip   (Ordner mit EXE, fuer Update und "Variante 1")
#   R.E.A.L.-Mod-Manager-<Version>-Setup.exe      (nur wenn Inno Setup 6 installiert ist)
# Laedt nichts hoch.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$build = $PSScriptRoot
$dist = Join-Path $root 'dist'
$appName = 'R.E.A.L. Mod Manager'

function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }

$ver = Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$ver.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "version.json: Version '$version' muss x.y.z sein." }
Write-Host "$appName $version" -ForegroundColor White

# ---------------------------------------------------------------- Bereitstellen
Step 'Dateien zusammenstellen'
if (Test-Path -LiteralPath $dist) {
    Get-ChildItem -LiteralPath $dist -Directory -Filter 'stage*' | Remove-Item -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $dist -Force)
$stageP = Join-Path $dist "stage-portable\$appName"
[void](New-Item -ItemType Directory -Path $stageP -Force)
foreach ($f in @('RealVRManager.ps1', 'version.json', 'README.md', 'LICENSE')) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $stageP }
foreach ($d in @('lib', 'ui', 'lang', 'assets')) { Copy-Item -LiteralPath (Join-Path $root $d) -Destination $stageP -Recurse }
Get-ChildItem -LiteralPath $stageP -Recurse -File | Where-Object { $_.Name -match '\.(bak|tmp|log)$' } | Remove-Item -Force

# ---------------------------------------------------------------- Starter-EXE
Step 'Starter-EXE kompilieren'
$csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe (.NET Framework 4) nicht gefunden.' }
$asmInfo = Join-Path $dist 'AssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("$appName")]
[assembly: AssemblyProduct("$appName")]
[assembly: AssemblyDescription("Installer/Uninstaller for Luke Ross' R.E.A.L. VR mod")]
[assembly: AssemblyCopyright("GPL-3.0-or-later")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyInformationalVersion("$version")]
"@ | Set-Content -LiteralPath $asmInfo -Encoding UTF8
$exe = Join-Path $stageP "$appName.exe"
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32icon:$(Join-Path $root 'assets\logo.ico')" "/win32manifest:$(Join-Path $build 'app.manifest')" (Join-Path $build 'Launcher.cs') $asmInfo
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw 'Kompilieren fehlgeschlagen.' }
Remove-Item -LiteralPath $asmInfo -Force

function Set-VersionJson($dir, $installType, $dataDir) {
    $p = Join-Path $dir 'version.json'
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $j | Add-Member -NotePropertyName InstallType -NotePropertyValue $installType -Force
    $j | Add-Member -NotePropertyName DataDir -NotePropertyValue $dataDir -Force
    $j | Add-Member -NotePropertyName BuildDate -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd') -Force
    [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
Set-VersionJson $stageP 'portable' ''

# ---------------------------------------------------------------- Portable ZIP
Step 'Portable ZIP'
$zip = Join-Path $dist "R.E.A.L.-Mod-Manager-$version-portable.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stageP, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Write-Host "  $zip"

# ---------------------------------------------------------------- Installer
Step 'Installer (Inno Setup 6)'
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $iscc) {
    Write-Host '  Inno Setup 6 nicht gefunden - Installer wird uebersprungen.' -ForegroundColor Yellow
    Write-Host '  Download: https://jrsoftware.org/isdl.php  (danach dieses Skript erneut starten)' -ForegroundColor Yellow
} else {
    $stageI = Join-Path $dist "stage-installer\$appName"
    [void](New-Item -ItemType Directory -Path (Split-Path $stageI -Parent) -Force)
    Copy-Item -LiteralPath $stageP -Destination (Split-Path $stageI -Parent) -Recurse
    Set-VersionJson $stageI 'installer' '%ProgramData%\R.E.A.L. Mod Manager'
    & $iscc /Q "/DAppVersion=$version" "/DStageDir=$stageI" "/DOutDir=$dist" (Join-Path $build 'RealModManager.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup meldet einen Fehler.' }
    Write-Host "  $(Join-Path $dist "R.E.A.L.-Mod-Manager-$version-Setup.exe")"
}

Get-ChildItem -LiteralPath $dist -Directory -Filter 'stage-installer' | Remove-Item -Recurse -Force
Step 'Fertig'
Write-Host "  Ordner zum Ausprobieren (portable): $stageP"
Write-Host "  Ausgabe: $dist"
