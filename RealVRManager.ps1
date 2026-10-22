# R.E.A.L. Mod Manager
# Installer / Uninstaller fuer Luke Ross' R.E.A.L. VR Mod mit vollstaendigem Aenderungsprotokoll.
# Start: Start-RealVRManager.cmd (fordert Administratorrechte an).
# Lizenz: GPL-3.0-or-later
param([switch]$DebugConsole)

$ErrorActionPreference = 'Stop'
$AppRoot = $PSScriptRoot

if ($env:OS -ne 'Windows_NT') { Write-Host 'Windows only.'; exit 1 }

# ---------------------------------------------------------------- Adminrechte
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA')
    if ($DebugConsole) { $argList += '-NoExit' } else { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', ('"{0}"' -f $PSCommandPath))
    if ($DebugConsole) { $argList += '-DebugConsole' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null }
    catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show('R.E.A.L. Mod Manager needs administrator rights. / Benötigt Administratorrechte.', 'R.E.A.L. Mod Manager', 'OK', 'Warning')
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------- nur eine Instanz (auch fuer den Installer: AppMutex)
$createdNew = $false
$AppMutex = New-Object Threading.Mutex($true, 'RealModManager', [ref]$createdNew)
if (-not $createdNew) {
    [void][System.Windows.MessageBox]::Show('R.E.A.L. Mod Manager is already running. / Läuft bereits.', 'R.E.A.L. Mod Manager', 'OK', 'Information')
    exit
}

function Show-Fatal { param($Msg) [void][System.Windows.MessageBox]::Show($Msg, 'R.E.A.L. Mod Manager', 'OK', 'Error') }

try {
    Get-ChildItem -LiteralPath $AppRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    . ([IO.Path]::Combine($AppRoot, 'lib', 'LoadAll.ps1'))
    $Shared = [hashtable]::Synchronized(@{
            LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
            AppRoot  = $AppRoot
        })
    Initialize-RVM -AppRoot $AppRoot -Shared $Shared
    $Version = Read-RvmJson ([IO.Path]::Combine($AppRoot, 'version.json'))
    if (-not $Version) { $Version = [pscustomobject]@{ Version = '0.0.0'; BuildDate = ''; Channel = ''; License = 'GPL-3.0-or-later'; Repository = '' } }

    if (-not ('RvmDwm' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class RvmDwm { [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size); }'
    }

    # Anwendung + Stile + Farben (Farben sind DynamicResources und koennen live umgeschaltet werden)
    $App = [System.Windows.Application]::Current
    if (-not $App) { $App = New-Object System.Windows.Application; $App.ShutdownMode = 'OnExplicitShutdown' }
    $ThemeDict = New-Object System.Windows.ResourceDictionary
    $App.Resources.MergedDictionaries.Add($ThemeDict)
    $Styles = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText([IO.Path]::Combine($AppRoot, 'ui', 'Styles.xaml')))
} catch {
    Show-Fatal ("Start failed:`n`n{0}`n`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}

# ================================================================ Farben / Design

$Themes = @{
    # angelehnt an PFDhub: tiefes Navy, Cyan als Akzent, Mint fuer "ok"
    dark  = @{ Bg = '#07111F'; Surface = '#0C1A2C'; Surface2 = '#12253B'; Line = '#1D3550'; Hover = '#16304A'; Selected = '#0F3A4D'
        Text = '#EAF2FA'; Muted = '#93A7BC'; Dim = '#5B7590'; Accent = '#1FC8EE'; AccentText = '#04121F'; Ok = '#4BEBC9'; Warn = '#F2A93B'; Danger = '#F26B5E'; DangerBg = '#3A1A22' }
    light = @{ Bg = '#F2F6FA'; Surface = '#FFFFFF'; Surface2 = '#E4ECF4'; Line = '#CCD9E6'; Hover = '#DCE7F1'; Selected = '#CDEFF7'
        Text = '#0B1A2C'; Muted = '#48607A'; Dim = '#8AA0B6'; Accent = '#0A8FB0'; AccentText = '#FFFFFF'; Ok = '#0E9C7A'; Warn = '#B7791F'; Danger = '#D04A3E'; DangerBg = '#F8DEDB' }
}
$CurrentColors = $Themes.dark

function Get-EffectiveTheme {
    param([string]$Setting)
    if ($Setting -eq 'light') { return 'light' }
    if ($Setting -eq 'system') {
        $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'
        if ($v -eq 1) { return 'light' } else { return 'dark' }
    }
    return 'dark'
}

function Set-Theme {
    param([string]$Setting)
    $name = Get-EffectiveTheme $Setting
    $script:CurrentColors = $Themes[$name]
    foreach ($k in $CurrentColors.Keys) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($CurrentColors[$k]))
        $b.Freeze()
        if ($ThemeDict.Contains($k)) { $ThemeDict.Remove($k) }
        $ThemeDict.Add($k, [System.Windows.Media.SolidColorBrush]$b)
    }
    if ($script:Window) { Set-DarkTitleBar $script:Window ($name -eq 'dark') }
    foreach ($m in @($UI.miThemeDark, $UI.miThemeLight, $UI.miThemeSystem)) { if ($m) { $m.IsChecked = $false } }
    switch ($Setting) { 'light' { if ($UI.miThemeLight) { $UI.miThemeLight.IsChecked = $true } } 'system' { if ($UI.miThemeSystem) { $UI.miThemeSystem.IsChecked = $true } } default { if ($UI.miThemeDark) { $UI.miThemeDark.IsChecked = $true } } }
}

function Set-DarkTitleBar {
    param($Win, [bool]$Dark)
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $v = [int]$Dark
        if ([RvmDwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) -ne 0) { [void][RvmDwm]::DwmSetWindowAttribute($h, 19, [ref]$v, 4) }
    } catch { }
}

$UI = @{}
Set-Theme (Get-RvmSettings).Theme
$App.Resources.MergedDictionaries.Add($Styles)

try {
    $xamlText = [regex]::Replace([IO.File]::ReadAllText([IO.Path]::Combine($AppRoot, 'ui', 'MainWindow.xaml')), '^\s*<\?xml[^>]*\?>', '')
    $Window = [Windows.Markup.XamlReader]::Parse($xamlText)
} catch {
    $detail = $_.Exception.ToString()
    try {
        $dump = "Theme keys: " + (($ThemeDict.Keys | ForEach-Object { '{0}={1}' -f $_, $ThemeDict[$_].GetType().FullName }) -join '; ') + "`r`n`r`n" + $detail
        [IO.File]::WriteAllText([IO.Path]::Combine((Get-RvmDir Logs), 'ui-error.txt'), $dump, [Text.Encoding]::UTF8)
    } catch { }
    $inner = $_.Exception; $msgs = @()
    while ($inner) { $msgs += $inner.Message; $inner = $inner.InnerException }
    Show-Fatal ("UI failed to load:`n`n{0}" -f ($msgs -join "`n`n-> "))
    exit 1
}
foreach ($n in @('mainMenu', 'miImportZip', 'miImportFolder', 'miModVersions', 'miRemoveMod', 'miOpenData', 'miCleanup', 'miExit', 'miLibrary', 'miRescan', 'miFullScan',
        'miAddFolder', 'miManageFolders', 'miRegistry', 'miRestorePoint', 'miRegExport', 'miLog', 'miLanguage', 'miThemeDark', 'miThemeLight', 'miThemeSystem',
        'miOnlineCovers', 'miGuide', 'miBuildInfo', 'miUpdate',
        'imgLogo', 'bdOnlineHint', 'btnEnableOnline', 'btnRemovePic',
        'pageLibrary', 'txtLibSub', 'btnScan', 'txtSearch', 'txtSearchHint', 'chipAll', 'chipInstalled', 'chipUpdate', 'chipNot', 'txtModVersion', 'icGames', 'txtEmpty',
        'pageDetail', 'imgHero', 'btnBack', 'btnChangePic', 'txtDetailName', 'pnlChips', 'txtDetailState', 'bdCompat', 'txtCompat', 'btnInstall', 'btnUpdate', 'txtUpdateBtn',
        'btnUninstall', 'btnOpenFolder', 'btnShop', 'txtShopBtn', 'btnOpenJournal', 'txtAbout', 'txtDetailInfo',
        'pageRegistry', 'txtRegName', 'btnRegSnap', 'btnRegExport', 'btnRestorePoint', 'btnRegCompare', 'btnRegDelete', 'lstSnapshots', 'gridReg', 'btnRegRestore', 'btnRegSelectAll', 'txtRegInfo',
        'pageLog', 'btnClearLog', 'btnOpenLogs', 'txtLog', 'btnLogToggle', 'prgBusy', 'txtSys', 'txtStatus')) {
    $UI[$n] = $Window.FindName($n)
}
Set-Theme (Get-RvmSettings).Theme   # Menue-Haken setzen
$LogoIco = [IO.Path]::Combine($AppRoot, 'assets', 'logo.ico')
$LogoPng = [IO.Path]::Combine($AppRoot, 'assets', 'logo.png')
try { if (Test-Path -LiteralPath $LogoIco) { $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($LogoIco)) } } catch { }

$State = @{
    Mods         = @()
    Mod          = $null
    Sys          = $null
    Rows         = @()
    Detail       = $null
    Page         = 'library'
    PrevPage     = 'library'
    Task         = $null
    BgTask       = $null
    RegDiffs     = @()
    RegVsCurrent = $false
    CoverPending = $false
    LogFile      = [IO.Path]::Combine((Get-RvmDir Logs), ('{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')))
}
$ActionControls = @('btnScan', 'btnInstall', 'btnUpdate', 'btnUninstall', 'btnRegSnap', 'btnRegExport', 'btnRestorePoint', 'btnRegCompare', 'btnRegDelete', 'btnRegRestore',
    'miImportZip', 'miImportFolder', 'miModVersions', 'miRemoveMod', 'miRescan', 'miFullScan', 'miAddFolder', 'miManageFolders', 'miRestorePoint', 'miRegExport', 'miLanguage', 'btnChangePic', 'miCleanup')

