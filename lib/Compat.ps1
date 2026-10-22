# R.E.A.L. Mod Manager - Systeminfo, Installationsstatus und Kompatibilitäts-Einschätzung

function Test-IntegratedGpu {
    param([string]$Name, [double]$VramGB)
    if ($Name -match '(?i)\b(UHD|Iris|HD Graphics)\b') { return $true }
    if ($Name -match '(?i)^(AMD )?Radeon(\(TM\))? Graphics$|Radeon(\(TM\))? \d{3,4}M\b|Vega \d+ Graphics|^Intel\(R\) Arc\(TM\) Graphics$|Adreno') { return $true }
    if ($VramGB -gt 0 -and $VramGB -lt 2) { return $true }
    return $false
}

function Get-RvmSystemInfo {
    $info = [ordered]@{
        IsWindows     = (Test-RvmWindows)
        IsAdmin       = (Test-RvmAdmin)
        OpenXR        = $null
        SteamVR       = $false
        VrRuntimes    = @()
        Gpus          = @()
        DedicatedGpus = @()
        HasNvidia     = $false
        MaxVramGB     = 0
        PSVersion     = $PSVersionTable.PSVersion.ToString()
    }
    if (-not $info.IsWindows) { return [pscustomobject]$info }

    $nameOf = {
        param($p)
        if ($p -match '(?i)steamvr') { 'SteamVR' }
        elseif ($p -match '(?i)virtualdesktop|virtual desktop') { 'Virtual Desktop' }
        elseif ($p -match '(?i)oculus|meta') { 'Meta Quest Link' }
        elseif ($p -match '(?i)pico') { 'PICO Connect' }
        elseif ($p -match '(?i)playfordream|pfd') { 'Play For Dream' }
        elseif ($p -match '(?i)mixedreality|wmr') { 'Windows Mixed Reality' }
        elseif ($p -match '(?i)varjo') { 'Varjo' }
        else { [IO.Path]::GetFileNameWithoutExtension($p) }
    }
    $rts = New-Object System.Collections.Generic.List[string]
    $rt = Get-RegValueSafe 'HKLM:\SOFTWARE\Khronos\OpenXR\1' 'ActiveRuntime'
    if ($rt) { $info.OpenXR = (& $nameOf $rt); $rts.Add($info.OpenXR) }
    try {
        $k = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Khronos\OpenXR\1\AvailableRuntimes' -ErrorAction Stop
        foreach ($v in $k.GetValueNames()) {
            if (-not (Test-Path -LiteralPath $v)) { continue }
            $n = & $nameOf $v
            if (-not $rts.Contains($n)) { $rts.Add($n) }
        }
    } catch { }
    $vrpath = [IO.Path]::Combine($env:LOCALAPPDATA, 'openvr', 'openvrpaths.vrpath')
    $info.SteamVR = (Test-Path -LiteralPath $vrpath)
    if ($info.SteamVR -and -not $rts.Contains('SteamVR')) { $rts.Add('SteamVR') }
    $vd = @(
        [IO.Path]::Combine($env:ProgramFiles, 'Virtual Desktop Streamer', 'VirtualDesktop.Streamer.exe'),
        [IO.Path]::Combine(${env:ProgramFiles(x86)}, 'Virtual Desktop Streamer', 'VirtualDesktop.Streamer.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($vd -and -not $rts.Contains('Virtual Desktop')) { $rts.Add('Virtual Desktop') }
    if ($env:OculusBase -and (Test-Path -LiteralPath $env:OculusBase) -and -not $rts.Contains('Meta Quest Link')) { $rts.Add('Meta Quest Link') }
    $info.VrRuntimes = @($rts)

    $gpus = @()
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in @(Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.DriverDesc) { continue }
        if ($p.DriverDesc -match '(?i)basic display|remote|virtual|parsec|meta virtual|indirect') { continue }
        $mem = 0
        $q = $p.'HardwareInformation.qwMemorySize'
        if ($q) { $mem = [double]$q }
        elseif ($p.'HardwareInformation.MemorySize') {
            $ms = $p.'HardwareInformation.MemorySize'
            if ($ms -is [byte[]]) { $mem = [double][BitConverter]::ToUInt32($ms, 0) } else { $mem = [double]$ms }
        }
        $vram = [Math]::Round($mem / 1GB, 1)
        $gpus += [pscustomobject]@{ Name = $p.DriverDesc; VramGB = $vram; Integrated = (Test-IntegratedGpu $p.DriverDesc $vram) }
    }
    $info.Gpus = @($gpus | Sort-Object Name -Unique)
    $info.DedicatedGpus = @($info.Gpus | Where-Object { -not $_.Integrated } | Sort-Object VramGB -Descending)
    $info.HasNvidia = [bool](@($info.DedicatedGpus | Where-Object { $_.Name -match '(?i)nvidia|geforce|rtx' }).Count)
    if ($info.DedicatedGpus.Count) { $info.MaxVramGB = ($info.DedicatedGpus | Measure-Object VramGB -Maximum).Maximum }
    return [pscustomobject]$info
}

# Liefert {Text; Ok; Tip} für den Footer: nur dedizierte GPU + gefundene VR-Runtimes
function Format-SystemInfo {
    param($Sys)
    if (-not $Sys.IsWindows) { return [pscustomobject]@{ Text = (T 'sys.noWindows'); Ok = $false; Tip = '' } }
    $ok = $true; $tip = @()
    if ($Sys.DedicatedGpus.Count) {
        $g = $Sys.DedicatedGpus[0]
        $gpu = if ($g.VramGB -gt 0) { '{0} ({1} GB)' -f $g.Name, $g.VramGB } else { $g.Name }
        if ($g.VramGB -gt 0 -and $g.VramGB -lt 8) { $ok = $false; $tip += (T 'cp.vram' $g.VramGB) }
    } else {
        $gpu = T 'sys.noGpu'; $ok = $false; $tip += (T 'cp.noGpu')
        $ig = @($Sys.Gpus | Where-Object { $_.Integrated } | ForEach-Object { $_.Name })
        if ($ig.Count) { $tip += (T 'sys.igpu' ($ig -join ', ')) }
    }
    if ($Sys.VrRuntimes.Count) { $vr = 'VR: ' + ($Sys.VrRuntimes -join ', ') }
    else { $vr = T 'sys.noVr'; $ok = $false; $tip += (T 'cp.noVr') }
    if (-not $Sys.IsAdmin) { $vr += '  ·  ' + (T 'sys.noAdmin') }
    if ($ok) { $tip = @((T 'sys.tip')) } else { $tip += ''; $tip += (T 'sys.missingTip') }
    return [pscustomobject]@{ Text = ('{0}  ·  {1}' -f $gpu, $vr); Ok = $ok; Tip = ($tip -join [Environment]::NewLine) }
}

# ---------------------------------------------------------------- Journal-Verwaltung

function Get-JournalDirForFolder {
    param([Parameter(Mandatory)][string]$Folder, [string]$Name = 'Game')
    $id = '{0}_{1}' -f (Get-SafeName $Name), (Get-ShortHash (Get-FullPathSafe $Folder).TrimEnd('\', '/'))
    return [IO.Path]::Combine((Get-RvmDir Journals), $id)
}

function Get-ActiveJournal {
    param([Parameter(Mandatory)][string]$Folder)
    $hash = Get-ShortHash (Get-FullPathSafe $Folder).TrimEnd('\', '/')
    foreach ($d in [IO.Directory]::GetDirectories((Get-RvmDir Journals))) {
        $leaf = [IO.Path]::GetFileName($d)
        if ($leaf.StartsWith('_')) { continue }
        if ($leaf.EndsWith('_' + $hash)) {
            $j = Read-RvmJson ([IO.Path]::Combine($d, 'journal.json'))
            if ($j) { $j | Add-Member -NotePropertyName Dir -NotePropertyValue $d -Force; return $j }
        }
    }
    return $null
}

# ---------------------------------------------------------------- Installationsstatus

function Get-ModInstallState {
    param([Parameter(Mandatory)][string]$Folder, $Def)

    $evidence = @()
    $version = $null
    $journal = Get-ActiveJournal $Folder
    if ($journal) {
        return [pscustomobject]@{
            State    = $(if ($journal.Status -eq 'installed') { 'Managed' } else { 'Incomplete' })
            Version  = $journal.ModVersion
            Journal  = $journal
            Evidence = @((T 'ev.journal' $journal.Status))
        }
    }

    $f = { param($n) [IO.Path]::Combine($Folder, $n) }
    if (Test-Path -LiteralPath (& $f 'RealRepo')) { $evidence += (T 'ev.realrepo') }
    if (Test-Path -LiteralPath (& $f 'RealConfig.bat')) { $evidence += 'RealConfig.bat' }
    if (@(Get-ChildItem -LiteralPath $Folder -Filter 'RealVR*.ini' -ErrorAction SilentlyContinue).Count) { $evidence += 'RealVR.ini' }
    if (Test-Path -LiteralPath (& $f 'RealVR64.dll')) { $evidence += 'RealVR64.dll' }
    if (Test-Path -LiteralPath (& $f 'start_protected_game_ori.exe')) { $evidence += (T 'ev.eac') }
    $dxgi = & $f 'dxgi.dll'
    if ((Test-Path -LiteralPath $dxgi) -and (Test-IsRealVRBinary $dxgi)) { $evidence += 'dxgi.dll (R.E.A.L. VR)' }
    if ($Def -and $Def.UsesVulkan -and (Test-RvmWindows)) {
        foreach ($k in @('HKLM\SOFTWARE\Khronos\Vulkan\ImplicitLayers', 'HKCU\SOFTWARE\Khronos\Vulkan\ImplicitLayers')) {
            try { if (@([RVM.RegCapture]::GetValueNames($k) | Where-Object { $_ -match 'RealVR64\.json$' }).Count) { $evidence += (T 'ev.vulkan' $k) } } catch { }
        }
    }
    foreach ($cand in @((& $f 'RealRepo\RealVR64.dll'), (& $f 'RealVR64.dll'), $dxgi, ([IO.Path]::Combine((Get-StdPaths).prog, 'RealVR64.dll')))) {
        $vi = Get-RvmFileVersionInfo (ConvertTo-NativePath $cand)
        if ($vi -and $vi.ProductName -match 'R\.E\.A\.L') { $version = ([regex]::Match($vi.ProductVersion, '\d+\.\d+\.\d+')).Value; break }
    }
    $state = 'None'
    if ($evidence.Count) { $state = 'Foreign' }
    return [pscustomobject]@{ State = $state; Version = $version; Journal = $null; Evidence = $evidence }
}

# ---------------------------------------------------------------- Kompatibilität

function Get-CompatAssessment {
    param([Parameter(Mandatory)]$Def, [string]$Folder, $Mod, $Sys)

    $problems = @(); $warnings = @(); $notes = @()

    if ($Mod -and -not (Test-ModHasRepo -Mod $Mod -Def $Def)) {
        $problems += (T 'cp.noRepo' $Def.RepoFolder)
    }
    if (-not $Folder) {
        $notes += (T 'cp.notOnDisk')
    } elseif ($Folder -match '(?i)\\WindowsApps\\') {
        $problems += (T 'cp.windowsApps')
    } elseif ($Folder -match '(?i)\\XboxGames\\') {
        $warnings += (T 'cp.xbox')
    }

    if ($Folder -and $Def.NeedsFirstRun) {
        $paths = @(Get-GameSettingsPaths -Def $Def -GameDir $Folder)
        $outside = @($paths | Where-Object { -not (Test-PathUnder $Folder $_) })
        if ($outside.Count) {
            $exists = @($outside | Where-Object { Test-Path -LiteralPath $_ })
            if (-not $exists.Count) { $warnings += (T 'cp.neverRun') }
        }
        if ($Def.RegQueryKeys.Count -and (Test-RvmWindows)) {
            $missing = @($Def.RegQueryKeys | Where-Object { -not [RVM.RegCapture]::KeyExists($_) })
            if ($missing.Count) { $warnings += (T 'cp.neverRunReg') }
        }
    }
    if ($Def.OnlineWarning) { $warnings += (T 'cp.online') }
    if ($Mod -and $Mod.EarlyAccess) { $notes += (T 'cp.ea') }
    if ($Def.UsesVulkan) { $notes += (T 'cp.vulkan') }
    if ($Def.RegImports.Count) { $notes += (T 'cp.regImport') }
    if ($Def.ReplacesLauncher) { $notes += (T 'cp.eac') }
    if ($Def.DeletesGameFiles.Count) { $notes += (T 'cp.deletes' ($Def.DeletesGameFiles -join ', ')) }
    if ($Def.Choices.Count) { $notes += (T 'cp.choice' ($Def.Choices -join '; ')) }

    if ($Sys -and $Sys.IsWindows) {
        if ($Sys.Gpus.Count -and -not $Sys.DedicatedGpus.Count) { $warnings += (T 'cp.noGpu') }
        if (-not $Sys.VrRuntimes.Count) { $warnings += (T 'cp.noVr') }
        if ($Sys.MaxVramGB -gt 0 -and $Sys.MaxVramGB -lt 8) { $warnings += (T 'cp.vram' $Sys.MaxVramGB) }
        if (-not $Sys.HasNvidia) { $notes += (T 'cp.noNvidia') }
    }

    $level = 'good'; $color = '#4CAF50'
    if ($warnings.Count) { $level = 'limited'; $color = '#F2B33D' }
    if ($problems.Count) { $level = 'problem'; $color = '#E5534B' }

    $lines = @()
    $lines += ($problems | ForEach-Object { 'X  ' + $_ })
    $lines += ($warnings | ForEach-Object { '!  ' + $_ })
    $lines += ($notes | ForEach-Object { 'i  ' + $_ })
    return [pscustomobject]@{
        Level    = $level
        LevelText = (T ('cp.level.' + $level))
        Color    = $color
        Problems = $problems
        Warnings = $warnings
        Notes    = $notes
        Text     = ($lines -join [Environment]::NewLine)
    }
}
