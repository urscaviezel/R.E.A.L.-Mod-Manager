# R.E.A.L. Mod Manager - Installation, Deinstallation, Update (mit Protokoll) und Entfernung ohne Protokoll

# ================================================================ Hilfen

function Invoke-RealConfigBat {
    # Startet Luke Ross' RealConfig.bat direkt im Admin-Modus (ohne elevate.exe),
    # damit wir auf das Ende warten koennen. Das Konsolenfenster ist sichtbar fuer Rueckfragen.
    param([string]$GameDir)
    $sp = Get-StdPaths
    $bat = [IO.Path]::Combine($GameDir, 'RealConfig.bat')
    $argStr = 'as_admin "{0}" "{1}" "{2}" "{3}" "{4}" "{5}" "{6}"' -f $sp.doc, $sp.doc1, $sp.doc2, $sp.loc, $sp.app, $sp.usrprf, $sp.prog
    $cmdLine = '/c ""{0}" {1}"' -f $bat, $argStr
    Write-RvmLog (T 'log.bat.start') STATUS
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WorkingDirectory $GameDir -PassThru
    $p.WaitForExit()
    Write-RvmLog (T 'log.bat.end' $p.ExitCode)
}

function Get-ScopeDir { param($JournalDir, $Index) return [IO.Path]::Combine($JournalDir, 'scopes', [string]$Index) }

function Get-CurrentFileState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $fi = New-Object IO.FileInfo($Path)
    return ('F|{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
}

$script:ModFilePattern = '(?i)^(RealVR.*|.*\.RealVR.*|RealConfig\.bat|cudart64_.*\.dll|openvr_api\.dll|dxgi\.dll|ReShadePreset\.ini|BackupSaves\.bat|start_protected_game_ori\.exe)$'
$script:ModDirPattern = '(?i)^(RealRepo|reshade-shaders)$'

