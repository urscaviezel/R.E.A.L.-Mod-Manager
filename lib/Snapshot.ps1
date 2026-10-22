# R.E.A.L. Mod Manager - Snapshots (Dateien, Registry, Ordnerrechte, NVIDIA-Profile)

$script:RegRootsStandard = @('HKCU\Software', 'HKLM\SOFTWARE\Khronos', 'HKLM\SOFTWARE\WOW6432Node\Khronos')
$script:RegRootsExtended = @('HKCU\Software', 'HKLM\SOFTWARE')
$script:NvidiaDrsDir = $(if ($env:ProgramData) { [IO.Path]::Combine($env:ProgramData, 'NVIDIA Corporation', 'Drs') } else { $null })

# ---------------------------------------------------------------- Bereiche (Scopes) für eine Installation

function Get-InstallScopes {
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)][string]$GameDir)

    $settings = Get-RvmSettings
    $maxBytes = [long]$settings.BackupMaxFileMB * 1MB
    $sp = Get-StdPaths
    $generic = @($sp.doc, $sp.doc1, $sp.doc2, $sp.loc, $sp.app, $sp.usrprf, $env:ProgramData, $(if ($env:SystemDrive) { $env:SystemDrive + '\' })) |
        Where-Object { $_ } | ForEach-Object { (Get-FullPathSafe $_).TrimEnd('\', '/') }

    $scopes = New-Object System.Collections.Generic.List[object]
    $gameFull = (Get-FullPathSafe $GameDir).TrimEnd('\', '/')
    $inGameSubdirs = New-Object System.Collections.Generic.List[string]
    foreach ($s in @('RealRepo', 'doomSandBox', 'reshade-shaders')) { $inGameSubdirs.Add($s) }

    $addScope = {
        param($Kind, $Path, $Recursive, $MaxDepth, $Rule)
        $full = (Get-FullPathSafe $Path).TrimEnd('\', '/')
        foreach ($g in $generic) { if ($full -ieq $g) { Write-RvmLog (T 'log.snap.tooGeneric' $full) WARN; return } }
        foreach ($x in $scopes) {
            if ($x.Path -ieq $full) { return }
            if ($x.Recursive -and $x.Kind -ne 'Game' -and (Test-PathUnder $x.Path $full)) { return }   # schon in einem anderen Bereich enthalten
        }
        $scopes.Add([pscustomobject]@{
                Index          = $scopes.Count
                Kind           = $Kind
                Path           = $full
                Recursive      = [bool]$Recursive
                MaxDepth       = [int]$MaxDepth
                BackupRule     = $Rule
                BackupSubdirs  = @()
                BackupMaxBytes = $maxBytes
            })
    }

    & $addScope 'Game' $gameFull $true 0 'RootAndSubdirs'

    foreach ($p in @(Get-GameSettingsPaths -Def $Def -GameDir $GameDir)) {
        if (Test-PathUnder $gameFull $p) {
            $rel = Get-RvmRelativePath $gameFull $p
            if ($rel -and -not $inGameSubdirs.Contains($rel)) { $inGameSubdirs.Add($rel) }
            continue
        }
        if (Test-PathUnder $p $gameFull) { & $addScope 'Extra' $p $false 0 'All'; continue }   # Elternordner des Spiels (z.B. ..\..)
        & $addScope 'Settings' $p $true 4 'All'
    }
    foreach ($rel in $Def.RelativePaths) {
        $abs = Get-FullPathSafe ([IO.Path]::Combine($gameFull, (ConvertTo-NativePath $rel)))
        if ([IO.Path]::GetExtension($abs)) { $abs = [IO.Path]::GetDirectoryName($abs) }
        if (Test-PathUnder $gameFull $abs) { continue }
        & $addScope 'Extra' $abs $false 0 'All'
    }
    & $addScope 'ProgramData' $sp.prog $true 0 'All'

    $scopes[0].BackupSubdirs = $inGameSubdirs.ToArray()
    return $scopes.ToArray()
}

function Save-ScopeSnapshot {
    # Erfasst einen Bereich und sichert (optional) Dateiinhalte.
    param([Parameter(Mandatory)]$Scope, [Parameter(Mandatory)][string]$ScopeDir, [Parameter(Mandatory)][string]$Tag, [switch]$Backup, [ref]$TotalBytes)

    $snap = [RVM.FileCapture]::Capture((ConvertTo-NativePath $Scope.Path), $Scope.Recursive, $Scope.MaxDepth)
    [RVM.SnapIO]::Save([IO.Path]::Combine($ScopeDir, "$Tag.snap.gz"), $snap)
    foreach ($e in $snap.Errors) { Write-RvmLog (T 'log.snap.accessError' $e) WARN }
    if (-not $Backup) { return $snap }

    $sep = [IO.Path]::DirectorySeparatorChar
    $backupDir = [IO.Path]::Combine($ScopeDir, 'backup')
    $skipped = @()
    $cap = [long]((Get-RvmSettings).SettingsBackupMaxTotalMB) * 1MB
    foreach ($kv in $snap.Entries.GetEnumerator()) {
        if (-not $kv.Value.StartsWith('F|')) { continue }
        $rel = $kv.Key
        $size = [long]($kv.Value.Split('|')[1])
        $take = $false
        if ($Scope.BackupRule -eq 'All') { $take = $true }
        elseif ($Scope.BackupRule -eq 'RootAndSubdirs') {
            if ($rel.IndexOf($sep) -lt 0) { $take = $true }
            else { foreach ($sd in $Scope.BackupSubdirs) { if ($rel.StartsWith((ConvertTo-NativePath $sd) + $sep, [StringComparison]::OrdinalIgnoreCase)) { $take = $true; break } } }
        }
        if (-not $take) { continue }
        if ($size -gt $Scope.BackupMaxBytes) { $skipped += "$rel ($(Format-Bytes $size))"; continue }
        if ($TotalBytes -and $Scope.Kind -ne 'Game' -and ($TotalBytes.Value + $size) -gt $cap) { $skipped += "$rel (Gesamtlimit)"; continue }
        try {
            Copy-FileSafe -Source ([IO.Path]::Combine((ConvertTo-NativePath $Scope.Path), $rel)) -Target ([IO.Path]::Combine($backupDir, $rel))
            if ($TotalBytes) { $TotalBytes.Value += $size }
        } catch { Write-RvmLog (T 'log.snap.backupFail' $rel $_.Exception.Message) WARN }
    }
    foreach ($s in $skipped) { Write-RvmLog (T 'log.snap.tooBig' $s) WARN }
    return $snap
}

# ---------------------------------------------------------------- Registry

function Get-RelevantRegPrefixes {
    param($Def, $Mod)
    $prefixes = @('HKLM\SOFTWARE\Khronos', 'HKLM\SOFTWARE\WOW6432Node\Khronos', 'HKCU\Software\Khronos')
    if ($Def) {
        foreach ($k in $Def.RegQueryKeys) { $prefixes += [RVM.RegCapture]::NormalizeHive($k) }
        if ($Mod) {
            foreach ($f in $Def.RegImports) {
                $p = [IO.Path]::Combine($Mod.Path, (ConvertTo-NativePath $f))
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $txt = [IO.File]::ReadAllText($p)
                foreach ($m in [regex]::Matches($txt, '(?m)^\[-?(HKEY_[^\]]+)\]')) { $prefixes += [RVM.RegCapture]::NormalizeHive($m.Groups[1].Value.Trim()) }
            }
        }
    }
    return @($prefixes | Select-Object -Unique)
}

function Split-RegDiffs {
    # Teilt Registry-Änderungen in "gehört zum Mod" und "andere".
    param($Diffs, [string[]]$Prefixes)
    $rel = New-Object 'System.Collections.Generic.List[RVM.DiffEntry]'
    $oth = New-Object 'System.Collections.Generic.List[RVM.DiffEntry]'
    foreach ($d in $Diffs) {
        $kp = $d.KeyPath
        $hit = $false
        foreach ($p in $Prefixes) {
            if ($kp.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or $kp.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
        }
        if (-not $hit -and ($kp -match '(?i)RealVR|R\.E\.A\.L' -or ($d.ValueName -and $d.ValueName -match '(?i)RealVR'))) { $hit = $true }
        if ($hit) { $rel.Add($d) } else { $oth.Add($d) }
    }
    return [pscustomobject]@{ Relevant = $rel; Other = $oth }
}

function Export-RegKeys {
    param([string[]]$Keys, [string]$OutDir)
    if (-not (Test-RvmWindows)) { return }
    $i = 0
    foreach ($k in $Keys) {
        $i++
        try {
            if (-not [RVM.RegCapture]::KeyExists($k)) { continue }
            $file = [IO.Path]::Combine($OutDir, ('export_{0:00}_{1}.reg' -f $i, (Get-SafeName ($k.Split('\')[-1]))))
            & reg.exe export $k $file /y /reg:64 2>&1 | Out-Null
        } catch { }
    }
}

# ---------------------------------------------------------------- Ordnerrechte

function Save-FolderAcl {
    param([string]$Folder, [string]$OutDir)
    if (-not (Test-RvmWindows)) { return $false }
    [void](New-Item -ItemType Directory -Path $OutDir -Force)
    try {
        $acl = Get-Acl -LiteralPath $Folder
        [IO.File]::WriteAllText([IO.Path]::Combine($OutDir, 'root.sddl'), $acl.Sddl)
        $out = & icacls.exe ($Folder.TrimEnd('\') + '\*') /save ([IO.Path]::Combine($OutDir, 'children.txt')) /T /C /Q 2>&1
        Write-RvmLog (T 'log.acl.saved' $Folder)
        return $true
    } catch {
        Write-RvmLog (T 'log.acl.saveFail' $_.Exception.Message) WARN
        return $false
    }
}

function Restore-FolderAcl {
    param([string]$Folder, [string]$AclDir)
    $log = @()
    $sddlFile = [IO.Path]::Combine($AclDir, 'root.sddl')
    if (Test-Path -LiteralPath $sddlFile) {
        try {
            $acl = Get-Acl -LiteralPath $Folder
            $acl.SetSecurityDescriptorSddlForm([IO.File]::ReadAllText($sddlFile), [Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -LiteralPath $Folder -AclObject $acl
            $log += 'OK  ' + (T 'res.acl.root')
        } catch { $log += 'ERR ' + (T 'res.acl.rootFail' $_.Exception.Message) }
    }
    $children = [IO.Path]::Combine($AclDir, 'children.txt')
    if (Test-Path -LiteralPath $children) {
        $out = & icacls.exe $Folder.TrimEnd('\') /restore $children /C /Q 2>&1
        if ($LASTEXITCODE -eq 0) { $log += 'OK  ' + (T 'res.acl.children') }
        else { $log += 'WARN ' + (T 'res.acl.childrenWarn' $LASTEXITCODE) }
    }
    return $log
}

# ---------------------------------------------------------------- NVIDIA-Profildatenbank (Vdesync)

function Get-NvidiaDrsHash {
    if (-not $script:NvidiaDrsDir -or -not (Test-Path -LiteralPath $script:NvidiaDrsDir)) { return $null }
    $parts = @()
    foreach ($f in @([IO.Directory]::GetFiles($script:NvidiaDrsDir, 'nvdrsdb*.bin') | Sort-Object)) {
        try { $parts += [IO.Path]::GetFileName($f) + '=' + (Get-FileSha256 $f) } catch { $parts += [IO.Path]::GetFileName($f) + '=?' }
    }
    if (-not $parts) { return $null }
    return ($parts -join ';')
}

function Backup-NvidiaDrs {
    param([string]$OutDir)
    if (-not $script:NvidiaDrsDir -or -not (Test-Path -LiteralPath $script:NvidiaDrsDir)) { return $false }
    [void](New-Item -ItemType Directory -Path $OutDir -Force)
    foreach ($f in [IO.Directory]::GetFiles($script:NvidiaDrsDir)) {
        try { Copy-FileSafe -Source $f -Target ([IO.Path]::Combine($OutDir, [IO.Path]::GetFileName($f))) } catch { Write-RvmLog (T 'log.nv.fileFail' $f) WARN }
    }
    return $true
}

function Restore-NvidiaDrs {
    param([string]$BackupDir)
    $log = @()
    $svc = Get-Service -Name 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue
    $wasRunning = $svc -and $svc.Status -eq 'Running'
    try {
        if ($wasRunning) { Stop-Service -Name $svc.Name -Force -ErrorAction Stop; $log += 'OK  ' + (T 'res.nv.svcStop') }
        foreach ($f in [IO.Directory]::GetFiles($BackupDir, 'nvdrsdb*.bin')) {
            Copy-FileSafe -Source $f -Target ([IO.Path]::Combine($script:NvidiaDrsDir, [IO.Path]::GetFileName($f)))
        }
        $log += 'OK  ' + (T 'res.nv.dbRestored')
    } catch { $log += 'ERR ' + (T 'res.nv.dbFail' $_.Exception.Message) }
    finally {
        if ($wasRunning) { try { Start-Service -Name $svc.Name -ErrorAction Stop; $log += 'OK  ' + (T 'res.nv.svcStart') } catch { $log += 'ERR ' + (T 'res.nv.svcStartFail' $_.Exception.Message) } }
    }
    return $log
}

function Invoke-NvidiaTool {
    # Fuehrt lib\NvidiaTool.ps1 in einem eigenen PowerShell-Prozess aus (NvAPI-Aufrufe isoliert).
    param([ValidateSet('capture', 'restore')][string]$Mode, [string[]]$Exes, $InObject, [int]$TimeoutSec = 90)
    if (-not (Test-RvmWindows)) { return $null }
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($env:WINDIR, 'System32', 'nvapi64.dll')))) { return $null }
    $tmp = [IO.Path]::Combine((Get-RvmDir Snapshots), ('nv_' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    $out = "$tmp.out.json"; $in = "$tmp.in.json"
    try {
        $tool = [IO.Path]::Combine($script:RVM.AppRoot, 'lib', 'NvidiaTool.ps1')
        $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tool), '-Mode', $Mode, '-OutFile', ('"{0}"' -f $out))
        if ($Exes) { $args2 += @('-Exes', ('"{0}"' -f (($Exes | Where-Object { $_ }) -join '|'))) }
        if ($InObject) { Write-RvmJson -Path $in -Object $InObject; $args2 += @('-InFile', ('"{0}"' -f $in)) }
        $p = Start-Process -FilePath ([IO.Path]::Combine($PSHOME, 'powershell.exe')) -ArgumentList $args2 -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Ok = $false; Error = 'Timeout' } }
        if (-not (Test-Path -LiteralPath $out)) { return [pscustomobject]@{ Ok = $false; Error = "Exitcode $($p.ExitCode)" } }
        return (Read-RvmJson $out)
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    } finally {
        foreach ($f in @($out, $in)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }
}