# ================================================================ Uebersetzung der Oberflaeche

$TrList = New-Object System.Collections.Generic.List[object]
function Register-Translations {
    param($Obj)
    if ($null -eq $Obj -or -not ($Obj -is [System.Windows.DependencyObject])) { return }
    if ($Obj -is [System.Windows.Controls.TextBlock]) {
        if ($Obj.Text -and $Obj.Text.StartsWith('@')) { $TrList.Add(@($Obj, 'Text', $Obj.Text.Substring(1))) }
    } elseif ($Obj -is [System.Windows.Controls.HeaderedItemsControl]) {
        if ($Obj.Header -is [string] -and $Obj.Header.StartsWith('@')) { $TrList.Add(@($Obj, 'Header', $Obj.Header.Substring(1))) }
    } elseif ($Obj -is [System.Windows.Controls.ContentControl]) {
        if ($Obj.Content -is [string] -and $Obj.Content.StartsWith('@')) { $TrList.Add(@($Obj, 'Content', $Obj.Content.Substring(1))) }
    }
    if ($Obj -is [System.Windows.FrameworkElement] -and $Obj.ToolTip -is [string] -and $Obj.ToolTip.StartsWith('@')) { $TrList.Add(@($Obj, 'ToolTip', $Obj.ToolTip.Substring(1))) }
    if ($Obj -is [System.Windows.Controls.DataGrid]) {
        foreach ($c in $Obj.Columns) { if ($c.Header -is [string] -and $c.Header.StartsWith('@')) { $TrList.Add(@($c, 'Header', $c.Header.Substring(1))) } }
    }
    foreach ($ch in [System.Windows.LogicalTreeHelper]::GetChildren($Obj)) { Register-Translations $ch }
}
function Apply-Translations {
    foreach ($t in $TrList) { try { $t[0].($t[1]) = (T $t[2]) } catch { } }
    $Window.Title = 'R.E.A.L. Mod Manager ' + $Version.Version + $(if ($Version.Channel) { " ($($Version.Channel))" } else { '' })
}

# ================================================================ Hintergrund-Aufgaben

function Start-RvmTask {
    # -Background: laeuft parallel ohne die Oberflaeche zu sperren (z.B. Cover laden)
    param([string]$Title, [scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnDone, $Context = $null, [switch]$Background)
    $slot = if ($Background) { 'BgTask' } else { 'Task' }
    if ($State[$slot]) {
        if (-not $Background) { [void][System.Windows.MessageBox]::Show((T 'msg.busy'), 'R.E.A.L. Mod Manager') }
        return
    }
    $wrapper = {
        param($LibPath, $Shared, $Body, $Params)
        $ErrorActionPreference = 'Stop'
        . $LibPath
        Initialize-RVM -AppRoot $Shared.AppRoot -Shared $Shared
        $sb = [scriptblock]::Create($Body)
        & $sb @Params
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($wrapper.ToString()).AddArgument([IO.Path]::Combine($AppRoot, 'lib', 'LoadAll.ps1')).AddArgument($Shared).AddArgument($Script.ToString()).AddArgument($Params)
    $State[$slot] = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Title = $Title; OnDone = $OnDone; Context = $Context; Slot = $slot }
    if (-not $Background) { Set-Busy $true $Title }
}

function Complete-RvmTask {
    param([string]$Slot)
    $t = $State[$Slot]
    $result = $null; $err = $null
    try {
        $out = $t.PS.EndInvoke($t.Handle)
        if ($out -and $out.Count -gt 0) { $result = $out[$out.Count - 1] }
        if ($t.PS.Streams.Error.Count -gt 0 -and -not $result) { $err = $t.PS.Streams.Error[0].Exception.Message }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $err = $e.Message
    } finally {
        $t.PS.Dispose(); $t.RS.Close(); $t.RS.Dispose()
        $State[$Slot] = $null
        if ($Slot -eq 'Task') { Set-Busy $false }
    }
    Flush-Log
    if ($err) {
        Add-LogLine ('{0} [ERROR] {1}' -f (Get-Date -Format 'HH:mm:ss'), $err)
        if ($Slot -eq 'Task') { [void][System.Windows.MessageBox]::Show((T 'msg.taskFailed' $t.Title $err), 'R.E.A.L. Mod Manager', 'OK', 'Error') }
        if ($Slot -eq 'BgTask' -and $State.CoverPending) { Start-CoverDownload }
        return
    }
    if ($t.OnDone) {
        try { & $t.OnDone $result $t.Context } catch { [void][System.Windows.MessageBox]::Show((T 'msg.evalFailed' $_.Exception.Message) + "`n" + $_.ScriptStackTrace, 'R.E.A.L. Mod Manager', 'OK', 'Error') }
    }
    # vorgemerkte Cover-Suche nachholen, sobald der Hintergrund frei ist
    if ($Slot -eq 'BgTask' -and $State.CoverPending -and -not $State.BgTask) { Start-CoverDownload }
}

function Set-Busy {
    param([bool]$Busy, [string]$Text)
    foreach ($b in $ActionControls) { if ($UI[$b]) { $UI[$b].IsEnabled = -not $Busy } }
    $UI.prgBusy.Visibility = $(if ($Busy) { 'Visible' } else { 'Hidden' })
    $UI.prgBusy.IsIndeterminate = $Busy
    $UI.txtStatus.Text = $(if ($Busy) { "$Text …" } else { T 'status.ready' })
    if (-not $Busy) { Update-DetailButtons }
}

function Add-LogLine {
    param([string]$Line)
    $UI.txtLog.AppendText($Line + [Environment]::NewLine)
    $UI.txtLog.ScrollToEnd()
    try { [IO.File]::AppendAllText($State.LogFile, $Line + [Environment]::NewLine, [Text.Encoding]::UTF8) } catch { }
}

function Flush-Log {
    $line = $null; $n = 0
    while ($Shared.LogQueue.TryDequeue([ref]$line)) {
        Add-LogLine $line
        if ($State.Task -and $line -match '\[(STATUS|OK|WARN|ERROR)\] (.+)$') { $UI.txtStatus.Text = $Matches[2] }
        $n++
        if ($n -gt 500) { break }
    }
}

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(200)
$Timer.Add_Tick({
        Flush-Log
        if ($State.Task -and $State.Task.Handle.IsCompleted) { Complete-RvmTask 'Task' }
        if ($State.BgTask -and $State.BgTask.Handle.IsCompleted) { Complete-RvmTask 'BgTask' }
    })

# ================================================================ Dialoge

function New-DialogWindow {
    param([string]$Title, [int]$Width = 860, [int]$Height = 600, [string]$Body)
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="$Width" Height="$Height" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  $Body
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($x)
    $w.Title = $Title
    $w.Owner = $Window
    if ($Window.Icon) { $w.Icon = $Window.Icon }
    $w.Add_SourceInitialized({ Set-DarkTitleBar $this ((Get-EffectiveTheme (Get-RvmSettings).Theme) -eq 'dark') })
    return $w
}

function Show-RvmDialog {
    # Text (Plan/Bericht) mit optionalen Checkboxen. Rueckgabe: $null bei Abbruch, sonst Hashtable der Optionen.
    param([string]$Title, [string]$Header, [string]$Text, $Options = @(), [string]$OkText = 'OK', [string]$CancelText = '<default>', [switch]$Proportional, [int]$Width = 900, [int]$Height = 620,
        [string]$ExtraText = '', [scriptblock]$ExtraAction = $null)
    if ($CancelText -eq '<default>') { $CancelText = T 'btn.cancel' }
    $font = if ($Proportional) { 'Segoe UI' } else { 'Consolas' }
    $size = if ($Proportional) { '13' } else { '12' }
    $body = @"
  <DockPanel Margin="18">
    <TextBlock x:Name="hdr" DockPanel.Dock="Top" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="extra" DockPanel.Dock="Left" Style="{StaticResource Link}" Visibility="Collapsed" VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="ok" Style="{StaticResource Primary}" IsDefault="True"/>
        <Button x:Name="cancel" IsCancel="True" Margin="0"/>
      </StackPanel>
    </DockPanel>
    <StackPanel x:Name="opts" DockPanel.Dock="Bottom" Margin="0,10,0,0"/>
    <TextBox x:Name="body" IsReadOnly="True" FontFamily="$font" FontSize="$size" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="$(if ($Proportional) { 'Wrap' } else { 'NoWrap' })" Padding="10,8"/>
  </DockPanel>
"@
    $w = New-DialogWindow -Title $Title -Width $Width -Height $Height -Body $body
    $w.FindName('hdr').Text = $Header
    $tb = $w.FindName('body')
    if ($Text) { $tb.Text = $Text } else { $tb.Visibility = 'Collapsed'; $w.SizeToContent = 'Height' }
    $okB = $w.FindName('ok'); $okB.Content = $OkText
    $cB = $w.FindName('cancel')
    if ($CancelText) { $cB.Content = $CancelText } else { $cB.Visibility = 'Collapsed'; $okB.Margin = '0' }
    if ($ExtraText -and $ExtraAction) {
        $xb = $w.FindName('extra'); $xb.Content = $ExtraText; $xb.Visibility = 'Visible'
        $xb.Add_Click($ExtraAction)
    }
    $boxes = @{}
    foreach ($o in $Options) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        $tbx = [System.Windows.Controls.TextBlock]::new()
        $tbx.Text = $o.Label; $tbx.TextWrapping = 'Wrap'
        $cb.Content = $tbx; $cb.IsChecked = [bool]$o.Default; $cb.Margin = '0,3,0,3'
        if ($o.Locked) { $cb.IsEnabled = $false }
        [void]$w.FindName('opts').Children.Add($cb)
        $boxes[$o.Key] = $cb
    }
    $okB.Add_Click({ $w.DialogResult = $true })
    $r = $w.ShowDialog()
    if (-not $r) { return $null }
    $res = @{}
    foreach ($k in $boxes.Keys) { $res[$k] = [bool]$boxes[$k].IsChecked }
    return $res
}

