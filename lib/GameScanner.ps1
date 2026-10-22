# R.E.A.L. Mod Manager - Spielesuche
# Wie bei DLSS5 Autopilot (MIT): keine Festplattensuche, sondern die Listen der Stores lesen
# (Steam, Epic, GOG, Ubisoft, EA, Rockstar, Amazon, Heroic, Xbox, X:\Games-Ordner, manuelle Ordner).
# Das Ergebnis wird in Data\library.json zwischengespeichert; danach wird nur Neues/Geaendertes angeschaut.

$script:ScanSkipDirs = @('Content', 'Paks', 'Movies', '__Installer', '_CommonRedist', 'CommonRedist', 'Redist', 'shadercache',
    'Engine', 'RealRepo', 'Localization', 'Video', 'Videos', 'Sound', 'Audio', 'uplay_download', 'Backup', 'Backups', 'Saved', 'Logs', 'Crashes')
$script:FolderJunk = @('steamlibrary', 'steamapps', 'epic games', 'gog galaxy', 'ea games', 'ubisoft', 'xboxgames', 'amazon games',
    'battle.net', 'common', 'riot games', 'rockstar games', 'modifiablewindowsapps')

function Get-RegValueSafe {
    param([string]$Path, [string]$Name)
    try {
        $v = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $v.$Name
    } catch { return $null }
}

function Get-SteamRoot {
    if (-not (Test-RvmWindows)) { return $null }
    foreach ($k in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'), @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'))) {
        $p = Get-RegValueSafe $k[0] $k[1]
        if ($p) { $p = ConvertTo-CanonicalDir $p; if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    }
    return $null
}

function Get-SteamLibraryFolders {
    $root = Get-SteamRoot
    if (-not $root) { return @() }
    $libs = @($root)
    $vdf = [IO.Path]::Combine($root, 'steamapps', 'libraryfolders.vdf')
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $p = ConvertTo-CanonicalDir ($m.Groups[1].Value.Replace('\\', '\'))
            if ($p) { $libs += $p }
        }
    }
    return @($libs | Select-Object -Unique)
}

function Get-FixedDrives {
    return @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
}

function New-Candidate {
    param($Path, $Source, $StoreName = $null, $AppId = $null, $EpicItem = $null, $EpicNs = $null, [int]$MaxDepth = 5)
    $p = ConvertTo-CanonicalDir $Path
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { return $null }
    return [pscustomobject]@{ Path = $p; Source = $Source; StoreName = $StoreName; AppId = $AppId; EpicItem = $EpicItem; EpicNs = $EpicNs; MaxDepth = $MaxDepth }
}

