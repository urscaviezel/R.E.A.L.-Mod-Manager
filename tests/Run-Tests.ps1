# Selbsttest der Kernlogik ohne echte Spiele (läuft auch unter Linux mit PowerShell 7).
# Simuliert RealConfig.bat für Elden Ring, High on Life und Kingdom Come 2 und prüft,
# dass nach der Deinstallation alles wieder exakt dem Ausgangszustand entspricht.
param([string]$ModSource, [string]$WorkDir)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
if (-not $ModSource) {
    $ModSource = @(Get-ChildItem -LiteralPath (Split-Path $appRoot -Parent) -Directory -Filter 'REAL_VR_by_LukeRoss_v*' | Sort-Object Name -Descending)[0].FullName
    Write-Host "Verwende Mod-Ordner: $ModSource"
}
. ([IO.Path]::Combine($appRoot, 'lib', 'LoadAll.ps1'))

if (-not $WorkDir) { $WorkDir = [IO.Path]::Combine($PSScriptRoot, '_work') }
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
$sep = [IO.Path]::DirectorySeparatorChar
function P { param([string[]]$Parts) return [IO.Path]::Combine([string[]](@($WorkDir) + $Parts)) }

Initialize-RVM -AppRoot $appRoot -DataRoot (P 'Data')
$script:RVM.PathOverrides = @{
    doc = (P 'User', 'Documents') + $sep; doc1 = (P 'User', 'Documents') + $sep; doc2 = (P 'User', 'Documents') + $sep
    loc = (P 'User', 'AppData', 'Local'); app = (P 'User', 'AppData', 'Roaming'); usrprf = (P 'User'); prog = (P 'ProgramData', 'RealVR')
}
$fails = 0
function Check { param([bool]$Cond, [string]$Msg) if ($Cond) { Write-Host "  PASS $Msg" -ForegroundColor Green } else { Write-Host "  FAIL $Msg" -ForegroundColor Red; $script:fails++ } }
function New-File { param($Path, $Content = 'x') $d = [IO.Path]::GetDirectoryName($Path); if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }; [IO.File]::WriteAllText($Path, $Content) }
function Get-TreeHash { param($Root)
    if (-not (Test-Path $Root)) { return '<fehlt>' }
    $items = Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length)
        if ($_.PSIsContainer) { "D $rel" } else { "F $rel " + (Get-FileSha256 $_.FullName) }
    }
    return ($items -join "`n")
}

Write-Host '== 1. RealConfig.bat einlesen'
$batPath = [IO.Path]::Combine($ModSource, 'RealConfig.bat')
$parsed = Read-RealConfig $batPath
Check ($parsed.Games.Count -ge 45) "Spiele erkannt: $($parsed.Games.Count)"
$parsed.Games | Select-Object Label, Name, RepoFolder, OnlineWarning, UsesVulkan, NeedsFirstRun, @{n = 'Sig'; e = { ($_.Signatures | ForEach-Object { $_ -join '+' }) -join ' | ' } } | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
$elden = $parsed.ByLabel['ELDEN']
Check ($elden.Name -eq 'Elden Ring') 'Name Elden Ring'
Check ($elden.ReplacesLauncher) 'Elden Ring ersetzt EAC-Launcher'
Check ($elden.Choices.Count -eq 1) 'Elden Ring Qualitätsabfrage erkannt'
Check ($parsed.ByLabel['SPIDEYMM'].RepoFolder -eq 'SPIDEY') 'SPIDEYMM nutzt RepoFolder SPIDEY'
Check ($parsed.ByLabel['DS2'].OnlineWarning) 'DS2 Online-Warnung'
Check ($parsed.ByLabel['DOOME'].UsesVulkan) 'DOOM Eternal Vulkan'
Check (@($parsed.ByLabel['HOL'].DeletesGameFiles).Count -eq 1) 'High on Life löscht openxr_loader.dll'
$sp = Get-GameSettingsPaths -Def $parsed.ByLabel['FC4'] -GameDir (P 'Games', 'FC4')
Check ($sp -contains (Get-FullPathSafe ((P 'User', 'Documents', 'My Games', 'Far Cry 4')))) "FC4 Settings-Pfad: $($sp -join ', ')"
$sp = Get-GameSettingsPaths -Def $parsed.ByLabel['FF7R'] -GameDir (P 'Games', 'FF7R')
Check (@($sp | Where-Object { $_ -match 'WindowsNoEditor' }).Count -eq 1) "FF7R wne-Pfad: $($sp -join ', ')"

