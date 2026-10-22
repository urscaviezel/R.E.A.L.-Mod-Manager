# R.E.A.L. Mod Manager - Updates ueber GitHub-Releases
# Ein Release enthaelt entweder eine ZIP (portable Version) und/oder eine Setup-EXE (Installer-Version).
# Die laufende Version weiss ueber version.json, wie sie installiert wurde (InstallType: portable | installer).

function Get-RvmVersionInfo { return (Read-RvmJson ([IO.Path]::Combine($script:RVM.AppRoot, 'version.json'))) }

function Get-RvmRepoParts {
    param($V = (Get-RvmVersionInfo))
    if ($V -and $V.Repository -match '^https?://github\.com/([^/\s]+)/([^/\s#?]+?)(\.git)?/?$') { return @($Matches[1], $Matches[2]) }
    return $null
}

function Invoke-RvmDownloadFile {
    # Grosse Datei direkt auf die Platte laden. Liefert $true/$false.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Target, [int64]$MaxBytes = 300MB, [int]$TimeoutSec = 60)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $tmp = $Target + '.part'
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'REAL-Mod-Manager'
        $resp = $req.GetResponse()
        try {
            $st = $resp.GetResponseStream()
            $fs = [IO.File]::Create($tmp)
            try {
                $buf = New-Object byte[] 131072; $total = [int64]0
                while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
                    $fs.Write($buf, 0, $n); $total += $n
                    if ($total -gt $MaxBytes) { throw 'too large' }
                }
            } finally { $fs.Close() }
        } finally { $resp.Close() }
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
        Move-Item -LiteralPath $tmp -Destination $Target
        return $true
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Get-RvmUpdateInfo {
    # Fragt GitHub nach dem neuesten Release. Rueckgabe: Available, Current, Latest, Notes, Page, AssetUrl, AssetName, Kind (zip|setup), Error
    param([switch]$IncludePrerelease)
    $v = Get-RvmVersionInfo
    $cur = if ($v) { [string]$v.Version } else { '0.0.0' }
    $res = [ordered]@{ Available = $false; Current = $cur; Latest = $null; Notes = ''; Page = $null; AssetUrl = $null; AssetName = $null; Kind = $null; Error = $null }
    $parts = Get-RvmRepoParts $v
    if (-not $parts) { $res.Error = 'norepo'; return [pscustomobject]$res }
    $api = 'https://api.github.com/repos/{0}/{1}/releases' -f $parts[0], $parts[1]
    $rel = $null
    if ($IncludePrerelease) {
        $raw = Invoke-RvmHttpGet ($api + '?per_page=10')
        if (-not $raw) { $res.Error = 'offline'; return [pscustomobject]$res }
        try { $rel = @([Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json) | Where-Object { -not $_.draft } | Select-Object -First 1 } catch { }
    } else {
        $raw = Invoke-RvmHttpGet ($api + '/latest')
        if (-not $raw) {
            # 404 (noch kein Release) und offline sehen gleich aus -> Repo-Seite pruefen
            $probe = Invoke-RvmHttpGet ('https://api.github.com/repos/{0}/{1}' -f $parts[0], $parts[1])
            $res.Error = $(if ($probe) { 'norelease' } else { 'offline' })
            return [pscustomobject]$res
        }
        try { $rel = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json } catch { }
    }
    if (-not $rel -or -not $rel.tag_name) { $res.Error = 'norelease'; return [pscustomobject]$res }
    $latest = ([string]$rel.tag_name).TrimStart('v', 'V')
    $res.Latest = $latest
    $res.Notes = [string]$rel.body
    $res.Page = [string]$rel.html_url
    $installer = ($v.InstallType -eq 'installer')
    $assets = @($rel.assets | Where-Object { $_.browser_download_url -match '^https://github\.com/' })
    $setup = $assets | Where-Object { $_.name -match '(?i)setup.*\.exe$' } | Select-Object -First 1
    $zip = $assets | Where-Object { $_.name -match '(?i)\.zip$' } | Select-Object -First 1
    $pick = if ($installer -and $setup) { $setup } elseif ($zip) { $zip } else { $setup }
    if ($pick) {
        $res.AssetUrl = [string]$pick.browser_download_url; $res.AssetName = [string]$pick.name
        $res.Kind = $(if ($pick.name -match '(?i)\.exe$') { 'setup' } else { 'zip' })
    }
    $res.Available = ((Get-VersionObject $latest) -gt (Get-VersionObject $cur)) -and [bool]$res.AssetUrl
    if ((Get-VersionObject $latest) -gt (Get-VersionObject $cur) -and -not $res.AssetUrl) { $res.Error = 'noasset' }
    return [pscustomobject]$res
}

function Save-RvmUpdate {
    # Laedt das Update herunter und bereitet es vor. Liefert @{ Kind; Path (Setup-EXE bzw. entpackter Ordner) }.
    param([Parameter(Mandatory)]$Info)
    $dir = [IO.Path]::Combine($script:RVM.DataRoot, 'Updates')
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $file = [IO.Path]::Combine($dir, (Get-SafeName $Info.AssetName))
    Write-RvmLog (T 'log.upd.download' $Info.AssetName) STATUS
    if (-not (Invoke-RvmDownloadFile -Url $Info.AssetUrl -Target $file)) { throw (T 'err.upd.download') }
    if ($Info.Kind -eq 'setup') { return @{ Kind = 'setup'; Path = $file } }

    $stage = [IO.Path]::Combine($dir, 'staging')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($file, $stage)
    # Inhalt darf direkt in der ZIP oder in genau einem Unterordner liegen
    $root = $stage
    $entries = @([IO.Directory]::GetFileSystemEntries($stage))
    if ($entries.Count -eq 1 -and [IO.Directory]::Exists($entries[0])) { $root = $entries[0] }
    $ok = (Test-Path -LiteralPath ([IO.Path]::Combine($root, 'version.json'))) -and (
        (Test-Path -LiteralPath ([IO.Path]::Combine($root, 'RealVRManager.ps1'))) -or @([IO.Directory]::GetFiles($root, '*.exe')).Count)
    if (-not $ok) { throw (T 'err.upd.package') }
    if (Test-Path -LiteralPath ([IO.Path]::Combine($root, 'Data'))) { Remove-Item -LiteralPath ([IO.Path]::Combine($root, 'Data')) -Recurse -Force }   # Daten nie ueberschreiben
    return @{ Kind = 'zip'; Path = $root }
}

function Start-RvmUpdateApply {
    # Startet einen kleinen Hilfsprozess, der auf das Beenden des Managers wartet, die Dateien ersetzt und neu startet.
    param([Parameter(Mandatory)][hashtable]$Prepared, [Parameter(Mandatory)][string]$RestartPath, [int]$ProcessId = $PID)
    $app = $script:RVM.AppRoot
    $script = [IO.Path]::Combine($script:RVM.DataRoot, 'Updates', 'apply-update.ps1')
    $body = @'
param([int]$WaitPid, [string]$Source, [string]$Target, [string]$Restart, [string]$Log, [string]$Setup)
function L($m) { Add-Content -LiteralPath $Log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) -Encoding UTF8 }
try { $p = Get-Process -Id $WaitPid -ErrorAction Stop; $p.WaitForExit(60000) | Out-Null } catch { }
Start-Sleep -Milliseconds 500
if ($Setup) {
    # Installer-Version: Setup startet das Programm am Ende selbst wieder
    L "Setup: $Setup"
    Start-Process -FilePath $Setup -ArgumentList '/SILENT', '/NORESTART', '/CLOSEAPPLICATIONS'
    return
}
L "Update: $Source -> $Target"
$fail = 0
foreach ($f in Get-ChildItem -LiteralPath $Source -Recurse -File) {
    $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
    if ($rel -like 'Data\*') { continue }
    $dest = Join-Path $Target $rel
    $dd = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    $done = $false
    for ($i = 0; $i -lt 10 -and -not $done; $i++) {
        try { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop; $done = $true } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $done) { $fail++; L "FAILED: $rel" }
}
L "Done, $fail error(s). Restart: $Restart"
if ($Restart -like '*.cmd') { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + $Restart + '"') -WindowStyle Hidden }
else { Start-Process -FilePath $Restart }
'@
    [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding($true)))
    $log = [IO.Path]::Combine((Get-RvmDir Logs), 'update.log')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $script),
        '-WaitPid', $ProcessId, '-Restart', ('"{0}"' -f $RestartPath), '-Log', ('"{0}"' -f $log))
    if ($Prepared.Kind -eq 'setup') { $argList += @('-Setup', ('"{0}"' -f $Prepared.Path)) }
    else { $argList += @('-Source', ('"{0}"' -f $Prepared.Path), '-Target', ('"{0}"' -f $app.TrimEnd('\'))) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden
}
