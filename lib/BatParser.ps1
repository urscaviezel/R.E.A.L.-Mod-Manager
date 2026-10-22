# R.E.A.L. Mod Manager - liest RealConfig.bat aus und leitet daraus die Spieldefinitionen ab.
# So erkennt das Tool neue Spiele automatisch, sobald Luke Ross sie in eine neue Version aufnimmt.

function Read-RealConfig {
    param([Parameter(Mandatory)][string]$BatPath)

    if (-not (Test-Path -LiteralPath $BatPath)) { throw (T 'err.bat.missing' $BatPath) }
    $lines = [IO.File]::ReadAllLines($BatPath, [Text.Encoding]::GetEncoding(1252))

    # --- Erkennungsblock: alles vor dem ersten ":install"-Label
    $firstInstall = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^\s*:install\w+') { $firstInstall = $i; break }
    }
    if ($firstInstall -lt 0) { throw (T 'err.bat.noSections') }

    $detect = New-Object System.Collections.Generic.List[object]
    $rxLine = [regex]'^\s*((?:IF\s+EXIST\s+(?:"[^"]+"|\S+)\s+)+)GOTO\s+install(\w+)\s*$'
    $rxCond = [regex]'IF\s+EXIST\s+(?:"([^"]+)"|(\S+))'
    for ($i = 0; $i -lt $firstInstall; $i++) {
        $m = $rxLine.Match($lines[$i])
        if (-not $m.Success) { continue }
        $patterns = @()
        foreach ($c in $rxCond.Matches($m.Groups[1].Value)) {
            if ($c.Groups[1].Success) { $patterns += $c.Groups[1].Value } else { $patterns += $c.Groups[2].Value }
        }
        $detect.Add([pscustomobject]@{ Label = $m.Groups[2].Value; Patterns = $patterns; Order = $detect.Count })
    }

    # --- Abschnitte einsammeln
    $sections = @{}
    $current = $null
    for ($i = $firstInstall; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*:(\w+)\s*$') {
            $lbl = $Matches[1]
            if ($lbl -match '^install(\w+)$') { $current = $Matches[1]; $sections[$current] = New-Object System.Collections.Generic.List[string]; continue }
            if ($lbl -match '^(?i)(neverrun|abort|finish|end|exitnow|badextract)$') { $current = $null; continue }
            # interne Sprungmarke innerhalb eines Spielabschnitts (z.B. :checkFF7Rprofile) -> Abschnitt geht weiter
        }
        if ($current) { $sections[$current].Add($l) }
    }

    # --- Spieldefinitionen
    $games = New-Object System.Collections.Generic.List[object]
    $byLabel = @{}
    foreach ($label in @($detect | Select-Object -ExpandProperty Label -Unique)) {
        $sec = $sections[$label]
        if (-not $sec) { continue }
        $def = ConvertTo-GameDefinition -Label $label -Section $sec.ToArray()
        $def | Add-Member -NotePropertyName Signatures -NotePropertyValue @($detect | Where-Object { $_.Label -eq $label } | ForEach-Object { , $_.Patterns })
        $def | Add-Member -NotePropertyName DetectOrder -NotePropertyValue (@($detect | Where-Object { $_.Label -eq $label })[0].Order)
        $games.Add($def)
        $byLabel[$label] = $def
    }

    return [pscustomobject]@{
        BatPath    = $BatPath
        Detect     = $detect.ToArray()
        Games      = $games.ToArray()
        ByLabel    = $byLabel
    }
}

