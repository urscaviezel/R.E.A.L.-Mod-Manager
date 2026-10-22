# R.E.A.L. Mod Manager - Mod-Bibliothek (importierte Versionen)

function Find-ModRoot {
    # Sucht den Ordner, der RealConfig.bat und RealRepo enthält (max. 3 Ebenen tief).
    param([string]$Path)
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Path, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue(); $dir = $item[0]; $depth = $item[1]
        if ((Test-Path -LiteralPath ([IO.Path]::Combine($dir, 'RealConfig.bat'))) -and (Test-Path -LiteralPath ([IO.Path]::Combine($dir, 'RealRepo')))) { return $dir }
        if ($depth -ge 3) { continue }
        foreach ($sub in [IO.Directory]::GetDirectories($dir)) { $queue.Enqueue(@($sub, $depth + 1)) }
    }
    return $null
}

function Get-ModVersionInfo {
    param([Parameter(Mandatory)][string]$ModRoot, [string]$SourceName)
    $dll = [IO.Path]::Combine($ModRoot, 'RealRepo', 'RealVR64.dll')
    $vi = $null
    if (Test-RvmWindows) { $vi = Get-RvmFileVersionInfo $dll }
    $version = $null; $productVersion = $null; $fileVersion = $null
    if ($vi -and $vi.ProductVersion) {
        $productVersion = $vi.ProductVersion
        $fileVersion = $vi.FileVersion
        $m = [regex]::Match($vi.ProductVersion, '\d+\.\d+\.\d+')
        if ($m.Success) { $version = $m.Value }
    }
    $nameHint = "$SourceName " + [IO.Path]::GetFileName($ModRoot.TrimEnd('\', '/'))
    if (-not $version) {
        $m = [regex]::Match($nameHint, 'v?(\d{3,4}\.\d+\.\d+)')
        if ($m.Success) { $version = $m.Groups[1].Value }
    }
    if (-not $version) { $version = '0.0.0' }
    $ea = ("$productVersion $nameHint" -match '(?i)early')
    return [pscustomobject]@{
        Version        = $version
        ProductVersion = $productVersion
        FileVersion    = $fileVersion
        EarlyAccess    = [bool]$ea
    }
}

function Get-ModLibrary {
    $dir = Get-RvmDir Mods
    $list = @()
    foreach ($d in [IO.Directory]::GetDirectories($dir)) {
        $name = [IO.Path]::GetFileName($d)
        if ($name.StartsWith('_')) { continue }
        $meta = Read-RvmJson ([IO.Path]::Combine($d, 'mod.json'))
        if (-not $meta) { continue }
        $root = [IO.Path]::Combine($d, 'files')
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($root, 'RealConfig.bat')))) { continue }
        $list += [pscustomobject]@{
            Id           = $name
            Version      = $meta.Version
            EarlyAccess  = [bool]$meta.EarlyAccess
            Display      = (T 'mod.display' $meta.Version $(if ($meta.EarlyAccess) { ' Early Access' } else { '' }) $meta.GameCount)
            Path         = $root
            BatPath      = [IO.Path]::Combine($root, 'RealConfig.bat')
            ImportedAt   = $meta.ImportedAt
            Source       = $meta.Source
            GameCount    = $meta.GameCount
            VersionObj   = (Get-VersionObject $meta.Version)
        }
    }
    return @($list | Sort-Object -Property @{ Expression = 'VersionObj'; Descending = $true }, @{ Expression = 'EarlyAccess'; Descending = $false })
}

function Import-RvmMod {
    # Importiert eine ZIP-Datei oder einen bereits entpackten Ordner in die Bibliothek.
    param([Parameter(Mandatory)][string]$Source)

    $modsDir = Get-RvmDir Mods
    $tmp = [IO.Path]::Combine($modsDir, ('_import_' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $isZip = (Test-Path -LiteralPath $Source -PathType Leaf) -and ($Source -match '(?i)\.zip$')
        if ($isZip) {
            Write-RvmLog (T 'log.mod.unzip' ([IO.Path]::GetFileName($Source))) STATUS
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [IO.Compression.ZipFile]::ExtractToDirectory($Source, $tmp)
            $root = Find-ModRoot $tmp
        } elseif (Test-Path -LiteralPath $Source -PathType Container) {
            $root = Find-ModRoot $Source
        } else {
            throw (T 'err.mod.source' $Source)
        }
        if (-not $root) { throw (T 'err.mod.noFiles') }

        $info = Get-ModVersionInfo -ModRoot $root -SourceName ([IO.Path]::GetFileName($Source))
        $parsed = Read-RealConfig ([IO.Path]::Combine($root, 'RealConfig.bat'))
        $id = 'v' + $info.Version + $(if ($info.EarlyAccess) { '_early_access' } else { '' })
        $target = [IO.Path]::Combine($modsDir, $id)
        if (Test-Path -LiteralPath $target) { throw (T 'err.mod.exists' $id) }
        [void](New-Item -ItemType Directory -Path $target -Force)
        $files = [IO.Path]::Combine($target, 'files')

        if ($isZip) {
            Move-Item -LiteralPath $root -Destination $files
        } else {
            Write-RvmLog (T 'log.mod.copy' $root) STATUS
            Copy-Item -LiteralPath $root -Destination $files -Recurse -Force
        }

        $meta = [ordered]@{
            Version        = $info.Version
            ProductVersion = $info.ProductVersion
            FileVersion    = $info.FileVersion
            EarlyAccess    = $info.EarlyAccess
            GameCount      = $parsed.Games.Count
            Games          = @($parsed.Games | ForEach-Object { $_.Name })
            ImportedAt     = (Get-Date).ToString('s')
            Source         = $Source
        }
        Write-RvmJson -Path ([IO.Path]::Combine($target, 'mod.json')) -Object $meta
        Write-RvmLog (T 'log.mod.imported' $id $parsed.Games.Count) OK
        return $id
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-RvmMod {
    param([Parameter(Mandatory)][string]$Id)
    $p = [IO.Path]::Combine((Get-RvmDir Mods), $Id)
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    Write-RvmLog (T 'log.mod.removed' $Id) OK
}

$script:ParsedCache = @{}
function Get-ParsedMod {
    param([Parameter(Mandatory)]$Mod)
    $key = $Mod.BatPath
    if (-not $script:ParsedCache.ContainsKey($key)) { $script:ParsedCache[$key] = Read-RealConfig $Mod.BatPath }
    return $script:ParsedCache[$key]
}

function Test-ModHasRepo {
    param($Mod, $Def)
    return (Test-Path -LiteralPath ([IO.Path]::Combine($Mod.Path, 'RealRepo', $Def.RepoFolder)))
}