function Test-NvStatesDiffer {
    param($A, $B)
    $fmt = { param($s) '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $s.Exe, [bool]$s.Found, $s.Profile, [bool]$s.VsyncPresent, [int]$s.VsyncLocation, [bool]$s.VsyncPredefined, [uint32]$s.VsyncValue }
    $ja = (@($A) | Where-Object { $_ } | ForEach-Object { & $fmt $_ }) -join ';'
    $jb = (@($B) | Where-Object { $_ } | ForEach-Object { & $fmt $_ }) -join ';'
    return ($ja -ne $jb)
}

# ================================================================ Installation

function Install-RealVR {
    param(
        [Parameter(Mandatory)][string]$GameFolder,
        [Parameter(Mandatory)][string]$GameLabel,
        [Parameter(Mandatory)]$Mod,
        [string]$RestoreIniFrom,
        [switch]$CreateRestorePoint
    )
    $parsed = Get-ParsedMod $Mod
    $def = $parsed.ByLabel[$GameLabel]
    if (-not $def) { throw (T 'err.notInMod' $GameLabel $Mod.Id) }
    if (-not (Test-ModHasRepo -Mod $Mod -Def $def)) { throw (T 'err.noRepo' $def.Name) }
    if (Get-ActiveJournal $GameFolder) { throw (T 'err.journalExists') }
    $running = Get-RunningProcessForExe (@($def.Signatures | ForEach-Object { $_ }) + $def.VdesyncExes)
    if ($running.Count) { throw (T 'err.gameRunning' $running[0].ProcessName) }

    if ($CreateRestorePoint -and (Test-RvmWindows)) {
        if (-not (New-RvmRestorePoint -Description (T 'rp.descInstall' $def.Name $Mod.Id))) {
            Write-RvmLog (T 'log.rp.continue') WARN
        }
    }

    $jdir = Get-JournalDirForFolder -Folder $GameFolder -Name $def.Name
    [void](New-Item -ItemType Directory -Path $jdir -Force)
    Write-RvmLog (T 'log.inst.start' $Mod.Id $def.Name) STATUS
    Write-RvmLog (T 'log.inst.journal' $jdir)

    $scopes = Get-InstallScopes -Def $def -GameDir $GameFolder
    $journal = [ordered]@{
        FormatVersion = 2
        Status        = 'pending'
        GameLabel     = $def.Label
        GameName      = $def.Name
        GameFolder    = (Get-FullPathSafe $GameFolder).TrimEnd('\', '/')
        ModId         = $Mod.Id
        ModVersion    = $Mod.Version
        ModPath       = $Mod.Path
        StartedAt     = (Get-Date).ToString('s')
        InstalledAt   = $null
        Scopes        = $scopes
        Registry      = [ordered]@{ Captured = $false; Roots = $script:RegRootsStandard; Prefixes = @(); RelevantCount = 0; OtherCount = 0 }
        Acl           = [ordered]@{ Saved = $false }
        Nvidia        = [ordered]@{ Backed = $false; BeforeHash = $null; AfterHash = $null; Changed = $false; Exes = @($def.VdesyncExes); AppsBefore = $null; AppsAfter = $null; AppsChanged = $false }
        Summary       = $null
    }
    $jfile = [IO.Path]::Combine($jdir, 'journal.json')
    Write-RvmJson -Path $jfile -Object $journal

    # ---- 1. Vorher-Zustand sichern
    Write-RvmLog (T 'log.inst.backupFiles') STATUS
    $total = [long]0
    foreach ($s in $scopes) {
        Write-RvmLog (T 'log.inst.scope' $s.Index $s.Kind $s.Path)
        [void](Save-ScopeSnapshot -Scope $s -ScopeDir (Get-ScopeDir $jdir $s.Index) -Tag 'before' -Backup -TotalBytes ([ref]$total))
    }
    Write-RvmLog (T 'log.inst.backupSize' (Format-Bytes $total))

    $regDir = [IO.Path]::Combine($jdir, 'registry')
    $prefixes = Get-RelevantRegPrefixes -Def $def -Mod $Mod
    $journal.Registry.Prefixes = $prefixes
    if (Test-RvmWindows) {
        Write-RvmLog (T 'log.inst.backupReg') STATUS
        $regBefore = [RVM.RegCapture]::Capture([string[]]$script:RegRootsStandard)
        [RVM.SnapIO]::Save([IO.Path]::Combine($regDir, 'before.snap.gz'), $regBefore)
        Export-RegKeys -Keys $prefixes -OutDir $regDir
        $journal.Registry.Captured = $true
        Write-RvmLog (T 'log.inst.regCount' $regBefore.Count)

        Write-RvmLog (T 'log.inst.backupAcl') STATUS
        $journal.Acl.Saved = Save-FolderAcl -Folder $journal.GameFolder -OutDir ([IO.Path]::Combine($jdir, 'acl'))

        $journal.Nvidia.BeforeHash = Get-NvidiaDrsHash
        if ($journal.Nvidia.BeforeHash) {
            $journal.Nvidia.Backed = Backup-NvidiaDrs -OutDir ([IO.Path]::Combine($jdir, 'nvidia'))
            if ($def.VdesyncExes.Count) {
                $cap = Invoke-NvidiaTool -Mode capture -Exes $def.VdesyncExes
                if ($cap -and $cap.Ok) {
                    $journal.Nvidia.AppsBefore = @($cap.States)
                    foreach ($st in $cap.States) { Write-RvmLog (T 'log.nv.state' $st.Exe $(if ($st.Found) { $st.Profile } else { '-' })) }
                } elseif ($cap) { Write-RvmLog (T 'log.nv.captureFail' $cap.Error) WARN }
            }
            Write-RvmLog (T 'log.inst.nvBacked')
        }
    }
    Write-RvmJson -Path $jfile -Object $journal

    # ---- 2. Mod-Dateien kopieren + RealConfig.bat ausfuehren
    Write-RvmLog (T 'log.inst.copy') STATUS
    Copy-Item -Path ([IO.Path]::Combine($Mod.Path, '*')) -Destination $GameFolder -Recurse -Force
    if ($script:RVM.BatRunner) { & $script:RVM.BatRunner $GameFolder } else { Invoke-RealConfigBat -GameDir $GameFolder }

    # ---- 3. Nachher-Zustand + Differenz
    Write-RvmLog (T 'log.inst.diff') STATUS
    $summary = [ordered]@{ FilesAdded = 0; FilesChanged = 0; FilesRemoved = 0; RegRelevant = 0; RegOther = 0; Nvidia = 0 }
    $success = $false
    foreach ($s in $scopes) {
        $sd = Get-ScopeDir $jdir $s.Index
        $before = [RVM.SnapIO]::Load([IO.Path]::Combine($sd, 'before.snap.gz'))
        $after = Save-ScopeSnapshot -Scope $s -ScopeDir $sd -Tag 'after'
        $diffs = [RVM.Differ]::Compare($before.Entries, $after.Entries)
        [RVM.SnapIO]::SaveDiffs([IO.Path]::Combine($sd, 'diff.gz'), $diffs)
        foreach ($d in $diffs) {
            if ($d.After -eq 'D' -or $d.Before -eq 'D') { continue }
            switch ($d.Change) { 'Added' { $summary.FilesAdded++ } 'Changed' { $summary.FilesChanged++ } 'Removed' { $summary.FilesRemoved++ } }
            $leaf = [IO.Path]::GetFileName($d.Key)
            if ($d.Change -ne 'Removed' -and ($leaf -ieq 'dxgi.dll' -or $leaf -ieq 'RealVR64.dll') -and $d.Key.IndexOf([IO.Path]::DirectorySeparatorChar) -lt 0) { $success = $true }
            Write-RvmLog ("  [{0}] {1}: {2}" -f $s.Kind, $d.ChangeDisplay, $d.Key)
        }
    }

    if ($journal.Registry.Captured) {
        $regAfter = [RVM.RegCapture]::Capture([string[]]$script:RegRootsStandard)
        $regBefore = [RVM.SnapIO]::Load([IO.Path]::Combine($regDir, 'before.snap.gz'))
        $rd = [RVM.Differ]::Compare($regBefore.Entries, $regAfter.Entries)
        $split = Split-RegDiffs -Diffs $rd -Prefixes $prefixes
        [RVM.SnapIO]::SaveDiffs([IO.Path]::Combine($regDir, 'relevant.diff.gz'), $split.Relevant)
        [RVM.SnapIO]::SaveDiffs([IO.Path]::Combine($regDir, 'other.diff.gz'), $split.Other)
        $journal.Registry.RelevantCount = $split.Relevant.Count
        $journal.Registry.OtherCount = $split.Other.Count
        $summary.RegRelevant = $split.Relevant.Count; $summary.RegOther = $split.Other.Count
        foreach ($d in $split.Relevant) { Write-RvmLog ("  [Registry] {0}: {1} -> {2}" -f $d.ChangeDisplay, $d.KeyPath, $d.ValueDisplay) }
    }
    if ($journal.Nvidia.BeforeHash) {
        $journal.Nvidia.AfterHash = Get-NvidiaDrsHash
        $journal.Nvidia.Changed = ($journal.Nvidia.AfterHash -ne $journal.Nvidia.BeforeHash)
        if ($null -ne $journal.Nvidia.AppsBefore) {
            $cap = Invoke-NvidiaTool -Mode capture -Exes $def.VdesyncExes
            if ($cap -and $cap.Ok) {
                $journal.Nvidia.AppsAfter = @($cap.States)
                $journal.Nvidia.AppsChanged = Test-NvStatesDiffer $journal.Nvidia.AppsBefore $journal.Nvidia.AppsAfter
                foreach ($st in $cap.States) { Write-RvmLog (T 'log.nv.stateAfter' $st.Exe $(if ($st.Found) { $st.Profile } else { '-' })) }
                if ($journal.Nvidia.AppsChanged) { $summary.Nvidia = 1 }
            }
        }
        if ($journal.Nvidia.Changed) { Write-RvmLog (T 'log.inst.nvChanged') }
    }
    foreach ($s in $scopes) {
        if ($s.Kind -ne 'ProgramData') { continue }
        foreach ($d in [RVM.SnapIO]::LoadDiffs([IO.Path]::Combine((Get-ScopeDir $jdir $s.Index), 'diff.gz'))) {
            if ([IO.Path]::GetFileName($d.Key) -ieq 'RealVR64.dll' -and $d.Change -ne 'Removed') { $success = $true }
        }
    }

    $journal.Summary = $summary
    if ($success) {
        $journal.Status = 'installed'
        $journal.InstalledAt = (Get-Date).ToString('s')
        if ($RestoreIniFrom -and (Test-Path -LiteralPath $RestoreIniFrom)) {
            Copy-FileSafe -Source $RestoreIniFrom -Target ([IO.Path]::Combine($GameFolder, 'RealVR.ini'))
            Write-RvmLog (T 'log.inst.iniRestored')
        }
        Write-RvmLog (T 'log.inst.done' $summary.FilesAdded $summary.FilesChanged $summary.FilesRemoved $summary.RegRelevant) OK
    } else {
        $journal.Status = 'failed'
        Write-RvmLog (T 'log.inst.failed') WARN
    }
    Write-RvmJson -Path $jfile -Object $journal
    return [pscustomobject]@{ Success = $success; JournalDir = $jdir; Summary = $summary }
}

# ================================================================ Plaene

function New-PlanAction {
    param([string]$Type, [string]$Path, [string]$Target, [string]$Desc, [bool]$Recurse = $false, [string]$OptionKey = $null, [int]$Phase = 1)
    return [pscustomobject]@{ Type = $Type; Path = $Path; Target = $Target; Desc = $Desc; Recurse = $Recurse; OptionKey = $OptionKey; Phase = $Phase }
}

function Get-JournalUninstallPlan {
    param([Parameter(Mandatory)][string]$JournalDir)
    $j = Read-RvmJson ([IO.Path]::Combine($JournalDir, 'journal.json'))
    if (-not $j) { throw (T 'err.journalRead' $JournalDir) }
    $actions = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $options = New-Object System.Collections.Generic.List[object]

    foreach ($s in $j.Scopes) {
        $sd = Get-ScopeDir $JournalDir $s.Index
        $diffFile = [IO.Path]::Combine($sd, 'diff.gz')
        $root = ConvertTo-NativePath $s.Path
        $knownAdded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $diffs = @()
        $live = $false
        $bfile = [IO.Path]::Combine($sd, 'before.snap.gz')
        if (Test-Path -LiteralPath $diffFile) { $diffs = [RVM.SnapIO]::LoadDiffs($diffFile) }
        elseif (Test-Path -LiteralPath $bfile) {
            $b0 = [RVM.SnapIO]::Load($bfile)
            $diffs = [RVM.Differ]::Compare($b0.Entries, ([RVM.FileCapture]::Capture($root, [bool]$s.Recursive, [int]$s.MaxDepth)).Entries)
            $live = $true
            if ($diffs.Count) { $warnings.Add((T 'plan.warn.interrupted' $s.Path)) }
        }

        $addedDirs = @()
        foreach ($d in $diffs) {
            $full = [IO.Path]::Combine($root, $d.Key)
            $backup = [IO.Path]::Combine($sd, 'backup', $d.Key)
            $isDir = ($d.After -eq 'D' -or $d.Before -eq 'D' -or $d.After -eq 'L' -or $d.Before -eq 'L')
            switch ($d.Change) {
                'Added' {
                    [void]$knownAdded.Add($d.Key)
                    if ($isDir) { $addedDirs += $d.Key; continue }
                    if (Test-Path -LiteralPath $full) { $actions.Add((New-PlanAction -Type DeleteFile -Path $full -Phase 1)) }
                }
                'Changed' {
                    if ($isDir) { continue }
                    if (-not (Test-Path -LiteralPath $backup)) { $warnings.Add((T 'plan.warn.noBackup' $full)); continue }
                    if (-not $live -and ($s.Kind -eq 'Game' -or $s.Kind -eq 'Extra')) {
                        $cur = Get-CurrentFileState $full
                        if ($cur -and $cur -ne $d.After) { $warnings.Add((T 'plan.warn.changedSince' $full)); continue }
                    }
                    $actions.Add((New-PlanAction -Type RestoreFile -Path $backup -Target $full -Phase 2))
                }
                'Removed' {
                    if ($isDir) { $actions.Add((New-PlanAction -Type CreateDir -Path $full -Phase 2)); continue }
                    if (Test-Path -LiteralPath $backup) {
                        if (-not (Test-Path -LiteralPath $full)) { $actions.Add((New-PlanAction -Type RestoreFile -Path $backup -Target $full -Phase 2)) }
                    } else { $warnings.Add((T 'plan.warn.deletedNoBackup' $full)) }
                }
            }
        }

        # Laufzeitdateien des Mods, die erst nach der Installation entstanden sind (z.B. RealVR64.log)
        if ((Test-Path -LiteralPath $bfile) -and (Test-Path -LiteralPath $root) -and ($s.Kind -eq 'Game' -or $s.Kind -eq 'ProgramData')) {
            $before = [RVM.SnapIO]::Load($bfile)
            $now = [RVM.FileCapture]::Capture($root, $false, 0)
            foreach ($kv in $now.Entries.GetEnumerator()) {
                if ($before.Entries.ContainsKey($kv.Key) -or $knownAdded.Contains($kv.Key)) { continue }
                $full = [IO.Path]::Combine($root, $kv.Key)
                if ($kv.Value -eq 'D') {
                    if ($s.Kind -eq 'ProgramData' -or $kv.Key -match $script:ModDirPattern) { $addedDirs += $kv.Key }
                } elseif ($s.Kind -eq 'ProgramData' -or $kv.Key -match $script:ModFilePattern) {
                    $actions.Add((New-PlanAction -Type DeleteFile -Path $full -Phase 1))
                }
            }
        }

        foreach ($ad in @($addedDirs | Sort-Object -Property @{ Expression = { $_.Length } } -Descending -Unique)) {
            $leaf = [IO.Path]::GetFileName($ad)
            $recurse = ($s.Kind -eq 'ProgramData') -or ($leaf -match $script:ModDirPattern) -or ($ad -match '(?i)^(RealRepo|reshade-shaders)([\\/]|$)')
            $actions.Add((New-PlanAction -Type DeleteDir -Path ([IO.Path]::Combine($root, $ad)) -Recurse $recurse -Phase 3))
        }
        if ($s.Kind -eq 'ProgramData' -and (Test-Path -LiteralPath $bfile) -and ([RVM.SnapIO]::LoadMeta($bfile))['Exists'] -eq '0' -and (Test-Path -LiteralPath $root)) {
            $actions.Add((New-PlanAction -Type DeleteDir -Path $root -Recurse $true -Phase 3))
        }
    }

    # Registry
    $regDir = [IO.Path]::Combine($JournalDir, 'registry')
    $relFile = [IO.Path]::Combine($regDir, 'relevant.diff.gz')
    if (Test-Path -LiteralPath $relFile) {
        $rel = [RVM.SnapIO]::LoadDiffs($relFile)
        if ($rel.Count) { $actions.Add((New-PlanAction -Type RegRestore -Path $relFile -Desc (T 'plan.desc.regRestore' $rel.Count) -Phase 4)) }
    } elseif ($j.Registry.Captured -and $j.Status -eq 'pending') {
        $actions.Add((New-PlanAction -Type RegRestoreFromSnapshot -Path ([IO.Path]::Combine($regDir, 'before.snap.gz')) -Desc (T 'plan.desc.regRestoreSnap') -Phase 4))
    }
    if ($j.Acl.Saved) { $actions.Add((New-PlanAction -Type AclRestore -Path ([IO.Path]::Combine($JournalDir, 'acl')) -Target $j.GameFolder -Desc (T 'plan.desc.acl') -Phase 5)) }

    # NVIDIA: bevorzugt nur die Profileintraege dieses Spiels zuruecksetzen
    $nv = $j.Nvidia
    $perApp = ($nv -and $nv.AppsBefore -and $nv.AppsAfter)
    if ($perApp -and $nv.AppsChanged) {
        $actions.Add((New-PlanAction -Type NvidiaAppRestore -Path $JournalDir -Desc (T 'plan.desc.nvApp' ((@($nv.Exes)) -join ', ')) -Phase 6))
    } elseif (-not $perApp -and $nv -and $nv.Changed -and $nv.Backed) {
        $cur = Get-NvidiaDrsHash
        $safe = ($cur -eq $nv.AfterHash)
        $label = if ($safe) { T 'plan.opt.nvDbSafe' } else { T 'plan.opt.nvDbUnsafe' }
        $options.Add([pscustomobject]@{ Key = 'Nvidia'; Label = $label; Default = $safe })
        $actions.Add((New-PlanAction -Type NvidiaRestore -Path ([IO.Path]::Combine($JournalDir, 'nvidia')) -Desc $label -OptionKey 'Nvidia' -Phase 6))
    }

    return [pscustomobject]@{
        Kind       = 'Journal'
        Title      = (T 'plan.title.uninstall' $j.GameName)
        GameName   = $j.GameName
        GameFolder = $j.GameFolder
        JournalDir = $JournalDir
        Journal    = $j
        Actions    = $actions.ToArray()
        Warnings   = $warnings.ToArray()
        Options    = $options.ToArray()
    }
}

function Get-LegacyUninstallPlan {
    # Entfernung ohne Protokoll (Mod wurde frueher manuell installiert). Basiert auf RealConfig.bat-Analyse.
    param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)]$Def, $Mod)
    $actions = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $options = New-Object System.Collections.Generic.List[object]
    $root = (Get-FullPathSafe $GameFolder).TrimEnd('\', '/')

    $scanDirs = @($root)
    $sandbox = [IO.Path]::Combine($root, 'doomSandBox')
    if (Test-Path -LiteralPath $sandbox) { $scanDirs += $sandbox }
    foreach ($dir in $scanDirs) {
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $leaf = [IO.Path]::GetFileName($f)
            if ($leaf -ieq 'dxgi.dll') {
                if (Test-IsRealVRBinary $f) { $actions.Add((New-PlanAction -Type DeleteFile -Path $f -Phase 1)) }
                continue
            }
            if ($leaf -ieq 'start_protected_game_ori.exe') {
                $actions.Add((New-PlanAction -Type RestoreOri -Path $f -Target ([IO.Path]::Combine($dir, 'start_protected_game.exe')) -Phase 1))
                continue
            }
            if ($leaf -match '(?i)^(RealVR.*|RealConfig\.bat|cudart64_.*\.dll|openvr_api\.dll|BackupSaves\.bat|ReShadePreset\.ini)$') {
                $actions.Add((New-PlanAction -Type DeleteFile -Path $f -Phase 1))
            }
        }
        foreach ($sub in @('RealRepo', 'reshade-shaders')) {
            $p = [IO.Path]::Combine($dir, $sub)
            if (Test-Path -LiteralPath $p) { $actions.Add((New-PlanAction -Type DeleteDir -Path $p -Recurse $true -Phase 3)) }
        }
    }

    # *_ori-Sicherungen von RealConfig.bat zurueckspielen
    $dirs = @(Get-GameSettingsPaths -Def $Def -GameDir $root)
    $dirs += $root
    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $recursive = -not (Test-PathUnder $d $root) -or ($d -ieq $root)
        $files = if ($recursive -and ($d -ine $root)) { @(Get-ChildItem -LiteralPath $d -File -Recurse -Depth 3 -ErrorAction SilentlyContinue) } else { @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue) }
        foreach ($fi in $files) {
            if ($fi.Name -ieq 'start_protected_game_ori.exe') { continue }
            $m = [regex]::Match($fi.Name, '^(.+)_ori(\.[^.]+)?$')
            if (-not $m.Success) { continue }
            $orig = [IO.Path]::Combine($fi.DirectoryName, $m.Groups[1].Value + $m.Groups[2].Value)
            $actions.Add((New-PlanAction -Type RestoreOri -Path $fi.FullName -Target $orig -Phase 1))
        }
    }

    if ($Def.UsesVulkan -and (Test-RvmWindows)) {
        foreach ($k in @('HKLM\SOFTWARE\Khronos\Vulkan\ImplicitLayers', 'HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers')) {
            foreach ($n in @([RVM.RegCapture]::GetValueNames($k) | Where-Object { $_ -match '(?i)RealVR64\.json$' })) {
                $actions.Add((New-PlanAction -Type RegDeleteValue -Path $k -Target $n -Phase 4))
            }
        }
        $prog = (Get-StdPaths).prog
        if (Test-Path -LiteralPath $prog) { $actions.Add((New-PlanAction -Type DeleteDir -Path $prog -Recurse $true -Phase 3)) }
        $warnings.Add((T 'plan.warn.vulkanShared'))
    }
    foreach ($k in $Def.RegQueryKeys) {
        $kk = [RVM.RegCapture]::NormalizeHive($k) + '\Graphics'
        $options.Add([pscustomobject]@{ Key = "RegKey:$kk"; Label = (T 'plan.opt.regKey' $kk); Default = $false })
        $actions.Add((New-PlanAction -Type RegDeleteKey -Path $kk -OptionKey "RegKey:$kk" -Phase 4))
    }
    foreach ($del in $Def.DeletesGameFiles) { $warnings.Add((T 'plan.warn.legacyDeleted' $del)) }
    $warnings.Add((T 'plan.warn.legacyAcl'))
    if ($Def.VdesyncExes.Count) { $warnings.Add((T 'plan.warn.legacyNvidia')) }
    if (-not $actions.Count) { $warnings.Add((T 'plan.warn.nothing')) }

    return [pscustomobject]@{
        Kind       = 'Legacy'
        Title      = (T 'plan.title.legacy' $Def.Name)
        GameName   = $Def.Name
        GameFolder = $root
        JournalDir = $null
        Journal    = $null
        Actions    = $actions.ToArray()
        Warnings   = $warnings.ToArray()
        Options    = $options.ToArray()
    }
}