function ConvertTo-GameDefinition {
    param([string]$Label, [string[]]$Section)

    $active = @($Section | Where-Object { $_ -notmatch '^\s*(REM\s|::)' })
    $text = $active -join "`n"

    # Spielname aus dem ECHO-Kasten nach "Detected game:"
    $name = $Label
    for ($i = 0; $i -lt $Section.Length; $i++) {
        if ($Section[$i] -match 'Detected game:') {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $Section.Length); $j++) {
                if ($Section[$j] -match '^\s*ECHO\s+\*\s*(.+?)\s*\*\s*$') { $name = $Matches[1].Trim(); break }
            }
            break
        }
    }
    # Aeltere Versionen (z.B. v19): "ECHO * R.E.A.L. VR mod for Elden Ring *"
    if ($name -eq $Label) {
        foreach ($l in $Section) {
            if ($l -match '^\s*ECHO\s+\*\s*R\.E\.A\.L\.(?:\s+VR)?\s+mod\s+for\s+(.+?)\s*\*\s*$') { $name = $Matches[1].Trim(); break }
        }
    }

    $repo = $Label
    if ($text -match 'IF\s+/I\s+NOT\s+%%~nD==(\w+)') { $repo = $Matches[1] }

    $regImports = @([regex]::Matches($text, '(?im)^\s*REG\s+IMPORT\s+("?)([^"\r\n]+)\1\s*$') | ForEach-Object { $_.Groups[2].Value.Trim() })
    $regQueries = @([regex]::Matches($text, '(?i)REG\s+QUERY\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $vdesync = @([regex]::Matches($text, '(?im)^\s*RealRepo\\Vdesync\s+"%base%([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

    # Choice-Abfragen (z.B. Qualitätsstufe bei Elden Ring)
    $choices = @()
    foreach ($m in [regex]::Matches($text, '(?i)CHOICE\s+/C\s+(\w+)\s+/M\s+"([^"]+)"')) {
        $letters = $m.Groups[1].Value.ToUpperInvariant()
        if ($letters -in @('AC', 'KD')) { continue }
        $choices += $m.Groups[2].Value
    }

    # Relative Pfade ausserhalb des Spielordners (z.B. ..\..\user.cfg, ..\..\..\Engine\...\openxr_loader.dll)
    $relPaths = @()
    foreach ($m in [regex]::Matches($text, '(?:%base%)?((?:\.\.\\)+[^"\s]*)')) {
        $relPaths += $m.Groups[1].Value
    }

    # SET-Zeilen für die Pfadauflösung
    $setLines = @()
    foreach ($l in $active) {
        if ($l -match '^\s*SET\s+/') { continue }
        if ($l -match '^\s*SET\s+"?([A-Za-z0-9_]+)=(.*?)"?\s*$') {
            $setLines += [pscustomobject]@{ Name = $Matches[1]; Value = $Matches[2] }
        }
    }

    # Dateien, die direkt im Spielordner angelegt/ersetzt werden
    $targetsBase = @()
    foreach ($m in [regex]::Matches($text, '(?im)COPY\s+/Y\s+\S+\s+("?)([^"\r\n]+)\1\s*$')) {
        $t = $m.Groups[2].Value.Trim()
        if ($t -notmatch '%') { $targetsBase += $t }
    }

    return [pscustomobject]@{
        Label          = $Label
        Name           = $name
        RepoFolder     = $repo
        OnlineWarning  = [bool]($text -match '(?i)SET\s+/P\s+accept')
        UsesVulkan     = [bool]($text -match '(?i)ImplicitLayers')
        UsesProgData   = [bool]($text -match '(?i)%prog%')
        NeedsFirstRun  = [bool]($text -match '(?i)GOTO\s+neverrun' -or $text -match '(?i)appears to never have been run')
        RegImports     = $regImports
        RegQueryKeys   = $regQueries
        VdesyncExes    = $vdesync
        Choices        = $choices
        RelativePaths  = @($relPaths | Select-Object -Unique)
        SetLines       = $setLines
        BaseTargets    = @($targetsBase | Select-Object -Unique)
        ReplacesLauncher = [bool]($text -match '(?i)start_protected_game_ori')
        DeletesGameFiles = @([regex]::Matches($text, '(?im)^\s*DEL\s+/F\s+/Q\s+(\.\.\\\S+)') | ForEach-Object { $_.Groups[1].Value })
        SectionText    = ($Section -join "`r`n")
    }
}

function Expand-BatVars {
    param([string]$Value, [hashtable]$Vars)
    return [regex]::Replace($Value, '%(\w+)%', {
            param($m)
            $k = $m.Groups[1].Value
            foreach ($key in $Vars.Keys) { if ($key -ieq $k) { return [string]$Vars[$key] } }
            return $m.Value
        })
}

function Get-GameSettingsPaths {
    # Ermittelt die Einstellungsordner ausserhalb des Spielordners, die RealConfig.bat anfasst.
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)][string]$GameDir)

    $sp = Get-StdPaths
    $base = $GameDir.TrimEnd('\', '/') + '\'
    $vars = @{ base = $base }
    foreach ($k in $sp.Keys) { $vars[$k] = $sp[$k] }

    $roots = @($vars.Values | Where-Object { $_ } | ForEach-Object { ConvertTo-NativePath ([string]$_) })
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Def.SetLines) {
        if ($s.Value -match ':') { continue }               # %x:"=% usw.
        $variants = @($s.Value)
        if ($s.Value -match '(?i)%doc%') {
            $variants = @('doc', 'doc1', 'doc2') | ForEach-Object { $s.Value -ireplace '%doc%', ('%' + $_ + '%') }
        }
        $expanded = @($variants | ForEach-Object { Expand-BatVars -Value $_ -Vars $vars })
        $vars[$s.Name] = $expanded[0]
        if ($s.Name -match '^(?i)(dst\w*|wne)$') {
            foreach ($e in $expanded) {
                if ($e -match '%') { continue }
                $ne = ConvertTo-NativePath $e
                $rooted = $false
                foreach ($r in $roots) { if ($r -and $ne.StartsWith($r.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $rooted = $true; break } }
                if (-not $rooted) { continue }
                $full = (Get-FullPathSafe $e).TrimEnd('\', '/')
                if (-not $result.Contains($full)) { $result.Add($full) }
            }
        }
    }
    return $result.ToArray()
}
