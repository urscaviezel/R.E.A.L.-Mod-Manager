# R.E.A.L. Mod Manager - gemeinsame Hilfsfunktionen
# Kompatibel mit Windows PowerShell 5.1 und PowerShell 7.

$script:RVM = @{
    AppRoot       = $null
    DataRoot      = $null
    Shared        = $null
    PathOverrides = $null   # nur für Tests (Linux)
    BatRunner     = $null   # nur für Tests: ersetzt das Ausführen der RealConfig.bat
}

function Initialize-RVM {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        $Shared = $null,
        [string]$DataRoot = $null
    )
    $script:RVM.AppRoot = $AppRoot
    if (-not $DataRoot) {
        # Portable: Data neben dem Programm. Installer-Version: version.json "DataDir" (z.B. %ProgramData%\R.E.A.L. Mod Manager)
        $vj = [IO.Path]::Combine($AppRoot, 'version.json')
        $dd = $null
        if (Test-Path -LiteralPath $vj) { try { $dd = ([IO.File]::ReadAllText($vj) | ConvertFrom-Json).DataDir } catch { } }
        if ($dd) { $DataRoot = [Environment]::ExpandEnvironmentVariables([string]$dd) } else { $DataRoot = [IO.Path]::Combine($AppRoot, 'Data') }
    }
    $script:RVM.DataRoot = $DataRoot
    $script:RVM.Shared = $Shared
    foreach ($d in @('Mods', 'Journals', 'Snapshots', 'Logs', 'Covers')) {
        $p = [IO.Path]::Combine($DataRoot, $d)
        if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
    }
    Import-RvmNative
    Initialize-RvmLanguage
}

function Import-RvmNative {
    if ('RVM.SnapIO' -as [type]) { return }
    $cs = [IO.Path]::Combine($PSScriptRoot, 'Native.cs')
    $src = [IO.File]::ReadAllText($cs)
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        if ($PSVersionTable.PSEdition -eq 'Core') { throw }
        Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies 'System.dll' -ErrorAction Stop -WarningAction SilentlyContinue
    }
}

function Get-RvmDir {
    param([ValidateSet('Mods', 'Journals', 'Snapshots', 'Logs', 'Root', 'JournalArchive', 'RegSnapshots', 'Covers')][string]$Name)
    switch ($Name) {
        'Root' { return $script:RVM.DataRoot }
        'JournalArchive' { $p = [IO.Path]::Combine($script:RVM.DataRoot, 'Journals', '_Archiv') }
        'RegSnapshots' { $p = [IO.Path]::Combine($script:RVM.DataRoot, 'Snapshots', 'Registry') }
        default { $p = [IO.Path]::Combine($script:RVM.DataRoot, $Name) }
    }
    if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force) }
    return $p
}

# ---------------------------------------------------------------- Logging
function Write-RvmLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'STATUS', 'OK')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $shared = $script:RVM.Shared
    if ($shared -and $shared.LogQueue) {
        $shared.LogQueue.Enqueue($line)
    } else {
        Write-Host $line
        try {
            if ($script:RVM.DataRoot) {
                $f = [IO.Path]::Combine((Get-RvmDir Logs), ('{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')))
                [IO.File]::AppendAllText($f, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
            }
        } catch { }
    }
}

# ---------------------------------------------------------------- JSON / Settings
function Write-RvmJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Depth 20
    $dir = [IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Read-RvmJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $txt = [IO.File]::ReadAllText($Path)
    if (-not $txt.Trim()) { return $null }
    return ($txt | ConvertFrom-Json)
}

function Get-RvmSettings {
    $p = [IO.Path]::Combine($script:RVM.DataRoot, 'settings.json')
    $s = Read-RvmJson $p
    if (-not $s) { $s = [pscustomobject]@{} }
    foreach ($kv in @(
            @{ N = 'ManualGameFolders'; V = @() },
            @{ N = 'SelectedMod'; V = $null },
            @{ N = 'BackupMaxFileMB'; V = 64 },
            @{ N = 'SettingsBackupMaxTotalMB'; V = 500 },
            @{ N = 'Language'; V = $null },
            @{ N = 'Theme'; V = 'dark' },
            @{ N = 'OnlineCovers'; V = $null },
            @{ N = 'AutoUpdate'; V = $true },
            @{ N = 'UpdatePrerelease'; V = $false },
            @{ N = 'SkipVersion'; V = $null })) {
        if (-not ($s.PSObject.Properties.Name -contains $kv.N)) { $s | Add-Member -NotePropertyName $kv.N -NotePropertyValue $kv.V }
    }
    $s.ManualGameFolders = @($s.ManualGameFolders | Where-Object { $_ })
    return $s
}

function Save-RvmSettings {
    param([Parameter(Mandatory)]$Settings)
    Write-RvmJson -Path ([IO.Path]::Combine($script:RVM.DataRoot, 'settings.json')) -Object $Settings
}