function Format-Plan {
    param($Plan)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine($Plan.Title)
    [void]$sb.AppendLine((T 'plan.folder' $Plan.GameFolder))
    [void]$sb.AppendLine('')
    $recDirs = @($Plan.Actions | Where-Object { $_.Type -eq 'DeleteDir' -and $_.Recurse } | ForEach-Object { $_.Path } | Sort-Object Length)
    $hidden = @{}
    foreach ($a in $Plan.Actions) {
        if ($a.Type -ne 'DeleteFile') { continue }
        foreach ($d in $recDirs) { if (Test-PathUnder $d $a.Path) { if (-not $hidden.ContainsKey($d)) { $hidden[$d] = 0 }; $hidden[$d]++; break } }
    }
    foreach ($a in ($Plan.Actions | Sort-Object Phase)) {
        if ($a.Type -eq 'DeleteFile' -or $a.Type -eq 'DeleteDir') {
            $skip = $false
            foreach ($d in $recDirs) { if ($d -ne $a.Path -and (Test-PathUnder $d $a.Path)) { $skip = $true; break } }
            if ($skip) { continue }
        }
        $t = T ('plan.act.' + $a.Type)
        if ($a.Type -eq 'DeleteDir' -and $hidden.ContainsKey($a.Path)) {
            [void]$sb.AppendLine(('[{0}] {1}  ({2})' -f $t, $a.Path, (T 'plan.inclFiles' $hidden[$a.Path])))
            continue
        }
        $p = if ($a.Type -eq 'RestoreFile') { $a.Target } elseif ($a.Type -eq 'RestoreOri') { "$($a.Target)  <-  $([IO.Path]::GetFileName($a.Path))" } elseif ($a.Type -eq 'RegDeleteValue') { "$($a.Path) -> $($a.Target)" } elseif ($a.Desc) { $a.Desc } else { $a.Path }
        $opt = if ($a.OptionKey) { ' (' + (T 'plan.optional') + ')' } else { '' }
        [void]$sb.AppendLine(('[{0}]{1} {2}' -f $t, $opt, $p))
    }
    if ($Plan.Warnings.Count) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine((T 'plan.notes'))
        foreach ($w in $Plan.Warnings) { [void]$sb.AppendLine(' - ' + $w) }
    }
    return $sb.ToString()
}