Write-Host '== 2. Mod importieren'
$id = Import-RvmMod -Source $ModSource
$mods = Get-ModLibrary
Check ($mods.Count -eq 1) "Bibliothek: $($mods[0].Display)"
$mod = $mods[0]
Check ($mod.Version -eq '2610.16.2' -and $mod.EarlyAccess) "Version $($mod.Version) EA=$($mod.EarlyAccess)"

Write-Host '== 3. Simulierte Spiele anlegen'
$er = P 'Games', 'ELDEN RING', 'Game'
New-File ([IO.Path]::Combine($er, 'eldenring.exe')) 'ER-EXE'
New-File ([IO.Path]::Combine($er, 'start_protected_game.exe')) ('EAC' * 400000)   # >1 MB
New-File ([IO.Path]::Combine($er, 'data0.bdt')) 'DATA'
New-File (P 'User', 'AppData', 'Roaming', 'EldenRing', 'GraphicsConfig.xml') '<orig/>'
New-File (P 'User', 'AppData', 'Roaming', 'EldenRing', '76561190000000000', 'ER0000.sl2') 'SAVE'

$holRoot = P 'Games', 'High on Life'
$hol = [IO.Path]::Combine($holRoot, 'Oregon', 'Binaries', 'Win64')
New-File ([IO.Path]::Combine($hol, 'Oregon-Win64-Shipping.exe')) 'HOL'
New-File ([IO.Path]::Combine($holRoot, 'Engine', 'Binaries', 'ThirdParty', 'OpenXR', 'win64', 'openxr_loader.dll')) 'OXR'
New-File (P 'User', 'AppData', 'Local', 'Oregon', 'Saved', 'Config', 'WindowsNoEditor', 'GameUserSettings.ini') '[orig]'

# Hogwarts: Launcher-EXE im Hauptordner, echte EXE + DLL tiefer -> muss trotzdem gefunden werden
New-File (P 'Games', 'Hogwarts Legacy', 'HogwartsLegacy.exe') 'LAUNCHER'
New-File (P 'Games', 'Hogwarts Legacy', 'Phoenix', 'Binaries', 'Win64', 'HogwartsLegacy.exe') 'HL'
New-File (P 'Games', 'Hogwarts Legacy', 'Phoenix', 'Binaries', 'Win64', 'amd_fidelityfx_dx12.dll') 'AMD'
$kcd = P 'Games', 'KCD2', 'Bin', 'Win64MasterMasterSteamPGO'
New-File ([IO.Path]::Combine($kcd, 'KingdomCome.exe')) 'KCD'
New-File (P 'Games', 'KCD2', 'user.cfg') 'orig-user-cfg'
New-File (P 'User', 'Saved Games', 'kingdomcome2', 'profiles', 'default', 'attributes.xml') '<attr orig/>'

$s = Get-RvmSettings; $s.ManualGameFolders = @((P 'Games')); Save-RvmSettings $s
# Nur im Testordner suchen - niemals echte Spiele anfassen!
$testCand = @([pscustomobject]@{ Path = (P 'Games'); Source = 'Test'; MaxDepth = 6; StoreName = $null; AppId = $null; EpicItem = $null; EpicNs = $null })
$found = Find-SupportedGames -Parsed $parsed -Candidates $testCand
$cacheJson = Read-RvmJson ([IO.Path]::Combine((Get-RvmDir Root), 'library.json'))
Check ($cacheJson -and @($cacheJson.Entries[0].Hits).Count -eq 4) 'Spielliste im Cache gespeichert'
$found2 = Find-SupportedGames -Parsed $parsed -Candidates $testCand
Check (@($found2).Count -eq 4) 'Zweite Suche aus dem Cache liefert dieselben Spiele'
$found | Format-Table Label, Name, Folder -AutoSize | Out-String -Width 200 | Write-Host
Check ($found.Count -eq 4 -and @($found | Where-Object { $_.Label -eq 'HOGWARTS' -and $_.Folder -match 'Win64$' }).Count -eq 1) "4 Spiele gefunden (inkl. Hogwarts tief im Ordner)"
$found = @($found | Where-Object { $_.Label -ne 'HOGWARTS' })