function Show-RvmInput {
    param([string]$Title, [string]$Prompt, [string]$Default = '', [string]$Note = '')
    $body = @"
  <StackPanel Margin="18">
    <TextBlock x:Name="prompt" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBox x:Name="input"/>
    <TextBlock x:Name="note" TextWrapping="Wrap" Margin="0,12,0,0" Foreground="{DynamicResource Muted}"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="ok" Style="{StaticResource Primary}" IsDefault="True"/>
      <Button x:Name="cancel" IsCancel="True" Margin="0"/>
    </StackPanel>
  </StackPanel>
"@
    $w = New-DialogWindow -Title $Title -Width 560 -Height 200 -Body $body
    $w.SizeToContent = 'Height'
    $w.FindName('prompt').Text = $Prompt
    $w.FindName('note').Text = $Note
    if (-not $Note) { $w.FindName('note').Visibility = 'Collapsed' }
    $in = $w.FindName('input'); $in.Text = $Default
    $w.FindName('ok').Content = (T 'btn.ok'); $w.FindName('cancel').Content = (T 'btn.cancel')
    $w.FindName('ok').Add_Click({ $w.DialogResult = $true })
    $w.Add_ContentRendered({ $in.Focus(); $in.SelectAll() })
    if (-not $w.ShowDialog()) { return $null }
    return $in.Text.Trim()
}

function Show-RvmChoice {
    # Dialog mit frei beschrifteten Schaltflaechen. Choices: @(@{Key; Text}). Rueckgabe: Key oder $null (Abbrechen).
    param([string]$Title, [string]$Header, $Choices, [int]$Width = 560)
    $body = @"
  <StackPanel Margin="18">
    <TextBlock x:Name="hdr" TextWrapping="Wrap" FontSize="14" Margin="0,0,0,16"/>
    <WrapPanel x:Name="btns" HorizontalAlignment="Right"/>
  </StackPanel>
"@
    $w = New-DialogWindow -Title $Title -Width $Width -Height 200 -Body $body
    $w.SizeToContent = 'Height'
    $w.FindName('hdr').Text = $Header
    $panel = $w.FindName('btns')
    $res = @{ Key = $null }
    $first = $true
    foreach ($c in $Choices) {
        $b = [System.Windows.Controls.Button]::new()
        $b.Content = $c.Text; $b.Tag = $c.Key
        if ($first) { $b.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'Primary'); $b.IsDefault = $true; $first = $false }
        $b.Add_Click({ param($s, $e) $res.Key = $s.Tag; $w.DialogResult = $true }.GetNewClosure())
        [void]$panel.Children.Add($b)
    }
    $cb = [System.Windows.Controls.Button]::new()
    $cb.Content = (T 'btn.cancel'); $cb.IsCancel = $true; $cb.Margin = '0'
    [void]$panel.Children.Add($cb)
    [void]$w.ShowDialog()
    return $res.Key
}

function Show-Info { param([string]$Msg, [string]$Icon = 'Information') [void][System.Windows.MessageBox]::Show($Msg, 'R.E.A.L. Mod Manager', 'OK', $Icon) }
function Confirm-Yes { param([string]$Msg) return ([System.Windows.MessageBox]::Show($Msg, 'R.E.A.L. Mod Manager', 'YesNo', 'Question') -eq 'Yes') }

function Open-Explorer { param([string]$Path) if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Path) } }

# ================================================================ Navigation

function Show-Page {
    param([ValidateSet('library', 'detail', 'registry', 'log')][string]$Name)
    if ($State.Page -ne $Name -and $State.Page -ne 'detail') { $State.PrevPage = $State.Page }
    $State.Page = $Name
    $UI.pageLibrary.Visibility = $(if ($Name -eq 'library') { 'Visible' } else { 'Collapsed' })
    $UI.pageDetail.Visibility = $(if ($Name -eq 'detail') { 'Visible' } else { 'Collapsed' })
    $UI.pageRegistry.Visibility = $(if ($Name -eq 'registry') { 'Visible' } else { 'Collapsed' })
    $UI.pageLog.Visibility = $(if ($Name -eq 'log') { 'Visible' } else { 'Collapsed' })
    if ($Name -eq 'registry') { Refresh-Snapshots }
}

# ================================================================ Mod-Versionen / Sprachen (Menues)

function Get-SelectedMod { return $State.Mod }

function Refresh-Mods {
    param([string]$SelectId)
    $State.Mods = @(Get-ModLibrary)
    $settings = Get-RvmSettings
    if (-not $SelectId) { $SelectId = $settings.SelectedMod }
    $sel = $State.Mods | Where-Object { $_.Id -eq $SelectId } | Select-Object -First 1
    if (-not $sel -and $State.Mods.Count) { $sel = $State.Mods[0] }
    $State.Mod = $sel
    if ($sel -and $settings.SelectedMod -ne $sel.Id) { $settings.SelectedMod = $sel.Id; Save-RvmSettings $settings }
    $UI.miModVersions.Items.Clear()
    foreach ($m in $State.Mods) {
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $m.Display
        $mi.Tag = $m.Id
        $mi.IsCheckable = $true
        $mi.IsChecked = ($sel -and $m.Id -eq $sel.Id)
        $mi.Add_Click({
                param($s, $e)
                $id = $s.Tag
                $st = Get-RvmSettings; $st.SelectedMod = $id; Save-RvmSettings $st
                Refresh-Mods -SelectId $id
                Start-Scan
            })
        [void]$UI.miModVersions.Items.Add($mi)
    }
    if (-not $State.Mods.Count) {
        $mi = [System.Windows.Controls.MenuItem]::new(); $mi.Header = (T 'menu.noMods'); $mi.IsEnabled = $false
        [void]$UI.miModVersions.Items.Add($mi)
    }
    $UI.miRemoveMod.IsEnabled = [bool]$sel
    $UI.txtModVersion.Text = $(if ($sel) { T 'lib.modVersion' $sel.Display } else { T 'lib.noMod' })
}

function Refresh-LanguageMenu {
    $UI.miLanguage.Items.Clear()
    foreach ($l in Get-RvmLanguages) {
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $l.Name
        $mi.Tag = $l.Code
        $mi.IsCheckable = $true
        $mi.IsChecked = ($l.Code -eq $script:RvmLang.Code)
        $mi.Add_Click({
                param($s, $e)
                $st = Get-RvmSettings; $st.Language = $s.Tag; Save-RvmSettings $st
                Initialize-RvmLanguage -Code $s.Tag
                Apply-Translations
                Refresh-LanguageMenu
                Refresh-Mods
                Set-Busy $false
                Start-Scan
            })
        [void]$UI.miLanguage.Items.Add($mi)
    }
    [void]$UI.miLanguage.Items.Add([System.Windows.Controls.Separator]::new())
    $mm = [System.Windows.Controls.MenuItem]::new(); $mm.Header = (T 'menu.langManage')
    $mm.Add_Click({ Show-LanguageManager })
    [void]$UI.miLanguage.Items.Add($mm)
}

function Show-LanguageManager {
    # Liest zuerst die Sprachen im GitHub-Repository (Hintergrund), dann Auswahlliste: Haken = installiert.
    Start-RvmTask -Title (T 'task.langList') -Params @{} -Script {
        return (Get-RvmOnlineLanguages)
    } -OnDone {
        param($online)
        $local = @(Get-RvmLanguages)
        $all = [ordered]@{}
        foreach ($l in $local) { $all[$l.Code] = [pscustomobject]@{ Code = $l.Code; Name = $l.Name; Local = $l; Online = $null } }
        foreach ($o in @($online.Items)) {
            if ($all.Contains($o.Code)) { $all[$o.Code].Online = $o }
            else { $all[$o.Code] = [pscustomobject]@{ Code = $o.Code; Name = $o.Name; Local = $null; Online = $o } }
        }
        $opts = @()
        foreach ($e in @($all.Values | Sort-Object Name)) {
            $locked = ($e.Code -eq 'en' -or $e.Code -eq $script:RvmLang.Code)
            if ($e.Local) {
                $st = T 'lang.installed' $e.Local.Version
                if ($e.Online -and (Get-VersionObject $e.Online.Version) -gt (Get-VersionObject $e.Local.Version)) { $st = T 'lang.update' $e.Local.Version $e.Online.Version }
            } else { $st = T 'lang.available' $e.Online.Version }
            if ($locked) { $st += '  ·  ' + (T 'lang.locked') }
            $opts += [pscustomobject]@{ Key = $e.Code; Label = ('{0} ({1})  –  {2}' -f $e.Name, $e.Code, $st); Default = [bool]$e.Local; Locked = $locked }
        }
        $hdr = T 'dlg.langManage'
        switch ($online.Error) { 'nosource' { $hdr += "`n`n" + (T 'lang.noSource') } 'offline' { $hdr += "`n`n" + (T 'lang.offline') } 'format' { $hdr += "`n`n" + (T 'lang.offline') } }
        $openDir = { Open-Explorer (Get-RvmLangDir) }
        $r = Show-RvmDialog -Title (T 'menu.langManage') -Header $hdr -Text '' -Options $opts -OkText (T 'btn.apply') -Width 640 -ExtraText (T 'menu.langFolder') -ExtraAction $openDir
        if ($null -eq $r) { return }
        $done = @()
        foreach ($e in $all.Values) {
            $locked = ($e.Code -eq 'en' -or $e.Code -eq $script:RvmLang.Code)
            try {
                if ($r[$e.Code]) {
                    $newer = $e.Online -and (-not $e.Local -or (Get-VersionObject $e.Online.Version) -gt (Get-VersionObject $e.Local.Version))
                    if ($newer) { Install-RvmLanguage -Code $e.Code -Content $e.Online.Content; $done += (T 'lang.didInstall' $e.Name) }
                } elseif ($e.Local -and -not $locked) {
                    Remove-Item -LiteralPath $e.Local.Path -Force; $done += (T 'lang.didRemove' $e.Name)
                }
            } catch { Show-Info ('{0}: {1}' -f $e.Name, $_.Exception.Message) 'Warning' }
        }
        foreach ($d in $done) { Write-RvmLog $d OK }
        Refresh-LanguageMenu
    }
}

