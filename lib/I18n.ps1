# R.E.A.L. Mod Manager - Sprachdateien (lang\<code>.json)
# Jede Datei: { "_meta": { "code": "de", "name": "Deutsch", "version": "1" }, "schluessel": "Text", ... }
# Fehlt ein Text, wird Englisch verwendet, sonst der Schluessel selbst. Neue Sprachen = neue Datei im Ordner lang.

$script:RvmLang = @{ Code = 'en'; Table = @{}; Fallback = @{} }

function Get-RvmLangDir { return [IO.Path]::Combine($script:RVM.AppRoot, 'lang') }

function Read-RvmLangFile {
    param([string]$Path)
    $t = @{}
    try {
        $obj = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name -eq '_meta') { continue }
            $t[$p.Name] = [string]$p.Value
        }
    } catch { }
    return $t
}

function Get-RvmLanguages {
    # Liefert alle Sprachdateien im Ordner lang (Code, Name, Pfad).
    $dir = Get-RvmLangDir
    $list = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $list }
    foreach ($f in [IO.Directory]::GetFiles($dir, '*.json')) {
        try {
            $obj = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            $code = [IO.Path]::GetFileNameWithoutExtension($f).ToLowerInvariant()
            $name = $code
            $ver = ''
            if ($obj._meta) {
                if ($obj._meta.name) { $name = $obj._meta.name }
                if ($obj._meta.version) { $ver = $obj._meta.version }
            }
            $list += [pscustomobject]@{ Code = $code; Name = $name; Version = $ver; Path = $f }
        } catch { }
    }
    return @($list | Sort-Object Name)
}

function Initialize-RvmLanguage {
    param([string]$Code)
    if (-not $Code) {
        try { $Code = (Get-RvmSettings).Language } catch { $Code = $null }
    }
    $dir = Get-RvmLangDir
    if (-not $Code) {
        $sys = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant()
        if (Test-Path -LiteralPath ([IO.Path]::Combine($dir, "$sys.json"))) { $Code = $sys } else { $Code = 'en' }
    }
    $file = [IO.Path]::Combine($dir, "$Code.json")
    if (-not (Test-Path -LiteralPath $file)) { $Code = 'en'; $file = [IO.Path]::Combine($dir, 'en.json') }
    $script:RvmLang.Code = $Code
    $script:RvmLang.Table = $(if (Test-Path -LiteralPath $file) { Read-RvmLangFile $file } else { @{} })
    $en = [IO.Path]::Combine($dir, 'en.json')
    $script:RvmLang.Fallback = $(if ($Code -ne 'en' -and (Test-Path -LiteralPath $en)) { Read-RvmLangFile $en } else { @{} })
    if ('RVM.DiffEntry' -as [type]) {
        [RVM.DiffEntry]::TxtAdded = T 'chg.added'
        [RVM.DiffEntry]::TxtRemoved = T 'chg.removed'
        [RVM.DiffEntry]::TxtChanged = T 'chg.changed'
        [RVM.DiffEntry]::TxtKey = T 'chg.key'
        [RVM.DiffEntry]::TxtDefault = T 'chg.default'
    }
}

function T {
    # Uebersetzt einen Schluessel. Weitere Argumente werden in {0}, {1} ... eingesetzt.
    param([string]$Key)
    $txt = $script:RvmLang.Table[$Key]
    if ($null -eq $txt) { $txt = $script:RvmLang.Fallback[$Key] }
    if ($null -eq $txt) { $txt = $Key }
    if ($args.Count) {
        try { return ($txt -f $args) } catch { return $txt }
    }
    return $txt
}

# ---------------------------------------------------------------- Sprachen aus dem GitHub-Repository

function Get-RvmLangSourceUrl {
    # API-Adresse des Ordners lang im GitHub-Repository (version.json: LanguageSource oder Repository).
    $v = Read-RvmJson ([IO.Path]::Combine($script:RVM.AppRoot, 'version.json'))
    if (-not $v) { return $null }
    if ($v.LanguageSource) { return [string]$v.LanguageSource }
    if ($v.Repository -match '^https?://github\.com/([^/\s]+)/([^/\s#?]+?)(\.git)?/?$') {
        $branch = if ($v.Branch) { $v.Branch } else { 'main' }
        return ('https://api.github.com/repos/{0}/{1}/contents/lang?ref={2}' -f $Matches[1], $Matches[2], $branch)
    }
    return $null
}

function Get-RvmOnlineLanguages {
    # Liest die verfuegbaren Sprachdateien aus dem Repository. Liefert @{ Ok; Error; Items = (Code, Name, Version, Content) }.
    $url = Get-RvmLangSourceUrl
    if (-not $url) { return @{ Ok = $false; Error = 'nosource'; Items = @() } }
    $raw = Invoke-RvmHttpGet $url
    if (-not $raw) { return @{ Ok = $false; Error = 'offline'; Items = @() } }
    try { $list = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json } catch { return @{ Ok = $false; Error = 'format'; Items = @() } }
    $items = @()
    foreach ($f in @($list)) {
        if (-not $f.name -or $f.name -notmatch '^([a-z]{2,3}(-[A-Za-z]{2,4})?)\.json$' -or -not $f.download_url) { continue }
        $code = $Matches[1].ToLowerInvariant()
        $bytes = Invoke-RvmHttpGet ([string]$f.download_url)
        if (-not $bytes) { continue }
        $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        try { $obj = $text | ConvertFrom-Json } catch { continue }
        if (-not $obj._meta) { continue }
        $items += [pscustomobject]@{
            Code = $code; Name = $(if ($obj._meta.name) { [string]$obj._meta.name } else { $code })
            Version = [string]$obj._meta.version; Content = $text
        }
    }
    return @{ Ok = $true; Error = ''; Items = @($items | Sort-Object Name) }
}

function Install-RvmLanguage {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Content)
    if ($Code -notmatch '^[a-z]{2,3}(-[a-z]{2,4})?$') { throw "Invalid language code: $Code" }
    $null = $Content | ConvertFrom-Json   # muss gueltiges JSON sein
    $dir = Get-RvmLangDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText([IO.Path]::Combine($dir, "$Code.json"), $Content, (New-Object Text.UTF8Encoding($false)))
}