$state0 = @{}
$watch = @((P 'Games'), (P 'User'), (P 'ProgramData'))
foreach ($w in $watch) { $state0[$w] = Get-TreeHash $w }

Write-Host '== 4. Kompatibilität'
foreach ($g in $found) {
    $c = Get-CompatAssessment -Def $parsed.ByLabel[$g.Label] -Folder $g.Folder -Mod $mod -Sys (Get-RvmSystemInfo)
    Write-Host ("  {0}: {1}`n{2}" -f $g.Name, $c.Level, $c.Text)
}

# Nicht installierte Spiele / Systemvoraussetzungen
$cMiss = Get-CompatAssessment -Def $parsed.ByLabel['DS2'] -Mod $mod -Sys $null
Check ($cMiss -and $cMiss.Level -in @('good', 'limited')) "Einschätzung ohne Spielordner: $($cMiss.Level)"
Check ((Get-CoverKey 'mod:DS2') -match '^[0-9a-f]{20}$') 'Cover-Schlüssel für nicht installiertes Spiel'
Check ((Get-ShopUrl -Game ([pscustomobject]@{ Name = 'Elden Ring'; AppId = '1245620' }) -Info $null) -eq 'https://store.steampowered.com/app/1245620/') 'Shop-Link mit AppId'
Check ((Get-ShopUrl -Game ([pscustomobject]@{ Name = 'Elden Ring'; AppId = $null }) -Info $null) -match 'search/\?term=Elden%20Ring') 'Shop-Suche ohne AppId'
Check ((ConvertFrom-HtmlText 'A &amp; B<br>C <b>D</b>') -eq "A & B`nC D") 'Shop-Beschreibung ohne HTML'
Check ((Test-IntegratedGpu 'Intel(R) UHD Graphics 770' 0.1) -and (Test-IntegratedGpu 'AMD Radeon(TM) Graphics' 0.5) -and -not (Test-IntegratedGpu 'NVIDIA GeForce RTX 4090' 24) -and -not (Test-IntegratedGpu 'AMD Radeon RX 7900 XTX' 24)) 'iGPU-Erkennung'
$fakeSys = [pscustomobject]@{ IsWindows = $true; IsAdmin = $true; Gpus = @([pscustomobject]@{ Name = 'Intel(R) UHD Graphics'; VramGB = 0.1; Integrated = $true }); DedicatedGpus = @(); VrRuntimes = @(); MaxVramGB = 0; HasNvidia = $false }
$fs = Format-SystemInfo $fakeSys
Check (-not $fs.Ok -and $fs.Text -match [regex]::Escape((T 'sys.noGpu')) -and $fs.Tip -match 'UHD') "Footer ohne dGPU/VR: $($fs.Text)"
$cNo = Get-CompatAssessment -Def $parsed.ByLabel['DS2'] -Mod $mod -Sys $fakeSys
Check ($cNo.Level -eq 'limited' -and @($cNo.Warnings).Count -ge 2) "Ohne dGPU/VR: Eingeschränkt ($(@($cNo.Warnings).Count) Warnungen)"
$okSys = [pscustomobject]@{ IsWindows = $true; IsAdmin = $true; Gpus = @([pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4080'; VramGB = 16; Integrated = $false }); DedicatedGpus = @([pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4080'; VramGB = 16; Integrated = $false }); VrRuntimes = @('SteamVR', 'Virtual Desktop'); MaxVramGB = 16; HasNvidia = $true }
$fo = Format-SystemInfo $okSys
Check ($fo.Ok -and $fo.Text -eq 'NVIDIA GeForce RTX 4080 (16 GB)  ·  VR: SteamVR, Virtual Desktop') "Footer ok: $($fo.Text)"