# ================================================================ Updates

$script:UpdateFromInfo = $false
function Get-RestartPath {
    # Portable/Script: Start-Datei; als EXE: die EXE selbst
    if ($env:RVM_LAUNCHER -and (Test-Path -LiteralPath $env:RVM_LAUNCHER)) { return $env:RVM_LAUNCHER }
    $exe = [IO.Path]::Combine($AppRoot, 'R.E.A.L. Mod Manager.exe')
    if (Test-Path -LiteralPath $exe) { return $exe }
    return [IO.Path]::Combine($AppRoot, 'Start-RealVRManager.cmd')
}

function Start-UpdateCheck {
    param([switch]$Manual)
    $pre = [bool](Get-RvmSettings).UpdatePrerelease
    Start-RvmTask -Background:(-not $Manual) -Title (T 'task.updCheck') -Params @{ Pre = $pre } -Context @{ Manual = [bool]$Manual } -Script {
        param($Pre)
        return (Get-RvmUpdateInfo -IncludePrerelease:$Pre)
    } -OnDone {
        param($info, $ctx)
        if (-not $info) { return }
        if (-not $info.Available) {
            if (-not $ctx.Manual) { return }
            $msg = switch ($info.Error) {
                'norepo' { T 'upd.noRepo' } 'offline' { T 'upd.offline' } 'norelease' { T 'upd.noRelease' } 'noasset' { T 'upd.noAsset' $info.Latest }
                default { T 'upd.current' $info.Current }
            }
            Show-Info $msg
            return
        }
        $st = Get-RvmSettings
        if (-not $ctx.Manual -and $st.SkipVersion -eq $info.Latest) { return }
        $notes = if ($info.Notes) { $info.Notes } else { T 'upd.noNotes' }
        $opts = @()
        if (-not $ctx.Manual) { $opts += [pscustomobject]@{ Key = 'skip'; Label = (T 'upd.skip' $info.Latest); Default = $false } }
        $page = $info.Page
        $r = Show-RvmDialog -Title (T 'upd.title') -Header (T 'upd.header' $info.Latest $info.Current) -Text $notes -Options $opts -OkText (T 'upd.now') -CancelText (T 'upd.later') -Proportional -Width 720 -Height 520 `
            -ExtraText $(if ($page) { T 'upd.page' } else { '' }) -ExtraAction $(if ($page) { [scriptblock]::Create("Start-Process '$($page -replace "'", '')'") } else { $null })
        if ($null -eq $r) { return }
        if ($r['skip']) { $st.SkipVersion = $info.Latest; Save-RvmSettings $st; return }
        if ($State.Task) { Show-Info (T 'msg.busy'); return }
        Start-RvmTask -Title (T 'task.updDownload' $info.Latest) -Params @{ Info = $info } -Script {
            param($Info)
            return (Save-RvmUpdate -Info $Info)
        } -OnDone {
            param($prep)
            if (-not $prep) { return }
            Start-RvmUpdateApply -Prepared $prep -RestartPath (Get-RestartPath)
            Write-RvmLog (T 'log.upd.restart') OK
            $script:ClosingForUpdate = $true
            $Window.Close()
        }
    }
}

# ================================================================ Bibliothek

function New-Bitmap {
    param([string]$Path, [int]$Width, [switch]$Gray)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $b = [System.Windows.Media.Imaging.BitmapImage]::new()
        $b.BeginInit()
        $b.CacheOption = 'OnLoad'
        $b.CreateOptions = 'IgnoreImageCache'
        $b.UriSource = [Uri]::new($Path)
        if ($Width) { $b.DecodePixelWidth = $Width }
        $b.EndInit()
        $b.Freeze()
        if ($Gray) {
            $g = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new($b, [System.Windows.Media.PixelFormats]::Gray8, $null, 0)
            $g.Freeze()
            return $g
        }
        return $b
    } catch { return $null }
}

function Update-RowView {
    # Ergaenzt eine Zeile um die Anzeige-Eigenschaften (Texte, Farben, Bilder) in der aktuellen Sprache/Farbe.
    param($r)
    $c = $CurrentColors
    switch ($r.State) {
        'Managed' { if ($r.Update) { $col = $c.Accent; $short = T 'state.update' $r.Version } else { $col = $c.Ok; $short = T 'state.installed' $r.Version } }
        'Incomplete' { $col = $c.Danger; $short = T 'state.incomplete' }
        'Foreign' { $col = $c.Warn; $short = T 'state.foreign' }
        'Missing' { $col = $c.Muted; $short = T 'state.missing' }
        default { $col = $c.Muted; $short = T 'state.none' }
    }
    $words = @($r.Name -split '[\s:\-]+' | Where-Object { $_ -match '^[A-Za-z0-9]' })
    $init = (($words | Select-Object -First 2 | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() }) -join '')
    $props = @{
        StateColor = $col; StateShort = $short; StateDot = $(if ($r.State -eq 'None') { 'Collapsed' } else { 'Visible' })
        Initials = $init; CompatLevelText = (T ('cp.level.' + $r.CompatLevel))
        CoverImage = (New-Bitmap $r.CoverPath 352)
        DimOpacity = $(if ($r.OnDisk) { 0.0 } elseif ($r.CoverPath) { 0.62 } else { 0.35 })
        MissingBadge = $(if ($r.OnDisk) { 'Collapsed' } else { 'Visible' })
        TextOpacity = $(if ($r.OnDisk) { 1.0 } else { 0.55 })
        CompatColor = $(switch ($r.CompatLevel) { 'good' { $c.Ok } 'limited' { $c.Warn } 'problem' { $c.Danger } default { $c.Dim } })
        TileTip = $(if ($r.OnDisk) { $r.Folder } else { T 'tile.missingTip' })
    }
    foreach ($k in $props.Keys) {
        $v = $props[$k]
        if ($null -ne $v -and $v -is [psobject]) { $v = $v.PSObject.BaseObject }
        $r | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force
    }
}

function Apply-LibraryFilter {
    $q = $UI.txtSearch.Text
    $UI.txtSearchHint.Visibility = $(if ($q) { 'Collapsed' } else { 'Visible' })
    $rows = @($State.Rows)
    $withMod = { $_.State -in @('Managed', 'Incomplete', 'Foreign') }
    if ($UI.chipInstalled.IsChecked) { $rows = @($rows | Where-Object $withMod) }
    elseif ($UI.chipUpdate.IsChecked) { $rows = @($rows | Where-Object { $_.Update }) }
    elseif ($UI.chipNot.IsChecked) { $rows = @($rows | Where-Object { $_.State -eq 'None' }) }
    if ($q) { $rows = @($rows | Where-Object { $_.Name -like "*$q*" -or $_.Folder -like "*$q*" }) }
    $UI.icGames.ItemsSource = $rows
    $moddable = @($State.Rows | Where-Object { $_.InMod } | ForEach-Object { $_.Label } | Sort-Object -Unique).Count
    $onDisk = @($State.Rows | Where-Object { $_.OnDisk }).Count
    $inst = @($State.Rows | Where-Object $withMod).Count
    $upd = @($State.Rows | Where-Object { $_.Update }).Count
    $not = @($State.Rows | Where-Object { $_.State -eq 'None' }).Count
    $m = $State.Mod
    $modTxt = if ($m) { T 'lib.modShort' $m.Version $(if ($m.EarlyAccess) { ' EA' } else { '' }) } else { T 'lib.noMod' }
    $UI.txtLibSub.Text = $modTxt + '  ·  ' + (T 'lib.sub' $moddable $onDisk $inst $upd)
    $needArt = @($State.Rows | Where-Object { -not $_.OnDisk -and -not $_.CoverPath }).Count
    $UI.bdOnlineHint.Visibility = $(if ($needArt -and (Get-RvmSettings).OnlineCovers -ne $true) { 'Visible' } else { 'Collapsed' })
    $UI.chipAll.Content = (T 'lib.filterAll') + "  $($State.Rows.Count)"
    $UI.chipInstalled.Content = (T 'lib.filterInstalled') + "  $inst"
    $UI.chipUpdate.Content = (T 'lib.filterUpdate') + "  $upd"
    $UI.chipNot.Content = (T 'lib.filterNot') + "  $not"
    if (-not $State.Rows.Count) {
        $UI.txtEmpty.Text = $(if ($State.Mod) { T 'lib.empty' } else { T 'lib.emptyNoMod' })
        $UI.txtEmpty.Visibility = 'Visible'
    } else { $UI.txtEmpty.Visibility = 'Collapsed' }
}

function Start-Scan {
    param([switch]$Full)
    $m = Get-SelectedMod
    Start-RvmTask -Title (T 'task.scan') -Params @{ ModId = $(if ($m) { $m.Id } else { $null }); Full = [bool]$Full } -Script {
        param($ModId, $Full)
        $sys = Get-RvmSystemInfo
        $mod = $null; $parsed = $null; $found = @()
        if ($ModId) {
            $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
            $parsed = Get-ParsedMod $mod
            $found = @(Find-SupportedGames -Parsed $parsed -Full:$Full)
        } else { Write-RvmLog (T 'log.scan.noMod') WARN }
        $rows = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        $mk = {
            param($g, $Def)
            $onDisk = [bool]$g.Folder
            if ($onDisk) { $st = Get-ModInstallState -Folder $g.Folder -Def $Def }
            else { $st = [pscustomobject]@{ State = 'Missing'; Version = $null; Journal = $null; Evidence = @() } }
            $compat = $null
            if ($Def) { $compat = Get-CompatAssessment -Def $Def -Folder $g.Folder -Mod $mod -Sys $sys }
            $upd = ($st.State -eq 'Managed' -and $mod -and (Get-VersionObject $mod.Version) -gt (Get-VersionObject $st.Version))
            $art = Get-GameArt $g
            $rows.Add([pscustomobject]@{
                    Key = $(if ($onDisk) { $g.Folder } else { $g.RootFolder }); OnDisk = $onDisk
                    Name = $g.Name; Label = $g.Label; Folder = $g.Folder; RootFolder = $g.RootFolder; Source = $g.Source
                    AppId = $g.AppId; StoreName = $g.StoreName; EpicItem = $g.EpicItem; EpicNs = $g.EpicNs
                    State = $st.State; Version = $st.Version; Update = [bool]$upd
                    Evidence = ($st.Evidence -join ', ')
                    JournalDir = $(if ($st.Journal) { $st.Journal.Dir } else { $null }); Journal = $st.Journal
                    CompatLevel = $(if ($compat) { $compat.Level } else { 'unknown' })
                    CompatColor = $(if ($compat) { $compat.Color } else { '#7A7F87' })
                    CompatText = $(if ($compat) { $compat.Text } else { '' })
                    InMod = [bool]$Def
                    CoverPath = $art.Cover; HeroPath = $art.Hero
                    Info = $(if (-not $onDisk) { Get-GameInfo $g } else { $null })
                })
        }
        $seenLabel = @{}
        foreach ($f in $found) {
            $seen[$f.Folder.ToLowerInvariant()] = $true
            $seenLabel[$f.Label] = $true
            & $mk $f $parsed.ByLabel[$f.Label]
        }
        foreach ($d in [IO.Directory]::GetDirectories((Get-RvmDir Journals))) {
            if ([IO.Path]::GetFileName($d).StartsWith('_')) { continue }
            $j = Read-RvmJson ([IO.Path]::Combine($d, 'journal.json'))
            if (-not $j -or $seen.ContainsKey($j.GameFolder.ToLowerInvariant())) { continue }
            $def = if ($parsed) { $parsed.ByLabel[$j.GameLabel] } else { $null }
            if ($j.GameLabel) { $seenLabel[$j.GameLabel] = $true }
            & $mk ([pscustomobject]@{ Name = $j.GameName; Label = $j.GameLabel; Folder = $j.GameFolder; RootFolder = $j.GameFolder; Source = 'Journal' }) $def
        }
        # Alle weiteren modbaren Spiele der Mod-Liste (nicht auf diesem PC)
        if ($parsed) {
            foreach ($def in $parsed.Games) {
                if ($seenLabel.ContainsKey($def.Label)) { continue }
                if (-not (Test-ModHasRepo -Mod $mod -Def $def)) { continue }
                $seenLabel[$def.Label] = $true
                $g = [pscustomobject]@{ Name = $def.Name; Label = $def.Label; Folder = $null; RootFolder = ('mod:' + $def.Label); Source = 'Mod'; AppId = $null }
                $inf = Get-GameInfo $g
                if ($inf -and $inf.AppId) { $g.AppId = [string]$inf.AppId }
                & $mk $g $def
            }
        }
        return @{ Rows = $rows.ToArray(); Sys = $sys }
    } -OnDone {
        param($r)
        $State.Sys = $r.Sys
        $si = Format-SystemInfo $r.Sys
        $UI.txtSys.Text = $si.Text
        $UI.txtSys.ToolTip = $si.Tip
        if ($si.Ok) { $UI.txtSys.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Dim') }
        else { $UI.txtSys.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Warn') }
        $rows = @($r.Rows | Sort-Object @{ Expression = { -not $_.OnDisk } }, Name)
        foreach ($row in $rows) { Update-RowView $row }
        $State.Rows = $rows
        Apply-LibraryFilter
        if ($State.Page -eq 'detail' -and $State.Detail) {
            $again = $State.Rows | Where-Object { $_.Key -eq $State.Detail.Key } | Select-Object -First 1
            if ($again) { Show-Detail $again } else { Show-Page 'library' }
        }
        Start-CoverDownload
    }
}

function Start-CoverDownload {
    # Laedt fehlende Cover/Infos in kleinen Paketen, damit die Bilder nach und nach erscheinen.
    # Ist der Hintergrund gerade belegt, wird der Auftrag vorgemerkt und danach ausgefuehrt.
    param($Queue = $null)
    if ((Get-RvmSettings).OnlineCovers -ne $true) { return }
    if ($State.BgTask) { $State.CoverPending = $true; return }
    if ($null -eq $Queue) {
        $State.CoverPending = $false
        $Queue = @($State.Rows | Where-Object { -not $_.CoverPath -or -not $_.HeroPath -or (-not $_.OnDisk -and -not ($_.Info -and ($_.Info.Lang -eq $script:RvmLang.Code -or $_.Info.Miss))) } | ForEach-Object {
                [pscustomobject]@{ Key = $_.Key; Name = $_.Name; Folder = $_.Folder; RootFolder = $_.RootFolder; AppId = $_.AppId; StoreName = $_.StoreName; EpicItem = $_.EpicItem; EpicNs = $_.EpicNs; NeedInfo = (-not $_.OnDisk) }
            })
        # sichtbare Spiele auf dem PC zuerst
        $Queue = @($Queue | Sort-Object @{ Expression = { [bool]$_.NeedInfo } }, Name)
    }
    $Queue = @($Queue)
    if (-not $Queue.Count) { return }
    $batch = @($Queue | Select-Object -First 4)
    $rest = @($Queue | Select-Object -Skip 4)
    Start-RvmTask -Background -Title (T 'task.covers') -Params @{ Games = $batch } -Context @{ Rest = $rest } -Script {
        param($Games)
        $n = Update-GameArtOnline -Games $Games
        $out = @()
        foreach ($g in $Games) { $a = Get-GameArt $g; $out += [pscustomobject]@{ Key = $g.Key; Cover = $a.Cover; Hero = $a.Hero; Info = (Get-GameInfo $g) } }
        return @{ New = $n; Art = $out }
    } -OnDone {
        param($r, $ctx)
        if ($r) {
            foreach ($a in $r.Art) {
                $row = $State.Rows | Where-Object { $_.Key -eq $a.Key } | Select-Object -First 1
                if (-not $row) { continue }
                $row.CoverPath = $a.Cover; $row.HeroPath = $a.Hero
                if ($a.Info) {
                    $row.Info = $a.Info
                    if (-not $row.AppId -and $a.Info.AppId) { $row.AppId = [string]$a.Info.AppId }
                }
                Update-RowView $row
            }
            Apply-LibraryFilter
            if ($State.Page -eq 'detail' -and $State.Detail) { Show-Detail $State.Detail }
        }
        if (@($ctx.Rest).Count) { Start-CoverDownload -Queue $ctx.Rest }
    }
}

# ================================================================ Detailseite

function New-Chip {
    param([string]$Text, [string]$Color = $null)
    $b = [System.Windows.Controls.Border]::new()
    $b.BorderThickness = '1'; $b.Padding = '10,4'; $b.Margin = '0,0,8,8'; $b.CornerRadius = '2'
    $b.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Line')
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text; $t.FontSize = 12
    if ($Color) { $t.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color) } else { $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted') }
    $b.Child = $t
    return $b
}

function Show-Detail {
    param($r)
    $State.Detail = $r
    $UI.txtDetailName.Text = $r.Name
    $hero = New-Bitmap $r.HeroPath 1600
    if (-not $hero) { $hero = New-Bitmap $r.CoverPath 600 }
    $UI.imgHero.Source = $hero
    $UI.pnlChips.Children.Clear()
    $inf = $r.Info
    if ($r.OnDisk) { [void]$UI.pnlChips.Children.Add((New-Chip (T ('src.' + $r.Source)))) }
    else {
        [void]$UI.pnlChips.Children.Add((New-Chip (T 'state.missing')))
        if ($inf -and $inf.Genres) { foreach ($gn in @($inf.Genres | Select-Object -First 3)) { [void]$UI.pnlChips.Children.Add((New-Chip $gn)) } }
    }
    if ($State.Mod) { [void]$UI.pnlChips.Children.Add((New-Chip ('Mod ' + $State.Mod.Id))) }
    [void]$UI.pnlChips.Children.Add((New-Chip (T ('cp.level.' + $r.CompatLevel)) $r.CompatColor))
    if ($r.AppId) { [void]$UI.pnlChips.Children.Add((New-Chip "Steam $($r.AppId)")) }
    $ua = Get-UserArt $r
    $UI.btnRemovePic.Visibility = $(if ($ua.Cover -or $ua.Hero) { 'Visible' } else { 'Collapsed' })
    $UI.txtDetailState.Text = $r.StateShort
    $UI.txtDetailState.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($r.StateColor)
    $UI.txtCompat.Text = $(if ($r.CompatText) { $r.CompatText } else { T 'detail.noNotes' })
    $UI.bdCompat.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($r.CompatColor)
    $about = @()
    if (-not $r.OnDisk) {
        if ($inf -and $inf.Name) {
            if ($inf.Developers) { $about += (T 'detail.developer' ($inf.Developers -join ', ')) }
            if ($inf.Publishers) { $about += (T 'detail.publisher' ($inf.Publishers -join ', ')) }
            if ($inf.Release) { $about += (T 'detail.release' $inf.Release) }
            if ($inf.Description) { $about += ''; $about += $inf.Description }
        } elseif ((Get-RvmSettings).OnlineCovers -ne $true) { $about += (T 'detail.infoOffline') }
        else { $about += (T 'detail.infoNone') }
    }
    $UI.txtAbout.Text = ($about -join [Environment]::NewLine)
    $UI.txtAbout.Visibility = $(if ($about.Count) { 'Visible' } else { 'Collapsed' })
    $UI.txtShopBtn.Text = $(if ($r.AppId) { T 'detail.shop' } else { T 'detail.shopSearch' })
    $info = @()
    if ($r.OnDisk) { $info += (T 'detail.folder' $r.Folder) } else { $info += (T 'detail.notOnDisk') }
    if ($r.Evidence) { $info += (T 'detail.evidence' $r.Evidence) }
    if ($r.Journal) {
        $info += (T 'detail.journal' $r.JournalDir)
        $info += (T 'detail.installedAt' $r.Journal.InstalledAt $r.Journal.ModId)
        if ($r.Journal.Summary) { $s = $r.Journal.Summary; $info += (T 'detail.summary' $s.FilesAdded $s.FilesChanged $s.FilesRemoved $s.RegRelevant) }
    }
    if (-not $r.InMod) { $info += (T 'detail.notInMod') }
    $UI.txtDetailInfo.Text = ($info -join [Environment]::NewLine)
    Update-DetailButtons
    Show-Page 'detail'
}

function Update-DetailButtons {
    $r = $State.Detail
    $m = Get-SelectedMod
    $busy = [bool]$State.Task
    $canInstall = [bool]($r -and $m -and $r.State -eq 'None' -and $r.InMod -and $r.CompatLevel -ne 'problem')
    $canUpdate = [bool]($r -and $m -and $r.State -eq 'Managed' -and $r.InMod)
    $UI.btnInstall.Visibility = $(if ($r -and $r.State -eq 'None') { 'Visible' } else { 'Collapsed' })
    $UI.btnUpdate.Visibility = $(if ($canUpdate) { 'Visible' } else { 'Collapsed' })
    $UI.btnUninstall.Visibility = $(if ($r -and $r.State -notin @('None', 'Missing')) { 'Visible' } else { 'Collapsed' })
    $UI.btnOpenFolder.Visibility = $(if ($r -and $r.OnDisk) { 'Visible' } else { 'Collapsed' })
    $UI.btnShop.Visibility = $(if ($r -and -not $r.OnDisk) { 'Visible' } else { 'Collapsed' })
    $UI.btnInstall.IsEnabled = $canInstall -and -not $busy
    $UI.btnUpdate.IsEnabled = $canUpdate -and -not $busy
    $UI.btnUninstall.IsEnabled = -not $busy
    if ($r -and $r.Update) { $UI.txtUpdateBtn.Text = T 'detail.updateTo' $m.Version } else { $UI.txtUpdateBtn.Text = T 'detail.reinstall' }
    $UI.btnOpenJournal.Visibility = $(if ($r -and $r.JournalDir) { 'Visible' } else { 'Collapsed' })
}

# ================================================================ Aktionen

function Start-Import {
    param([string]$Source)
    Start-RvmTask -Title (T 'task.import') -Params @{ Source = $Source } -Script {
        param($Source)
        $id = Import-RvmMod -Source $Source
        return @{ Id = $id }
    } -OnDone {
        param($r)
        Refresh-Mods -SelectId $r.Id
        Show-Info (T 'msg.imported' $r.Id)
        Start-Scan
    }
}

function Start-InstallFlow {
    $r = $State.Detail; $m = Get-SelectedMod
    if (-not $r -or -not $m) { return }
    $txt = (T 'dlg.install.text' $r.Name $r.Folder $m.Id) + [Environment]::NewLine + [Environment]::NewLine + (T 'dlg.install.compat' (T ('cp.level.' + $r.CompatLevel))) + [Environment]::NewLine + $r.CompatText
    $rpOpt = [pscustomobject]@{ Key = 'RestorePoint'; Label = (T 'dlg.install.rp' $r.Name); Default = $true }
    $o = Show-RvmDialog -Title (T 'dlg.install.title') -Header (T 'dlg.install.header' $r.Name) -Text $txt -Options @($rpOpt) -OkText (T 'detail.install') -Proportional
    if ($null -eq $o) { return }
    Start-RvmTask -Title (T 'task.install' $r.Name) -Params @{ Folder = $r.Folder; Label = $r.Label; ModId = $m.Id; RestorePoint = [bool]$o['RestorePoint'] } -Script {
        param($Folder, $Label, $ModId, $RestorePoint)
        $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
        $res = Install-RealVR -GameFolder $Folder -GameLabel $Label -Mod $mod -CreateRestorePoint:$RestorePoint
        return @{ Success = $res.Success; Summary = $res.Summary }
    } -OnDone {
        param($res)
        if ($res.Success) { $s = $res.Summary; Show-Info (T 'msg.installed' $s.FilesAdded $s.FilesChanged $s.FilesRemoved $s.RegRelevant) }
        else { Show-Info (T 'msg.installFailed') 'Warning' }
        Start-Scan
    }
}

function Start-UninstallFlow {
    param($Row, [switch]$IsUpdate)
    $m = Get-SelectedMod
    Start-RvmTask -Title (T 'task.plan') -Context @{ IsUpdate = [bool]$IsUpdate } -Params @{ Folder = $Row.Folder; Label = $Row.Label; JournalDir = $Row.JournalDir; ModId = $(if ($m) { $m.Id } else { $null }) } -Script {
        param($Folder, $Label, $JournalDir, $ModId)
        if ($JournalDir) { $plan = Get-JournalUninstallPlan -JournalDir $JournalDir }
        else {
            $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
            if (-not $mod) { throw (T 'err.legacyNeedsMod') }
            $def = (Get-ParsedMod $mod).ByLabel[$Label]
            $plan = Get-LegacyUninstallPlan -GameFolder $Folder -Def $def -Mod $mod
        }
        return @{ Plan = $plan; Text = (Format-Plan $plan) }
    } -OnDone {
        param($r, $ctx)
        $IsUpdate = $ctx.IsUpdate
        $plan = $r.Plan
        $opts = @($plan.Options)
        if ($IsUpdate) { $opts += [pscustomobject]@{ Key = '_KeepIni'; Label = (T 'dlg.update.keepIni'); Default = $true } }
        $opts += [pscustomobject]@{ Key = '_RestorePoint'; Label = (T $(if ($IsUpdate) { 'dlg.update.rp' } else { 'dlg.unin.rp' }) $plan.GameName); Default = $false }
        $header = if ($IsUpdate) { T 'dlg.update.header' $plan.GameName } elseif ($plan.Kind -eq 'Legacy') { T 'dlg.unin.legacyHeader' } else { T 'dlg.unin.header' }
        $o = Show-RvmDialog -Title $plan.Title -Header $header -Text $r.Text -Options $opts -OkText $(if ($IsUpdate) { T 'btn.startUpdate' } else { T 'btn.run' })
        if ($null -eq $o) { return }
        if ($IsUpdate) {
            $mm = Get-SelectedMod
            Start-RvmTask -Title (T 'task.update' $plan.GameName) -Params @{ Folder = $plan.GameFolder; ModId = $mm.Id; Options = $o; GameName = $plan.GameName } -Script {
                param($Folder, $ModId, $Options, $GameName)
                $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
                if ($Options['_RestorePoint']) { [void](New-RvmRestorePoint -Description (T 'rp.descUpdate' $GameName $mod.Id)) }
                $res = Update-RealVR -GameFolder $Folder -Mod $mod -Options $Options -KeepIni ([bool]$Options['_KeepIni'])
                return @{ Success = $res.Success }
            } -OnDone {
                param($res)
                if ($res.Success) { Show-Info (T 'msg.updated') } else { Show-Info (T 'msg.updateFailed') 'Warning' }
                Start-Scan
            }
        } else {
            Start-RvmTask -Title (T 'task.uninstall' $plan.GameName) -Params @{ Plan = $plan; Options = $o } -Script {
                param($Plan, $Options)
                if ($Options['_RestorePoint']) { [void](New-RvmRestorePoint -Description (T 'rp.descUninstall' $Plan.GameName)) }
                $res = Invoke-RvmPlan -Plan $Plan -Options $Options
                $vt = if ($res.Verify) { $res.Verify.Text } else { '' }
                return @{ Message = $res.Message; Errors = $res.Errors; Verify = $vt; Log = ($res.Log -join [Environment]::NewLine) }
            } -OnDone {
                param($res)
                $body = $res.Verify + [Environment]::NewLine + '--- ' + (T 'report.exec') + ' ---' + [Environment]::NewLine + $res.Log
                [void](Show-RvmDialog -Title (T 'dlg.result') -Header $res.Message -Text $body -OkText (T 'btn.close') -CancelText '')
                Start-Scan
            }
        }
    }
}

function Start-RestorePointFlow {
    $default = if ($State.Detail -and $State.Page -eq 'detail') { "REAL Mod - $($State.Detail.Name)" } else { 'REAL Mod - ' }
    $name = Show-RvmInput -Title (T 'dlg.rp.title') -Prompt (T 'dlg.rp.prompt') -Default $default -Note (T 'dlg.rp.note')
    if (-not $name) { return }
    Start-RvmTask -Title (T 'task.rp') -Params @{ Desc = $name } -Script { param($Desc) $ok = New-RvmRestorePoint -Description $Desc; return @{ Ok = $ok } } -OnDone {
        param($r)
        if ($r.Ok) { Show-Info (T 'msg.rpOk') } else { Show-Info (T 'msg.rpFail') 'Warning' }
    }
}

# ================================================================ Registry-Seite

function Refresh-Snapshots { $UI.lstSnapshots.ItemsSource = @(Get-RegSnapshotList) }

function Apply-RegList {
    $list = @($State.RegDiffs)
    $UI.gridReg.ItemsSource = $list
    $UI.txtRegInfo.Text = T 'reg.diffCount' $list.Count
}

# ================================================================ Ereignisse

$UI.icGames.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $src = $e.OriginalSource
        if ($src -and $src.Tag) { Show-Detail $src.Tag }
    })
$UI.txtSearch.Add_TextChanged({ Apply-LibraryFilter })
foreach ($c in @($UI.chipAll, $UI.chipInstalled, $UI.chipUpdate, $UI.chipNot)) { $c.Add_Checked({ Apply-LibraryFilter }) }
$UI.btnScan.Add_Click({ Start-Scan })
$UI.btnBack.Add_Click({ Show-Page 'library' })
$UI.btnInstall.Add_Click({ Start-InstallFlow })
$UI.btnUninstall.Add_Click({ if ($State.Detail) { Start-UninstallFlow -Row $State.Detail } })
$UI.btnUpdate.Add_Click({
        $r = $State.Detail; $m = Get-SelectedMod
        if (-not $r -or -not $m) { return }
        if (-not $r.Update -and -not (Confirm-Yes (T 'msg.reinstallSame' $r.Version $m.Id))) { return }
        Start-UninstallFlow -Row $r -IsUpdate
    })
$UI.btnOpenFolder.Add_Click({ if ($State.Detail) { Open-Explorer $State.Detail.Folder } })
$UI.btnShop.Add_Click({
        if (-not $State.Detail) { return }
        $u = Get-ShopUrl -Game $State.Detail -Info $State.Detail.Info
        if ($u -match '^https://') { Start-Process $u }
    })
$UI.btnOpenJournal.Add_Click({ if ($State.Detail) { Open-Explorer $State.Detail.JournalDir } })
$UI.btnChangePic.Add_Click({
        $r = $State.Detail
        if (-not $r) { return }
        $kind = Show-RvmChoice -Title (T 'detail.changePic') -Header (T 'msg.picKind') -Choices @(@{ Key = 'cover'; Text = (T 'pic.cover') }, @{ Key = 'hero'; Text = (T 'pic.hero') })
        if (-not $kind) { return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = (T 'dlg.picFilter') + '|*.jpg;*.jpeg;*.png'
        if (-not $dlg.ShowDialog($Window)) { return }
        try {
            Set-UserCover -Game $r -File $dlg.FileName -Kind $kind
            $a = Get-GameArt $r
            $r.CoverPath = $a.Cover; $r.HeroPath = $a.Hero
            Update-RowView $r
            Apply-LibraryFilter
            Show-Detail $r
        } catch { Show-Info $_.Exception.Message 'Warning' }
    })

$UI.btnRemovePic.Add_Click({
        $r = $State.Detail
        if (-not $r) { return }
        $ua = Get-UserArt $r
        $ch = @()
        if ($ua.Cover) { $ch += @{ Key = 'cover'; Text = (T 'pic.cover') } }
        if ($ua.Hero) { $ch += @{ Key = 'hero'; Text = (T 'pic.hero') } }
        if ($ch.Count -eq 2) { $ch += @{ Key = 'both'; Text = (T 'pic.both') } }
        if (-not $ch.Count) { return }
        $k = Show-RvmChoice -Title (T 'detail.removePic') -Header (T 'msg.picRemove') -Choices $ch
        if (-not $k) { return }
        try {
            if ($k -in @('cover', 'both')) { Remove-UserCover -Game $r -Kind cover }
            if ($k -in @('hero', 'both')) { Remove-UserCover -Game $r -Kind hero }
            $a = Get-GameArt $r
            $r.CoverPath = $a.Cover; $r.HeroPath = $a.Hero
            Update-RowView $r
            Apply-LibraryFilter
            Show-Detail $r
            if (-not $a.Cover -or -not $a.Hero) { Start-CoverDownload }
        } catch { Show-Info $_.Exception.Message 'Warning' }
    })
$UI.btnEnableOnline.Add_Click({
        $st = Get-RvmSettings; $st.OnlineCovers = $true; Save-RvmSettings $st
        $UI.miOnlineCovers.IsChecked = $true
        Apply-LibraryFilter
        Start-CoverDownload
    })

# Menue
$UI.miImportZip.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'R.E.A.L. VR ZIP (*.zip)|*.zip'
        if ($dlg.ShowDialog($Window)) { Start-Import $dlg.FileName }
    })
$UI.miImportFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = T 'dlg.importFolder'
        if ($dlg.ShowDialog() -eq 'OK') { Start-Import $dlg.SelectedPath }
    })
$UI.miRemoveMod.Add_Click({
        $m = Get-SelectedMod
        if ($m -and (Confirm-Yes (T 'msg.removeMod' $m.Id))) { Remove-RvmMod -Id $m.Id; Refresh-Mods; Start-Scan }
    })
$UI.miOpenData.Add_Click({ Open-Explorer (Get-RvmDir Root) })
$UI.miCleanup.Add_Click({
        $items = @(Get-RvmCleanupItems | Where-Object { $_.Size -gt 0 })
        if (-not $items.Count) { Show-Info (T 'msg.cleanNothing'); return }
        $opts = @(); $i = 0; $map = @{}
        foreach ($it in $items) {
            $key = 'k' + $i; $i++; $map[$key] = $it
            $label = switch ($it.Kind) {
                'archive' { T 'clean.archive' $it.Name (Format-Size $it.Size) }
                'regexport' { T 'clean.regexport' $it.Name (Format-Size $it.Size) }
                'logs' { T 'clean.logs' @($it.Path).Count (Format-Size $it.Size) }
                'covers' { T 'clean.covers' (Format-Size $it.Size) }
            }
            $opts += [pscustomobject]@{ Key = $key; Label = $label; Default = ($it.Kind -in @('archive', 'logs')) }
        }
        $total = ($items | Measure-Object Size -Sum).Sum
        $r = Show-RvmDialog -Title (T 'menu.cleanup') -Header (T 'dlg.cleanup' (Format-Size $total)) -Text '' -Options $opts -OkText (T 'btn.delete') -Width 720 -ExtraText (T 'menu.openData') -ExtraAction { Open-Explorer (Get-RvmDir Root) }
        if ($null -eq $r) { return }
        $sel = @($map.Keys | Where-Object { $r[$_] } | ForEach-Object { $map[$_] })
        if (-not $sel.Count) { return }
        Start-RvmTask -Title (T 'task.cleanup') -Params @{ Items = $sel } -Context @{ Covers = [bool]@($sel | Where-Object { $_.Kind -eq 'covers' }).Count } -Script {
            param($Items)
            $freed = [int64]0
            foreach ($it in $Items) {
                try { Remove-RvmCleanupItem $it; $freed += $it.Size } catch { Write-RvmLog (T 'log.cleanFail' $it.Name $_.Exception.Message) WARN }
            }
            Write-RvmLog (T 'log.cleaned' (Format-Size $freed)) OK
            return @{ Freed = $freed }
        } -OnDone {
            param($res, $ctx)
            Refresh-Snapshots
            Show-Info (T 'msg.cleaned' (Format-Size $res.Freed))
            if ($ctx.Covers) { Start-Scan }
        }
    })
$UI.miExit.Add_Click({ $Window.Close() })
$UI.miLibrary.Add_Click({ Show-Page 'library' })
$UI.miRescan.Add_Click({ Start-Scan })
$UI.miFullScan.Add_Click({ Start-Scan -Full })
$UI.miAddFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = T 'dlg.addFolder'
        if ($dlg.ShowDialog() -eq 'OK') {
            $s = Get-RvmSettings
            if ($s.ManualGameFolders -notcontains $dlg.SelectedPath) { $s.ManualGameFolders = @($s.ManualGameFolders) + $dlg.SelectedPath }
            Save-RvmSettings $s
            Start-Scan   # nur der neue Ordner wird durchsucht, der Rest kommt aus dem Cache
        }
    })
$UI.miManageFolders.Add_Click({
        $s = Get-RvmSettings
        if (-not $s.ManualGameFolders.Count) { Show-Info (T 'msg.noManualFolders'); return }
        $opts = @($s.ManualGameFolders | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_; Default = $true } })
        $r = Show-RvmDialog -Title (T 'menu.manageFolders') -Header (T 'dlg.manageFolders') -Text '' -Options $opts -OkText (T 'btn.save')
        if ($null -eq $r) { return }
        $removed = @($s.ManualGameFolders | Where-Object { -not $r[$_] })
        $s.ManualGameFolders = @($s.ManualGameFolders | Where-Object { $r[$_] })
        Save-RvmSettings $s
        $State.Rows = @($State.Rows | Where-Object { $row = $_; -not ($row.Source -eq 'Manual' -and @($removed | Where-Object { Test-PathUnder $_ $row.Folder }).Count) })
        Apply-LibraryFilter
        Start-Scan
    })
$UI.miRegistry.Add_Click({ Show-Page 'registry' })
$UI.miRestorePoint.Add_Click({ Start-RestorePointFlow })
$UI.miRegExport.Add_Click({ $UI.btnRegExport.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
$UI.miLog.Add_Click({ Show-Page 'log' })
$UI.btnLogToggle.Add_Click({ if ($State.Page -eq 'log') { Show-Page $State.PrevPage } else { Show-Page 'log' } })
foreach ($pair in @(@($UI.miThemeDark, 'dark'), @($UI.miThemeLight, 'light'), @($UI.miThemeSystem, 'system'))) {
    $pair[0].Tag = $pair[1]
    $pair[0].Add_Click({
            param($s, $e)
            $st = Get-RvmSettings; $st.Theme = $s.Tag; Save-RvmSettings $st
            Set-Theme $s.Tag
            foreach ($row in $State.Rows) { Update-RowView $row }
            Apply-LibraryFilter
            if ($State.Page -eq 'detail' -and $State.Detail) { Show-Detail $State.Detail }
        })
}
$UI.miOnlineCovers.Add_Click({
        $st = Get-RvmSettings; $st.OnlineCovers = [bool]$UI.miOnlineCovers.IsChecked; Save-RvmSettings $st
        Apply-LibraryFilter
        if ($st.OnlineCovers) { Start-CoverDownload }
    })
$UI.miGuide.Add_Click({ [void](Show-RvmDialog -Title (T 'menu.guide') -Header (T 'guide.header') -Text (T 'guide.text') -OkText (T 'btn.close') -CancelText '' -Proportional -Width 820 -Height 680) })
$UI.miUpdate.Add_Click({ Start-UpdateCheck -Manual })
$UI.miBuildInfo.Add_Click({
        $txt = T 'build.text' $Version.Version $Version.BuildDate $Version.Channel $PSVersionTable.PSVersion ([Environment]::OSVersion.VersionString) $AppRoot (Get-RvmDir Root) $Version.License $(if ($Version.Repository) { $Version.Repository } else { '-' })
        $st = Get-RvmSettings
        $opts = @(
            [pscustomobject]@{ Key = 'auto'; Label = (T 'upd.optAuto'); Default = [bool]$st.AutoUpdate },
            [pscustomobject]@{ Key = 'pre'; Label = (T 'upd.optPre'); Default = [bool]$st.UpdatePrerelease })
        $r = Show-RvmDialog -Title (T 'menu.buildInfo') -Header 'R.E.A.L. Mod Manager' -Text $txt -Options $opts -OkText (T 'btn.close') -CancelText '' -Proportional -Width 720 -Height 640 `
            -ExtraText (T 'menu.checkUpdate') -ExtraAction { $script:UpdateFromInfo = $true; $w.DialogResult = $true }
        if ($null -ne $r) {
            $st = Get-RvmSettings; $st.AutoUpdate = $r['auto']; $st.UpdatePrerelease = $r['pre']; Save-RvmSettings $st
        }
        if ($script:UpdateFromInfo) { $script:UpdateFromInfo = $false; Start-UpdateCheck -Manual }
    })

