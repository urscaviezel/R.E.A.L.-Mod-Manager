# R.E.A.L. Mod Manager - Cover-Bilder
# Ansatz nach DLSS5 Autopilot (MIT): zuerst lokal (eigene Bilder, Steams Bildercache), online nur mit Zustimmung:
# Epic-Katalog-Cache -> Epic-CDN, sonst Steam-Store-Suche nach Name -> Steam-CDN. Alles landet in Data\Covers\<key>.

$script:CoverMissTtlSec = 7 * 24 * 3600
$script:CoverFailTtlSec = 24 * 3600
$script:CoverLookupVersion = 4   # erhoeht = alte 'nicht gefunden'-Eintraege werden neu versucht

function Get-CoverKey {
    param([string]$Folder)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $n = $null
        if (-not $Folder.StartsWith('mod:')) { $n = (ConvertTo-CanonicalDir $Folder) }
        if (-not $n) { $n = $Folder }
        $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($n.ToLowerInvariant()))
        return (($b[0..9] | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-CoverDir {
    param($Game)
    $f = if ($Game.RootFolder) { $Game.RootFolder } else { $Game.Folder }
    return [IO.Path]::Combine((Get-RvmDir Covers), (Get-CoverKey $f))
}

function Get-ImageExt {
    param([byte[]]$Data)
    if (-not $Data -or $Data.Length -lt 16) { return $null }
    if ($Data[0] -eq 0xFF -and $Data[1] -eq 0xD8 -and $Data[2] -eq 0xFF) { return '.jpg' }
    if ($Data[0] -eq 0x89 -and $Data[1] -eq 0x50 -and $Data[2] -eq 0x4E -and $Data[3] -eq 0x47) { return '.png' }
    return $null
}

function Find-ImageFile {
    param([string]$Dir, [string]$Prefix, [string]$Kind)
    foreach ($ext in @('.jpg', '.png')) {
        $p = [IO.Path]::Combine($Dir, "$Prefix$Kind$ext")
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-SteamCacheImage {
    param([string]$AppId, [string[]]$Names)
    $root = Get-SteamRoot
    if (-not $root -or -not $AppId) { return $null }
    $base = [IO.Path]::Combine($root, 'appcache', 'librarycache')
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    $dir = [IO.Path]::Combine($base, $AppId)
    foreach ($n in $Names) {
        $flat = [IO.Path]::Combine($base, "${AppId}_$n")
        if (Test-Path -LiteralPath $flat) { return $flat }
        if (Test-Path -LiteralPath $dir) {
            $p = [IO.Path]::Combine($dir, $n)
            if (Test-Path -LiteralPath $p) { return $p }
            foreach ($sub in [IO.Directory]::GetDirectories($dir)) {
                $p = [IO.Path]::Combine($sub, $n)
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    }
    return $null
}

function Get-GameArt {
    # Liefert die lokalen Bildpfade (Cover, Hero) fuer ein Spiel - ohne Internet.
    param($Game)
    $dir = Get-CoverDir $Game
    $cover = Find-ImageFile $dir 'user-' 'cover'
    $hero = Find-ImageFile $dir 'user-' 'hero'
    if ($Game.AppId) {
        if (-not $cover) { $cover = Find-SteamCacheImage $Game.AppId @('library_600x900.jpg', 'library_capsule.jpg') }
        if (-not $hero) { $hero = Find-SteamCacheImage $Game.AppId @('library_hero.jpg') }
    }
    if (-not $cover) { $cover = Find-ImageFile $dir 'got-' 'cover' }
    if (-not $hero) { $hero = Find-ImageFile $dir 'got-' 'hero' }
    return [pscustomobject]@{ Cover = $cover; Hero = $hero }
}

function Set-UserCover {
    # Eigenes Bild fuer ein Spiel setzen (wird kopiert).
    param($Game, [string]$File, [ValidateSet('cover', 'hero')][string]$Kind = 'cover')
    $bytes = [IO.File]::ReadAllBytes($File)
    $ext = Get-ImageExt $bytes
    if (-not $ext) { throw (T 'cover.err.format') }
    $dir = Get-CoverDir $Game
    [void](New-Item -ItemType Directory -Path $dir -Force)
    foreach ($e in @('.jpg', '.png')) { $o = [IO.Path]::Combine($dir, "user-$Kind$e"); if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force } }
    [IO.File]::WriteAllBytes([IO.Path]::Combine($dir, "user-$Kind$ext"), $bytes)
}

function Get-UserArt {
    # Welche eigenen Bilder gibt es fuer ein Spiel? (Cover, Hero = Bild der Detailseite)
    param($Game)
    $dir = Get-CoverDir $Game
    return [pscustomobject]@{ Cover = (Find-ImageFile $dir 'user-' 'cover'); Hero = (Find-ImageFile $dir 'user-' 'hero') }
}

function Remove-UserCover {
    # Eigenes Bild entfernen -> wieder das Original (Steam-Cache bzw. heruntergeladen) verwenden.
    param($Game, [ValidateSet('cover', 'hero')][string]$Kind)
    $dir = Get-CoverDir $Game
    foreach ($e in @('.jpg', '.png')) { $o = [IO.Path]::Combine($dir, "user-$Kind$e"); if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force } }
}

# ---------------------------------------------------------------- Online (nur mit Zustimmung)

function ConvertTo-NormName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $s = $Name -replace '[™®©]', '' -replace '[''`‘’´]', ''
    $s = $s -replace '\(\d{4}\)', ''
    $s = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$sb.Append($ch) } }
    $s = $sb.ToString().ToLowerInvariant().Replace('&', ' and ')
    $s = $s -replace '[^0-9a-z]+', ' '
    return (($s -split '\s+') | Where-Object { $_ }) -join ' '
}

function Remove-EditionSuffix {
    param([string]$N, [switch]$Loose)
    $r = ($N -replace '(?:\s+the)?\s+(?:(?:complete|definitive|enhanced|deluxe|digital deluxe|standard|ultimate|gold|premium|special|anniversary|collectors|legendary|game of the year|goty)\s+edition|directors cut|goty)$', '').Trim()
    if (-not $Loose) { return $r }
    # einzelnes Zusatzwort, z.B. "Crimson Desert Enhanced"
    return ($r -replace '\s+(?:enhanced|remastered|definitive|complete|redux|deluxe|ultimate)$', '').Trim()
}

function Get-SteamSearchCandidates {
    # Liefert (Id, Name)-Paare aus der Steam-Store-Suche; 'offline' wenn Steam nicht erreichbar.
    param([string]$Term)
    $q = [Uri]::EscapeDataString($Term)
    $out = @()
    $raw = Invoke-RvmHttpGet "https://store.steampowered.com/api/storesearch/?term=$q&l=english&cc=CH"
    if (-not $raw) { return 'offline' }
    try {
        $j = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
        foreach ($i in @($j.items)) { if ($i.id -and $i.name -and (-not $i.type -or $i.type -eq 'app')) { $out += [pscustomobject]@{ Id = [string]$i.id; Name = [string]$i.name } } }
    } catch { }
    return $out
}

function Get-SteamSuggestCandidates {
    # Zweite Quelle: Vorschlagsliste der Steam-Suche (findet auch neue/vorbestellbare Spiele).
    param([string]$Term)
    $q = [Uri]::EscapeDataString($Term)
    $raw = Invoke-RvmHttpGet "https://store.steampowered.com/search/suggest?term=$q&f=games&cc=CH&realm=1&l=english"
    if (-not $raw) { return @() }
    $html = [Text.Encoding]::UTF8.GetString($raw)
    $out = @()
    foreach ($m in [regex]::Matches($html, '(?s)data-ds-appid="(\d+)".*?class="match_name"[^>]*>([^<]+)<')) {
        $out += [pscustomobject]@{ Id = $m.Groups[1].Value; Name = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim() }
    }
    return $out
}

function Select-SteamCandidate {
    # Waehlt aus den Kandidaten das passende Spiel (exakt, ohne Edition-Zusatz, eindeutiger Untertitel).
    param([string]$Name, $Apps)
    $g = ConvertTo-NormName $Name
    $gs = Remove-EditionSuffix $g
    foreach ($a in $Apps) { if ((ConvertTo-NormName $a.Name) -eq $g) { return $a.Id } }
    $addon = '\b(dlc|soundtrack|ost|pack|bundle|upgrade|demo|season pass|expansion|artbook|trial|benchmark|playtest)\b'
    foreach ($a in $Apps) {
        $n = ConvertTo-NormName $a.Name
        if ((Remove-EditionSuffix $n) -eq $gs -and $n -notmatch $addon) { return $a.Id }
    }
    $gl = Remove-EditionSuffix $g -Loose
    foreach ($a in $Apps) {
        $n = ConvertTo-NormName $a.Name
        if ((Remove-EditionSuffix $n -Loose) -eq $gl -and $n -notmatch $addon) { return $a.Id }
    }
    if (($gs -split ' ').Count -ge 2) {
        $subs = @($Apps | Where-Object { $_.Name -match ':' } | Where-Object {
                $parts = $_.Name.Split(':', 2)
                (Remove-EditionSuffix (ConvertTo-NormName $parts[0])) -eq $gs -and (ConvertTo-NormName $parts[1]) -notmatch $addon
            })
        if (@($subs | Select-Object -ExpandProperty Id -Unique).Count -eq 1) { return $subs[0].Id }
    }
    return $null
}

function Find-SteamAppIdByName {
    param([string]$Name)
    # Jahreszahl in Klammern ("DOOM (2016)") stoert die Steam-Suche
    $term = ($Name -replace '\(\d{4}\)', '' -replace '[™®©]', '').Trim()
    $apps = Get-SteamSearchCandidates $term
    if ($apps -is [string] -and $apps -eq 'offline') { return 'offline' }
    $id = Select-SteamCandidate $Name @($apps)
    if ($id) { return $id }
    $id = Select-SteamCandidate $Name @(Get-SteamSuggestCandidates $term)
    if ($id) { return $id }
    # Editionen sind bei Steam oft Bundles, die die Suche nicht liefert ("Ghostrunner: Complete Edition") -> Grundname suchen
    $base = Remove-EditionSuffix (ConvertTo-NormName $Name)
    if ($base -and $base -ne (ConvertTo-NormName $term)) {
        $apps2 = Get-SteamSearchCandidates $base
        if (-not ($apps2 -is [string])) { $id = Select-SteamCandidate $Name @($apps2) }
    }
    return $id
}

function Get-SteamArtUrls {
    param([string]$AppId)
    $f = "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/$AppId/"
    $c = "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/"
    $out = @{ cover = @(); hero = @() }
    # Neuere Apps legen die Bilder in einem Hash-Ordner ab -> Asset-Liste des Stores
    $q = '{"ids":[{"appid":' + $AppId + '}],"context":{"language":"english","country_code":"US"},"data_request":{"include_assets":true}}'
    $raw = Invoke-RvmHttpGet ("https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=" + [Uri]::EscapeDataString($q))
    if ($raw) {
        try {
            $j = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
            $a = $j.response.store_items[0].assets
            if ($a -and $a.asset_url_format) {
                $fmt = 'https://shared.fastly.steamstatic.com/store_item_assets/' + $a.asset_url_format
                foreach ($n in @('library_capsule_2x', 'library_capsule')) { if ($a.$n) { $out.cover += $fmt.Replace('${FILENAME}', $a.$n) } }
                if ($a.library_hero) { $out.hero += $fmt.Replace('${FILENAME}', $a.library_hero) }
            }
        } catch { }
    }
    $out.cover += @("${f}library_600x900_2x.jpg", "${f}library_600x900.jpg", "${c}library_600x900.jpg")
    $out.hero += @("${f}library_hero.jpg", "${c}library_hero.jpg")
    return $out
}

$script:EpicCatalog = $null
function Get-EpicArtUrls {
    param([string]$ItemId, [string]$Namespace)
    if (-not $ItemId) { return $null }
    if ($null -eq $script:EpicCatalog) {
        $script:EpicCatalog = @{}
        $f = [IO.Path]::Combine($env:ProgramData, 'Epic', 'EpicGamesLauncher', 'Data', 'Catalog', 'catcache.bin')
        if ((Test-Path -LiteralPath $f) -and (New-Object IO.FileInfo($f)).Length -lt 64MB) {
            try {
                $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([IO.File]::ReadAllText($f)).Trim()))
                Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
                $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $ser.MaxJsonLength = [int]::MaxValue
                foreach ($it in $ser.DeserializeObject($json)) { if ($it['id']) { $script:EpicCatalog[$it['id']] = $it } }
            } catch { }
        }
    }
    $item = $script:EpicCatalog[$ItemId]
    if (-not $item) { return $null }
    $imgs = @($item['keyImages'])
    $pick = { param($types) foreach ($t in $types) { foreach ($k in $imgs) { if ($k['type'] -eq $t -and ([string]$k['url']).StartsWith('https://')) { return $k['url'] } } }; return $null }
    $c = & $pick @('DieselGameBoxTall', 'OfferImageTall', 'DieselStoreFrontTall')
    $h = & $pick @('DieselGameBox', 'DieselGameBoxWide', 'OfferImageWide')
    return @{ cover = @($c | Where-Object { $_ }); hero = @($h | Where-Object { $_ }) }
}