$old = ConvertTo-GameDefinition -Label 'HZD' -Section @(':installHZD', 'ECHO ******************************************', 'ECHO * R.E.A.L. VR mod for Horizon: Zero Dawn *', 'ECHO ******************************************')
Check ($old.Name -eq 'Horizon: Zero Dawn') "Spielname aus alter Mod-Version (v19): $($old.Name)"
$hzdC = @([pscustomobject]@{ Id = '2561580'; Name = 'Horizon Zero Dawn™ Remastered' }, [pscustomobject]@{ Id = '1151640'; Name = 'Horizon Zero Dawn™ Complete Edition' })
Check ((Select-SteamCandidate 'Horizon: Zero Dawn' $hzdC) -eq '1151640') 'Horizon: Zero Dawn -> Complete Edition (nicht Remastered)'
Check ((Select-SteamCandidate 'Ghostrunner: Complete Edition' @([pscustomobject]@{ Id = '1139900'; Name = 'Ghostrunner' }, [pscustomobject]@{ Id = '2144740'; Name = 'Ghostrunner 2' })) -eq '1139900') 'Ghostrunner: Complete Edition -> Ghostrunner'
$grId = & {
    function Get-SteamSearchCandidates { param($Term) if ($Term -eq 'ghostrunner') { return @([pscustomobject]@{ Id = '2144740'; Name = 'Ghostrunner 2' }, [pscustomobject]@{ Id = '1139900'; Name = 'Ghostrunner' }) } else { return @() } }
    function Get-SteamSuggestCandidates { param($Term) return @() }
    Find-SteamAppIdByName 'Ghostrunner: Complete Edition'
}
Check ($grId -eq '1139900') "Ghostrunner: Complete Edition ueber Grundnamen gefunden: $grId"
# Steam-Namensabgleich
$cands = @([pscustomobject]@{ Id = '782330'; Name = 'DOOM Eternal' }, [pscustomobject]@{ Id = '379720'; Name = 'DOOM' })
Check ((Select-SteamCandidate 'DOOM (2016)' $cands) -eq '379720') 'DOOM (2016) -> DOOM'
Check ((Select-SteamCandidate 'Dead Space (2023)' @([pscustomobject]@{ Id = '1693980'; Name = 'Dead Space' }, [pscustomobject]@{ Id = '47780'; Name = 'Dead Space 2' })) -eq '1693980') 'Dead Space (2023)'
$cd = @([pscustomobject]@{ Id = '3321460'; Name = 'Crimson Desert Enhanced' }, [pscustomobject]@{ Id = '5001840'; Name = 'Crimson Desert Enhanced: Charting the Unknown' }, [pscustomobject]@{ Id = '4024620'; Name = 'Crimson Desert - Deluxe Pack' }, [pscustomobject]@{ Id = '4572870'; Name = 'Crimson Desert Original Soundtrack Volume 1' })
Check ((Select-SteamCandidate 'Crimson Desert' $cd) -eq '3321460') 'Crimson Desert -> Crimson Desert Enhanced'
$hz = @([pscustomobject]@{ Id = '2561580'; Name = 'Horizon Zero Dawn Remastered' }, [pscustomobject]@{ Id = '1151640'; Name = 'Horizon Zero Dawn Complete Edition' })
Check ((Select-SteamCandidate 'Horizon Zero Dawn Remastered' $hz) -eq '2561580') 'Horizon Remastered bleibt Remastered'
# Updates (GitHub simuliert)
$upd = & {
    function Get-RvmVersionInfo { [pscustomobject]@{ Version = '0.7.0'; Repository = 'https://github.com/x/R.E.A.L.-Mod-Manager'; InstallType = 'portable' } }
    function Invoke-RvmHttpGet { param($Url)
        if ($Url -like '*/releases/latest') { return [Text.Encoding]::UTF8.GetBytes('{"tag_name":"v0.8.0","body":"Neu: X","html_url":"https://github.com/x/r/releases/tag/v0.8.0","assets":[{"name":"R.E.A.L.-Mod-Manager-0.8.0-Setup.exe","browser_download_url":"https://github.com/x/r/releases/download/v0.8.0/Setup.exe"},{"name":"R.E.A.L.-Mod-Manager-0.8.0.zip","browser_download_url":"https://github.com/x/r/releases/download/v0.8.0/p.zip"}]}') }
        return $null }
    Get-RvmUpdateInfo
}
Check ($upd.Available -and $upd.Latest -eq '0.8.0' -and $upd.Kind -eq 'zip') "Update erkannt: $($upd.Latest) ($($upd.Kind))"
$updNone = & {
    function Get-RvmVersionInfo { [pscustomobject]@{ Version = '0.7.0'; Repository = 'https://github.com/x/y' } }
    function Invoke-RvmHttpGet { param($Url) if ($Url -like '*/releases/latest') { return $null } else { return [byte[]](1, 2) } }
    Get-RvmUpdateInfo
}
Check (-not $updNone.Available -and $updNone.Error -eq 'norelease') 'Noch kein Release erkannt'
# Paket vorbereiten
$pkgSrc = P 'pkg', 'R.E.A.L.-Mod-Manager'
New-File ([IO.Path]::Combine($pkgSrc, 'version.json')) '{"Version":"0.8.0"}'
New-File ([IO.Path]::Combine($pkgSrc, 'RealVRManager.ps1')) '#'
New-File ([IO.Path]::Combine($pkgSrc, 'Data', 'x.txt')) 'nie kopieren'
$zipFile = P 'pkg.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory((P 'pkg'), $zipFile)
$prep = & {
    function Invoke-RvmDownloadFile { param($Url, $Target) Copy-Item -LiteralPath $zipFile -Destination $Target; return $true }
    Save-RvmUpdate -Info $upd
}
Check ($prep.Kind -eq 'zip' -and (Test-Path ([IO.Path]::Combine($prep.Path, 'RealVRManager.ps1'))) -and -not (Test-Path ([IO.Path]::Combine($prep.Path, 'Data')))) "Update-Paket entpackt: $($prep.Path)"
# Sprachen von GitHub (simuliert, Ueberschreibungen nur im Kind-Scope)
$ol = & {
    function Get-RvmLangSourceUrl { return 'https://api.github.com/repos/x/y/contents/lang?ref=main' }
    function Invoke-RvmHttpGet { param($Url)
        if ($Url -like '*contents/lang*') { return [Text.Encoding]::UTF8.GetBytes('[{"name":"it.json","download_url":"https://raw/it.json"},{"name":"README.md","download_url":"https://raw/README.md"}]') }
        if ($Url -eq 'https://raw/it.json') { return [Text.Encoding]::UTF8.GetBytes('{"_meta":{"code":"it","name":"Italiano","version":"0.6.0"},"btn.ok":"OK"}') }
        return $null }
    Get-RvmOnlineLanguages
}
Check ($ol.Ok -and @($ol.Items).Count -eq 1 -and $ol.Items[0].Name -eq 'Italiano') 'Online-Sprachliste gelesen'
$src = Get-RvmLangSourceUrl
Check (-not $src -or $src -match '^https://api\.github\.com/repos/[^/]+/[^/]+/contents/lang\?ref=') "Sprachquelle: $src"
Write-Host '== 5. Installation (simulierte RealConfig.bat)'
$script:RVM.BatRunner = {
    param($GameDir)
    $sp = Get-StdPaths
    if (Test-Path ([IO.Path]::Combine($GameDir, 'eldenring.exe'))) {
        $dst = [IO.Path]::Combine($sp.app, 'EldenRing')
        Copy-Item ([IO.Path]::Combine($dst, 'GraphicsConfig.xml')) ([IO.Path]::Combine($dst, 'GraphicsConfig_ori.xml'))
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'ELDEN', 'Settings', 'GraphicsConfig_2high.xml')) ([IO.Path]::Combine($dst, 'GraphicsConfig.xml')) -Force
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'ELDEN', 'BackupSaves.bat')) ([IO.Path]::Combine($GameDir, 'RealRepo'))
        Rename-Item ([IO.Path]::Combine($GameDir, 'start_protected_game.exe')) 'start_protected_game_ori.exe'
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'ELDEN', 'start_protected_game.exe')) $GameDir
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'RealVR64.dll')) $GameDir
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'RealVR.ini')) $GameDir
        $repo = 'ELDEN'
    } elseif (Test-Path ([IO.Path]::Combine($GameDir, 'Oregon-Win64-Shipping.exe'))) {
        Remove-Item ([IO.Path]::Combine($GameDir, '..', '..', '..', 'Engine', 'Binaries', 'ThirdParty', 'OpenXR', 'win64', 'openxr_loader.dll')) -Force
        $dst = [IO.Path]::Combine($sp.loc, 'Oregon', 'Saved', 'Config', 'WindowsNoEditor')
        Copy-Item ([IO.Path]::Combine($dst, 'GameUserSettings.ini')) ([IO.Path]::Combine($dst, 'GameUserSettings_ori.ini'))
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'HOL', 'Settings', 'GameUserSettings.ini')) $dst -Force
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'RealVR64.dll')) ([IO.Path]::Combine($GameDir, 'dxgi.dll'))
        $repo = 'HOL'
    } elseif (Test-Path ([IO.Path]::Combine($GameDir, 'KingdomCome.exe'))) {
        $dst = [IO.Path]::Combine($sp.usrprf, 'Saved Games', 'kingdomcome2', 'profiles', 'default')
        Copy-Item ([IO.Path]::Combine($dst, 'attributes.xml')) ([IO.Path]::Combine($dst, 'attributes_ori.xml'))
        New-File ([IO.Path]::Combine($dst, 'attributes.xml')) '<attr vr/>'
        $base2 = [IO.Path]::GetFullPath([IO.Path]::Combine($GameDir, '..', '..'))
        Copy-Item ([IO.Path]::Combine($base2, 'user.cfg')) ([IO.Path]::Combine($base2, 'user_ori.cfg'))
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'KCD2', 'user.cfg')) $base2 -Force
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'RealVR64.dll')) ([IO.Path]::Combine($GameDir, 'dxgi.dll'))
        Copy-Item ([IO.Path]::Combine($GameDir, 'RealRepo', 'RealVR.ini')) $GameDir
        $repo = 'KCD2'
    }
    # Aufräumen wie RealConfig.bat
    foreach ($d in [IO.Directory]::GetDirectories([IO.Path]::Combine($GameDir, 'RealRepo'))) {
        if ([IO.Path]::GetFileName($d) -ne $repo) { Remove-Item $d -Recurse -Force }
    }
    New-File ([IO.Path]::Combine($GameDir, 'RealRepo', 'NvProfileBackup.nip')) 'nv'
}