# Registry-Seite
$UI.btnRegSnap.Add_Click({
        $name = $UI.txtRegName.Text
        if (-not $name) { $name = T 'reg.defaultName' }
        $m = Get-SelectedMod
        Start-RvmTask -Title (T 'task.regSnap') -Params @{ Name = $name; ModId = $(if ($m) { $m.Id } else { $null }) } -Script {
            param($Name, $ModId)
            $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
            return @{ File = (New-RegSnapshot -Name $Name -Mod $mod) }
        } -OnDone { param($r) Refresh-Snapshots }
    })
$UI.btnRegExport.Add_Click({
        $m = Get-SelectedMod
        Start-RvmTask -Title (T 'task.regExport') -Params @{ ModId = $(if ($m) { $m.Id } else { $null }) } -Script {
            param($ModId)
            $mod = Get-ModLibrary | Where-Object { $_.Id -eq $ModId } | Select-Object -First 1
            return @{ Dir = (Export-RegFull -Mod $mod) }
        } -OnDone { param($r) Show-Info (T 'msg.exported' $r.Dir) }
    })
$UI.btnRestorePoint.Add_Click({ Start-RestorePointFlow })
$UI.btnRegDelete.Add_Click({
        $sel = @($UI.lstSnapshots.SelectedItems)
        if (-not $sel.Count) { return }
        if (Confirm-Yes (T 'msg.deleteSnaps' $sel.Count)) { foreach ($s in $sel) { Remove-Item -LiteralPath $s.Path -Force }; Refresh-Snapshots }
    })