function Get-StoreCandidates {
    # Alle Spielordner, die die Stores kennen (schnell, ohne Festplattensuche).
    $list = New-Object System.Collections.Generic.List[object]
    $add = { param($c) if ($c) { $list.Add($c) } }

    if (Test-RvmWindows) {
        # Steam: nur vollstaendig installierte Spiele (appmanifest, StateFlags & 4)
        foreach ($lib in Get-SteamLibraryFolders) {
            $apps = [IO.Path]::Combine($lib, 'steamapps')
            if (-not (Test-Path -LiteralPath $apps)) { continue }
            foreach ($acf in @([IO.Directory]::GetFiles($apps, 'appmanifest_*.acf'))) {
                try { $t = [IO.File]::ReadAllText($acf) } catch { continue }
                $dir = [regex]::Match($t, '"installdir"\s*"([^"]+)"')
                if (-not $dir.Success) { continue }
                $st = [regex]::Match($t, '"StateFlags"\s*"(\d+)"')
                if ($st.Success -and -not ([int64]$st.Groups[1].Value -band 4)) { continue }
                $name = [regex]::Match($t, '"name"\s*"([^"]+)"')
                $appid = [regex]::Match($t, '"appid"\s*"(\d+)"')
                & $add (New-Candidate -Path ([IO.Path]::Combine($apps, 'common', $dir.Groups[1].Value)) -Source 'Steam' `
                        -StoreName $(if ($name.Success) { $name.Groups[1].Value }) -AppId $(if ($appid.Success) { $appid.Groups[1].Value }))
            }
        }
        # Epic
        $epic = [IO.Path]::Combine($env:ProgramData, 'Epic', 'EpicGamesLauncher', 'Data', 'Manifests')
        if (Test-Path -LiteralPath $epic) {
            foreach ($f in [IO.Directory]::GetFiles($epic, '*.item')) {
                try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { continue }
                if ($j.bIsApplication -eq $false -or $j.bIsExecutable -eq $false) { continue }
                & $add (New-Candidate -Path $j.InstallLocation -Source 'Epic' -StoreName $j.DisplayName -EpicItem $j.CatalogItemId -EpicNs $j.CatalogNamespace)
            }
        }
        # GOG
        foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue)) {
            & $add (New-Candidate -Path (Get-RegValueSafe $k.PSPath 'path') -Source 'GOG' -StoreName (Get-RegValueSafe $k.PSPath 'gameName'))
        }
        # Ubisoft
        foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -ErrorAction SilentlyContinue)) {
            & $add (New-Candidate -Path (Get-RegValueSafe $k.PSPath 'InstallDir') -Source 'Ubisoft')
        }
        # EA / Origin
        foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\Electronic Arts', 'HKLM:\SOFTWARE\Electronic Arts', 'HKLM:\SOFTWARE\WOW6432Node\EA Games')) {
            foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
                & $add (New-Candidate -Path (Get-RegValueSafe $k.PSPath 'Install Dir') -Source 'EA')
            }
        }
        foreach ($g in @("$env:ProgramFiles\EA Games", "${env:ProgramFiles(x86)}\EA Games")) {
            if ($g -and (Test-Path -LiteralPath $g)) { foreach ($d in [IO.Directory]::GetDirectories($g)) { & $add (New-Candidate -Path $d -Source 'EA') } }
        }
        # Rockstar
        foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\Rockstar Games', 'HKLM:\SOFTWARE\Rockstar Games')) {
            foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
                if ($k.PSChildName -match '(?i)launcher|social club') { continue }
                & $add (New-Candidate -Path (Get-RegValueSafe $k.PSPath 'InstallFolder') -Source 'Rockstar')
            }
        }
        # Amazon
        $amazonRoots = @([IO.Path]::Combine($env:LOCALAPPDATA, 'Amazon Games', 'Library'))
        foreach ($drv in Get-FixedDrives) { $amazonRoots += [IO.Path]::Combine($drv, 'Amazon Games', 'Library') }
        foreach ($r in $amazonRoots) {
            if (Test-Path -LiteralPath $r) { foreach ($d in [IO.Directory]::GetDirectories($r)) { & $add (New-Candidate -Path $d -Source 'Amazon') } }
        }
        # Heroic
        $heroic = [IO.Path]::Combine($env:APPDATA, 'heroic')
        foreach ($rel in @('legendaryConfig\legendary\installed.json', 'gog_store\installed.json', 'nile_config\nile\installed.json')) {
            $p = [IO.Path]::Combine($heroic, $rel)
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try {
                $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
                $items = if ($j -is [array]) { $j } else { @($j.PSObject.Properties | ForEach-Object { $_.Value }) }
                foreach ($it in $items) {
                    $loc = if ($it.install_path) { $it.install_path } else { $it.path }
                    & $add (New-Candidate -Path $loc -Source 'Heroic' -StoreName $it.title)
                }
            } catch { }
        }
        # Xbox / Game Pass + typische Spiele-Ordner (eine Ebene)
        foreach ($drv in Get-FixedDrives) {
            foreach ($x in @('XboxGames', 'Program Files\ModifiableWindowsApps')) {
                $root = [IO.Path]::Combine($drv, $x)
                if (-not (Test-Path -LiteralPath $root)) { continue }
                foreach ($d in [IO.Directory]::GetDirectories($root)) {
                    if ([IO.Path]::GetFileName($d) -match '(?i)^(GameSave|Minecraft Launcher)$') { continue }
                    $inner = [IO.Path]::Combine($d, 'Content')
                    & $add (New-Candidate -Path $(if (Test-Path -LiteralPath $inner) { $inner } else { $d }) -Source 'Xbox')
                }
            }
            foreach ($n in @('Games', 'Game', 'Spiele', 'Jeux', 'Juegos', 'Giochi', 'My Games', 'PC Games', 'Installed Games')) {
                $root = [IO.Path]::Combine($drv, $n)
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                try { $subs = [IO.Directory]::GetDirectories($root) } catch { continue }
                foreach ($d in $subs) {
                    $leaf = [IO.Path]::GetFileName($d)
                    if ($leaf.StartsWith('.') -or $leaf.StartsWith('$') -or ($script:FolderJunk -contains $leaf.ToLowerInvariant())) { continue }
                    & $add (New-Candidate -Path $d -Source 'Folder')
                }
            }
        }
    }

    # Manuell hinzugefuegte Ordner (tiefer durchsuchen)
    foreach ($f in (Get-RvmSettings).ManualGameFolders) { & $add (New-Candidate -Path $f -Source 'Manual' -MaxDepth 6) }

    # Doppelte entfernen (Store gewinnt; groesste Suchtiefe bleibt)
    $uniq = [ordered]@{}
    foreach ($c in $list) {
        $k = $c.Path.ToLowerInvariant()
        if ($uniq.Contains($k)) { if ($c.MaxDepth -gt $uniq[$k].MaxDepth) { $uniq[$k].MaxDepth = $c.MaxDepth }; continue }
        $uniq[$k] = $c
    }
    return @($uniq.Values)
}

function Get-SignatureHash {
    param($Parsed)
    $txt = (@($Parsed.Games | Sort-Object Label | ForEach-Object { $_.Label + ':' + (($_.Signatures | ForEach-Object { $_ -join '+' }) -join '|') })) -join ';'
    return Get-ShortHash $txt
}

function Find-GamesInCandidate {
    # Sucht die Spiel-EXE(s) in einem Store-Ordner. Liefert Treffer (Label, Folder).
    param($Candidate, $Defs, [string[]]$AllPatterns)
    $hits = @()
    $labels = @{}
    $dirs = [RVM.DirSearch]::FindDirsWithFiles($Candidate.Path, $Candidate.MaxDepth, 3000, [string[]]$script:ScanSkipDirs, [string[]]$AllPatterns)
    foreach ($dir in $dirs) {
        try { $names = @([IO.Directory]::GetFiles($dir) | ForEach-Object { [IO.Path]::GetFileName($_) }) } catch { continue }
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $names) { [void]$set.Add($n) }
        foreach ($def in $Defs) {
            $ok = $false
            foreach ($sig in $def.Signatures) { if (Test-SignatureMatch -Patterns $sig -NameSet $set -Names $names) { $ok = $true; break } }
            if ($ok) {
                if (-not $labels.ContainsKey($def.Label)) { $labels[$def.Label] = $true; $hits += [pscustomobject]@{ Label = $def.Label; Folder = (ConvertTo-CanonicalDir $dir) } }
                break
            }
        }
    }
    return $hits
}

function Test-SignatureMatch {
    param([string[]]$Patterns, $NameSet, [string[]]$Names)
    foreach ($p in $Patterns) {
        if ($p -match '[\*\?]') {
            $hit = $false
            foreach ($n in $Names) { if ($n -like $p) { $hit = $true; break } }
            if (-not $hit) { return $false }
        } elseif (-not $NameSet.Contains($p)) { return $false }
    }
    return $true
}

function Get-DirStamp {
    param([string]$Path)
    try { return [string]([IO.Directory]::GetLastWriteTimeUtc($Path).Ticks) } catch { return '' }
}

function Find-SupportedGames {
    # -Full ignoriert den Cache. -Candidates nur fuer Tests (sonst Store-Listen).
    param([Parameter(Mandatory)]$Parsed, $Candidates = $null, [switch]$Full)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $Candidates) {
        Write-RvmLog (T 'log.scan.stores') STATUS
        $Candidates = @(Get-StoreCandidates)
    }
    $defs = @($Parsed.Games | Sort-Object DetectOrder)
    $patterns = @($defs | ForEach-Object { $_.Signatures | ForEach-Object { $_ } } | ForEach-Object { $_ } | Select-Object -Unique)
    $sigHash = Get-SignatureHash $Parsed

    $cacheFile = [IO.Path]::Combine((Get-RvmDir Root), 'library.json')
    $cache = @{}
    if (-not $Full) {
        $c = Read-RvmJson $cacheFile
        if ($c -and $c.SigHash -eq $sigHash -and $c.Entries) {
            foreach ($e in $c.Entries) { $cache[$e.Path.ToLowerInvariant()] = $e }
        }
    }

    $found = New-Object System.Collections.Generic.List[object]
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $scanned = 0
    foreach ($cand in $Candidates) {
        $stamp = Get-DirStamp $cand.Path
        $hit = $cache[$cand.Path.ToLowerInvariant()]
        $hits = $null
        if ($hit -and $hit.Stamp -eq $stamp) {
            $orig = @($hit.Hits | Where-Object { $_ })
            $hits = @($orig | Where-Object { Test-Path -LiteralPath $_.Folder })
            if ($orig.Count -ne $hits.Count) { $hits = $null }   # Spiel-EXE verschwunden -> neu suchen
        }
        if ($null -eq $hits) {
            $scanned++
            Write-RvmLog (T 'log.scan.folder' $cand.Path) STATUS
            $hits = @(Find-GamesInCandidate -Candidate $cand -Defs $defs -AllPatterns $patterns)
        }
        $entries.Add([pscustomobject]@{ Path = $cand.Path; Source = $cand.Source; Stamp = $stamp; Hits = @($hits) })
        foreach ($h in $hits) {
            if (-not $seen.Add($h.Folder)) { continue }
            $def = $Parsed.ByLabel[$h.Label]
            if (-not $def) { continue }
            $found.Add([pscustomobject]@{
                    Label = $h.Label; Name = $def.Name; Folder = $h.Folder; Source = $cand.Source
                    RootFolder = $cand.Path; StoreName = $cand.StoreName; AppId = $cand.AppId; EpicItem = $cand.EpicItem; EpicNs = $cand.EpicNs
                })
        }
    }
    try { Write-RvmJson -Path $cacheFile -Object ([ordered]@{ SigHash = $sigHash; Updated = (Get-Date).ToString('s'); Entries = $entries.ToArray() }) } catch { }
    Write-RvmLog (T 'log.scan.done' $Candidates.Count $scanned $found.Count ([Math]::Round($sw.Elapsed.TotalSeconds, 1)))
    return $found.ToArray()
}