foreach ($g in $found) {
    $r = Install-RealVR -GameFolder $g.Folder -GameLabel $g.Label -Mod $mod
    Check $r.Success "Installation $($g.Name): +$($r.Summary.FilesAdded) ~$($r.Summary.FilesChanged) -$($r.Summary.FilesRemoved)"
    $st = Get-ModInstallState -Folder $g.Folder -Def $parsed.ByLabel[$g.Label]
    Check ($st.State -eq 'Managed') "Status $($g.Name) = $($st.State)"
}
Check (-not (Test-Path ([IO.Path]::Combine($holRoot, 'Engine', 'Binaries', 'ThirdParty', 'OpenXR', 'win64', 'openxr_loader.dll')))) 'HOL openxr_loader.dll wurde (simuliert) gelöscht'

# Nutzung simulieren: Logdatei entsteht, Benutzer ändert RealVR.ini, Spiel schreibt Spielstand
New-File ([IO.Path]::Combine($er, 'RealVR64.log')) 'log'
New-File ([IO.Path]::Combine($er, 'RealVR.ini')) "[RVR]`nUser=1"
New-File (P 'User', 'AppData', 'Roaming', 'EldenRing', '76561190000000000', 'ER0000.sl2') 'SAVE-NEU'

Write-Host '== 6. Deinstallation'
foreach ($g in $found) {
    $st = Get-ModInstallState -Folder $g.Folder
    $plan = Get-JournalUninstallPlan -JournalDir $st.Journal.Dir
    Write-Host (Format-Plan $plan)
    $res = Invoke-RvmPlan -Plan $plan -Options @{ Nvidia = $true }
    Check ($res.Errors -eq 0) "Deinstallation $($g.Name) ohne Fehler"
    Check ($res.Verify.FileIssues -eq 0) "Keine Rückstände $($g.Name): $($res.Verify.Headline)"
    Check ((Get-ModInstallState -Folder $g.Folder).State -eq 'None') "Status danach None"
}
# Spielstand wurde vom Spiel geändert -> darf NICHT zurückgesetzt werden; ansonsten muss alles identisch sein
Check ([IO.File]::ReadAllText((P 'User', 'AppData', 'Roaming', 'EldenRing', '76561190000000000', 'ER0000.sl2')) -eq 'SAVE-NEU') 'Spielstand blieb unangetastet'
New-File (P 'User', 'AppData', 'Roaming', 'EldenRing', '76561190000000000', 'ER0000.sl2') 'SAVE'
foreach ($w in $watch) {
    $now = Get-TreeHash $w
    Check ($now -eq $state0[$w]) "Zustand identisch: $w"
    if ($now -ne $state0[$w]) { Compare-Object ($state0[$w] -split "`n") ($now -split "`n") | Format-Table -AutoSize | Out-String -Width 250 | Write-Host }
}
Check ([IO.File]::ReadAllText([IO.Path]::Combine($er, 'start_protected_game.exe')).StartsWith('EACEAC')) 'Original-EAC-Launcher zurück'