$UI.btnRegCompare.Add_Click({
        $sel = @($UI.lstSnapshots.SelectedItems | Sort-Object Created)
        if ($sel.Count -lt 1 -or $sel.Count -gt 2) { Show-Info (T 'msg.selectSnaps'); return }
        $p1 = $sel[0].Path; $p2 = if ($sel.Count -eq 2) { $sel[1].Path } else { $null }
        $State.RegVsCurrent = (-not $p2)
        Start-RvmTask -Title (T 'task.regCompare') -Params @{ P1 = $p1; P2 = $p2 } -Script {
            param($P1, $P2)
            return @{ Diffs = @(Compare-RegSnapshot -Path $P1 -Path2 $P2) }
        } -OnDone {
            param($r)
            $State.RegDiffs = @($r.Diffs)
            Apply-RegList
            if (-not $State.RegDiffs.Count) { Show-Info (T 'msg.regNoDiff') }
        }
    })
$UI.btnRegSelectAll.Add_Click({ $UI.gridReg.SelectAll() })
$UI.btnRegRestore.Add_Click({
        if (-not $State.RegVsCurrent) { Show-Info (T 'msg.regRestoreOnlyCurrent'); return }
        $sel = @($UI.gridReg.SelectedItems)
        if (-not $sel.Count) { Show-Info (T 'msg.regSelectFirst'); return }
        $preview = ($sel | Select-Object -First 60 | ForEach-Object { '{0,-9} {1} -> {2}' -f $_.ChangeDisplay, $_.KeyPath, $_.ValueDisplay }) -join [Environment]::NewLine
        $o = Show-RvmDialog -Title (T 'dlg.regRestore.title') -Header (T 'dlg.regRestore.header' $sel.Count) -Text $preview -OkText (T 'btn.restore')
        if ($null -eq $o) { return }
        Start-RvmTask -Title (T 'task.regRestore') -Params @{ Diffs = $sel } -Script {
            param($Diffs)
            return @{ Errors = (Restore-RegFromSnapshot -Diffs $Diffs) }
        } -OnDone { param($r) Show-Info $(if ($r.Errors) { T 'msg.regRestoreErr' $r.Errors } else { T 'msg.regRestoreOk' }) }
    })

