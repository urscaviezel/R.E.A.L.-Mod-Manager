# R.E.A.L. Mod Manager - Registry-Sicherung (nur Mod-relevante Schluessel), Vergleich, Wiederherstellung,
# .reg-Export und Windows-Wiederherstellungspunkt.

function Get-ModRelevantRegRoots {
    # Vulkan/OpenXR (Khronos) + die Grafik-Schluessel aller Spiele der gewaehlten Mod-Version.
    param($Mod)
    $roots = @('HKLM\SOFTWARE\Khronos', 'HKLM\SOFTWARE\WOW6432Node\Khronos', 'HKCU\Software\Khronos')
    if ($Mod) {
        $parsed = Get-ParsedMod $Mod
        foreach ($d in $parsed.Games) { $roots += Get-RelevantRegPrefixes -Def $d -Mod $Mod }
    }
    # doppelte und verschachtelte Schluessel entfernen
    $uniq = @($roots | Select-Object -Unique | Sort-Object Length)
    $out = @()
    foreach ($r in $uniq) {
        $inner = $false
        foreach ($o in $out) { if ($r.StartsWith($o + '\', [StringComparison]::OrdinalIgnoreCase) -or $r -ieq $o) { $inner = $true; break } }
        if (-not $inner) { $out += $r }
    }
    return $out
}

function Get-RegSnapshotList {
    $dir = Get-RvmDir RegSnapshots
    $list = @()
    foreach ($f in @([IO.Directory]::GetFiles($dir, '*.snap.gz'))) {
        try {
            $m = [RVM.SnapIO]::LoadMeta($f)
            $list += [pscustomobject]@{
                Name    = $m['Name']
                Created = $m['Created']
                Count   = $m['Count']
                Path    = $f
                Display = ('{0}   ({1}, {2})' -f $m['Name'], ($m['Created'] -replace 'T', ' '), (T 'reg.entries' $m['Count']))
            }
        } catch { }
    }
    return @($list | Sort-Object Created -Descending)
}

function New-RegSnapshot {
    param([string]$Name, $Mod)
    if (-not (Test-RvmWindows)) { throw (T 'err.windowsOnly') }
    $roots = Get-ModRelevantRegRoots -Mod $Mod
    if (-not $Name) { $Name = 'Snapshot' }
    Write-RvmLog (T 'log.reg.snap' $Name $roots.Count) STATUS
    $snap = [RVM.RegCapture]::Capture([string[]]$roots)
    $snap.Meta['Name'] = $Name
    $snap.Meta['Count'] = [string]$snap.Count
    $file = [IO.Path]::Combine((Get-RvmDir RegSnapshots), ('{0}_{1}.snap.gz' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), (Get-SafeName $Name)))
    [RVM.SnapIO]::Save($file, $snap)
    Write-RvmLog (T 'log.reg.snapSaved' $snap.Count) OK
    return $file
}

function Compare-RegSnapshot {
    # Vergleicht einen Snapshot mit dem aktuellen Zustand (oder mit einem zweiten Snapshot).
    param([Parameter(Mandatory)][string]$Path, [string]$Path2)
    $a = [RVM.SnapIO]::Load($Path)
    if ($Path2) { $b = [RVM.SnapIO]::Load($Path2) }
    else {
        $roots = [string[]]($a.Meta['Roots'].Split('|'))
        Write-RvmLog (T 'log.reg.readCurrent') STATUS
        $b = [RVM.RegCapture]::Capture($roots)
    }
    $diffs = [RVM.Differ]::Compare($a.Entries, $b.Entries)
    Write-RvmLog (T 'log.reg.compared' $diffs.Count) OK
    return $diffs
}

function Restore-RegFromSnapshot {
    # Setzt die uebergebenen Unterschiede (Snapshot -> aktuell) wieder auf den Snapshot-Stand zurueck.
    param([Parameter(Mandatory)]$Diffs)
    $list = New-Object 'System.Collections.Generic.List[RVM.DiffEntry]'
    foreach ($d in $Diffs) { $list.Add($d) }
    Write-RvmLog (T 'log.reg.restoring' $list.Count) STATUS
    $log = [RVM.RegCapture]::Restore($list)
    $err = 0
    foreach ($l in $log) { if ($l.StartsWith('ERR')) { $err++; Write-RvmLog $l ERROR } else { Write-RvmLog $l } }
    Write-RvmLog (T 'log.reg.restored' $err) $(if ($err) { 'WARN' } else { 'OK' })
    return $err
}

function Export-RegFull {
    # Klassischer .reg-Export der Mod-relevanten Schluessel (mit regedit lesbar/importierbar).
    param($Mod)
    if (-not (Test-RvmWindows)) { throw (T 'err.windowsOnly') }
    $dir = [IO.Path]::Combine((Get-RvmDir Snapshots), ('RegExport_' + (Get-Date -Format 'yyyyMMdd_HHmmss')))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $roots = Get-ModRelevantRegRoots -Mod $Mod
    Write-RvmLog (T 'log.reg.export' $roots.Count) STATUS
    Export-RegKeys -Keys $roots -OutDir $dir
    Write-RvmLog (T 'log.reg.exported' $dir) OK
    return $dir
}

function New-RvmRestorePoint {
    # Erstellt einen Windows-Wiederherstellungspunkt. Windows erlaubt standardmaessig nur einen pro 24 Stunden;
    # diese Sperre wird fuer den Aufruf kurz aufgehoben und danach wieder auf den alten Wert gesetzt.
    param([string]$Description = 'REAL Mod')
    if ($PSVersionTable.PSEdition -eq 'Core') { throw (T 'err.rpCore') }
    if ($Description.Length -gt 200) { $Description = $Description.Substring(0, 200) }
    Write-RvmLog (T 'log.rp.creating' $Description) STATUS
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $old = $null; $hadOld = $false
    try {
        $p = Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
        if ($p -and ($p.PSObject.Properties.Name -contains $name)) { $old = $p.$name; $hadOld = $true }
        Set-ItemProperty -LiteralPath $key -Name $name -Value 0 -Type DWord -ErrorAction Stop
    } catch { Write-RvmLog (T 'log.rp.freqFail' $_.Exception.Message) WARN }
    try {
        $w = $null
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable w -WarningAction SilentlyContinue
        if ($w) { Write-RvmLog (T 'log.rp.windowsNote' ($w -join ' ')) WARN; return $false }
        Write-RvmLog (T 'log.rp.created' $Description) OK
        return $true
    } catch {
        Write-RvmLog (T 'log.rp.failed' $_.Exception.Message) ERROR
        return $false
    } finally {
        try {
            if ($hadOld) { Set-ItemProperty -LiteralPath $key -Name $name -Value $old -Type DWord -ErrorAction Stop }
            else { Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop }
        } catch { Write-RvmLog (T 'log.rp.freqResetFail' $_.Exception.Message) WARN }
    }
}