# ---------------------------------------------------------------- Plattform / Pfade
function Test-RvmWindows { return ($env:OS -eq 'Windows_NT') }

function Test-RvmAdmin {
    if (-not (Test-RvmWindows)) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-NativePath {
    # Wandelt Windows-Pfadtrenner auf Nicht-Windows-Systemen (Tests) um.
    param([string]$Path)
    if ($null -eq $Path) { return $null }
    if (-not (Test-RvmWindows)) { return $Path.Replace('\', '/') }
    return $Path
}

function Get-FullPathSafe {
    param([string]$Path)
    try { return [IO.Path]::GetFullPath((ConvertTo-NativePath $Path)) } catch { return $Path }
}

function ConvertTo-CanonicalDir {
    # Einheitliche Schreibweise fuer Ordnerpfade (Epic liefert z.B. "D:/Epic Games/...").
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"')
    if (Test-RvmWindows) { $p = $p.Replace('/', '\') }
    try { $p = [IO.Path]::GetFullPath($p) } catch { return $null }
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }
    return $p
}

function Get-RvmRelativePath {
    param([string]$Base, [string]$Full)
    $b = (Get-FullPathSafe $Base).TrimEnd('\', '/')
    $f = Get-FullPathSafe $Full
    if ($f.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) {
        return $f.Substring($b.Length).TrimStart('\', '/')
    }
    return $null
}

function Test-PathUnder {
    param([string]$Parent, [string]$Child)
    $p = (Get-FullPathSafe $Parent).TrimEnd('\', '/')
    $c = Get-FullPathSafe $Child
    if ($c.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $sep = [IO.Path]::DirectorySeparatorChar
    return $c.StartsWith($p + $sep, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeName {
    param([string]$Text)
    $t = ($Text -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
    if (-not $t) { $t = 'Spiel' }
    return $t
}

function Get-ShortHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))
        return (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-StdPaths {
    # Entspricht den Variablen, die RealConfig.bat per "as_admin" erhält.
    if ($script:RVM.PathOverrides) { return $script:RVM.PathOverrides }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $sep = '\'
    return @{
        doc    = $docs.TrimEnd('\') + $sep
        doc1   = $docs.TrimEnd('\') + $sep
        doc2   = ([IO.Path]::Combine($env:USERPROFILE, 'Documents')).TrimEnd('\') + $sep
        loc    = $env:LOCALAPPDATA
        app    = $env:APPDATA
        usrprf = $env:USERPROFILE
        prog   = [IO.Path]::Combine($env:ProgramData, 'RealVR')
    }
}

function Get-VersionObject {
    param([string]$Text)
    if (-not $Text) { return [version]'0.0' }
    $m = [regex]::Match($Text, '(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return [version]'0.0' }
    $parts = @($m.Groups[1].Value, $m.Groups[2].Value)
    if ($m.Groups[3].Success) { $parts += $m.Groups[3].Value }
    if ($m.Groups[4].Success) { $parts += $m.Groups[4].Value }
    return [version]($parts -join '.')
}

function Get-RvmFileVersionInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return [pscustomobject]@{
            ProductName     = $vi.ProductName
            ProductVersion  = $vi.ProductVersion
            FileVersion     = $vi.FileVersion
            FileDescription = $vi.FileDescription
            CompanyName     = $vi.CompanyName
        }
    } catch { return $null }
}

function Test-IsRealVRBinary {
    param([string]$Path)
    $vi = Get-RvmFileVersionInfo $Path
    if (-not $vi) { return $false }
    return (("$($vi.ProductName) $($vi.FileDescription) $($vi.CompanyName)") -match 'R\.E\.A\.L|RealVR|LukeRoss')
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Copy-FileSafe {
    param([string]$Source, [string]$Target)
    $dir = [IO.Path]::GetDirectoryName($Target)
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::Copy($Source, $Target, $true)
}

function Invoke-RvmHttpGet {
    # Einfacher HTTPS-Download (TLS 1.2), liefert Bytes oder $null. Nur fuer Cover-Bilder/Store-Suche.
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 15, [int]$MaxBytes = 8MB)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'REAL-Mod-Manager'
        $resp = $req.GetResponse()
        try {
            $st = $resp.GetResponseStream()
            $ms = New-Object IO.MemoryStream
            $buf = New-Object byte[] 65536
            while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
                $ms.Write($buf, 0, $n)
                if ($ms.Length -gt $MaxBytes) { return $null }
            }
            return , $ms.ToArray()
        } finally { $resp.Close() }
    } catch { return $null }
}

function Get-RunningProcessForExe {
    param([string[]]$ExeNames)
    $names = @($ExeNames | Where-Object { $_ -and $_ -notmatch '[\*\?]' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    if (-not $names) { return @() }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
}