# Protokoll-Seite
$UI.btnClearLog.Add_Click({ $UI.txtLog.Clear() })
$UI.btnOpenLogs.Add_Click({ Open-Explorer (Get-RvmDir Logs) })

# Tastatur
$Window.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'F5' -and -not $State.Task) { Start-Scan; $e.Handled = $true }
        elseif ($e.Key -eq 'Escape' -and $State.Page -ne 'library') { Show-Page 'library'; $e.Handled = $true }
        elseif ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { Show-Page 'library'; $UI.txtSearch.Focus(); $e.Handled = $true }
    })

# ================================================================ Start

$Window.Add_SourceInitialized({ Set-DarkTitleBar $Window ((Get-EffectiveTheme (Get-RvmSettings).Theme) -eq 'dark') })
$Window.Add_Loaded({
        $Timer.Start()
        Register-Translations $Window
        Apply-Translations
        $UI.imgLogo.Source = New-Bitmap $LogoPng 40
        Add-LogLine ('{0} [INFO] R.E.A.L. Mod Manager {1} (PowerShell {2}, {3})' -f (Get-Date -Format 'HH:mm:ss'), $Version.Version, $PSVersionTable.PSVersion, (Get-RvmDir Root))
        Refresh-LanguageMenu
        Refresh-Mods
        $UI.txtRegName.Text = T 'reg.defaultName'
        $st = Get-RvmSettings
        if ($null -eq $st.OnlineCovers) {
            $st.OnlineCovers = (Confirm-Yes (T 'msg.askCovers'))
            Save-RvmSettings $st
        }
        $UI.miOnlineCovers.IsChecked = [bool]$st.OnlineCovers
        Set-Busy $false
        Show-Page 'library'
        Start-Scan
        if ($st.AutoUpdate -ne $false) {
            # Nach dem Laden der Bibliothek still im Hintergrund pruefen
            $t = [System.Windows.Threading.DispatcherTimer]::new()
            $t.Interval = [TimeSpan]::FromSeconds(4)
            $t.Add_Tick({ param($s, $e) $s.Stop(); if (-not $State.BgTask) { Start-UpdateCheck } else { $s.Start() } })
            $t.Start()
        }
    })
$Window.Add_Closing({
        param($s, $e)
        if ($script:ClosingForUpdate) { return }
        if ($State.Task -and -not (Confirm-Yes (T 'msg.closeBusy'))) { $e.Cancel = $true }
    })

try {
    [void]$Window.ShowDialog()
} catch {
    Show-Fatal ("{0}`n`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
} finally {
    $Timer.Stop()
}
