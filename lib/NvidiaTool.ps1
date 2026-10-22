# Eigenstaendiger Hilfsprozess fuer NVIDIA-Treiberprofile (wird vom Manager gestartet).
# capture: Zustand der Spiel-EXEs in den NVIDIA-Profilen als JSON schreiben
# restore: Zustand "Before" aus der Eingabedatei wiederherstellen (nur diese Spiele)
param(
    [Parameter(Mandatory)][ValidateSet('capture', 'restore')][string]$Mode,
    [string]$Exes,
    [string]$InFile,
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
$result = @{ Ok = $false; Error = $null; States = @(); Log = @() }
try {
    if (-not ('RVM.NvDrs' -as [type])) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NvDrs.cs'))) -Language CSharp -WarningAction SilentlyContinue
    }
    if ($Mode -eq 'capture') {
        $list = [RVM.NvDrs]::Capture([string[]]($Exes -split '\|' | Where-Object { $_ }))
        $result.States = @($list | ForEach-Object {
                @{ Exe = $_.Exe; Found = $_.Found; Profile = $_.Profile; ProfilePredefined = $_.ProfilePredefined; ProfileApps = $_.ProfileApps
                    VsyncPresent = $_.VsyncPresent; VsyncLocation = $_.VsyncLocation; VsyncPredefined = $_.VsyncPredefined; VsyncValue = $_.VsyncValue; Error = $_.Error }
            })
    } else {
        $in = [IO.File]::ReadAllText($InFile) | ConvertFrom-Json
        $conv = {
            param($arr)
            $out = @()
            foreach ($x in @($arr)) {
                if (-not $x) { continue }
                $s = New-Object RVM.NvAppState
                foreach ($p in 'Exe', 'Found', 'Profile', 'ProfilePredefined', 'ProfileApps', 'VsyncPresent', 'VsyncLocation', 'VsyncPredefined', 'VsyncValue') {
                    if ($null -ne $x.$p) { $s.$p = $x.$p }
                }
                $out += $s
            }
            return , ([RVM.NvAppState[]]$out)
        }
        $before = & $conv $in.Before
        $after = & $conv $in.After
        $result.Log = @([RVM.NvDrs]::Restore($before, $after))
    }
    $result.Ok = $true
} catch {
    $result.Error = $_.Exception.Message
}
[IO.File]::WriteAllText($OutFile, ($result | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