function Save-DownloadedImage {
    param([string]$Dir, [string]$Kind, [string[]]$Urls)
    foreach ($u in $Urls) {
        $data = Invoke-RvmHttpGet $u
        $ext = Get-ImageExt $data
        if (-not $ext) { continue }
        [void](New-Item -ItemType Directory -Path $Dir -Force)
        [IO.File]::WriteAllBytes([IO.Path]::Combine($Dir, "got-$Kind$ext"), $data)
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- Spiel-Infos (Hersteller, Release, Beschreibung, Shop)

function Get-GameInfo {
    # Gecachte Shop-Infos (Data\Covers\<key>\info.json) - ohne Internet.
    param($Game)
    $i = Read-RvmJson ([IO.Path]::Combine((Get-CoverDir $Game), 'info.json'))
    return $i
}

function Get-ShopUrl {
    param($Game, $Info)
    $id = if ($Game.AppId) { $Game.AppId } elseif ($Info -and $Info.AppId) { $Info.AppId } else { $null }
    if ($id) { return "https://store.steampowered.com/app/$id/" }
    return ('https://store.steampowered.com/search/?term=' + [Uri]::EscapeDataString($Game.Name))
}

function ConvertFrom-HtmlText {
    param([string]$Html)
    if (-not $Html) { return '' }
    $t = $Html -replace '(?i)<br\s*/?>', "`n" -replace '<[^>]+>', ''
    return ([System.Net.WebUtility]::HtmlDecode($t)).Trim()
}

function Get-SteamAppDetails {
    param([string]$AppId)
    $lang = switch ($script:RvmLang.Code) { 'de' { 'german' } 'fr' { 'french' } default { 'english' } }
    $raw = Invoke-RvmHttpGet "https://store.steampowered.com/api/appdetails?appids=$AppId&l=$lang&cc=CH"
    if (-not $raw) { return $null }
    try { $j = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json } catch { return $null }
    $e = $j.$AppId
    if (-not $e -or -not $e.success) { return $null }
    $d = $e.data
    return [ordered]@{
        Name        = [string]$d.name
        AppId       = $AppId
        Developers  = @($d.developers | Where-Object { $_ })
        Publishers  = @($d.publishers | Where-Object { $_ })
        Release     = $(if ($d.release_date) { [string]$d.release_date.date } else { '' })
        Genres      = @($d.genres | ForEach-Object { $_.description } | Where-Object { $_ })
        Description = (ConvertFrom-HtmlText ([string]$d.short_description))
        Lang        = $script:RvmLang.Code
        Fetched     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Update-GameArtOnline {
    # Laedt fehlende Cover nach (nur wenn in den Einstellungen erlaubt). Liefert die Anzahl neuer Bilder.
    param($Games)
    if ((Get-RvmSettings).OnlineCovers -ne $true) { return 0 }
    $new = 0
    $offline = 0
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($g in $Games) {
        $art = Get-GameArt $g
        $dir = Get-CoverDir $g
        $needInfo = [bool]$g.NeedInfo
        if ($needInfo) {
            $inf = Read-RvmJson ([IO.Path]::Combine($dir, 'info.json'))
            if ($inf -and ($inf.Lang -eq $script:RvmLang.Code -or $inf.Miss)) { $needInfo = $false }
            if ($inf -and $inf.Miss -and (([int]$inf.V -lt $script:CoverLookupVersion) -or ($inf.For -and $inf.For -ne $g.Name) -or ($now - [int64]$inf.Miss) -gt $script:CoverMissTtlSec)) { $needInfo = $true }
        }
        if ($art.Cover -and $art.Hero -and -not $needInfo) { continue }
        $metaFile = [IO.Path]::Combine($dir, 'meta.json')
        $meta = Read-RvmJson $metaFile
        # gilt nur fuer dieselbe Version der Suche und denselben Spielnamen (aeltere Mod-Versionen hatten z.B. nur Kuerzel)
        $metaOk = $meta -and [int]$meta.V -ge $script:CoverLookupVersion -and (-not $meta.Name -or $meta.Name -eq $g.Name)
        if (-not $needInfo -and $metaOk -and $meta.Miss -and ($now - [int64]$meta.Miss) -lt [int64]$meta.Ttl) { continue }
        # Cover vorhanden, nur das grosse Bild fehlt und wurde kuerzlich vergeblich gesucht
        if (-not $needInfo -and $art.Cover -and $metaOk -and $meta.HeroMiss -and ($now - [int64]$meta.HeroMiss) -lt $script:CoverMissTtlSec) { continue }

        Write-RvmLog (T 'log.cover.lookup' $g.Name)
        $urls = $null
        if ($g.EpicItem) { $urls = Get-EpicArtUrls $g.EpicItem $g.EpicNs }
        $appid = $g.AppId
        $looked = $false
        if ((-not $urls -or -not $urls.cover.Count) -or $needInfo) {
            if (-not $appid) {
                $appid = Find-SteamAppIdByName $(if ($g.StoreName) { $g.StoreName } else { $g.Name })
                $looked = $true
                if ($appid -eq 'offline') {
                    # einzelne Zeitueberschreitung ist kein Grund, alles abzubrechen
                    $offline++
                    if ($offline -ge 2) { Write-RvmLog (T 'log.cover.offline') WARN; return $new }
                    continue
                }
                $offline = 0
            }
        }
        if (-not $urls -or -not $urls.cover.Count) {
            if ($appid -and -not ($art.Cover -and $art.Hero)) { $urls = Get-SteamArtUrls $appid }
        }
        if ($needInfo) {
            $info = $null
            if ($appid) { $info = Get-SteamAppDetails $appid }
            if ($info) { Write-RvmJson -Path ([IO.Path]::Combine($dir, 'info.json')) -Object $info }
            else { [void](New-Item -ItemType Directory -Path $dir -Force); Write-RvmJson -Path ([IO.Path]::Combine($dir, 'info.json')) -Object @{ Miss = $now; AppId = $appid; V = $script:CoverLookupVersion; For = $g.Name } }
        }
        $got = $false
        if ($urls) {
            if (-not $art.Cover -and $urls.cover.Count) { if (Save-DownloadedImage $dir 'cover' $urls.cover) { $got = $true; $new++ } }
            if (-not $art.Hero -and $urls.hero.Count) { if (Save-DownloadedImage $dir 'hero' $urls.hero) { $got = $true } }
        }
        $art2 = Get-GameArt $g
        if (-not $art2.Cover) {
            Write-RvmJson -Path $metaFile -Object @{ Miss = $now; Ttl = $script:CoverMissTtlSec; Name = $g.Name; V = $script:CoverLookupVersion }
        } elseif (-not $art2.Hero) {
            Write-RvmJson -Path $metaFile -Object @{ HeroMiss = $now; Name = $g.Name; V = $script:CoverLookupVersion }
        } elseif (Test-Path -LiteralPath $metaFile) { Remove-Item -LiteralPath $metaFile -Force }
    }
    return $new
}