# ================================================================ Ausfuehren

function Invoke-RvmPlan {
    param([Parameter(Mandatory)]$Plan, [hashtable]$Options = @{}, [switch]$SkipVerify, [switch]$KeepJournal)

    $log = New-Object System.Collections.Generic.List[string]
    $errors = 0
    $legacyBackup = $null
    if ($Plan.Kind -eq 'Legacy') {
        $legacyBackup = [IO.Path]::Combine((Get-RvmDir JournalArchive), ('legacy_{0}_{1}' -f (Get-SafeName $Plan.GameName), (Get-Date -Format 'yyyyMMdd_HHmmss')))
        [void](New-Item -ItemType Directory -Path $legacyBackup -Force)
        Write-RvmLog (T 'log.legacy.backup' $legacyBackup)
    }
    $backupLegacy = {
        param($path)
        if (-not $legacyBackup -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        try {
            $fi = New-Object IO.FileInfo($path)
            if ($fi.Length -gt 256MB) { return }
            $rel = (Get-SafeName ([IO.Path]::GetDirectoryName($path))) + [IO.Path]::DirectorySeparatorChar + $fi.Name
            Copy-FileSafe -Source $path -Target ([IO.Path]::Combine($legacyBackup, $rel))
        } catch { }
    }

    Write-RvmLog "$($Plan.Title) ..." STATUS
    if ($Plan.Kind -eq 'Journal' -and $Plan.Journal) {
        $ini = [IO.Path]::Combine($Plan.GameFolder, 'RealVR.ini')
        if (Test-Path -LiteralPath $ini) {
            Copy-FileSafe -Source $ini -Target ([IO.Path]::Combine($Plan.JournalDir, 'RealVR.ini.saved'))
            Write-RvmLog (T 'log.unin.iniSaved')
        }
    }

    foreach ($a in ($Plan.Actions | Sort-Object Phase)) {
        if ($a.OptionKey -and -not $Options[$a.OptionKey]) { $log.Add("SKIP $(T ('plan.act.' + $a.Type)) $($a.Path)"); continue }
        try {
            switch ($a.Type) {
                'DeleteFile' {
                    if (Test-Path -LiteralPath $a.Path) {
                        & $backupLegacy $a.Path
                        [IO.File]::SetAttributes($a.Path, [IO.FileAttributes]::Normal)
                        Remove-Item -LiteralPath $a.Path -Force
                        $log.Add('OK  ' + (T 'res.deleted' $a.Path))
                    }
                }
                'RestoreOri' {
                    if (Test-Path -LiteralPath $a.Target) { & $backupLegacy $a.Target; Remove-Item -LiteralPath $a.Target -Force }
                    Move-Item -LiteralPath $a.Path -Destination $a.Target
                    $log.Add('OK  ' + (T 'res.oriBack' $a.Target))
                }
                'RestoreFile' {
                    Copy-FileSafe -Source $a.Path -Target $a.Target
                    $log.Add('OK  ' + (T 'res.restored' $a.Target))
                }
                'CreateDir' {
                    if (-not (Test-Path -LiteralPath $a.Path)) { [void](New-Item -ItemType Directory -Path $a.Path -Force) }
                    $log.Add('OK  ' + (T 'res.dirCreated' $a.Path))
                }
                'DeleteDir' {
                    if (Test-Path -LiteralPath $a.Path) {
                        if ($a.Recurse) { Remove-Item -LiteralPath $a.Path -Recurse -Force; $log.Add('OK  ' + (T 'res.dirDeleted' $a.Path)) }
                        elseif (-not @(Get-ChildItem -LiteralPath $a.Path -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $a.Path -Force; $log.Add('OK  ' + (T 'res.dirDeleted' $a.Path)) }
                        else { $log.Add('WARN ' + (T 'res.dirNotEmpty' $a.Path)) }
                    }
                }
                'RegRestore' {
                    $diffs = [RVM.SnapIO]::LoadDiffs($a.Path)
                    foreach ($l in [RVM.RegCapture]::Restore($diffs)) { $log.Add($l) }
                }
                'RegRestoreFromSnapshot' {
                    $before = [RVM.SnapIO]::Load($a.Path)
                    $now = [RVM.RegCapture]::Capture([string[]]$script:RegRootsStandard)
                    $split = Split-RegDiffs -Diffs ([RVM.Differ]::Compare($before.Entries, $now.Entries)) -Prefixes @($Plan.Journal.Registry.Prefixes)
                    foreach ($l in [RVM.RegCapture]::Restore($split.Relevant)) { $log.Add($l) }
                }
                'RegDeleteValue' {
                    [RVM.RegCapture]::DeleteValue($a.Path, $a.Target)
                    $log.Add('OK  ' + (T 'res.regValueDeleted' "$($a.Path) -> $($a.Target)"))
                }
                'RegDeleteKey' {
                    & reg.exe delete $a.Path /f /reg:64 2>&1 | Out-Null
                    $log.Add('OK  ' + (T 'res.regKeyDeleted' $a.Path))
                }
                'AclRestore' { foreach ($l in (Restore-FolderAcl -Folder $a.Target -AclDir $a.Path)) { $log.Add($l) } }
                'NvidiaRestore' { foreach ($l in (Restore-NvidiaDrs -BackupDir $a.Path)) { $log.Add($l) } }
                'NvidiaAppRestore' {
                    $jj = $Plan.Journal
                    $r = Invoke-NvidiaTool -Mode restore -InObject @{ Before = @($jj.Nvidia.AppsBefore); After = @($jj.Nvidia.AppsAfter) }
                    if ($r -and $r.Ok) { foreach ($l in @($r.Log)) { $log.Add($l) } }
                    else { $log.Add('ERR ' + (T 'res.nvFail' $(if ($r) { $r.Error } else { '?' }))) }
                }
            }
        } catch {
            $log.Add("ERR $($a.Type) $($a.Path): $($_.Exception.Message)")
        }
    }
    foreach ($l in $log) {
        $lvl = if ($l.StartsWith('ERR')) { 'ERROR' } elseif ($l.StartsWith('WARN')) { 'WARN' } else { 'INFO' }
        if ($l.StartsWith('ERR')) { $errors++ }
        Write-RvmLog $l $lvl
    }

    $verify = $null
    if ($Plan.Kind -eq 'Journal' -and -not $SkipVerify) { $verify = Test-UninstallResult -JournalDir $Plan.JournalDir }

    $reportDir = if ($Plan.JournalDir) { $Plan.JournalDir } else { $legacyBackup }
    $report = New-Object Text.StringBuilder
    [void]$report.AppendLine((Format-Plan $Plan))
    [void]$report.AppendLine('--- ' + (T 'report.exec') + ' ---')
    foreach ($l in $log) { [void]$report.AppendLine($l) }
    if ($verify) { [void]$report.AppendLine(''); [void]$report.AppendLine('--- ' + (T 'report.verify') + ' ---'); [void]$report.AppendLine($verify.Text) }
    if ($reportDir) { [IO.File]::WriteAllText([IO.Path]::Combine($reportDir, ('uninstall-report_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))), $report.ToString(), [Text.Encoding]::UTF8) }

    if ($Plan.Kind -eq 'Journal' -and -not $KeepJournal) {
        $j = Read-RvmJson ([IO.Path]::Combine($Plan.JournalDir, 'journal.json'))
        $j.Status = 'uninstalled'
        $j | Add-Member -NotePropertyName UninstalledAt -NotePropertyValue (Get-Date).ToString('s') -Force
        Write-RvmJson -Path ([IO.Path]::Combine($Plan.JournalDir, 'journal.json')) -Object $j
        $dest = [IO.Path]::Combine((Get-RvmDir JournalArchive), ([IO.Path]::GetFileName($Plan.JournalDir) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss')))
        Move-Item -LiteralPath $Plan.JournalDir -Destination $dest
        $clean = (-not $errors) -and (-not $verify -or ($verify.FileIssues + $verify.RegIssues + $verify.NvIssues) -eq 0)
        if ($clean) {
            $freed = Compress-ArchivedJournal $dest
            Write-RvmLog (T 'log.unin.archivedSlim' $dest (Format-Size $freed))
        } else {
            Write-RvmLog (T 'log.unin.archived' $dest)
        }
    }

    $lvl = if ($errors) { 'WARN' } else { 'OK' }
    $msg = if ($errors) { T 'res.doneErrors' $errors } else { T 'res.done' }
    if ($verify) { $msg += ' ' + $verify.Headline }
    Write-RvmLog $msg $lvl
    return [pscustomobject]@{ Errors = $errors; Log = $log.ToArray(); Verify = $verify; Message = $msg }
}

# ================================================================ Archiv / Speicherplatz

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $sum = [int64]0
    try { foreach ($f in [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories)) { try { $sum += (New-Object IO.FileInfo($f)).Length } catch { } } } catch { }
    return $sum
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f [Math]::Max(1, [Math]::Ceiling($Bytes / 1KB)))
}

function Compress-ArchivedJournal {
    # Nach sauberer Deinstallation werden die Sicherungen nicht mehr gebraucht: nur Protokoll (journal.json) und Berichte bleiben.
    param([Parameter(Mandatory)][string]$Dir)
    $before = Get-DirSize $Dir
    foreach ($e in [IO.Directory]::GetFileSystemEntries($Dir)) {
        $n = [IO.Path]::GetFileName($e)
        if ($n -eq 'journal.json' -or $n -like '*.txt') { continue }
        try {
            if ([IO.Directory]::Exists($e)) { Remove-Item -LiteralPath $e -Recurse -Force } else { Remove-Item -LiteralPath $e -Force }
        } catch { Write-RvmLog (T 'log.cleanFail' $e $_.Exception.Message) WARN }
    }
    return [int64]($before - (Get-DirSize $Dir))
}

function Get-RvmCleanupItems {
    # Was im Datenordner Platz belegt und geloescht werden kann.
    $items = @()
    $arch = Get-RvmDir JournalArchive
    if (Test-Path -LiteralPath $arch) {
        foreach ($d in [IO.Directory]::GetDirectories($arch)) {
            $items += [pscustomobject]@{ Kind = 'archive'; Path = $d; Name = [IO.Path]::GetFileName($d); Size = (Get-DirSize $d) }
        }
    }
    $snap = Get-RvmDir Snapshots
    if (Test-Path -LiteralPath $snap) {
        foreach ($d in [IO.Directory]::GetDirectories($snap, 'RegExport_*')) {
            $items += [pscustomobject]@{ Kind = 'regexport'; Path = $d; Name = [IO.Path]::GetFileName($d); Size = (Get-DirSize $d) }
        }
    }
    $logs = Get-RvmDir Logs
    $old = @(); $oldSize = [int64]0
    if (Test-Path -LiteralPath $logs) {
        foreach ($f in [IO.Directory]::GetFiles($logs)) {
            $fi = New-Object IO.FileInfo($f)
            if ($fi.LastWriteTime -lt (Get-Date).AddDays(-30)) { $old += $f; $oldSize += $fi.Length }
        }
    }
    if ($old.Count) { $items += [pscustomobject]@{ Kind = 'logs'; Path = $old; Name = ''; Size = $oldSize } }
    $cov = Get-RvmDir Covers
    if (Test-Path -LiteralPath $cov) { $items += [pscustomobject]@{ Kind = 'covers'; Path = $cov; Name = ''; Size = (Get-DirSize $cov) } }
    return $items
}

function Remove-RvmCleanupItem {
    param($Item)
    switch ($Item.Kind) {
        'logs' { foreach ($f in $Item.Path) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        'covers' {
            # eigene Bilder (user-*) bleiben erhalten
            foreach ($d in [IO.Directory]::GetDirectories($Item.Path)) {
                foreach ($f in [IO.Directory]::GetFiles($d)) { if ([IO.Path]::GetFileName($f) -notlike 'user-*') { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
                if (-not [IO.Directory]::GetFileSystemEntries($d).Count) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
            }
        }
        default { Remove-Item -LiteralPath $Item.Path -Recurse -Force }
    }
}

# ================================================================ Pruefung nach Deinstallation

function Test-UninstallResult {
    param([Parameter(Mandatory)][string]$JournalDir)
    Write-RvmLog (T 'log.verify') STATUS
    $j = Read-RvmJson ([IO.Path]::Combine($JournalDir, 'journal.json'))
    $lines = New-Object System.Collections.Generic.List[string]
    $fileIssues = 0; $regIssues = 0; $nvIssues = 0

    foreach ($s in $j.Scopes) {
        $sd = Get-ScopeDir $JournalDir $s.Index
        $bf = [IO.Path]::Combine($sd, 'before.snap.gz')
        if (-not (Test-Path -LiteralPath $bf)) { continue }
        $before = [RVM.SnapIO]::Load($bf)
        $now = [RVM.FileCapture]::Capture((ConvertTo-NativePath $s.Path), [bool]$s.Recursive, [int]$s.MaxDepth)
        [RVM.SnapIO]::Save([IO.Path]::Combine($sd, 'verify.snap.gz'), $now)
        $installDiff = @{}
        $df = [IO.Path]::Combine($sd, 'diff.gz')
        if (Test-Path -LiteralPath $df) { foreach ($d in [RVM.SnapIO]::LoadDiffs($df)) { $installDiff[$d.Key] = $d } }
        foreach ($d in [RVM.Differ]::Compare($before.Entries, $now.Entries)) {
            $touched = $installDiff.ContainsKey($d.Key)
            if ($s.Kind -eq 'Game' -and -not $touched -and $d.Change -eq 'Changed') { continue }   # Spiel-Updates ignorieren
            if ($s.Kind -eq 'Game' -and -not $touched -and $d.Change -eq 'Added' -and $d.Key -notmatch $script:ModFilePattern -and $d.Key -notmatch '(?i)^(RealRepo|reshade-shaders)') { continue }
            if ($s.Kind -eq 'Settings' -and -not $touched) { continue }   # Spielstaende/Einstellungen, die das Spiel selbst geaendert hat
            $fileIssues++
            $lines.Add(('{0}  {1,-9} {2}' -f (T 'verify.file'), $d.ChangeDisplay, [IO.Path]::Combine($s.Path, $d.Key)))
        }
    }

    $regBeforeFile = [IO.Path]::Combine($JournalDir, 'registry', 'before.snap.gz')
    if ((Test-RvmWindows) -and (Test-Path -LiteralPath $regBeforeFile)) {
        $before = [RVM.SnapIO]::Load($regBeforeFile)
        $now = [RVM.RegCapture]::Capture([string[]]$script:RegRootsStandard)
        $split = Split-RegDiffs -Diffs ([RVM.Differ]::Compare($before.Entries, $now.Entries)) -Prefixes @($j.Registry.Prefixes)
        foreach ($d in $split.Relevant) {
            $regIssues++
            $lines.Add(('Reg    {0,-9} {1} -> {2}' -f $d.ChangeDisplay, $d.KeyPath, $d.ValueDisplay))
        }
    }
    $nv = $j.Nvidia
    if ($nv -and $nv.AppsBefore) {
        $cap = Invoke-NvidiaTool -Mode capture -Exes @($nv.Exes)
        if ($cap -and $cap.Ok -and (Test-NvStatesDiffer $nv.AppsBefore $cap.States)) { $nvIssues++; $lines.Add((T 'verify.nvApp')) }
    } elseif ($nv -and $nv.BeforeHash) {
        if ((Get-NvidiaDrsHash) -ne $nv.BeforeHash) { $lines.Add((T 'verify.nvDb')) }
    }

    $sum = $fileIssues + $regIssues + $nvIssues
    $head = if ($sum -eq 0) { T 'verify.clean' } else { T 'verify.issues' $fileIssues $regIssues $nvIssues }
    $text = New-Object Text.StringBuilder
    [void]$text.AppendLine($head)
    foreach ($l in $lines) { [void]$text.AppendLine('  ' + $l) }
    foreach ($l in $lines) { Write-RvmLog $l WARN }
    return [pscustomobject]@{ FileIssues = $fileIssues; RegIssues = $regIssues; NvIssues = $nvIssues; Headline = $head; Text = $text.ToString() }
}

# ================================================================ Update

function Update-RealVR {
    param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)]$Mod, [hashtable]$Options = @{}, [bool]$KeepIni = $true)
    $j = Get-ActiveJournal $GameFolder
    if (-not $j) { throw (T 'err.updateNoJournal') }
    $label = $j.GameLabel
    $plan = Get-JournalUninstallPlan -JournalDir $j.Dir
    Write-RvmLog (T 'log.update' $j.GameName $j.ModVersion $Mod.Version) STATUS
    $res = Invoke-RvmPlan -Plan $plan -Options $Options -KeepJournal
    $ini = [IO.Path]::Combine($j.Dir, 'RealVR.ini.saved')
    $keep = $null
    if ($KeepIni -and (Test-Path -LiteralPath $ini)) {
        $keep = [IO.Path]::Combine((Get-RvmDir Root), 'RealVR.ini.update.tmp')
        Copy-FileSafe -Source $ini -Target $keep
    }
    $jj = Read-RvmJson ([IO.Path]::Combine($j.Dir, 'journal.json')); $jj.Status = 'uninstalled'
    Write-RvmJson -Path ([IO.Path]::Combine($j.Dir, 'journal.json')) -Object $jj
    $oldDest = [IO.Path]::Combine((Get-RvmDir JournalArchive), ([IO.Path]::GetFileName($j.Dir) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss')))
    Move-Item -LiteralPath $j.Dir -Destination $oldDest
    if ($res.Errors) { Write-RvmLog (T 'log.update.errors') WARN }
    else { [void](Compress-ArchivedJournal $oldDest) }
    try {
        return Install-RealVR -GameFolder $GameFolder -GameLabel $label -Mod $Mod -RestoreIniFrom $keep
    } finally { if ($keep -and (Test-Path -LiteralPath $keep)) { Remove-Item -LiteralPath $keep -Force } }
}