Write-Host '== 7. Legacy-Entfernung (ohne Protokoll)'
Copy-Item -Path ([IO.Path]::Combine($mod.Path, '*')) -Destination $er -Recurse -Force   # Mod "von Hand" installieren (ohne Protokoll)
& $script:RVM.BatRunner $er
Check ((Get-ModInstallState -Folder $er -Def $elden).State -eq 'Foreign') 'Manuelle Installation als "ohne Protokoll" erkannt'
$leg = Get-LegacyUninstallPlan -GameFolder $er -Def $elden -Mod $mod
Write-Host (Format-Plan $leg)
$res = Invoke-RvmPlan -Plan $leg
Check ($res.Errors -eq 0) 'Legacy-Entfernung ohne Fehler'
Check ((Get-ModInstallState -Folder $er -Def $elden).State -eq 'None') 'Legacy: danach keine Mod-Spuren'
Check ([IO.File]::ReadAllText((P 'User', 'AppData', 'Roaming', 'EldenRing', 'GraphicsConfig.xml')) -eq '<orig/>') 'Legacy: GraphicsConfig.xml original'

Write-Host '== 8. Update-Ablauf'
$g = $found | Where-Object Label -eq 'KCD2'
$r = Install-RealVR -GameFolder $g.Folder -GameLabel $g.Label -Mod $mod
New-File ([IO.Path]::Combine($g.Folder, 'RealVR.ini')) "[RVR]`nMeineEinstellung=42"
$newModDir = [IO.Path]::Combine($WorkDir, 'REAL_VR_by_LukeRoss_v2611.1.0')
Copy-Item -LiteralPath $ModSource -Destination $newModDir -Recurse
[void](Import-RvmMod -Source $newModDir)
$mods = Get-ModLibrary
Check ($mods[0].Version -eq '2611.1.0') "Neueste Version oben: $($mods[0].Version)"
$u = Update-RealVR -GameFolder $g.Folder -Mod $mods[0]
Check $u.Success 'Update erfolgreich'
$st = Get-ModInstallState -Folder $g.Folder
Check ($st.Version -eq '2611.1.0') "Neue Version im Protokoll: $($st.Version)"
Check ([IO.File]::ReadAllText([IO.Path]::Combine($g.Folder, 'RealVR.ini')) -match 'MeineEinstellung=42') 'RealVR.ini übernommen'
$res = Invoke-RvmPlan -Plan (Get-JournalUninstallPlan -JournalDir $st.Journal.Dir)
Check ($res.Verify.FileIssues -eq 0) 'Nach Update + Deinstallation keine Rückstände'
Check ([IO.File]::ReadAllText((P 'Games', 'KCD2', 'user.cfg')) -eq 'orig-user-cfg') 'KCD2 user.cfg (ausserhalb des EXE-Ordners) wieder original'

$arch = @([IO.Directory]::GetDirectories((Get-RvmDir JournalArchive)) | Where-Object { [IO.Path]::GetFileName($_) -notlike 'legacy_*' })
$big = @($arch | Where-Object { @([IO.Directory]::GetFileSystemEntries($_) | Where-Object { [IO.Path]::GetFileName($_) -ne 'journal.json' -and $_ -notlike '*.txt' }).Count })
Check ($arch.Count -ge 1 -and $big.Count -eq 0) "Archiv nach sauberer Deinstallation schlank ($($arch.Count) Ordner)"
$ci = @(Get-RvmCleanupItems)
Check (@($ci | Where-Object Kind -eq 'archive').Count -eq $arch.Count + @([IO.Directory]::GetDirectories((Get-RvmDir JournalArchive)) | Where-Object { [IO.Path]::GetFileName($_) -like 'legacy_*' }).Count) "Aufräumliste: $(@($ci).Count) Einträge"
foreach ($it in @($ci | Where-Object Kind -eq 'archive')) { Remove-RvmCleanupItem $it }
Check (-not [IO.Directory]::GetDirectories((Get-RvmDir JournalArchive)).Count) 'Archiv aufgeräumt'

Write-Host ''
if ($fails) { Write-Host "$fails Test(s) fehlgeschlagen" -ForegroundColor Red; exit 1 } else { Write-Host 'Alle Tests bestanden' -ForegroundColor Green }
